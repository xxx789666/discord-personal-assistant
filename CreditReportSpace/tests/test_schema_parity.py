"""schema-vs-model parity：JSON Schema 與 Python 驗證器對同批案例的
接受/拒絕必須一致（結構層）；語意層（change 核對等）model 可更嚴格，
但不得比 schema 寬鬆。"""

import copy
import json
from pathlib import Path

import pytest

jsonschema = pytest.importorskip("jsonschema")

from credit_report import validate

SPACE_ROOT = Path(__file__).resolve().parent.parent
SCHEMA = json.loads(
    (SPACE_ROOT / "schema" / "credit_report.schema.json").read_text(encoding="utf-8")
)
VALIDATOR = jsonschema.Draft7Validator(SCHEMA)


def _mutations(base):
    """(名稱, 資料, 預期兩邊一致) 的結構層案例。"""
    def mut(fn):
        data = copy.deepcopy(base)
        fn(data)
        return data

    yield "fixture-valid", copy.deepcopy(base)
    yield "missing-data-date", mut(lambda d: d["meta"].pop("data_date"))
    yield "bad-source-note-type", mut(lambda d: d["meta"].__setitem__("source_note", 123))
    yield "unknown-meta-field", mut(lambda d: d["meta"].__setitem__("extra", "x"))
    yield "bad-layout", mut(lambda d: d["entities"][0].__setitem__("layout", "fancy"))
    yield "simple-with-prev-labels", mut(
        lambda d: d["entities"][0].__setitem__("prev_labels", ["a", "b"]))
    yield "extended-missing-prev-labels", mut(
        lambda d: d["entities"][1].pop("prev_labels"))
    yield "simple-row-with-change", mut(
        lambda d: d["entities"][0]["groups"][0]["rows"][0].__setitem__("change", -5))
    yield "simple-total-with-change", mut(
        lambda d: d["entities"][0]["groups"][0]["total"].__setitem__("change", 0))
    yield "missing-balance-key", mut(
        lambda d: d["entities"][0]["groups"][0]["rows"][0].pop("balance"))
    yield "null-balance-no-flags", mut(
        lambda d: d["entities"][0]["groups"][0]["rows"][0].__setitem__("balance", None))
    yield "negative-loan-amount", mut(
        lambda d: d["entities"][0]["groups"][0]["rows"][0].__setitem__("loan_amount", -1))
    yield "negative-prev-balance", mut(
        lambda d: d["entities"][1]["groups"][0]["rows"][0].__setitem__(
            "prev_balances", [-1, 0]))
    yield "unknown-row-field", mut(
        lambda d: d["entities"][0]["groups"][0]["rows"][0].__setitem__("extra", 1))
    yield "unknown-total-field", mut(
        lambda d: d["entities"][0]["groups"][0]["total"].__setitem__("extra", 1))
    yield "string-amount", mut(
        lambda d: d["entities"][0]["groups"][0]["rows"][0].__setitem__(
            "loan_amount", "20,000"))
    yield "short-prev-balances", mut(
        lambda d: d["entities"][1]["groups"][0]["rows"][0].__setitem__(
            "prev_balances", [1]))
    yield "forbidden-pii-key", mut(lambda d: d.__setitem__("身分證號", "X"))
    yield "empty-entities", mut(lambda d: d.__setitem__("entities", []))
    yield "bad-role", mut(
        lambda d: d["entities"][0]["groups"][0].__setitem__("role", "第三方"))
    yield "explicit-null-total", mut(
        lambda d: d["entities"][0]["groups"][0].__setitem__("total", None))
    yield "explicit-null-notes", mut(
        lambda d: d["entities"][0].__setitem__("notes", None))
    yield "explicit-null-row-prev-balances", mut(
        lambda d: d["entities"][1]["groups"][0]["rows"][0].__setitem__(
            "prev_balances", None))
    yield "explicit-null-total-prev-balances", mut(
        lambda d: d["entities"][1]["groups"][0]["total"].__setitem__(
            "prev_balances", None))
    yield "null-loan-amount-no-flags", mut(
        lambda d: d["entities"][1]["groups"][0]["rows"][0].__setitem__(
            "loan_amount", None))
    yield "null-change-no-flags", mut(
        lambda d: d["entities"][1]["groups"][0]["rows"][0].__setitem__(
            "change", None))
    yield "null-prev-element-no-flags", mut(
        lambda d: d["entities"][1]["groups"][0]["rows"][0].__setitem__(
            "prev_balances", [None, 4000]))
    yield "na-loan-amount-accepted", mut(
        lambda d: d["entities"][1]["groups"][1]["rows"][0].__setitem__(
            "loan_amount", "N/A"))
    yield "na-balance-rejected", mut(
        lambda d: d["entities"][0]["groups"][0]["rows"][0].__setitem__(
            "balance", "N/A"))
    yield "na-prev-element-accepted", copy.deepcopy(base)  # fixture 本身已含 N/A


@pytest.mark.parametrize(
    "name,data",
    [(n, d) for n, d in _mutations(
        json.loads((SPACE_ROOT / "fixtures" / "sample_report.json").read_text(
            encoding="utf-8")))],
)
def test_structural_parity(name, data):
    schema_ok = VALIDATOR.is_valid(data)
    model_ok = validate(data).ok
    assert schema_ok == model_ok, (
        f"{name}: schema={'accept' if schema_ok else 'reject'} "
        f"model={'accept' if model_ok else 'reject'}"
    )


def test_model_at_least_as_strict_as_schema(sample_data):
    """語意層案例：schema 接受但 model 以 change 核對擋下 — 允許 model 更嚴，
    反向（schema 拒絕、model 接受）永遠不允許。"""
    data = copy.deepcopy(sample_data)
    data["entities"][1]["groups"][0]["rows"][0]["change"] = -49  # 與定義不符
    assert VALIDATOR.is_valid(data)          # schema 只看結構
    assert not validate(data).ok             # model 語意層更嚴格


def test_fixture_valid_under_both(sample_data):
    assert VALIDATOR.is_valid(sample_data)
    assert validate(sample_data).ok
