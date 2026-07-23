"""CLI 測試：gen_report.py 的驗證、產檔與錯誤處理。"""

import json

import pytest

import gen_report
from conftest import FIXTURE


def test_check_only_ok(capsys):
    assert gen_report.main([str(FIXTURE), "--check-only"]) == 0
    out = capsys.readouterr().out
    assert "驗證通過" in out
    assert "警告" in out  # fixture 內含 needs_review 列


def test_generate_to_custom_path(tmp_path, capsys):
    out = tmp_path / "sub" / "r.docx"
    assert gen_report.main([str(FIXTURE), "-o", str(out)]) == 0
    assert out.is_file()


def test_missing_input_file(tmp_path):
    assert gen_report.main([str(tmp_path / "nope.json")]) == 2


def test_invalid_json(tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text("{not json", encoding="utf-8")
    assert gen_report.main([str(bad)]) == 2


def test_unreadable_input_is_controlled_error(tmp_path):
    # 目錄當輸入檔 → OSError → exit 2（可控錯誤，不噴 traceback）
    assert gen_report.main([str(tmp_path)]) == 2


def test_generation_failure_exits_3_without_partial_file(tmp_path, monkeypatch, capsys):
    def boom(data, out):
        raise RuntimeError("simulated docx failure")

    monkeypatch.setattr(gen_report, "build_docx", boom)
    out = tmp_path / "r.docx"
    assert gen_report.main([str(FIXTURE), "-o", str(out)]) == 3
    assert not out.exists()
    assert "產檔失敗" in capsys.readouterr().err


def test_atomic_output_leaves_no_tmp_files(tmp_path):
    out = tmp_path / "r.docx"
    assert gen_report.main([str(FIXTURE), "-o", str(out)]) == 0
    assert out.is_file()
    leftovers = [p for p in tmp_path.iterdir() if p.name != "r.docx"]
    assert leftovers == []


def test_validation_error_blocks_generation(tmp_path, capsys):
    data = json.loads(FIXTURE.read_text(encoding="utf-8"))
    del data["meta"]["data_date"]
    src = tmp_path / "invalid.json"
    src.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    out = tmp_path / "should_not_exist.docx"
    assert gen_report.main([str(src), "-o", str(out)]) == 1
    assert not out.exists()
