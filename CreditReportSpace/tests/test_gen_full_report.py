"""CLI 測試：gen_full_report.py 的清點、覆蓋摘要、產檔與退出碼。
使用去識別化（虛構）資料與臨時 PDF/影像 fixture。"""

import json

import pytest
from docx import Document

import gen_full_report as G


LUDUAN = {
    "meta": {"section_title": "陸、金融借款：（仟元）",
             "data_date": "資料日期-115年3月底（虛構）", "source_note": ""},
    "entities": [{
        "name": "測試甲（虛構）", "layout": "simple",
        "groups": [{"role": "主債", "rows": [
            {"bank": "測試銀行/測試北", "item": "中擔",
             "loan_amount": 1000, "balance": 900}],
            "total": {"balance": 900}}],
        "notes": ["測試（虛構）。"],
    }],
}
GUARANTOR = {"guarantors": [
    {"name": "測試甲", "birth": "80.01.01", "gender": "男",
     "id_no": "測試證號X", "address": "測試市A", "married": "已婚"},
]}


@pytest.fixture
def case_folder(tmp_path, make_pdf, make_image):
    root = tmp_path / "case"
    (root / "身分證").mkdir(parents=True)
    (root / "財報").mkdir()
    make_image(root / "身分證" / "測試甲-身分證正面.jpg")
    make_pdf(root / "財報" / "測試114報表.pdf",
             "測試企業有限公司\n綜合損益表(明細)")
    make_pdf(root / "20250101測試甲信用憑證.pdf", "x", encrypt=True)
    return root


@pytest.fixture
def sections_dir(tmp_path):
    d = tmp_path / "sections"
    d.mkdir()
    (d / "luduan.json").write_text(json.dumps(LUDUAN, ensure_ascii=False),
                                   encoding="utf-8")
    (d / "guarantor.json").write_text(json.dumps(GUARANTOR, ensure_ascii=False),
                                      encoding="utf-8")
    return d


def test_inventory_only_returns_0(case_folder, capsys):
    rc = G.main([str(case_folder)])
    assert rc == 0
    out = capsys.readouterr().out
    assert "檔案清點" in out
    assert "jcic" in out and "id" in out and "income_mgmt" in out
    assert "只清點" in out


def test_missing_folder_returns_2(tmp_path):
    assert G.main([str(tmp_path / "nope")]) == 2


def test_generate_with_sections(case_folder, sections_dir, tmp_path, capsys):
    out = tmp_path / "out" / "r.docx"
    rc = G.main([str(case_folder), "--sections", str(sections_dir),
                 "-o", str(out)])
    assert rc == 0
    assert out.is_file()
    printed = capsys.readouterr().out
    assert "已產生" in printed
    # 陸段與捌段有填入
    doc = Document(str(out))
    titles = "\n".join(p.text for p in doc.paragraphs)
    assert "◎測試甲（虛構）" in titles


def test_coverage_summary_flags_present_sources(case_folder, capsys):
    G.main([str(case_folder)])
    out = capsys.readouterr().out
    assert "v1 段落覆蓋" in out
    assert "陸 金融借款" in out and "捌 保證人" in out


def test_empty_sections_dir_returns_2(case_folder, tmp_path):
    empty = tmp_path / "empty_sections"
    empty.mkdir()
    assert G.main([str(case_folder), "--sections", str(empty)]) == 2


def test_load_sections_maps_filenames(sections_dir):
    sections = G.load_sections(sections_dir)
    assert set(sections) == {"luduan", "guarantor"}
    assert sections["luduan"]["entities"][0]["name"] == "測試甲（虛構）"


def test_unknown_file_warned(tmp_path, make_pdf, capsys):
    root = tmp_path / "case"
    root.mkdir()
    make_pdf(root / "無線索.pdf", "一些無關內容" * 40)  # 有文字層但無類型訊號
    G.main([str(root)])
    out = capsys.readouterr().out
    assert "無法辨識" in out
