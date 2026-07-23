# /// script
# requires-python = ">=3.10"
# dependencies = ["requests"]
# ///
"""Steel Browser helper — web access without curl (the codex image has none).

Run via uv (preinstalled in the container; it fetches python + deps itself):

    uv run tools/web.py scrape https://example.com
    uv run tools/web.py scrape https://example.com --delay 2000
    uv run tools/web.py screenshot https://example.com /tmp/shot.png
    uv run tools/web.py pdf https://example.com /tmp/page.pdf
    uv run tools/web.py session start|status|release

Steel API lives at http://steel-api:3000 on the compose network (STEEL_SETUP.md).
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import requests

# Windows host console 是 cp950，印韓文/特殊字元會炸；容器內無影響
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# 容器內走 compose DNS；host 端測試可用 STEEL_API_BASE=http://localhost:3000 覆寫
BASE = os.environ.get("STEEL_API_BASE", "http://steel-api:3000")
# 搜尋走自架 SearXNG（搜尋引擎的結果頁會擋 headless，不要用 scrape 搜尋）
SEARX = os.environ.get("SEARX_BASE", "http://searxng:8080")
TIMEOUT = 90


def search(query: str, limit: int) -> int:
    r = requests.get(
        f"{SEARX}/search",
        params={"q": query, "format": "json"},
        timeout=TIMEOUT,
    )
    if not r.ok:
        print(f"search failed: HTTP {r.status_code} {r.text[:300]}", file=sys.stderr)
        return 1
    results = r.json().get("results") or []
    if not results:
        print("(no results)")
        return 0
    for i, item in enumerate(results[:limit], 1):
        print(f"{i}. {item.get('title', '')}")
        print(f"   {item.get('url', '')}")
        snippet = (item.get("content") or "").strip()
        if snippet:
            print(f"   {snippet[:200]}")
    return 0


def scrape(url: str, delay: int | None, max_chars: int) -> int:
    body: dict = {"url": url, "format": ["markdown"]}
    if delay:
        body["delay"] = delay
    r = requests.post(f"{BASE}/v1/scrape", json=body, timeout=TIMEOUT)
    if not r.ok:
        print(f"scrape failed: HTTP {r.status_code} {r.text[:300]}", file=sys.stderr)
        return 1
    md = (r.json().get("content") or {}).get("markdown") or ""
    if not md.strip():
        print("(empty markdown — page may need --delay or be blocked)")
        return 0
    # 截斷保護：完整頁面動輒數萬字元，連抓幾頁就會撐爆模型 context
    # （NIM 端的症狀是 EngineCore error / -32603，2026-06-12 實測）。
    if len(md) > max_chars:
        print(md[:max_chars])
        print(f"\n[...truncated {len(md) - max_chars} of {len(md)} chars — "
              f"need more? re-run with --max-chars {min(len(md), max_chars * 3)}]")
    else:
        print(md)
    return 0


def binary(kind: str, url: str, out: str) -> int:
    r = requests.post(f"{BASE}/v1/{kind}", json={"url": url}, timeout=TIMEOUT)
    if not r.ok:
        print(f"{kind} failed: HTTP {r.status_code} {r.text[:300]}", file=sys.stderr)
        return 1
    with open(out, "wb") as f:
        f.write(r.content)
    print(f"saved {len(r.content)} bytes -> {out}")
    return 0


def session(action: str) -> int:
    if action == "status":
        r = requests.get(f"{BASE}/v1/sessions", timeout=TIMEOUT)
    elif action == "start":
        r = requests.post(f"{BASE}/v1/sessions", json={}, timeout=TIMEOUT)
    elif action == "release":
        r = requests.post(f"{BASE}/v1/sessions/release", json={}, timeout=TIMEOUT)
    else:
        print(f"unknown session action: {action}", file=sys.stderr)
        return 2
    print(json.dumps(r.json(), ensure_ascii=False, indent=2)[:2000])
    return 0 if r.ok else 1


def main() -> int:
    p = argparse.ArgumentParser(description="Steel Browser helper")
    sub = p.add_subparsers(dest="cmd", required=True)

    se = sub.add_parser("search")
    se.add_argument("query")
    se.add_argument("--limit", type=int, default=8, help="max results to print")

    sp = sub.add_parser("scrape")
    sp.add_argument("url")
    sp.add_argument("--delay", type=int, default=None, help="ms to wait for JS content")
    sp.add_argument("--max-chars", type=int, default=8000,
                    help="truncate markdown output (default 8000; keeps model context small)")

    for kind in ("screenshot", "pdf"):
        bp = sub.add_parser(kind)
        bp.add_argument("url")
        bp.add_argument("out")

    ss = sub.add_parser("session")
    ss.add_argument("action", choices=["start", "status", "release"])

    a = p.parse_args()
    if a.cmd == "search":
        return search(a.query, a.limit)
    if a.cmd == "scrape":
        return scrape(a.url, a.delay, a.max_chars)
    if a.cmd in ("screenshot", "pdf"):
        return binary(a.cmd, a.url, a.out)
    return session(a.action)


if __name__ == "__main__":
    raise SystemExit(main())
