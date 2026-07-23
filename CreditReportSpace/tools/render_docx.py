#!/usr/bin/env python
"""DOCX → PDF → 每頁 PNG，供目視檢查表格溢出／分頁／對齊。

依賴：LibreOffice（soffice）＋ Poppler（pdftoppm），皆為本機工具，
不上傳任何內容到外部服務。

用法：
    python tools/render_docx.py output/doc/xxx.docx
    # PDF 與 PNG 產生於 tmp/docs/render/<檔名>/page-N.png
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):
        pass

SPACE_ROOT = Path(__file__).resolve().parent.parent

SOFFICE_CANDIDATES = [
    "soffice",
    r"C:\Program Files\LibreOffice\program\soffice.exe",
    r"C:\Program Files (x86)\LibreOffice\program\soffice.exe",
    os.path.expandvars(r"%LOCALAPPDATA%\Programs\LibreOffice\program\soffice.exe"),
]


def find_soffice() -> str | None:
    for cand in SOFFICE_CANDIDATES:
        path = shutil.which(cand) or (cand if Path(cand).is_file() else None)
        if path:
            return path
    return None


def render(docx_path: Path, out_root: Path, dpi: int = 120) -> list[Path]:
    soffice = find_soffice()
    if not soffice:
        raise RuntimeError("找不到 LibreOffice（soffice），無法轉 PDF")
    pdftoppm = shutil.which("pdftoppm")
    if not pdftoppm:
        raise RuntimeError("找不到 Poppler（pdftoppm），無法轉 PNG")

    out_dir = out_root / docx_path.stem
    out_dir.mkdir(parents=True, exist_ok=True)

    subprocess.run(
        [soffice, "--headless", "--convert-to", "pdf",
         "--outdir", str(out_dir), str(docx_path)],
        check=True, capture_output=True, timeout=180,
    )
    pdf = out_dir / (docx_path.stem + ".pdf")
    if not pdf.is_file():
        raise RuntimeError(f"LibreOffice 未輸出 PDF：{pdf}")

    for old in out_dir.glob("page-*.png"):
        old.unlink()
    subprocess.run(
        [pdftoppm, "-png", "-r", str(dpi), str(pdf), str(out_dir / "page")],
        check=True, capture_output=True, timeout=120,
    )
    pages = sorted(out_dir.glob("page-*.png"))
    if not pages:
        raise RuntimeError("pdftoppm 未輸出任何頁面")
    return pages


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="渲染 DOCX 每頁為 PNG 供目視檢查")
    ap.add_argument("docx", help="DOCX 路徑")
    ap.add_argument("--dpi", type=int, default=120)
    ap.add_argument("--outdir", default=str(SPACE_ROOT / "tmp" / "docs" / "render"))
    args = ap.parse_args(argv)

    docx_path = Path(args.docx)
    if not docx_path.is_file():
        print(f"[錯誤] 找不到 {docx_path}", file=sys.stderr)
        return 2
    try:
        pages = render(docx_path, Path(args.outdir), args.dpi)
    except (RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        print(f"[錯誤] {e}", file=sys.stderr)
        return 1
    for p in pages:
        print(p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
