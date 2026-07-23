"""合計與增減核對測試。

- 金額欄合計 vs 非刪除線列加總 → 不符出警告。
- total.change vs 全列（含刪除線）加總 → 不符出警告；有 null 列則警告無法完整核對。
"""

import copy

from credit_report import validate


def _minimal_extended(rows, total):
    return {
        "meta": {"data_date": "資料日期-2026年6月底（TEST）"},
        "entities": [
            {
                "name": "合計測試（虛構）",
                "layout": "extended",
                "prev_labels": ["2023", "2020.06"],
                "groups": [{"role": "主債", "rows": rows, "total": total}],
            }
        ],
    }


def test_total_mismatch_warns(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][0]["groups"][0]["total"]["balance"] = 999999
    res = validate(data)
    assert res.ok  # 合計不符是警告不是錯誤
    assert any("不一致" in w and "balance" in w for w in res.warnings)


def test_struck_rows_excluded_from_amount_sums(sample_data):
    """fixture 主債群組：兩列刪除線不列入 loan_amount 加總 → 4,000 應無警告。"""
    res = validate(sample_data)
    assert not any("loan_amount" in w and "不一致" in w for w in res.warnings)


def test_unstruck_row_enters_amount_sum():
    """同一組資料把 struck 拿掉 → 金額進入加總 → 應產生警告，證明核對真的在算。"""
    rows = [
        {"bank": "甲銀/測試", "item": "中擔", "loan_amount": 1000, "balance": 900,
         "prev_balances": [1000, 1100], "change": -100},
        {"bank": "乙銀/測試", "item": "中擔", "loan_amount": 5000, "balance": 5000,
         "prev_balances": [4000, "N/A"], "change": 1000, "struck": True},
    ]
    total = {"loan_amount": 1000, "balance": 900}
    assert validate(_minimal_extended(rows, total)).ok

    unstruck = copy.deepcopy(rows)
    unstruck[1]["struck"] = False
    res = validate(_minimal_extended(unstruck, total))
    assert any("loan_amount" in w and "不一致" in w for w in res.warnings)


def test_prev_balance_sums_checked(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][1]["groups"][1]["total"]["prev_balances"][0] = 1
    res = validate(data)
    assert any("prev_balances[0]" in w for w in res.warnings)


def test_total_change_checked_over_all_rows(sample_data):
    """total.change 語意＝全列（含刪除線）加總；改壞宣告值要出警告。"""
    data = copy.deepcopy(sample_data)
    data["entities"][1]["groups"][0]["total"]["change"] = 123
    res = validate(data)
    assert any("total.change" in w and "不一致" in w for w in res.warnings)


def test_total_change_with_null_row_warns_incomplete(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][1]["groups"][1]["rows"][3]["change"] = None
    res = validate(data)
    assert any("total.change" in w and "無法完整核對" in w for w in res.warnings)


def test_null_total_fields_skip_check(sample_data):
    data = copy.deepcopy(sample_data)
    data["entities"][0]["groups"][0]["total"] = {"loan_amount": None, "balance": None}
    res = validate(data)
    assert res.ok
    assert not any("不一致" in w for w in res.warnings)
