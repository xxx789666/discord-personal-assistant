"""確定性 DOCX 產製：結構化 JSON → 比照 WORD 報告範例版型的金融借款報告。

版型規則（自範例目視歸納）：
- A4 直式，頁首左「伍、金融借款：(仟元)」粗體、右「資料日期-YYYY年M月底」。
- 每個 entity 一段：「◎名稱」標題 + 一張格線表；主債／從債群組堆疊在同一張表。
- simple 6 欄；extended 9 欄（多兩期前次餘額與增減情形）。
- 同群組內相鄰列同銀行 → 銀行儲存格垂直合併；主/從欄整群組垂直合併。
- 合計列：前三欄水平合併顯示「合計」，整列灰底。
- 已結清／轉貸沖轉列：整列刪除線。增減欄負數渲染為 (絕對值)。
- needs_review 列：淡黃底，備註尾加「（待人工確認）」。
- 表下「說明：」自動編號；最後一個 entity 後補資料來源句。
"""

from __future__ import annotations

import os
import uuid
from pathlib import Path

from docx import Document
from docx.enum.table import WD_ALIGN_VERTICAL
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_TAB_ALIGNMENT
from docx.oxml.ns import qn
from docx.shared import Mm, Pt
from docx.oxml import OxmlElement

from .model import DEFAULT_SECTION_TITLE, DEFAULT_SOURCE_NOTE, fmt_amount

CJK_FONT = "標楷體"

# 版面（mm）
PAGE_W, PAGE_H, MARGIN = 210, 297, 15
USABLE_W = PAGE_W - 2 * MARGIN  # 180

SIMPLE_HEADERS = ["主/從債", "往來銀行", "項目", "借款金額", "借款餘額", "備註"]
SIMPLE_WIDTHS = [16, 30, 22, 30, 30, 52]
SIMPLE_FONT_PT = 12

EXTENDED_WIDTHS = [12, 24, 13, 19, 19, 19, 19, 20, 35]
EXTENDED_FONT_PT = 10

GRAY = "D9D9D9"
REVIEW_YELLOW = "FFF2CC"


def _set_run_font(run, size_pt, *, bold=False, strike=False):
    run.font.name = "Times New Roman"
    run.font.size = Pt(size_pt)
    run.font.bold = bold
    run.font.strike = strike
    rpr = run._element.get_or_add_rPr()
    rfonts = rpr.find(qn("w:rFonts"))
    if rfonts is None:
        rfonts = OxmlElement("w:rFonts")
        rpr.append(rfonts)
    rfonts.set(qn("w:eastAsia"), CJK_FONT)


def _shade(cell, fill):
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:fill"), fill)
    cell._tc.get_or_add_tcPr().append(shd)


def _fill_cell(cell, text, size_pt, *, bold=False, strike=False,
               align=WD_ALIGN_PARAGRAPH.CENTER):
    cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
    p = cell.paragraphs[0]
    p.alignment = align
    p.paragraph_format.space_before = Pt(1)
    p.paragraph_format.space_after = Pt(1)
    lines = str(text).split("\n")
    for line_no, line in enumerate(lines):
        run = p.add_run(line)
        _set_run_font(run, size_pt, bold=bold, strike=strike)
        if line_no < len(lines) - 1:
            run.add_break()


def _set_no_wrap(cell):
    """數字儲存格禁止折行，避免「(10,700)」等括號金額被攔腰換行。"""
    tcpr = cell._tc.get_or_add_tcPr()
    if tcpr.find(qn("w:noWrap")) is None:
        tcpr.append(OxmlElement("w:noWrap"))


def _set_row_cant_split(row):
    trpr = row._tr.get_or_add_trPr()
    el = OxmlElement("w:cantSplit")
    trpr.append(el)


def _mark_header_row(row):
    trpr = row._tr.get_or_add_trPr()
    el = OxmlElement("w:tblHeader")
    trpr.append(el)


def _row_values(row, layout, prev_count=2):
    """一列 → 各欄字串（不含主/從欄）。"""
    note = row.get("note", "")
    if row.get("needs_review"):
        note = (note + "（待人工確認）") if note else "（待人工確認）"
    vals = [
        row["bank"],
        row["item"],
        fmt_amount(row.get("loan_amount")),
        fmt_amount(row.get("balance")),
    ]
    if layout == "extended":
        pb = row.get("prev_balances") or [None] * prev_count
        vals.extend(fmt_amount(v) for v in pb)
        vals.append(fmt_amount(row.get("change"), change=True))
    vals.append(note)
    return vals


def _total_values(total, layout):
    vals = [
        fmt_amount(total.get("loan_amount")),
        fmt_amount(total.get("balance")),
    ]
    if layout == "extended":
        pb = total.get("prev_balances") or [None, None]
        vals.extend(fmt_amount(v) for v in pb)
        vals.append(fmt_amount(total.get("change"), change=True))
    vals.append("")
    return vals


def _build_entity_table(doc, ent):
    layout = ent["layout"]
    if layout == "simple":
        headers, widths, font_pt = SIMPLE_HEADERS, SIMPLE_WIDTHS, SIMPLE_FONT_PT
    else:
        l1, l2 = ent["prev_labels"]
        headers = ["主/從", "往來銀行", "項目", "借款金額", "餘額",
                   f"前次餘額\n{l1}", f"前次餘額\n{l2}", "增減情形", "備註"]
        widths, font_pt = EXTENDED_WIDTHS, EXTENDED_FONT_PT
    ncols = len(headers)

    table = doc.add_table(rows=1, cols=ncols)
    table.style = "Table Grid"
    table.autofit = False
    table.alignment = 1  # center

    hdr = table.rows[0]
    _mark_header_row(hdr)
    _set_row_cant_split(hdr)
    for i, text in enumerate(headers):
        _fill_cell(hdr.cells[i], text, font_pt, bold=True)

    for group in ent["groups"]:
        rows = group["rows"]
        first_data_idx = len(table.rows)
        for row in rows:
            tr = table.add_row()
            _set_row_cant_split(tr)
            strike = bool(row.get("struck"))
            # 主/從欄逐列重複：垂直合併儲存格跨頁時續頁會整段空白，
            # 逐列標示才能保證任何分頁位置都看得到角色。
            _fill_cell(tr.cells[0], group["role"], font_pt)
            _set_no_wrap(tr.cells[0])
            vals = _row_values(row, layout)
            for ci, val in enumerate(vals, start=1):
                is_note = ci == ncols - 1
                _fill_cell(
                    tr.cells[ci], val, font_pt, strike=strike,
                    align=WD_ALIGN_PARAGRAPH.LEFT if is_note else WD_ALIGN_PARAGRAPH.CENTER,
                )
                if ci >= 3 and not is_note:
                    _set_no_wrap(tr.cells[ci])
            if row.get("needs_review"):
                for c in tr.cells:
                    _shade(c, REVIEW_YELLOW)

        # 同銀行相鄰列 → 銀行儲存格垂直合併
        run_start = 0
        for i in range(1, len(rows) + 1):
            same = (
                i < len(rows)
                and rows[i]["bank"] == rows[run_start]["bank"]
                and bool(rows[i].get("struck")) == bool(rows[run_start].get("struck"))
            )
            if not same:
                if i - run_start > 1:
                    top = table.rows[first_data_idx + run_start].cells[1]
                    bot = table.rows[first_data_idx + i - 1].cells[1]
                    merged = top.merge(bot)
                    merged.text = ""
                    _fill_cell(merged, rows[run_start]["bank"], font_pt,
                               strike=bool(rows[run_start].get("struck")))
                run_start = i

        total = group.get("total")
        if total is not None:
            tr = table.add_row()
            _set_row_cant_split(tr)
            label_cell = tr.cells[0].merge(tr.cells[2])
            _fill_cell(label_cell, "合計", font_pt, bold=True)
            total_vals = _total_values(total, layout)
            for off, val in enumerate(total_vals):
                _fill_cell(tr.cells[3 + off], val, font_pt, bold=True)
                if off < len(total_vals) - 1:
                    _set_no_wrap(tr.cells[3 + off])
            seen = set()
            for c in tr.cells:
                if id(c._tc) not in seen:
                    seen.add(id(c._tc))
                    _shade(c, GRAY)

    for r in table.rows:
        for i, c in enumerate(r.cells):
            c.width = Mm(widths[min(i, len(widths) - 1)])
    return table


def _add_notes(doc, notes, source_note=None):
    items = list(notes or [])
    if source_note:
        items.append(source_note)
    if not items:
        return
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(4)
    p.paragraph_format.keep_with_next = True
    run = p.add_run("說明：")
    _set_run_font(run, 12, bold=False)
    for i, text in enumerate(items, start=1):
        np = doc.add_paragraph()
        np.paragraph_format.left_indent = Mm(12)
        np.paragraph_format.space_after = Pt(0)
        np.paragraph_format.keep_together = True
        if i < len(items):
            np.paragraph_format.keep_with_next = True
        r = np.add_run(f"{i}. {text}")
        _set_run_font(r, 12)


def build_docx(data, out_path):
    """已通過 validate() 的資料 → DOCX。回傳 out_path。

    輸出採「暫存檔 + 原子替換」：先寫入同目錄的 .tmp 檔，成功後才
    os.replace 到目標路徑，中途失敗不會留下半成品或毀掉舊檔。
    """
    doc = Document()
    section = doc.sections[0]
    section.page_width = Mm(PAGE_W)
    section.page_height = Mm(PAGE_H)
    for attr in ("left_margin", "right_margin"):
        setattr(section, attr, Mm(MARGIN))
    for attr in ("top_margin", "bottom_margin"):
        setattr(section, attr, Mm(18))

    meta = data["meta"]
    title = meta.get("section_title", DEFAULT_SECTION_TITLE)
    head = doc.add_paragraph()
    head.paragraph_format.tab_stops.add_tab_stop(Mm(USABLE_W), WD_TAB_ALIGNMENT.RIGHT)
    r1 = head.add_run(title)
    _set_run_font(r1, 16, bold=True)
    r2 = head.add_run("\t" + meta["data_date"])
    _set_run_font(r2, 14, bold=True)

    entities = data["entities"]
    source_note = meta.get("source_note", DEFAULT_SOURCE_NOTE)
    for ei, ent in enumerate(entities):
        hp = doc.add_paragraph()
        hp.paragraph_format.space_before = Pt(8)
        hr = hp.add_run(f"◎{ent['name']}")
        _set_run_font(hr, 14, bold=True)
        _build_entity_table(doc, ent)
        _add_notes(doc, ent.get("notes"),
                   source_note if ei == len(entities) - 1 else None)

    out = Path(out_path)
    tmp = out.with_name(f".{out.name}.{uuid.uuid4().hex}.tmp")
    try:
        doc.save(str(tmp))
        os.replace(tmp, out)
    finally:
        if tmp.exists():
            try:
                tmp.unlink()
            except OSError:
                pass
    return out_path
