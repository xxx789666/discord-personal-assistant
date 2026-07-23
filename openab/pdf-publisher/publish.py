"""pdf-publisher — 行程自動轉 PDF 並發佈到 Discord。

監看 /vault/Trips/*/itinerary.md（輪詢），內容變動時：
  1. markdown → styled HTML（CJK 字型、表格樣式）
  2. 由內部 HTTP server 提供該 HTML，請 Steel (/v1/pdf) 用真 Chrome 印成 PDF
     （Steel 不接受 data: URL，所以走這條；容器間走 compose 網路，不開 host 口）
  3. PDF 存回 vault（itinerary.pdf，Obsidian 可見）
  4. 以 travel-claudebridge 的 bot token 上傳到 Discord 頻道（CHANNEL_ID）

狀態（已發佈內容的 hash）存 /state/state.json：重啟不會重發；
首次見到的 itinerary.md 會立即發佈一次。
"""
from __future__ import annotations

import hashlib
import http.server
import json
import os
import threading
import time
from pathlib import Path

import markdown
import requests

VAULT = Path(os.environ.get("VAULT", "/vault"))
STEEL = os.environ.get("STEEL", "http://steel-api:3000")
TOKEN = os.environ["DISCORD_TOKEN_TRAVEL_CLAUDE"]
CHANNEL = os.environ["CHANNEL_ID"]
STATE_FILE = Path(os.environ.get("STATE", "/state/state.json"))
SERVE_DIR = Path("/tmp/serve")
POLL_SECONDS = 20
SELF_URL = os.environ.get("SELF_URL", "http://pdf-publisher:8000")

CSS = """
body { font-family: "Noto Sans CJK TC", "Noto Sans CJK KR", "Microsoft JhengHei", sans-serif;
       font-size: 11px; line-height: 1.55; margin: 28px; color: #1a1a1a; }
h1 { font-size: 20px; border-bottom: 3px solid #4a6fa5; padding-bottom: 6px; }
h2 { font-size: 15px; color: #2c4a73; border-left: 5px solid #4a6fa5; padding-left: 8px; margin-top: 22px; }
h3 { font-size: 12px; color: #444; }
table { border-collapse: collapse; width: 100%; margin: 8px 0; page-break-inside: avoid; }
th { background: #4a6fa5; color: white; padding: 5px 7px; text-align: left; font-size: 10.5px; }
td { border: 1px solid #c8d4e3; padding: 4px 7px; font-size: 10.5px; }
tr:nth-child(even) { background: #f2f6fb; }
blockquote { background: #fff8e6; border-left: 4px solid #e6b800; margin: 8px 0;
             padding: 6px 10px; color: #5c4a00; }
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


def md_to_pdf(md_path: Path, slug: str) -> bytes:
    body = markdown.markdown(md_path.read_text(encoding="utf-8"), extensions=["tables"])
    html = (
        '<!DOCTYPE html><html><head><meta charset="utf-8">'
        f"<style>{CSS}</style></head><body>{body}</body></html>"
    )
    (SERVE_DIR / f"{slug}.html").write_text(html, encoding="utf-8")
    r = requests.post(
        f"{STEEL}/v1/pdf",
        json={"url": f"{SELF_URL}/{slug}.html", "delay": 500},
        timeout=120,
    )
    r.raise_for_status()
    if not r.content.startswith(b"%PDF"):
        raise RuntimeError(f"steel returned non-PDF: {r.content[:120]!r}")
    return r.content


def post_to_discord(pdf: bytes, slug: str) -> None:
    r = requests.post(
        f"https://discord.com/api/v10/channels/{CHANNEL}/messages",
        headers={"Authorization": f"Bot {TOKEN}"},
        data={
            "payload_json": json.dumps(
                {"content": f"📄 行程已更新：**{slug}**（自動產生 PDF）"}
            )
        },
        files={"files[0]": (f"{slug}-itinerary.pdf", pdf, "application/pdf")},
        timeout=60,
    )
    r.raise_for_status()


def main() -> None:
    threading.Thread(target=serve_forever, daemon=True).start()
    state = load_state()
    log(f"watching {VAULT}/Trips/*/itinerary.md every {POLL_SECONDS}s")
    while True:
        for md_path in sorted(VAULT.glob("Trips/*/itinerary.md")):
            slug = md_path.parent.name
            try:
                digest = hashlib.sha256(md_path.read_bytes()).hexdigest()
            except OSError:
                continue  # mid-write; retry next poll
            if state.get(slug) == digest:
                continue
            log(f"change detected: {slug}")
            try:
                pdf = md_to_pdf(md_path, slug)
                (md_path.parent / "itinerary.pdf").write_bytes(pdf)
                post_to_discord(pdf, slug)
                state[slug] = digest
                save_state(state)
                log(f"published {slug} ({len(pdf)} bytes)")
            except Exception as e:  # noqa: BLE001 — keep watching; retry next poll
                log(f"publish failed for {slug}: {e}")
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    main()
