#!/usr/bin/env python
"""CLI：徵信案件資料夾 → 整份徵信報告 DOCX（半自動骨架，v1）。

流程：
  1. 走訪案件資料夾、分類每個檔案，印清點清單（類型/歸屬/掃描/加密）。
  2. 讀入已抽取的段落 JSON（--sections 目錄；由 LLM 抽取層產生），
     用空白模板填出整份 DOCX。
  3. 印缺件與 needs_review 清單，並標明哪些段落屬 v2 尚未建。

抽取層（讀 PDF/影像 → 段落 JSON）＝ LLM（本機由你、雲端由 Codex）。
本 CLI 負責分類、清點、填格、缺件回報——不做數值抽取。

用法：
  python tools/gen_full_report.py <案件資料夾> --sections <段落JSON目錄> \
      -o output/doc/<案名>_徵信報告.docx
  python tools/gen_full_report.py <案件資料夾>          # 只清點、不產檔
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):
        pass

sys.path.insert(0, str(Path(__file__).resolve().parent))

from credit_report.template_filler import fill_report  # noqa: E402
from intake.classifier import classify_folder  # noqa: E402

SPACE_ROOT = Path(__file__).resolve().parent.parent

# 檔案類型 → (報告段落, 版本)
TYPE_SECTION = {
    "jcic": ("陸 金融借款（＋捌信用卡）", "v1"),
    "income_mgmt": ("肆一 損益表", "v1"),
    "income_settlement": ("肆一 損益表", "v1"),
    "id": ("捌 保證人基本欄", "v1"),
    "tax401": ("肆二 401 表", "v1"),
    "balancesheet": ("肆三 資產負債表", "v1"),
    "unknown": ("（無法辨識）", "-"),
}

# 段落 JSON 檔名 → fill_report 段鍵
SECTION_FILES = {
    "luduan.json": "luduan",
    "income.json": "income",
    "tax401.json": "tax401",
    "balancesheet.json": "balancesheet",
    "guarantor.json": "guarantor",
}


def print_inventory(items):
    print(f"\n=== 檔案清點（{len(items)} 檔）===")
    by_type = {}
    for it in items:
        by_type.setdefault(it["type"], []).append(it)
    for t, group in by_type.items():
        sect, ver = TYPE_SECTION.get(t, ("?", "?"))
        print(f"\n▶ {t}  →  {sect}  [{ver}]  ({len(group)} 檔)")
        for it in group:
            flags = []
            if it["encrypted"]:
                flags.append("加密")
            if it["scanned"]:
                flags.append("掃描")
            tag = ("  ⚠" + "/".join(flags)) if flags else ""
            ent = it.get("entity") or "?"
            per = it.get("period") or ""
            print(f"    - [{it['subdir']}] {it['name']}  歸屬:{ent} {per}{tag}")


def summarize_coverage(items):
    present = {it["type"] for it in items}
    print("\n=== v1 段落覆蓋 ===")
    checks = [
        ("陸 金融借款", "jcic" in present),
        ("肆一 損益表", bool(present & {"income_mgmt", "income_settlement"})),
        ("肆二 401 表", "tax401" in present),
        ("肆三 資產負債表", "balancesheet" in present),
        ("捌 保證人基本欄", "id" in present),
    ]
    for name, ok in checks:
        print(f"    {'✔' if ok else '✘'} {name}：{'有來源' if ok else '無來源檔'}")
    v2 = present & {"balancesheet", "tax401"}
    if v2:
        names = [TYPE_SECTION[t][0] for t in v2]
        print("\n=== v2 尚未建（本次留空）===")
        for n in names:
            print(f"    · {n}")


def load_sections(sections_dir):
    d = Path(sections_dir)
    sections = {}
    for fname, key in SECTION_FILES.items():
        fp = d / fname
        if fp.exists():
            sections[key] = json.loads(fp.read_text(encoding="utf-8"))
    return sections


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("case_folder", nargs="?", help="徵信案件資料夾（一次性模式）")
    ap.add_argument("--case", help="案件目錄（含 intake/ 與 sections/）；逐次累積模式，"
                                   "自動推導路徑，供 Discord 手機端每次收檔重填")
    ap.add_argument("--sections", help="段落 JSON 目錄（一次性模式）")
    ap.add_argument("-o", "--output", help="輸出 DOCX 路徑")
    ap.add_argument("--template", help="空白模板路徑（預設 templates/credit_report_blank.docx）")
    args = ap.parse_args(argv)

    incremental = bool(args.case)
    if incremental:
        case = Path(args.case)
        folder = case / "intake"
        sections_dir = case / "sections"
        default_out = case / f"{case.name}_徵信報告.docx"
    elif args.case_folder:
        folder = Path(args.case_folder)
        sections_dir = Path(args.sections) if args.sections else None
        default_out = SPACE_ROOT / "output" / "doc" / f"{folder.name}_徵信報告.docx"
    else:
        print("[錯誤] 需提供 案件資料夾 或 --case 目錄", file=sys.stderr)
        return 2

    if not folder.is_dir():
        print(f"[錯誤] 找不到資料夾：{folder}", file=sys.stderr)
        return 2

    items = classify_folder(folder)
    print_inventory(items)
    summarize_coverage(items)

    unknowns = [it for it in items if it["type"] == "unknown"]
    if unknowns:
        print("\n[警告] 無法辨識的檔案：")
        for it in unknowns:
            print(f"    - {it['name']}")

    if sections_dir is None:
        print("\n[結果] 只清點（未給 --sections，不產檔）")
        return 0

    sections = load_sections(sections_dir)
    if not sections:
        if incremental:
            print("\n[結果] 尚無段落資料（sections/ 空），本次只清點")
            return 0
        print(f"[錯誤] --sections {sections_dir} 內沒有可用段落 JSON", file=sys.stderr)
        return 2

    out = Path(args.output) if args.output else default_out
    out.parent.mkdir(parents=True, exist_ok=True)
    _, review = fill_report(sections, out, template=args.template)

    print(f"\n[結果] 已產生 {out}")
    print(f"    填入段落：{', '.join(sections.keys())}")
    if review:
        print("\n=== needs_review / 缺件（交付前逐條確認）===")
        for r in review:
            print(f"    · {r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
