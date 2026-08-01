import json
import sys
from pathlib import Path

import pytest

SPACE_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SPACE_ROOT / "tools"))

FIXTURE = SPACE_ROOT / "fixtures" / "sample_report.json"


@pytest.fixture
def sample_data():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


@pytest.fixture
def make_pdf():
    """工廠：產生含 CJK 文字層（或加密、或空白掃描）的測試 PDF。

    無 pymupdf 時整個測試自動 skip（intake 層依賴，見 requirements-dev.txt）。
    """
    def _make(path, text="", encrypt=False):
        fitz = pytest.importorskip("fitz")
        doc = fitz.open()
        page = doc.new_page()
        if text:
            page.insert_text((72, 72), text, fontname="china-s", fontsize=11)
        if encrypt:
            doc.save(str(path), encryption=fitz.PDF_ENCRYPT_AES_256,
                     owner_pw="o", user_pw="u")
        else:
            doc.save(str(path))
        return Path(path)
    return _make


@pytest.fixture
def make_image():
    """工廠：產生最小 JPG 檔（分類器影像分支只看副檔名/檔名，不解碼）。"""
    def _make(path):
        Path(path).write_bytes(b"\xff\xd8\xff\xe0")
        return Path(path)
    return _make
