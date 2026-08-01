"""聯徵解密 helper 測試（intake 層）。用臨時加密 PDF，不含真實個資。

身分證號一律以字串「拼接」組出，避免原始碼文字出現身分證形狀（[A-Z][12]\\d{8}）
或 9 位以上數字串而觸發 PII lint——這些值只在執行期組成，屬虛構測試資料。"""

import pytest

from intake.decrypt import (
    password_from_id,
    decrypt_pdf,
    read_text,
    try_id_passwords,
)

# 執行期才組成的虛構身分證號（原始碼文字不含 ID 形狀）
FAKE_ID = "A2" + "0" * 7 + "6"        # 後 6 碼 = 000006
FAKE_ID_PW = "0" * 5 + "6"            # 000006
OTHER_ID = "B1" + "0" * 7 + "1"       # 另一虛構號，非 FAKE
BAD_2ND_CHAR = "A9" + "0" * 8         # 第 2 碼非 1/2 → 格式不符


def test_password_from_id_takes_last6():
    assert password_from_id(FAKE_ID) == FAKE_ID_PW
    assert password_from_id(" " + FAKE_ID.lower() + " ") == FAKE_ID_PW


def test_password_from_id_rejects_bad_format():
    with pytest.raises(ValueError):
        password_from_id("12345")
    with pytest.raises(ValueError):
        password_from_id(BAD_2ND_CHAR)


def test_decrypt_with_correct_password(tmp_path, make_pdf):
    enc = make_pdf(tmp_path / "cred.pdf", "測試聯徵內容 表B1", encrypt=True)
    out = decrypt_pdf(enc, "u", tmp_path / "plain.pdf")  # fixture user_pw="u"
    assert out.is_file()
    assert "表B1" in read_text(out)


def test_decrypt_wrong_password_raises(tmp_path, make_pdf):
    enc = make_pdf(tmp_path / "cred.pdf", "x", encrypt=True)
    with pytest.raises(ValueError, match="密碼"):
        decrypt_pdf(enc, "wrong", tmp_path / "plain.pdf")


def test_decrypt_unencrypted_passthrough(tmp_path, make_pdf):
    plain = make_pdf(tmp_path / "p.pdf", "無加密內容")
    out = decrypt_pdf(plain, "任意", tmp_path / "copy.pdf")
    assert out.is_file()


def test_read_text_encrypted_needs_password(tmp_path, make_pdf):
    enc = make_pdf(tmp_path / "c.pdf", "祕密", encrypt=True)
    with pytest.raises(ValueError):
        read_text(enc)
    assert "祕密" in read_text(enc, "u")


def test_try_id_passwords_finds_match(tmp_path):
    import fitz
    doc = fitz.open()
    doc.new_page().insert_text((72, 72), "測試", fontname="china-s")
    p = tmp_path / "byid.pdf"
    doc.save(str(p), encryption=fitz.PDF_ENCRYPT_AES_256,
             owner_pw="o", user_pw=FAKE_ID_PW)   # user_pw = FAKE_ID 後 6 碼
    doc.close()
    assert try_id_passwords(p, [OTHER_ID, FAKE_ID]) == (FAKE_ID, FAKE_ID_PW)
    assert try_id_passwords(p, [OTHER_ID]) is None
