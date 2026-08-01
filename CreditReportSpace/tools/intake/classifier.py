"""Intake 層：檔案分類器（辨識徵信案件資料的類型與歸屬）。

注意：本模組屬 intake 層，讀 PDF 需 pymupdf；純產製層（credit_report）
不依賴它。分類結果用於路由、清點與缺件回報，不做數值抽取（抽取＝LLM）。

回傳 dict：type / entity / period / scanned / encrypted / note
type ∈ {jcic, income_mgmt, income_settlement, balancesheet, tax401, id, unknown}
"""

from __future__ import annotations

import re
from pathlib import Path

try:
    import fitz  # pymupdf
except ImportError:  # pragma: no cover
    fitz = None

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".tif", ".tiff", ".heic", ".heif"}

# 公司名／統編以通用樣式從內容擷取，不硬編任何真實個資（符合 git 去識別化政策）
COMPANY_RE = re.compile(
    r"[一-鿿]{2,10}(?:股份有限公司|有限公司|企業社|工程行|實業社|商行|企業行)")
UBN_RE = re.compile(r"(?<!\d)\d{8}(?!\d)")


def _person_from_name(stem: str) -> str | None:
    # 人名多在關鍵字前或分隔符前（如「<日期><姓名>信用憑證」「<姓名>-身分證正面」）
    m = re.search(r"([一-鿿]{2,4})(?=信用憑證|聯徵|身分證|身份證|[-－_\s]|$)", stem)
    return m.group(1) if m else None


def _detect_entity(text: str, stem: str) -> str | None:
    """由內容/檔名通用擷取公司名；無則退回人名。回傳擷取到的字串（執行期用）。"""
    m = COMPANY_RE.search(text) or COMPANY_RE.search(stem)
    if m:
        return m.group(0)
    return _person_from_name(stem)


def _detect_period(text: str, stem: str) -> str | None:
    m = re.search(r"(1\d{2})\s*年", stem) or re.search(r"(1\d{2})\s*年度", text)
    if m:
        return f"民國{m.group(1)}"
    m = re.search(r"(20\d{2})", stem)
    return m.group(1) if m else None


def classify_file(path) -> dict:
    p = Path(path)
    stem = p.stem
    ext = p.suffix.lower()
    res = {"path": str(p), "name": p.name, "type": "unknown", "entity": None,
           "period": None, "scanned": False, "encrypted": False, "note": ""}

    if ext in IMAGE_EXTS:
        if "身分證" in stem or "身份證" in p.parent.name or "身分證" in p.parent.name:
            res["type"] = "id"
        else:
            res["type"] = "id" if "證" in stem else "unknown"
        res["entity"] = _person_from_name(stem)
        res["note"] = "反面" if "反" in stem else ("正面" if "正" in stem else "")
        return res

    if ext != ".pdf":
        return res

    if fitz is None:
        res["note"] = "無 pymupdf，無法讀 PDF 內容"
        return res

    doc = fitz.open(str(p))
    if doc.needs_pass:
        res["encrypted"] = True
        doc.close()
        # 本工作流裡加密 PDF 只會是聯徵憑證，直接歸 jcic。不要依賴檔名：
        # Discord 上傳會把附件檔名裡的 CJK 剝掉（「蔡○○信用憑證」→ 消失）。
        res["type"] = "jcic"
        res["entity"] = _person_from_name(stem)
        res["note"] = "加密（聯徵，需身分證後6碼解密）"
        return res

    text = "\n".join(pg.get_text() for pg in doc)
    doc.close()
    res["scanned"] = len(text.strip()) < 200
    res["type"], res["note"] = _classify_pdf_text(
        text, stem, p.parent.name, res["scanned"])
    res["entity"] = _detect_entity(text, stem)
    res["period"] = _detect_period(text, stem)
    return res


def _classify_pdf_text(text: str, stem: str, parent: str, scanned: bool):
    """由 PDF 文字（有文字層）或檔名/父資料夾（掃描檔）判類型。回傳 (type, note)。"""
    if "損益及稅額計算表" in text or "營利事業所得稅結算申報" in text:
        return "income_settlement", ""
    if "綜合損益表" in text:
        return "income_mgmt", ""
    if "資產負債表" in text:
        return "balancesheet", ""
    if "401" in stem or "營業人銷售額" in text:
        return "tax401", ""
    if scanned:
        note = "掃描圖（無文字層，需視讀）"
        if "401" in stem or "401" in parent:
            return "tax401", note
        if "報表" in stem or "損益" in stem or "綜合損益" in parent:
            return "income_mgmt", note
        if "資產負債" in parent:
            return "balancesheet", note
        if "結算申報" in parent:
            return "income_settlement", note
        return "unknown", note
    return "unknown", ""


def classify_folder(folder) -> list[dict]:
    root = Path(folder)
    out = []
    for pth in sorted(root.rglob("*")):
        if pth.is_file() and pth.suffix.lower() in (IMAGE_EXTS | {".pdf"}):
            r = classify_file(pth)
            r["subdir"] = str(pth.parent.relative_to(root))
            out.append(r)
    return out
