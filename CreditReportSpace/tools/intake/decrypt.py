"""Intake 層：聯徵憑證（加密 PDF）解密。

規則（已驗證）：JCIC 自調信用憑證 PDF 的開啟密碼＝當事人身分證字號**後 6 碼**。
身分證號可由身分證正面 JPG 視讀取得（抽取層 LLM），或直接提供 6 碼密碼。

解密後的明文 PDF 只落 tmp/（含真實個資），交抽取層讀取；不外傳、不進 git。
本模組屬 intake 層，讀寫 PDF 需 pymupdf；純產製層不依賴它。
"""

from __future__ import annotations

import re
from pathlib import Path

try:
    import fitz  # pymupdf
except ImportError:  # pragma: no cover
    fitz = None

TW_ID_RE = re.compile(r"[A-Z][12]\d{8}")


def password_from_id(id_number: str) -> str:
    """身分證字號 → 開啟密碼（後 6 碼）。格式不符則報錯，不臆測。"""
    s = str(id_number).strip().upper()
    if not re.fullmatch(r"[A-Z][12]\d{8}", s):
        raise ValueError("身分證字號格式不符（應為 1 英文字母＋9 數字）")
    return s[-6:]


def _require_fitz():
    if fitz is None:
        raise RuntimeError("聯徵解密需要 pymupdf（intake 層依賴）")


def decrypt_pdf(src, password, dest):
    """用密碼解密 src，另存明文 PDF 到 dest。回傳 dest（Path）。

    - src 未加密：直接另存（等同複製正規化），不報錯。
    - 密碼錯誤：raise ValueError，不留半成品。
    """
    _require_fitz()
    doc = fitz.open(str(src))
    try:
        if doc.needs_pass and not doc.authenticate(str(password)):
            raise ValueError("聯徵密碼錯誤，無法解密")
        dest = Path(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        doc.save(str(dest))  # 預設不再加密 → 明文
    finally:
        doc.close()
    return dest


def read_text(src, password=None) -> str:
    """讀取 PDF 全文（加密則需正確密碼）。供抽取層取用文字層。"""
    _require_fitz()
    doc = fitz.open(str(src))
    try:
        if doc.needs_pass:
            if not password or not doc.authenticate(str(password)):
                raise ValueError("讀取加密 PDF 需要正確密碼")
        return "\n".join(pg.get_text() for pg in doc)
    finally:
        doc.close()


def try_id_passwords(src, id_numbers):
    """對一組候選身分證號，試出能解開 src 的那一個。回傳 (id_number, password) 或 None。

    用於「聯徵與身分證同批但配對未知」時，逐一試身分證後 6 碼。
    """
    _require_fitz()
    for idn in id_numbers:
        try:
            pw = password_from_id(idn)
        except ValueError:
            continue
        doc = fitz.open(str(src))
        try:
            ok = (not doc.needs_pass) or doc.authenticate(pw)
        finally:
            doc.close()
        if ok:
            return idn, pw
    return None
