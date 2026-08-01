"""分類器測試（intake 層）：以虛構字串/檔名驗證類型判別、歸屬與期別擷取。
純字串測試不需真實 PDF，也不含任何真實個資。"""

from intake.classifier import (
    _classify_pdf_text,
    _detect_entity,
    _detect_period,
    _person_from_name,
    classify_file,
    classify_folder,
)


# ── 由文字判類型 ─────────────────────────────────────────
def test_income_settlement_by_text():
    assert _classify_pdf_text("…損益及稅額計算表…", "測試", "結算申報書", False)[0] \
        == "income_settlement"


def test_income_mgmt_by_text():
    assert _classify_pdf_text("…綜合損益表(明細)…", "測試報表", "x", False)[0] \
        == "income_mgmt"


def test_balancesheet_by_text():
    assert _classify_pdf_text("…資產負債表…", "測試", "x", False)[0] == "balancesheet"


def test_tax401_by_filename():
    assert _classify_pdf_text("模糊掃描", "測試115年01-02月401", "401", True)[0] \
        == "tax401"


def test_scanned_401_by_parent_folder():
    # 檔名無 401，但父資料夾為「401」→ 仍歸 tax401
    t, note = _classify_pdf_text("", "測試甲-113全年度", "401", True)
    assert t == "tax401"
    assert "掃描" in note


def test_unknown_when_no_signal():
    assert _classify_pdf_text("一些無關文字內容夠長" * 30, "abc", "x", False)[0] \
        == "unknown"


# ── 歸屬與期別 ───────────────────────────────────────────
def test_detect_company_generic():
    # 通用公司樣式擷取，不依賴任何硬編真值（實務中公司名為獨立一行）
    assert _detect_entity("測試企業有限公司\n綜合損益表(明細)", "x") \
        == "測試企業有限公司"


def test_person_from_name_before_keyword():
    assert _person_from_name("20250101測試甲信用憑證") == "測試甲"
    assert _person_from_name("測試乙-身分證正面") == "測試乙"


def test_detect_period():
    assert _detect_period("", "測試114年報表") == "民國114"
    assert _detect_period("113 年度損益", "無年份") == "民國113"
    assert _detect_period("", "報表2023final") == "2023"   # 西元退路
    assert _detect_period("無年份資訊", "無年份") is None


def test_detect_entity_falls_back_to_person():
    assert _detect_entity("無公司字樣", "測試甲-身分證正面") == "測試甲"


def test_scanned_settlement_and_balancesheet_by_parent():
    assert _classify_pdf_text("", "掃描", "結算申報書", True)[0] == "income_settlement"
    assert _classify_pdf_text("", "掃描", "資產負債表", True)[0] == "balancesheet"
    assert _classify_pdf_text("", "無線索", "其他", True)[0] == "unknown"


def test_classify_pdf_without_fitz(tmp_path, monkeypatch):
    import intake.classifier as C
    monkeypatch.setattr(C, "fitz", None)
    f = tmp_path / "測試.pdf"
    f.write_bytes(b"%PDF-1.4 test")
    r = C.classify_file(f)
    assert r["type"] == "unknown"
    assert "pymupdf" in r["note"]


# ── classify_file（影像分支不需開檔）──────────────────────
def test_classify_id_image(tmp_path):
    f = tmp_path / "測試甲-身分證正面.jpg"
    f.write_bytes(b"\xff\xd8\xff")  # 影像分支只看副檔名與檔名
    r = classify_file(f)
    assert r["type"] == "id"
    assert r["entity"] == "測試甲"
    assert r["note"] == "正面"


def test_classify_unknown_extension(tmp_path):
    f = tmp_path / "測試.docx"
    f.write_bytes(b"PK\x03\x04")
    assert classify_file(f)["type"] == "unknown"


# ── classify_file 對真實 PDF（fitz 路徑）──────────────────
def test_classify_text_pdf_income_mgmt(tmp_path, make_pdf):
    # 真實損益表文字量大；填足 200+ 字使 scanned 判定為 False（有文字層）
    body = "測試企業有限公司\n綜合損益表(明細)\n114年度\n" + "會計項目金額百分比\n" * 30
    f = make_pdf(tmp_path / "測試114年報表.pdf", body)
    r = classify_file(f)
    assert r["type"] == "income_mgmt"
    assert r["entity"] == "測試企業有限公司"
    assert r["period"] == "民國114"
    assert r["scanned"] is False


def test_classify_encrypted_jcic(tmp_path, make_pdf):
    f = make_pdf(tmp_path / "20250101測試甲信用憑證.pdf", "secret", encrypt=True)
    r = classify_file(f)
    assert r["encrypted"] is True
    assert r["type"] == "jcic"
    assert r["entity"] == "測試甲"


def test_classify_scanned_pdf_in_401_folder(tmp_path, make_pdf):
    sub = tmp_path / "401"
    sub.mkdir()
    f = make_pdf(sub / "測試甲-113全年度.pdf", "")  # 空白＝無文字層＝掃描
    r = classify_file(f)
    assert r["scanned"] is True
    assert r["type"] == "tax401"


def test_classify_folder_walks_and_labels(tmp_path, make_pdf, make_image):
    make_image(tmp_path / "測試甲-身分證正面.jpg")
    sub = tmp_path / "財報"
    sub.mkdir()
    make_pdf(sub / "測試資產負債.pdf", "測試企業有限公司\n資產負債表")
    items = classify_folder(tmp_path)
    types = {it["type"] for it in items}
    assert types == {"id", "balancesheet"}
    bs = [it for it in items if it["type"] == "balancesheet"][0]
    assert bs["subdir"] == "財報"
