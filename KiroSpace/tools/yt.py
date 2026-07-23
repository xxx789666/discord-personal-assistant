# /// script
# requires-python = ">=3.10"
# dependencies = ["requests", "yt-dlp", "youtube-transcript-api>=1.0"]
# ///
"""YouTube → 逐字稿。移植自隔壁 quant 專案的 intake 鏈路（c2_intake.py）：

  1. youtube-transcript-api 抓現成字幕（繁中優先，手動字幕優於自動生成）
  2. 全部 miss（字幕被關）→ yt-dlp 下載音軌；容器有 ffmpeg 就壓成
     16kHz mono opus（長片也塞得進 Groq 上限），沒有就靠 format ladder
  3. Groq Whisper (whisper-large-v3-turbo) 轉錄 — 需要 GROQ_API_KEY 環境變數

用法（nvidia 容器用 uv；kiro 容器已全域裝好套件用 python3）：

    uv run tools/yt.py "https://www.youtube.com/watch?v=XXXX"
    python3 tools/yt.py "https://youtu.be/XXXX" --out /tmp/transcript.txt

逐字稿印到 stdout（或 --out 檔案）。失敗會印原因到 stderr 並回非零。
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import requests

_YT_URL_RE = re.compile(
    r"https?://(?:www\.|m\.)?(?:youtube\.com/watch\?v=|youtu\.be/)([\w-]{11})"
)
# 順序即優先序；zh-TW 與 zh-Hant 在 YouTube metadata 是不同代碼。
_LANGS = ["zh-TW", "zh-Hant", "zh-Hans", "zh-CN", "zh", "en"]
# Groq 免費層上限 25MB，留安全邊際。沒有 ffmpeg 可重壓，靠 yt-dlp 選小檔。
_MAX_BYTES = 24 * 1024 * 1024
_FORMAT_LADDER = ["bestaudio[abr<=64]", "bestaudio[abr<=32]", "worstaudio"]


def video_id(url: str) -> str | None:
    m = _YT_URL_RE.search(url)
    return m.group(1) if m else None


def try_captions(vid: str) -> str | None:
    from youtube_transcript_api import YouTubeTranscriptApi

    api = YouTubeTranscriptApi()
    try:
        fetched = api.fetch(vid, languages=_LANGS)
        text = " ".join(s.text for s in fetched).strip()
        if text:
            return text
    except Exception as e:  # noqa: BLE001 — fall through to any-language
        print(f"[captions] preferred langs miss: {e}", file=sys.stderr)
    try:
        available = api.list(vid)
        # 手動字幕優於自動生成
        for t in sorted(available, key=lambda t: t.is_generated):
            try:
                fetched = api.fetch(vid, languages=[t.language_code])
                text = " ".join(s.text for s in fetched).strip()
                if text:
                    print(f"[captions] any-language hit: {t.language_code}", file=sys.stderr)
                    return text
            except Exception:  # noqa: BLE001 — try next language
                continue
    except Exception as e:  # noqa: BLE001 — captions fully unavailable
        print(f"[captions] unavailable: {e}", file=sys.stderr)
    return None


def _compress(src: Path) -> Path | None:
    """有 ffmpeg 就壓成 16kHz mono opus（Whisper 內部本來就是 16kHz mono，
    對 STT 近乎無損）— 長片也能塞進 Groq 上限。做法同 quant intake。"""
    if not shutil.which("ffmpeg"):
        return None
    out = src.parent / f"{src.stem}.16k.opus"
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-i", str(src), "-ac", "1", "-ar", "16000",
             "-c:a", "libopus", "-b:a", "16k", str(out)],
            timeout=300, check=True, capture_output=True,
        )
    except Exception as e:  # noqa: BLE001 — fail-soft，退回 format ladder
        print(f"[ffmpeg] compression failed: {e}", file=sys.stderr)
        return None
    if out.exists() and out.stat().st_size:
        return out
    return None


def download_audio(vid: str, tmp: Path) -> Path | None:
    import yt_dlp

    url = f"https://www.youtube.com/watch?v={vid}"
    for fmt in _FORMAT_LADDER:
        for old in tmp.glob(f"{vid}.*"):
            old.unlink(missing_ok=True)
        opts = {
            "format": fmt,
            "outtmpl": str(tmp / f"{vid}.%(ext)s"),
            "noplaylist": True,
            "quiet": True,
            "no_warnings": True,
        }
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                ydl.download([url])
        except Exception as e:  # noqa: BLE001 — try next format
            print(f"[yt-dlp] format {fmt!r} failed: {e}", file=sys.stderr)
            continue
        files = sorted(tmp.glob(f"{vid}.*"))
        if not files:
            continue
        audio = files[0]
        size = audio.stat().st_size
        if size <= _MAX_BYTES:
            print(f"[yt-dlp] got {audio.name} ({size/1e6:.1f} MB, fmt={fmt})", file=sys.stderr)
            return audio
        # 超過上限 → 先試 ffmpeg 壓縮（kiro 容器有裝，救長片），再退小格式
        c = _compress(audio)
        if c and c.stat().st_size <= _MAX_BYTES:
            print(f"[ffmpeg] compressed to {c.stat().st_size/1e6:.1f} MB", file=sys.stderr)
            return c
        print(f"[yt-dlp] {audio.name} too big ({size/1e6:.1f} MB), trying smaller", file=sys.stderr)
    return None


def groq_stt(audio: Path) -> str:
    key = os.environ.get("GROQ_API_KEY", "").strip()
    if not key:
        raise SystemExit("GROQ_API_KEY not set — STT fallback unavailable")
    with open(audio, "rb") as f:
        r = requests.post(
            "https://api.groq.com/openai/v1/audio/transcriptions",
            headers={"Authorization": f"Bearer {key}"},
            files={"file": (audio.name, f)},
            data={"model": "whisper-large-v3-turbo", "response_format": "text"},
            timeout=300,
        )
    if not r.ok:
        raise SystemExit(f"groq STT failed: HTTP {r.status_code} {r.text[:300]}")
    return r.text.strip()


def main() -> int:
    p = argparse.ArgumentParser(description="YouTube → transcript")
    p.add_argument("url")
    p.add_argument("--out", default=None, help="write transcript to file instead of stdout")
    a = p.parse_args()

    vid = video_id(a.url)
    if not vid:
        print("not a recognizable YouTube URL", file=sys.stderr)
        return 2

    text = try_captions(vid)
    if not text:
        print("[stt] no captions — falling back to yt-dlp + Groq Whisper", file=sys.stderr)
        with tempfile.TemporaryDirectory() as td:
            audio = download_audio(vid, Path(td))
            if not audio:
                print("audio download failed or video too long for the size cap", file=sys.stderr)
                return 1
            text = groq_stt(audio)

    if not text:
        print("no transcript produced", file=sys.stderr)
        return 1
    if a.out:
        Path(a.out).write_text(text, encoding="utf-8")
        print(f"transcript ({len(text)} chars) -> {a.out}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
