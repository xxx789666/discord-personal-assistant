"""金融借款報告（聯徵整理）產製工具。

分層原則：
- 抽取層（LLM／人工）：讀聯徵 PDF/圖片 → 產出符合 schema 的 JSON。本套件不做 OCR。
- 產製層（本套件，確定性）：validate() 驗證 JSON → build_docx() 生成 DOCX。
"""

from .model import ValidationResult, validate
from .docx_builder import build_docx

__all__ = ["validate", "ValidationResult", "build_docx"]
