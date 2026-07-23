"""驗證層測試：合法輸入通過；各類錯誤輸入被擋下並給出可讀訊息。"""

import copy

from credit_report import validate
from credit_report.model import fmt_amount


def test_sample_fixture_passes(sample_data):
    res = validate(sample_data)
    assert res.ok, res.errors
    # fixture 刻意含一列 needs_review → 恰好一個警告
    assert len(res.warnings) == 1
    assert "待人工確認" in res.warnings[0]


def test_not_a_dict():
    assert not validate([]).ok
    assert not validate("x").ok


def test_missing_data_date(sample_data):
    data = copy.deepcopy(sample_data)
    del data["meta"]["data_date"]
    res = validate(data)
    assert any("data_date" in e for e in res.errors)


def test_bad_layout(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][0]["layout"] = "fancy"
    assert any("layout" in e for e in validate(data).errors)


def test_forbidden_pii_key_rejected(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][0]["身分證號"] = "FAKE-VALUE"
    res = validate(data)
    assert any("禁止欄位" in e for e in res.errors)


def test_simple_layout_rejects_extended_fields(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][0]["groups"][0]["rows"][0]["change"] = -5
    assert any("simple 版不得出現" in e for e in validate(data).errors)


def test_string_amount_rejected(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][0]["groups"][0]["rows"][0]["loan_amount"] = "20,000"
    assert any("整數" in e for e in validate(data).errors)


def test_negative_balance_rejected(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][0]["groups"][0]["rows"][0]["balance"] = -1
    assert any("不可為負數" in e for e in validate(data).errors)


def test_unknown_row_field_rejected(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][0]["groups"][0]["rows"][0]["extra"] = 1
    assert any("未定義的欄位" in e for e in validate(data).errors)


def test_extended_requires_prev_labels(sample_data):
    data = copy.deepcopy(sample_data)
    del data["entities"][1]["prev_labels"]
    assert any("prev_labels" in e for e in validate(data).errors)


def test_missing_balance_key_rejected(sample_data):
    data = copy.deepcopy(sample_data)
    del data["entities"][0]["groups"][0]["rows"][0]["balance"]
    assert any(".balance: 必填" in e for e in validate(data).errors)


def test_null_balance_without_flags_rejected(sample_data):
    """重要金額鐵律：非刪除線列 balance=null 必須 needs_review。"""
    data = copy.deepcopy(sample_data)
    data["entities"][0]["groups"][0]["rows"][0]["balance"] = None
    res = validate(data)
    assert any("needs_review" in e and ".balance" in e for e in res.errors)


def test_null_balance_with_needs_review_accepted(sample_data):
    data = copy.deepcopy(sample_data)
    row = data["entities"][0]["groups"][0]["rows"][0]
    row["balance"] = None
    row["needs_review"] = True
    res = validate(data)
    assert res.ok
    assert any("待人工確認" in w for w in res.warnings)


def test_change_mismatch_rejected(sample_data):
    """change = 餘額 − prev_balances[0]；三值皆已知時嚴格核對。"""
    data = copy.deepcopy(sample_data)
    data["entities"][1]["groups"][0]["rows"][0]["change"] = -49
    res = validate(data)
    assert any("與定義不符" in e for e in res.errors)


def test_change_mismatch_not_bypassed_by_needs_review(sample_data):
    """已知三值矛盾永遠是硬錯誤，needs_review 不得繞過。"""
    data = copy.deepcopy(sample_data)
    row = data["entities"][1]["groups"][0]["rows"][0]
    row["change"] = -49
    row["needs_review"] = True
    res = validate(data)
    assert any("與定義不符" in e for e in res.errors)


def test_change_unverifiable_without_review_warns():
    data = {
        "meta": {"data_date": "資料日期-2026年6月底（TEST）"},
        "entities": [{
            "name": "增減測試（虛構）",
            "layout": "extended",
            "prev_labels": ["2023", "2020.06"],
            "groups": [{"role": "主債", "rows": [{
                "bank": "甲銀/測試", "item": "中擔", "balance": 100,
                "prev_balances": ["N/A", 50], "change": -5,
            }]}],
        }],
    }
    res = validate(data)
    assert res.ok
    assert any("change 無法核對" in w for w in res.warnings)
    # 標了 needs_review 就不再重複警告 change，僅保留待人工確認警告
    data["entities"][0]["groups"][0]["rows"][0]["needs_review"] = True
    res2 = validate(data)
    assert not any("change 無法核對" in w for w in res2.warnings)


def test_null_optional_amounts_require_review_flag(sample_data):
    """loan_amount/change/prev_balances 的 null＝未知，該列必須 needs_review。"""
    for field, value in (
        ("loan_amount", None),
        ("change", None),
        ("prev_balances", [None, 4000]),
    ):
        data = copy.deepcopy(sample_data)
        data["entities"][1]["groups"][0]["rows"][0][field] = value
        res = validate(data)
        assert any(field in e and "needs_review" in e for e in res.errors), field


def test_na_sentinel_accepted_without_review(sample_data):
    """\"N/A\"＝明確不適用，不需要 needs_review（fixture 內已含一例）。"""
    data = copy.deepcopy(sample_data)
    row = data["entities"][1]["groups"][1]["rows"][0]
    row["loan_amount"] = "N/A"
    res = validate(data)
    assert res.ok


def test_na_rejected_for_balance(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][0]["groups"][0]["rows"][0]["balance"] = "N/A"
    res = validate(data)
    assert any(".balance" in e for e in res.errors)


def test_explicit_null_rejected_for_structures(sample_data):
    """total／notes／row.prev_balances／total.prev_balances 不接受明確 null（應省略）。"""
    cases = [
        lambda d: d["entities"][0]["groups"][0].__setitem__("total", None),
        lambda d: d["entities"][0].__setitem__("notes", None),
        lambda d: d["entities"][1]["groups"][0]["rows"][0].__setitem__("prev_balances", None),
        lambda d: d["entities"][1]["groups"][0]["total"].__setitem__("prev_balances", None),
    ]
    for mutate in cases:
        data = copy.deepcopy(sample_data)
        mutate(data)
        assert not validate(data).ok


def test_struck_row_change_not_checked(sample_data):
    """沖轉列 change 由人工填寫，不套 change = 餘額 − prev0 檢核。"""
    res = validate(sample_data)  # fixture 內兩列 struck 的 change 不符公式
    assert res.ok


def test_bad_source_note_type_rejected(sample_data):
    data = copy.deepcopy(sample_data)
    data["meta"]["source_note"] = 123
    assert any("source_note" in e for e in validate(data).errors)


def test_simple_total_rejects_extended_fields(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][0]["groups"][0]["total"]["change"] = 0
    assert any("total.change" in e and "simple" in e for e in validate(data).errors)


def test_missing_bank_rejected(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][0]["groups"][0]["rows"][0]["bank"] = ""
    assert any(".bank" in e for e in validate(data).errors)


def test_fmt_amount():
    assert fmt_amount(None) == ""
    assert fmt_amount(0) == "0"
    assert fmt_amount(1234567) == "1,234,567"
    assert fmt_amount(-1815, change=True) == "(1,815)"
    assert fmt_amount(28072, change=True) == "28,072"
    assert fmt_amount("N/A") == "—"
    assert fmt_amount("N/A", change=True) == "—"
