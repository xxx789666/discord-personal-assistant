"""Markdown watcher — 自動轉 PDF 並發佈到 Discord。

預設監看 /vault/Trips/*/itinerary.md（輪詢），內容變動時：
  1. markdown → styled HTML（CJK 字型、表格樣式）
  2. 由內部 HTTP server 提供該 HTML，請 Steel (/v1/pdf) 用真 Chrome 印成 PDF
     （Steel 不接受 data: URL，所以走這條；容器間走 compose 網路，不開 host 口）
  3. PDF 存回 vault（itinerary.pdf，Obsidian 可見）
  4. 以指定的 bot token 上傳到 Discord 頻道（CHANNEL_ID）

狀態（已發佈內容的 hash）存 /state/state.json：重啟不會重發；
首次見到的 Markdown 會立即發佈一次。FILE_GLOB、PDF_SUBDIR、訊息與檔名
都可由環境變數覆寫，同一個 image 因此也能服務 URL intake。
"""
from __future__ import annotations

import hashlib
import http.server
import json
import os
import re
import threading
import time
from pathlib import Path

import markdown
import requests

VAULT = Path(os.environ.get("VAULT", "/vault"))
STEEL = os.environ.get("STEEL", "http://steel-api:3000")
TOKEN_ENV = os.environ.get("DISCORD_TOKEN_VAR", "DISCORD_TOKEN_TRAVEL_CLAUDE")
TOKEN = os.environ[TOKEN_ENV]
CHANNEL = os.environ["CHANNEL_ID"]
CLOUDFLARE_ACCOUNT_ID = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "").strip()
CLOUDFLARE_API_TOKEN = os.environ.get("CLOUDFLARE_API_TOKEN", "").strip()
ALLOW_STEEL_PDF_FALLBACK = (
    os.environ.get("ALLOW_STEEL_PDF_FALLBACK", "true").lower() == "true"
)
STATE_FILE = Path(os.environ.get("STATE", "/state/state.json"))
SERVE_DIR = Path("/tmp/serve")
FILE_GLOB = os.environ.get("FILE_GLOB", "Trips/*/itinerary.md")
PDF_SUBDIR = os.environ.get("PDF_SUBDIR", "").strip("/\\")
PDF_FILENAME_TEMPLATE = os.environ.get("PDF_FILENAME_TEMPLATE", "{stem}.pdf")
DISCORD_FILENAME_TEMPLATE = os.environ.get(
    "DISCORD_FILENAME_TEMPLATE", "{slug}-itinerary.pdf"
)
MESSAGE_TEMPLATE = os.environ.get(
    "MESSAGE_TEMPLATE", "📄 行程已更新：**{slug}**（自動產生 PDF）"
)
POLL_SECONDS = int(os.environ.get("POLL_SECONDS", "20"))
RENDER_VERSION = os.environ.get("RENDER_VERSION", "")
SELF_URL = os.environ.get("SELF_URL", "http://pdf-publisher:8000")

CSS = """
@page {
  size: A4;
  margin: 16mm 14mm 18mm;
  @bottom-center { content: counter(page) " / " counter(pages); color: #777; font-size: 9px; }
}
body { font-family: "Noto Sans CJK TC", "Noto Sans CJK KR", "Microsoft JhengHei", sans-serif;
       font-size: 11px; line-height: 1.55; margin: 0; color: #1a1a1a; }
h1 { font-size: 20px; border-bottom: 3px solid #4a6fa5; padding-bottom: 6px; }
h2 { font-size: 15px; color: #2c4a73; border-left: 5px solid #4a6fa5; padding-left: 8px; margin-top: 22px; }
h3 { font-size: 12px; color: #444; }
h1, h2, h3 { break-after: avoid-page; }
table { border-collapse: collapse; width: 100%; margin: 8px 0; page-break-inside: avoid; }
th { background: #4a6fa5; color: white; padding: 5px 7px; text-align: left; font-size: 10.5px; }
td { border: 1px solid #c8d4e3; padding: 4px 7px; font-size: 10.5px; }
tr:nth-child(even) { background: #f2f6fb; }
blockquote { background: #fff8e6; border-left: 4px solid #e6b800; margin: 8px 0;
             padding: 6px 10px; color: #5c4a00; }
blockquote, pre { break-inside: avoid; }
pre { white-space: pre-wrap; overflow-wrap: anywhere; background: #f6f8fa; padding: 8px; }
code { overflow-wrap: anywhere; }
li { margin: 2px 0; }
"""


def log(msg: str) -> None:
    print(time.strftime("[%Y-%m-%d %H:%M:%S] ") + msg, flush=True)


def load_state() -> dict:
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:  # noqa: BLE001 — missing/corrupt state → start fresh
        return {}


def save_state(state: dict) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state))


def serve_forever() -> None:
    SERVE_DIR.mkdir(parents=True, exist_ok=True)
    handler = lambda *a, **kw: http.server.SimpleHTTPRequestHandler(  # noqa: E731
        *a, directory=str(SERVE_DIR), **kw
    )
    http.server.ThreadingHTTPServer(("0.0.0.0", 8000), handler).serve_forever()


def markdown_body(md_path: Path) -> str:
    """Read Markdown and omit YAML frontmatter from the rendered PDF."""
    text = md_path.read_text(encoding="utf-8")
    if text.startswith("---\n"):
        _, marker, body = text.partition("\n---\n")
        if marker:
            return body.lstrip()
    return text


def document_title(md_path: Path) -> str:
    match = re.search(r"^#\s+(.+?)\s*$", markdown_body(md_path), re.MULTILINE)
    return match.group(1).strip() if match else md_path.stem


def output_path(md_path: Path) -> Path:
    values = {"stem": md_path.stem, "name": md_path.name, "parent": md_path.parent.name}
    filename = PDF_FILENAME_TEMPLATE.format(**values)
    parent = VAULT / PDF_SUBDIR if PDF_SUBDIR else md_path.parent
    return parent / filename


def kitesurf_pdf(html: str) -> bytes:
    """Render HTML remotely with Cloudflare KiteSurf (no local Chromium load)."""
    if not CLOUDFLARE_ACCOUNT_ID or not CLOUDFLARE_API_TOKEN:
        raise RuntimeError("KiteSurf credentials are not configured")
    endpoint = (
        "https://api.cloudflare.com/client/v4/accounts/"
        f"{CLOUDFLARE_ACCOUNT_ID}/browser-run/pdf?browser=kitesurf"
    )
    response = requests.post(
        endpoint,
        headers={
            "Authorization": f"Bearer {CLOUDFLARE_API_TOKEN}",
            "Content-Type": "application/json",
        },
        json={"html": html},
        timeout=120,
    )
    response.raise_for_status()
    if not response.content.startswith(b"%PDF"):
        raise RuntimeError(f"KiteSurf returned non-PDF: {response.content[:120]!r}")
    return response.content


def steel_pdf(html: str, serve_id: str) -> bytes:
    (SERVE_DIR / f"{serve_id}.html").write_text(html, encoding="utf-8")
    response = requests.post(
        f"{STEEL}/v1/pdf",
        json={"url": f"{SELF_URL}/{serve_id}.html", "delay": 500},
        timeout=120,
    )
    response.raise_for_status()
    if not response.content.startswith(b"%PDF"):
        raise RuntimeError(f"steel returned non-PDF: {response.content[:120]!r}")
    return response.content


def md_to_pdf(md_path: Path, serve_id: str) -> bytes:
    body = markdown.markdown(markdown_body(md_path), extensions=["tables", "fenced_code"])
    html = (
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        f"<style>{CSS}</style></head><body>{body}</body></html>"
    )
    try:
        pdf = kitesurf_pdf(html)
        log(f"rendered {md_path.name} with Cloudflare KiteSurf")
        return pdf
    except Exception as exc:  # noqa: BLE001 - optional local failover
        if not ALLOW_STEEL_PDF_FALLBACK:
            raise
        log(f"KiteSurf PDF unavailable ({exc}); falling back to local Steel")
        return steel_pdf(html, serve_id)


def post_to_discord(pdf: bytes, md_path: Path, slug: str) -> None:
    title = document_title(md_path)
    values = {
        "slug": slug,
        "stem": md_path.stem,
        "title": title,
        "filename": md_path.name,
    }
    r = requests.post(
        f"https://discord.com/api/v10/channels/{CHANNEL}/messages",
        headers={"Authorization": f"Bot {TOKEN}"},
        data={
            "payload_json": json.dumps(
                {"content": MESSAGE_TEMPLATE.format(**values)[:1900]}
            )
        },
        files={
            "files[0]": (
                DISCORD_FILENAME_TEMPLATE.format(**values),
                pdf,
                "application/pdf",
            )
        },
        timeout=60,
    )
    r.raise_for_status()


def main() -> None:
    threading.Thread(target=serve_forever, daemon=True).start()
    state = load_state()
    log(f"watching {VAULT}/{FILE_GLOB} every {POLL_SECONDS}s")
    while True:
        for md_path in sorted(VAULT.glob(FILE_GLOB)):
            relative = md_path.relative_to(VAULT).as_posix()
            state_key = relative
            slug = md_path.parent.name if md_path.name == "itinerary.md" else md_path.stem
            serve_id = hashlib.sha256(relative.encode("utf-8")).hexdigest()[:20]
            try:
                digest = hashlib.sha256(
                    md_path.read_bytes() + RENDER_VERSION.encode("utf-8")
                ).hexdigest()
            except OSError:
                continue  # mid-write; retry next poll
            # Backward compatibility: the original travel-only publisher keyed
            # state by trip slug. Avoid re-publishing every existing itinerary
            # the first time this generalized image is deployed.
            legacy_digest = state.get(slug) if md_path.name == "itinerary.md" else None
            if state.get(state_key) == digest or legacy_digest == digest:
                continue
            log(f"change detected: {relative}")
            try:
                pdf = md_to_pdf(md_path, serve_id)
                pdf_path = output_path(md_path)
                pdf_path.parent.mkdir(parents=True, exist_ok=True)
                pdf_path.write_bytes(pdf)
                post_to_discord(pdf, md_path, slug)
                state[state_key] = digest
                save_state(state)
                log(f"published {relative} ({len(pdf)} bytes) -> {pdf_path}")
            except Exception as e:  # noqa: BLE001 — keep watching; retry next poll
                log(f"publish failed for {slug}: {e}")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
