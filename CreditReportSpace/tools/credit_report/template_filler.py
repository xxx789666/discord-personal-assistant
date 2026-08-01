"""填格引擎：空白模板 + 各段結構化資料 → 整份徵信報告 DOCX。

設計（見 docs/specs/2026-07-31-full-report-generator-design.md）：
- 8 個樣板段落沿用模板既有版面（版面貼近手工範例＝自動達成）。
- 陸段（金融借款）列數隨銀行/人數變動，故以「陸、金融借款」標題為錨，
  刪除模板佔位、動態產出每個 entity 的「◎標題＋借款表＋說明」插回原位。
- needs_review 列淡黃底；輸出採暫存檔 + 原子替換。

本模組只負責「填」，不做抽取；各段 JSON 由對應 extractor 產生。
"""

from __future__ import annotations

import os
import uuid
from pathlib import Path

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml.ns import qn
from docx.shared import Mm, Pt

from .docx_builder import (
    GRAY,
    REVIEW_YELLOW,
    SIMPLE_FONT_PT,
    SIMPLE_WIDTHS,
    _fill_cell,
    _mark_header_row,
    _row_values,
    _set_no_wrap,
    _set_row_cant_split,
    _set_run_font,
    _shade,
    _total_values,
)

SPACE_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_TEMPLATE = SPACE_ROOT / "templates" / "credit_report_blank.docx"

# 陸段標題錨與下一段標題（用於定位並清除模板佔位）
LUDUAN_ANCHOR = "陸、金融借款"
LUDUAN_END = "柒、"


def _iter_body_children(doc):
    return list(doc.element.body.iterchildren())


def _para_text(el, doc):
    if el.tag != qn("w:p"):
        return None
    from docx.text.paragraph import Paragraph
    return Paragraph(el, doc).text


def _find_anchor(doc, prefix):
    for el in _iter_body_children(doc):
        t = _para_text(el, doc)
        if t is not None and t.strip().startswith(prefix):
            return el
    return None


def _luduan_balance_header(data_date: str) -> str:
    """由 meta.data_date 推餘額欄表頭（比照範例顯示資料年月，如 2026/02）。"""
    import re
    m = re.search(r"(\d{2,4})\s*年\s*(\d{1,2})\s*月", data_date)
    if m:
        year = int(m.group(1))
        west = year + 1911 if year < 1000 else year
        return f"{west}/{int(m.group(2)):02d}"
    return "借款餘額"


def _build_luduan_entity(doc, ent, balance_header):
    """在 doc 末端建「◎名稱＋借款表＋說明」，回傳依序的 body 元素清單。"""
    created = []
    headers = ["主/從債", "往來銀行", "項目", "借款金額", balance_header, "備註"]
    ncols = len(headers)
    font_pt = SIMPLE_FONT_PT

    # ◎ 標題
    hp = doc.add_paragraph()
    hp.paragraph_format.space_before = Pt(8)
    hr = hp.add_run(f"◎{ent['name']}")
    _set_run_font(hr, 14, bold=True)
    created.append(hp._p)

    # 借款表
    table = doc.add_table(rows=1, cols=ncols)
    table.style = "Table Grid"
    table.autofit = False
    table.alignment = 1
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
            _fill_cell(tr.cells[0], group["role"], font_pt)
            _set_no_wrap(tr.cells[0])
            vals = _row_values(row, "simple")
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
            total_vals = _total_values(total, "simple")
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
            c.width = Mm(SIMPLE_WIDTHS[min(i, len(SIMPLE_WIDTHS) - 1)])
    created.append(table._tbl)

    # 說明
    notes = ent.get("notes") or []
    if notes:
        p = doc.add_paragraph()
        p.paragraph_format.space_before = Pt(4)
        p.paragraph_format.keep_with_next = True
        run = p.add_run("說明：")
        _set_run_font(run, 12, bold=False)
        created.append(p._p)
        for i, text in enumerate(notes, start=1):
            np = doc.add_paragraph()
            np.paragraph_format.left_indent = Mm(12)
            np.paragraph_format.space_after = Pt(0)
            np.paragraph_format.keep_together = True
            if i < len(notes):
                np.paragraph_format.keep_with_next = True
            r = np.add_run(f"{i}. {text}")
            _set_run_font(r, 12)
            created.append(np._p)
    return created


def _fill_luduan(doc, section):
    """填陸段：刪模板佔位、依 entities 動態產列插回錨後。"""
    anchor = _find_anchor(doc, LUDUAN_ANCHOR)
    if anchor is None:
        raise ValueError(f"模板找不到「{LUDUAN_ANCHOR}」標題錨")
    end = _find_anchor(doc, LUDUAN_END)

    body = doc.element.body
    children = _iter_body_children(doc)
    ai = children.index(anchor)
    ei = children.index(end) if end is not None else len(children)
    # 刪除錨與下一段標題之間的所有佔位元素
    for el in children[ai + 1:ei]:
        body.remove(el)

    meta = section.get("meta", {})
    balance_header = _luduan_balance_header(meta.get("data_date", ""))
    # 依序在 doc 末端產出各 entity 元素，再整批移到錨之後（保持順序）
    ref = anchor
    for ent in section["entities"]:
        for el in _build_luduan_entity(doc, ent, balance_header):
            ref.addnext(el)
            ref = el


# ── 肆一 損益表 ─────────────────────────────────────────────
INCOME_ANCHOR_CELL = "項目/年度"   # 表 8 表頭第一格
# 表 8 第 0 欄列標籤（去除「－」與空白後）→ 內部鍵
INCOME_LABEL2KEY = {
    "銷貨淨額": "sales_net", "銷貨成本": "cogs", "銷貨毛利": "gross",
    "營業費用": "opex", "營業淨利": "op_income", "其他收入": "other_income",
    "利息支出": "interest_exp", "其他支出": "other_exp",
    "稅前淨利": "pretax", "所得稅": "tax", "稅後淨利": "aftertax",
}


def _compute_income_year(y):
    """由基本項（已四捨五入為仟元）算衍生列，套暫結慣例。回傳 11 列顯示值 dict。

    基本項：sales_net, cogs, opex, other_income, interest_exp, other_exp, tax
    衍生：gross=淨額−成本；op_income=毛利−費用；
         pretax=營業淨利+其他收入−利息支出−其他支出；
         aftertax=暫結時=pretax，否則=pretax−tax（暫結時 tax 顯示留空）。
    None 視為 0 參與運算、但顯示為空白。
    """
    def n(k):
        v = y.get(k)
        return v if isinstance(v, int) else 0
    sales = n("sales_net")
    gross = sales - n("cogs")
    op = gross - n("opex")
    pretax = op + n("other_income") - n("interest_exp") - n("other_exp")
    prov = bool(y.get("provisional"))
    aftertax = pretax if prov else pretax - n("tax")
    disp = {
        "sales_net": y.get("sales_net"),
        "cogs": y.get("cogs"),
        "gross": gross,
        "opex": y.get("opex"),
        "op_income": op,
        "other_income": y.get("other_income"),
        "interest_exp": y.get("interest_exp"),
        "other_exp": y.get("other_exp"),
        "pretax": pretax,
        "tax": None if prov else y.get("tax"),
        "aftertax": aftertax,
    }
    return disp


def _find_table_by_header(doc, first_cell_text):
    for tb in doc.tables:
        if tb.rows[0].cells[0].text.strip().startswith(first_cell_text):
            return tb
    return None


def _set_cell_keepfont(cell, text):
    """寫入儲存格並沿用模板原字型（清空後的空 run 保有原格式）。"""
    p = cell.paragraphs[0]
    if p.runs:
        p.runs[0].text = str(text)
        for r in p.runs[1:]:
            r.text = ""
    else:
        _fill_cell(cell, text, 11)


def _fill_income(doc, section):
    """填表 8 損益表：年度欄表頭、11 列數值與百分比；缺件年度標 needs_review。"""
    review = []
    tb = _find_table_by_header(doc, INCOME_ANCHOR_CELL)
    if tb is None:
        raise ValueError("模板找不到損益表（表頭 項目/年度）")

    # 列標籤 → row index
    row_of = {}
    for ri, row in enumerate(tb.rows):
        if ri == 0:
            continue
        lbl = row.cells[0].text.strip().lstrip("－-").strip()
        if lbl in INCOME_LABEL2KEY:
            row_of[INCOME_LABEL2KEY[lbl]] = ri

    years = section.get("years", [])
    ncols = len(tb.columns)
    max_years = (ncols - 1) // 2  # 每年佔 值+% 兩欄
    for yi, y in enumerate(years[:max_years]):
        vcol, pcol = 1 + 2 * yi, 2 + 2 * yi
        # 年度表頭
        _set_cell_keepfont(tb.rows[0].cells[vcol], y.get("label", ""))
        if y.get("missing"):
            for key, ri in row_of.items():
                _set_cell_keepfont(tb.rows[ri].cells[vcol], "")
                _set_cell_keepfont(tb.rows[ri].cells[pcol], "")
                _shade(tb.rows[ri].cells[vcol], REVIEW_YELLOW)
                _shade(tb.rows[ri].cells[pcol], REVIEW_YELLOW)
            review.append(f"肆損益 {y.get('label','?')}：缺來源檔，整欄待人工補（needs_review）")
            continue
        disp = _compute_income_year(y)
        base = disp.get("sales_net") or 0
        for key, ri in row_of.items():
            v = disp.get(key)
            _set_cell_keepfont(tb.rows[ri].cells[vcol], f"{v:,}" if isinstance(v, int) else "")
            pct = (v / base * 100) if (isinstance(v, int) and base) else 0.0
            _set_cell_keepfont(tb.rows[ri].cells[pcol], f"{pct:.2f}")
    return review


# ── 肆二 401 表（申戶／關企）───────────────────────────────
TAX401_HEADER = ["項目", "年度", "1-2", "3-4", "5-6", "7-8", "9-10", "11-12",
                 "合計", "月平均"]


def _find_tax401_tables(doc):
    """依模板順序回傳 401 表：[0]=◎申戶、[1]=◎關企。"""
    out = []
    for tb in doc.tables:
        if [c.text.strip() for c in tb.rows[0].cells] == TAX401_HEADER:
            out.append(tb)
    return out


def _fmt_401(v):
    return f"{v:,}" if isinstance(v, int) else ""


def _fill_tax401_group(tb, years, review, label):
    """把一組年度資料填進一張 401 表。

    每年兩列：銷貨（月平均＝合計÷月數，四捨五入）、進貨（末欄＝進銷比％）。
    只吃基本項（雙月值）；合計、月平均、進銷比一律由此處計算。
    年度數不受模板預留列數限制——不足時以「複製模板末列」動態增列，
    保留原儲存格字型與列高（直接 add_row 會掉格式）。
    """
    from copy import deepcopy
    while len(tb.rows) < 1 + 2 * len(years):
        clone = deepcopy(tb.rows[-1]._tr)
        tb._tbl.append(clone)
    for yi, y in enumerate(years):
        sales = list(y.get("sales") or [None] * 6)[:6]
        purchases = list(y.get("purchases") or [None] * 6)[:6]
        s_total = sum(v for v in sales if isinstance(v, int)) \
            if any(isinstance(v, int) for v in sales) else None
        p_total = sum(v for v in purchases if isinstance(v, int)) \
            if any(isinstance(v, int) for v in purchases) else None
        months = y.get("months") or 2 * sum(
            1 for v in sales if isinstance(v, int))
        avg = None
        if isinstance(s_total, int) and months:
            avg = int(s_total / months + 0.5) if s_total >= 0 else \
                -int(-s_total / months + 0.5)
        ratio = ""
        if isinstance(p_total, int) and isinstance(s_total, int) and s_total:
            ratio = f"{p_total / s_total * 100:.2f}%"

        r_sales = tb.rows[1 + 2 * yi]
        r_purch = tb.rows[2 + 2 * yi]
        year_label = str(y.get("year", ""))
        row_vals = [
            (r_sales, ["銷貨", year_label, *[_fmt_401(v) for v in sales],
                       _fmt_401(s_total), _fmt_401(avg)]),
            (r_purch, ["進貨", year_label, *[_fmt_401(v) for v in purchases],
                       _fmt_401(p_total), ratio]),
        ]
        for row, vals in row_vals:
            for ci, val in enumerate(vals):
                _set_cell_keepfont(row.cells[ci], val)
            if y.get("needs_review"):
                for c in row.cells:
                    _shade(c, REVIEW_YELLOW)
        if y.get("needs_review"):
            review.append(
                f"肆二401（{label}）{year_label} 年：視讀不確定，整年淡黃待人工核對")


def _fill_tax401(doc, section):
    """填肆二 401 表：section = {applicant: {years: […]}, affiliate: {years: […]}}。"""
    review = []
    tables = _find_tax401_tables(doc)
    if len(tables) < 2:
        raise ValueError("模板找不到 401 表（◎申戶／◎關企）")
    applicant = section.get("applicant") or {}
    affiliate = section.get("affiliate") or {}
    if applicant.get("years"):
        _fill_tax401_group(tables[0], applicant["years"], review, "申戶")
    if affiliate.get("years"):
        _fill_tax401_group(tables[1], affiliate["years"], review, "關企")
    extra = section.get("extra_affiliates") or []
    if extra:
        review.append(
            f"肆二401：另有 {len(extra)} 家關企超出模板單表容量，未填（需人工併表）")
    return review


# ── 肆三 資產負債表（申戶＝模板表；保證公司＝動態生成）────────
BS_ANCHOR_CELL = "項目＼年度"
BS_PCT_BASE = "資產總額"   # 全表百分比以該年資產總額為分母


def _find_bs_table(doc):
    for tb in doc.tables:
        if tb.rows[0].cells[0].text.strip().startswith(BS_ANCHOR_CELL):
            return tb
    return None


def _bs_fill_columns(tb, years, review, label, font_pt=None):
    """把年度資料填進一張資負表（模板表或生成表通用）。

    years[i] = {"label": "2024 年", "values": {列標籤: 仟元整數|null}}。
    百分比＝值/該年資產總額，工具計算；負值照 -0.79 呈現。
    另核對 資產總額 ≒ 負債總額＋淨值總額，不符列入回報（照填不擋）。
    """
    row_of = {}
    for ri, row in enumerate(tb.rows):
        if ri == 0:
            continue
        lbl = row.cells[0].text.strip()
        if lbl and lbl not in row_of:
            row_of[lbl] = ri
    ncols = len(tb.columns)
    max_years = (ncols - 1) // 2
    if len(years) > max_years:
        review.append(
            f"肆三資負（{label}）：{len(years)} 年超過表格 {max_years} 年欄位，超出未填")
    setter = (_set_cell_keepfont if font_pt is None
              else lambda c, t: _fill_cell(c, t, font_pt))
    for yi, y in enumerate(years[:max_years]):
        vcol, pcol = 1 + 2 * yi, 2 + 2 * yi
        setter(tb.rows[0].cells[vcol], y.get("label", ""))
        values = y.get("values") or {}
        base = values.get(BS_PCT_BASE)
        unknown = [k for k in values if k not in row_of]
        if unknown:
            review.append(
                f"肆三資負（{label}）{y.get('label','?')}：未知列標籤 {unknown}，未填")
        for lbl, ri in row_of.items():
            v = values.get(lbl)
            setter(tb.rows[ri].cells[vcol], f"{v:,}" if isinstance(v, int) else "")
            if isinstance(v, int) and isinstance(base, int) and base:
                setter(tb.rows[ri].cells[pcol], f"{v / base * 100:.2f}")
            else:
                setter(tb.rows[ri].cells[pcol], "")
        debt, equity = values.get("負債總額"), values.get("淨值總額")
        if all(isinstance(x, int) for x in (base, debt, equity)) \
                and debt + equity != base:
            review.append(
                f"肆三資負（{label}）{y.get('label','?')}：資產總額 {base:,} ≠ "
                f"負債 {debt:,}＋淨值 {equity:,}（差 {base - debt - equity:,}），"
                "已照來源填入，請人工確認")


def _build_guarantor_bs_table(doc, applicant_tb, name, years):
    """比照申戶資負表列結構，生成「◎保證公司-<名>」N 年欄表格，回傳 body 元素。"""
    labels = [applicant_tb.rows[ri].cells[0].text.strip()
              for ri in range(1, len(applicant_tb.rows))]
    n = min(len(years), 5)
    ncols = 1 + 2 * n
    font_pt = 9 if n >= 5 else 10

    created = []
    hp = doc.add_paragraph()
    hp.paragraph_format.space_before = Pt(8)
    hr = hp.add_run(f"◎保證公司-{name}")
    _set_run_font(hr, 12, bold=True)
    created.append(hp._p)

    table = doc.add_table(rows=1 + len(labels), cols=ncols)
    table.style = "Table Grid"
    table.autofit = False
    table.alignment = 1
    _mark_header_row(table.rows[0])
    _fill_cell(table.rows[0].cells[0], BS_ANCHOR_CELL, font_pt, bold=True)
    for yi in range(n):
        _fill_cell(table.rows[0].cells[1 + 2 * yi], "", font_pt, bold=True)
        _fill_cell(table.rows[0].cells[2 + 2 * yi], "%", font_pt, bold=True)
    for ri, lbl in enumerate(labels, start=1):
        _fill_cell(table.rows[ri].cells[0], lbl, font_pt,
                   align=WD_ALIGN_PARAGRAPH.LEFT)
    label_w = 40
    col_w = (180 - label_w) / (ncols - 1)
    for r in table.rows:
        for i, c in enumerate(r.cells):
            c.width = Mm(label_w if i == 0 else col_w)
    created.append(table._tbl)
    return created, table, font_pt


def _fill_balancesheet(doc, section):
    """填肆三：applicant 填模板表；guarantors 各生成一張表接在申戶表之後。"""
    review = []
    tb = _find_bs_table(doc)
    if tb is None:
        raise ValueError("模板找不到資產負債表（表頭 項目＼年度）")
    applicant = section.get("applicant") or {}
    if applicant.get("years"):
        _bs_fill_columns(tb, applicant["years"], review, "申戶")
    ref = tb._tbl
    for g in section.get("guarantors") or []:
        years = g.get("years") or []
        if not years:
            continue
        if len(years) > 5:
            review.append(
                f"肆三資負（{g.get('name','保證公司')}）：{len(years)} 年超過 5 年欄位上限，"
                "僅填最近 5 年")
        created, gtb, font_pt = _build_guarantor_bs_table(
            doc, tb, g.get("name", ""), years)
        _bs_fill_columns(gtb, years[:5], review, g.get("name", "保證公司"),
                         font_pt=font_pt)
        for el in created:
            ref.addnext(el)
            ref = el
    return review


# ── 捌 保證人資力（基本欄）─────────────────────────────────
GUARANTOR_HEADER = ["姓名", "出生年月日", "婚姻", "現職", "電話"]


def _find_guarantor_tables(doc):
    out = []
    for tb in doc.tables:
        row0 = [c.text.strip() for c in tb.rows[0].cells]
        if row0[:5] == GUARANTOR_HEADER:
            out.append(tb)
    return out


def _fill_guarantor(doc, section):
    """填保證人基本欄（表 18/20…）。身分證可得欄自動填；現職/電話標 needs_review。

    排序規則：申戶負責人（principal=true）排第一位（（1）），其餘依原序穩定排列。
    """
    review = []
    tables = _find_guarantor_tables(doc)
    guars = sorted(section.get("guarantors", []),
                   key=lambda g: 0 if g.get("principal") else 1)
    if len(guars) > len(tables):
        review.append(
            f"捌保證人：{len(guars)} 位超過模板 {len(tables)} 個區塊，超出者未填")
    for gi, g in enumerate(guars[:len(tables)]):
        tb = tables[gi]
        # 第1列：姓名/出生年月日/婚姻/現職/電話
        r1 = tb.rows[1].cells
        _set_cell_keepfont(r1[0], g.get("name", ""))
        _set_cell_keepfont(r1[1], g.get("birth", ""))
        _set_cell_keepfont(r1[2], g.get("married", ""))
        job, phone = g.get("job"), g.get("phone")
        _set_cell_keepfont(r1[3], job or "")
        _set_cell_keepfont(r1[4], phone or "")
        if not job:
            _shade(r1[3], REVIEW_YELLOW)
        if not phone:
            _shade(r1[4], REVIEW_YELLOW)
        # 第3列：性別/身份證號/通訊地址(合併)
        r3 = tb.rows[3].cells
        _set_cell_keepfont(r3[0], g.get("gender", ""))
        _set_cell_keepfont(r3[1], g.get("id_no", ""))
        _set_cell_keepfont(r3[2], g.get("address", ""))
    if guars and any((not g.get("job")) or (not g.get("phone")) for g in guars):
        review.append("捌保證人：現職/電話身分證未載，已標 needs_review 待人工補")
    return review


SECTION_FILLERS = {
    "luduan": _fill_luduan,
    "income": _fill_income,
    "tax401": _fill_tax401,
    "balancesheet": _fill_balancesheet,
    "guarantor": _fill_guarantor,
}


def fill_report(sections: dict, out_path, template=None):
    """sections: {段鍵: 該段結構化資料} → 整份 DOCX。

    回傳 (out_path, review)；review 為缺件/待人工確認清單。
    支援段鍵：'luduan'（陸）、'income'（肆一 損益表）。其餘沿用模板空白版面。
    """
    template = Path(template) if template else DEFAULT_TEMPLATE
    doc = Document(str(template))
    review = []
    for key, filler in SECTION_FILLERS.items():
        if key in sections and sections[key] is not None:
            r = filler(doc, sections[key])
            if r:
                review.extend(r)

    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
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
    return out_path, review
