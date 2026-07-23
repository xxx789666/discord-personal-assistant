#!/usr/bin/env python
"""CLI：結構化 JSON → 金融借款 WORD 報告（DOCX）。

用法：
    python tools/gen_report.py fixtures/sample_report.json \
        -o output/doc/金融借款報告.docx
    python tools/gen_report.py input.json --check-only   # 只驗證不產檔

輸出約定：正式產出放 output/doc/，中間檔放 tmp/docs/。
DOCX 以暫存檔寫入後原子替換，不會留下半成品。
exit code：0 成功（可能帶警告）、1 驗證錯誤、2 輸入／參數錯誤、3 產檔失敗。
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):
        pass

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_report import build_docx, validate  # noqa: E402

SPACE_ROOT = Path(__file__).resolve().parent.parent


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("input", help="結構化輸入 JSON 路徑")
    ap.add_argument("-o", "--output",
                    help="輸出 DOCX 路徑（預設 output/doc/<輸入檔名>.docx）")
    ap.add_argument("--check-only", action="store_true", help="只驗證，不產生 DOCX")
    args = ap.parse_args(argv)

    src = Path(args.input)
    try:
        data = json.loads(src.read_text(encoding="utf-8"))
    except FileNotFoundError:
        print(f"[錯誤] 找不到輸入檔：{src}", file=sys.stderr)
        return 2
    except OSError as e:
        print(f"[錯誤] 讀取輸入檔失敗：{e}", file=sys.stderr)
        return 2
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        print(f"[錯誤] JSON 解析失敗：{e}", file=sys.stderr)
        return 2

    res = validate(data)
    for w in res.warnings:
        print(f"[警告] {w}")
    if not res.ok:
        for e in res.errors:
            print(f"[錯誤] {e}", file=sys.stderr)
        print(f"[結果] 驗證失敗（{len(res.errors)} 個錯誤），未產生檔案", file=sys.stderr)
        return 1

    if args.check_only:
        print("[結果] 驗證通過" + (f"，{len(res.warnings)} 個警告待確認" if res.warnings else ""))
        return 0

    out = Path(args.output) if args.output else SPACE_ROOT / "output" / "doc" / (src.stem + ".docx")
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        build_docx(data, out)
    except OSError as e:
        print(f"[錯誤] 產檔失敗（檔案系統）：{e}", file=sys.stderr)
        return 3
    except Exception as e:  # docx 生成內部錯誤也要可控，不噴 traceback
        print(f"[錯誤] 產檔失敗：{type(e).__name__}: {e}", file=sys.stderr)
        return 3
    print(f"[結果] 已產生 {out}")
    if res.warnings:
        print(f"[提醒] 有 {len(res.warnings)} 個警告，請人工確認後再交付")
    return 0


if __name__ == "__main__":
    sys.exit(main())
