"""輸入 JSON 的驗證與合計核對（純標準庫，不依賴 jsonschema）。

驗證分兩級：
- errors  — 結構／型別錯誤，擋下產製。
- warnings — 資料可疑（合計對不上、needs_review 列存在…），照樣產製，
  但必須回報給使用者確認。
"""

from __future__ import annotations

from dataclasses import dataclass, field

VALID_ROLES = ("主債", "從債")
VALID_LAYOUTS = ("simple", "extended")

DEFAULT_SECTION_TITLE = "伍、金融借款：(仟元)"
DEFAULT_SOURCE_NOTE = "資料來源：財團法人金融聯合徵信中心信用報告。"

# 去識別化防呆：這些欄位名絕不允許出現在輸入 JSON 任何層級
FORBIDDEN_KEYS = {
    "id_number", "national_id", "身分證", "身分證號", "統一編號", "統編",
    "report_no", "報表編號", "account_no", "帳號",
}


@dataclass
class ValidationResult:
    errors: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors


NOT_APPLICABLE = "N/A"


def _is_amount(v) -> bool:
    return v is None or (isinstance(v, int) and not isinstance(v, bool))


def _is_amount_or_na(v) -> bool:
    """可選金額欄的值域：整數／null（未知）／\"N/A\"（明確不適用）。"""
    return _is_amount(v) or v == NOT_APPLICABLE


def _scan_forbidden_keys(node, path: str, res: ValidationResult) -> None:
    if isinstance(node, dict):
        for k, v in node.items():
            if k in FORBIDDEN_KEYS:
                res.errors.append(f"{path}.{k}: 禁止欄位（個資去識別化要求），請移除")
            _scan_forbidden_keys(v, f"{path}.{k}", res)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _scan_forbidden_keys(v, f"{path}[{i}]", res)


def _check_row(row, where: str, layout: str, res: ValidationResult) -> None:
    if not isinstance(row, dict):
        res.errors.append(f"{where}: 每一列必須是物件")
        return
    for key in ("bank", "item"):
        v = row.get(key)
        if not isinstance(v, str) or not v.strip():
            res.errors.append(f"{where}.{key}: 必填且須為非空字串")
    if "balance" not in row:
        res.errors.append(f"{where}.balance: 必填（未知請明確填 null 並標 needs_review）")
    if "balance" in row and not _is_amount(row["balance"]):
        res.errors.append(f"{where}.balance: 必須是整數（仟元）或 null，不接受字串")
    if "loan_amount" in row and not _is_amount_or_na(row["loan_amount"]):
        res.errors.append(f"{where}.loan_amount: 必須是整數（仟元）、null 或 \"N/A\"")
    for key in ("struck", "needs_review"):
        if key in row and not isinstance(row[key], bool):
            res.errors.append(f"{where}.{key}: 必須是 true/false")
    if "note" in row and not isinstance(row["note"], str):
        res.errors.append(f"{where}.note: 必須是字串")

    if layout == "extended":
        if "prev_balances" in row:
            pb = row["prev_balances"]
            if not (isinstance(pb, list) and len(pb) == 2 and all(_is_amount_or_na(x) for x in pb)):
                res.errors.append(
                    f"{where}.prev_balances: 必須是長度 2 的整數/null/\"N/A\" 陣列"
                    "（整欄不適用請省略欄位，不要填 null）"
                )
            elif any(isinstance(x, int) and x < 0 for x in pb):
                res.errors.append(f"{where}.prev_balances: 不可為負數")
        if "change" in row and not _is_amount_or_na(row["change"]):
            res.errors.append(f"{where}.change: 必須是整數（負數＝減少）、null 或 \"N/A\"")
    else:
        for key in ("prev_balances", "change"):
            if key in row:
                res.errors.append(f"{where}.{key}: simple 版不得出現此欄位")

    known = {"bank", "item", "loan_amount", "balance", "prev_balances",
             "change", "note", "struck", "needs_review"}
    for k in row:
        if k not in known:
            res.errors.append(f"{where}.{k}: 未定義的欄位")

    for key in ("loan_amount", "balance"):
        v = row.get(key)
        if isinstance(v, int) and v < 0:
            res.errors.append(f"{where}.{key}: 不可為負數（減少請用 extended 版 change 欄表達）")

    # 重要金額鐵律：任何「明確填 null＝未知」的金額，該列必須 needs_review
    # （沖轉列 struck 除外）。不適用請省略欄位或填 "N/A"，不要用 null。
    if not row.get("struck") and not row.get("needs_review"):
        null_fields = [
            key for key in ("balance", "loan_amount", "change")
            if key in row and row[key] is None
        ]
        pb = row.get("prev_balances")
        if isinstance(pb, list) and any(x is None for x in pb):
            null_fields.append("prev_balances")
        for key in null_fields:
            res.errors.append(
                f"{where}.{key}: 為 null（未知）的金額必須將該列 needs_review 設為 true"
                "（沖轉列請設 struck；明確不適用請省略欄位或填 \"N/A\"）"
            )


def _check_change_semantics(row, where: str, res: ValidationResult) -> None:
    """change 語意（extended 版）：change = 本期餘額 − prev_balances[0]（最近前期）。

    - 刪除線（沖轉/結清）列不核對：其 change 依聯徵慣例由人工照沖轉金額填寫。
    - 三值（餘額、最近前次餘額、change）皆為已知整數 → 嚴格核對，
      不符**一律硬錯誤**；needs_review 不得繞過已知數值間的矛盾。
    - 無法推導（餘額或前期為 null/\"N/A\"）但 change 有值 → 該列必須
      needs_review，否則警告；不得靜默跳過。
    """
    change = row.get("change")
    if row.get("struck") or not isinstance(change, int) or isinstance(change, bool):
        return
    balance = row.get("balance")
    if balance is not None and not _is_amount(balance):
        return
    prev = row.get("prev_balances") or [None, None]
    prev0 = prev[0] if isinstance(prev, list) and len(prev) == 2 else None
    if isinstance(balance, int) and isinstance(prev0, int):
        expected = balance - prev0
        if change != expected:
            res.errors.append(
                f"{where}.change: {change:,} 與定義不符"
                f"（change = 餘額 {balance:,} − 前次餘額 {prev0:,} = {expected:,}）；"
                "已知數值間的矛盾必須修正，needs_review 不能取代更正"
            )
    elif not row.get("needs_review"):
        res.warnings.append(
            f"{where}.change: 餘額或最近前次餘額非已知整數，change 無法核對，"
            "請將該列標 needs_review 或補齊數值"
        )


def _sum_rows(rows, getter):
    """非刪除線列的欄位和；至少一個非 null 才回傳數字，否則 None。"""
    vals = [getter(r) for r in rows if not r.get("struck")]
    vals = [v for v in vals if isinstance(v, int)]
    return sum(vals) if vals else None


def _check_total(group, where: str, layout: str, res: ValidationResult) -> None:
    if "total" not in group:
        return
    total = group["total"]
    if not isinstance(total, dict):
        res.errors.append(f"{where}.total: 必須是物件（不畫合計列請省略欄位，不要填 null）")
        return
    known = {"loan_amount", "balance", "prev_balances", "change"}
    for k in total:
        if k not in known:
            res.errors.append(f"{where}.total.{k}: 未定義的欄位")
    if layout == "simple":
        for key in ("prev_balances", "change"):
            if key in total:
                res.errors.append(f"{where}.total.{key}: simple 版不得出現此欄位")
    for key in ("loan_amount", "balance", "change"):
        if key in total and not _is_amount(total[key]):
            res.errors.append(f"{where}.total.{key}: 必須是整數或 null")
    for key in ("loan_amount", "balance"):
        if isinstance(total.get(key), int) and total[key] < 0:
            res.errors.append(f"{where}.total.{key}: 不可為負數")
    pb = total.get("prev_balances")
    if "prev_balances" in total and not (
        isinstance(pb, list) and len(pb) == 2 and all(_is_amount(x) for x in pb)
    ):
        res.errors.append(
            f"{where}.total.prev_balances: 必須是長度 2 的整數/null 陣列"
            "（不適用請省略欄位，不要填 null）"
        )
    elif isinstance(pb, list) and any(isinstance(x, int) and x < 0 for x in pb):
        res.errors.append(f"{where}.total.prev_balances: 不可為負數")
    if res.errors:
        return

    rows = group.get("rows", [])
    checks = [
        ("loan_amount", total.get("loan_amount"), _sum_rows(rows, lambda r: r.get("loan_amount"))),
        ("balance", total.get("balance"), _sum_rows(rows, lambda r: r.get("balance"))),
    ]
    if layout == "extended":
        if pb is not None:
            for i in (0, 1):
                checks.append((
                    f"prev_balances[{i}]", pb[i],
                    _sum_rows(rows, lambda r, i=i: (r.get("prev_balances") or [None, None])[i]),
                ))
    for name, declared, computed in checks:
        if declared is not None and computed is not None and declared != computed:
            res.warnings.append(
                f"{where}.total.{name}: 宣告合計 {declared:,} 與非刪除線列加總 {computed:,} 不一致，"
                "請人工確認（刪除線列不列入加總）"
            )

    # 增減合計語意：total.change = 全部列（含沖轉/刪除線列）change 之和。
    declared_change = total.get("change")
    if layout == "extended" and declared_change is not None:
        row_changes = [r.get("change") for r in rows]
        if any(not (isinstance(c, int) and not isinstance(c, bool)) for c in row_changes):
            res.warnings.append(
                f"{where}.total.change: 有列的 change 非已知整數（null/\"N/A\"），"
                "合計無法完整核對，請人工確認"
            )
        else:
            computed_change = sum(row_changes)
            if computed_change != declared_change:
                res.warnings.append(
                    f"{where}.total.change: 宣告合計 {declared_change:,} 與全列（含刪除線）"
                    f"加總 {computed_change:,} 不一致，請人工確認"
                )


def validate(data) -> ValidationResult:
    """驗證整份輸入 JSON。回傳 ValidationResult（errors / warnings）。"""
    res = ValidationResult()
    if not isinstance(data, dict):
        res.errors.append("$: 輸入必須是 JSON 物件")
        return res

    _scan_forbidden_keys(data, "$", res)

    meta = data.get("meta")
    if not isinstance(meta, dict):
        res.errors.append("$.meta: 必填且須為物件")
    else:
        dd = meta.get("data_date")
        if not isinstance(dd, str) or not dd.strip():
            res.errors.append("$.meta.data_date: 必填且須為非空字串（例：資料日期-2026年1月底）")
        for key in ("section_title", "source_note"):
            if key in meta and not isinstance(meta[key], str):
                res.errors.append(f"$.meta.{key}: 必須是字串")
        for k in meta:
            if k not in {"section_title", "data_date", "source_note"}:
                res.errors.append(f"$.meta.{k}: 未定義的欄位")

    entities = data.get("entities")
    if not isinstance(entities, list) or not entities:
        res.errors.append("$.entities: 必填且至少一個 entity")
        entities = []

    for ei, ent in enumerate(entities):
        ew = f"$.entities[{ei}]"
        if not isinstance(ent, dict):
            res.errors.append(f"{ew}: 必須是物件")
            continue
        name = ent.get("name")
        if not isinstance(name, str) or not name.strip():
            res.errors.append(f"{ew}.name: 必填且須為非空字串")
        layout = ent.get("layout")
        if layout not in VALID_LAYOUTS:
            res.errors.append(f"{ew}.layout: 必須是 {VALID_LAYOUTS} 之一")
            layout = "simple"
        if layout == "extended":
            pl = ent.get("prev_labels")
            if not (isinstance(pl, list) and len(pl) == 2 and all(isinstance(x, str) and x for x in pl)):
                res.errors.append(f"{ew}.prev_labels: extended 版必填，長度 2 的字串陣列")
        elif "prev_labels" in ent:
            res.errors.append(f"{ew}.prev_labels: simple 版不得出現")
        notes = ent.get("notes")
        if "notes" in ent and not (
            isinstance(notes, list) and all(isinstance(n, str) for n in notes)
        ):
            res.errors.append(f"{ew}.notes: 必須是字串陣列（沒有說明請省略欄位，不要填 null）")
        for k in ent:
            if k not in {"name", "layout", "prev_labels", "groups", "notes"}:
                res.errors.append(f"{ew}.{k}: 未定義的欄位")

        groups = ent.get("groups")
        if not isinstance(groups, list) or not groups:
            res.errors.append(f"{ew}.groups: 必填且至少一個群組")
            continue
        for gi, group in enumerate(groups):
            gw = f"{ew}.groups[{gi}]"
            if not isinstance(group, dict):
                res.errors.append(f"{gw}: 必須是物件")
                continue
            if group.get("role") not in VALID_ROLES:
                res.errors.append(f"{gw}.role: 必須是 {VALID_ROLES} 之一")
            rows = group.get("rows")
            if not isinstance(rows, list) or not rows:
                res.errors.append(f"{gw}.rows: 必填且至少一列")
                continue
            for ri, row in enumerate(rows):
                _check_row(row, f"{gw}.rows[{ri}]", layout, res)
                if layout == "extended" and isinstance(row, dict):
                    _check_change_semantics(row, f"{gw}.rows[{ri}]", res)
            for k in group:
                if k not in {"role", "rows", "total"}:
                    res.errors.append(f"{gw}.{k}: 未定義的欄位")
            if not res.errors:
                _check_total(group, gw, layout, res)
                for ri, row in enumerate(rows):
                    if row.get("needs_review"):
                        res.warnings.append(
                            f"{gw}.rows[{ri}]（{row.get('bank')} {row.get('item')}）標記待人工確認"
                        )
    return res


def fmt_amount(v, *, change: bool = False) -> str:
    """金額 → 表格字串。None → 空白；"N/A" → 「—」；change 欄負數 → (絕對值)。"""
    if v is None:
        return ""
    if v == NOT_APPLICABLE:
        return "—"
    if change and v < 0:
        return f"({abs(v):,})"
    return f"{v:,}"
