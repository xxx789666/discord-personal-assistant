# 銷售中物件參照 + 實價登錄改 2 年 — 實作計畫

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓 `#不動產估價` 頻道在估價時，除了實價登錄成交價，另外查詢附近銷售中物件的開價、扣除議價空間後作為交叉驗證參照；同時把實價登錄預設查詢年限從 3 年縮短為 2 年。

**Architecture:** 新增獨立 CLI 工具 `tools/listing.py`，形態完全比照既有的 `tools/lvr.py`（PEP 723 inline deps、`uv run` 執行、純文字輸出給 agent 讀）。它從好房網公開的地區頁抓銷售中物件，行為受 robots.txt 與節流約束。估價方法論寫在 `AGENTS.md`：實價登錄是估價基準，折後開價只做交叉驗證。兩支工具彼此獨立，不共用程式碼。

**Tech Stack:** Python ≥3.10、`httpx`、`beautifulsoup4`、`truststore`、`pytest`；容器內以 `uv run` 執行（沒有 `curl` / `python3`）。

**Spec:** `EstateSpace/docs/specs/2026-08-04-listing-reference-design.md`

---

## File Structure

| 檔案 | 職責 |
|---|---|
| `tools/listing.py`（新增） | 好房網銷售中物件查詢：抓取、解析、篩選、折算、統計、輸出。單檔，比照 `lvr.py` 的單檔慣例 |
| `tests/fixtures/housefun_list.html`（新增） | 真實列表頁快照，parser 測試用 |
| `tests/test_listing.py`（新增） | parser／折算／統計的單元測試 |
| `tools/lvr.py`（修改，第 226 行） | 預設年限 3 → 2 |
| `AGENTS.md`（修改） | 查詢階梯、新增 §銷售中參照、回覆格式、目錄約定 |
| `WebAccess.md`（修改） | 年限說明修正、新增 `listing.py` 用法 |

`listing.py` 內部分四段，與 `lvr.py` 相同的排列順序：常數與合規設定 → 解析函式 → 統計／折算函式 → `main()` CLI。解析與計算都是純函式，不碰網路，方便測試。

---

## Task 1: Spike — 確認地區頁 URL 與 robots 允許範圍

**這是所有後續工作的前提。** 若地區頁被 robots 禁止或格式與預期不符，後面的任務都要改。

**Files:**
- 產出：`tests/fixtures/housefun_list.html`

- [ ] **Step 1: 取得 robots.txt 並確認 `/region/` 未被禁止**

在容器內執行：

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run --with httpx python -c "
import httpx
r = httpx.get(\"https://buy.housefun.com.tw/robots.txt\", timeout=30)
print(r.text)
"'
```

預期輸出含 `Allow: /`，以及四條 `Disallow`：
`/buy/detailprint/*`、`/Building/building_print*`、`/Building/building_street*`、`/building/building_street*`。

**判斷**：`/region/` 不在 Disallow 清單 → 可繼續。
若清單已改變且包含 `/region`，**停止並回報使用者**，不要繞過。

- [ ] **Step 2: 確認區級 URL 格式**

已知城市級格式為 `https://buy.housefun.com.tw/region/{地區}_c/`（地區名 URL-encoded），
分頁為 `?pg=N`。需確認**區級**（如「桃園市桃園區」）的實際形式。

依序試這三種，記錄哪一種回傳正確的區級結果：

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run --with httpx python -c "
import httpx, urllib.parse
UA = \"EstateSpaceValuation/1.0 (+https://github.com/xxx789666/discord-personal-assistant)\"
for path in [\"桃園市桃園區_c\", \"桃園市_c/桃園區_z\", \"桃園市_c\"]:
    url = \"https://buy.housefun.com.tw/region/\" + urllib.parse.quote(path) + \"/\"
    try:
        r = httpx.get(url, headers={\"User-Agent\": UA}, timeout=30, follow_redirects=False)
        print(path, r.status_code, len(r.text))
    except Exception as e:
        print(path, \"ERR\", e)
"'
```

預期：正確格式回 `200` 且內容長度數萬字元。記下可用的格式，Task 5 會用到。

- [ ] **Step 3: 存一份真實列表頁當 fixture**

用 Step 2 確認可行的 URL：

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && mkdir -p tests/fixtures && uv run --with httpx python -c "
import httpx, urllib.parse
UA = \"EstateSpaceValuation/1.0 (+https://github.com/xxx789666/discord-personal-assistant)\"
url = \"https://buy.housefun.com.tw/region/\" + urllib.parse.quote(\"<Step2 確認的格式>\") + \"/\"
r = httpx.get(url, headers={\"User-Agent\": UA}, timeout=30)
open(\"tests/fixtures/housefun_list.html\", \"w\", encoding=\"utf-8\").write(r.text)
print(len(r.text))
"'
```

- [ ] **Step 4: 確認 fixture 含可解析的物件卡片**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run --with beautifulsoup4 python -c "
from bs4 import BeautifulSoup
html = open(\"tests/fixtures/housefun_list.html\", encoding=\"utf-8\").read()
soup = BeautifulSoup(html, \"html.parser\")
cards = soup.select(\"section.m-list-obj\")
print(\"cards:\", len(cards))
c = cards[0]
for sel in [\"a[href^=/buy/house/]\", \"address.address\", \".ping-number .number\", \".discount-price .number\", \".casename a\"]:
    print(sel, \"->\", bool(c.select_one(sel)))
"'
```

預期：`cards:` 大於 0，五個選擇器全部 `True`。

**若選擇器已失效**（版面改版），停止並回報 —— 需要重新對照實際 HTML 調整選擇器，
不要猜。

- [ ] **Step 5: Commit fixture**

```bash
git add EstateSpace/tests/fixtures/housefun_list.html
git commit -m "test(estate): add HouseFun list page fixture

Real snapshot captured for parser tests. Selectors verified against it:
section.m-list-obj cards with address, ping-number, discount-price and
casename nodes."
```

---

## Task 2: Parser（TDD）

把 HTML 解析成結構化物件。純函式，不碰網路。

**Files:**
- Create: `tools/listing.py`
- Test: `tests/test_listing.py`

- [ ] **Step 1: 寫失敗的測試**

`tests/test_listing.py`：

```python
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from listing import Listing, parse_list_page  # noqa: E402

FIXTURE = Path(__file__).parent / "fixtures" / "housefun_list.html"


def test_parse_returns_listings():
    items = parse_list_page(FIXTURE.read_text(encoding="utf-8"))
    assert len(items) > 0
    assert all(isinstance(i, Listing) for i in items)


def test_parsed_fields_are_sane():
    items = parse_list_page(FIXTURE.read_text(encoding="utf-8"))
    first = items[0]
    assert first.city.endswith(("市", "縣"))
    assert first.district.endswith(("區", "鄉", "鎮", "市"))
    assert first.total_price_twd > 0
    assert first.area_ping > 0
    assert first.unit_price_per_ping == round(first.total_price_twd / first.area_ping)
    assert first.url.startswith("https://buy.housefun.com.tw/buy/house/")


def test_malformed_cards_are_skipped_not_raised():
    assert parse_list_page("<html><body><section class='m-list-obj'></section></body></html>") == []
```

- [ ] **Step 2: 執行測試，確認失敗**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run --with pytest --with beautifulsoup4 pytest tests/test_listing.py -v'
```

預期：`ModuleNotFoundError: No module named 'listing'`

- [ ] **Step 3: 實作 parser**

建立 `tools/listing.py`：

```python
# /// script
# requires-python = ">=3.10"
# dependencies = ["httpx", "beautifulsoup4", "truststore"]
# ///
"""好房網銷售中物件查詢 — 開價扣議價空間後，供估價交叉驗證。

與 tools/lvr.py 的分工：
  lvr.py    內政部實價登錄 open data → 過去的「成交價」（事實，但有登錄時間差）
  listing.py 好房網公開地區頁       → 當下的「開價」（即時，但含賣方意圖）
估價基準一律是 lvr.py 的成交中位數；本工具的折後開價只做交叉驗證（見 AGENTS.md）。

合規（沿用 property-case-radar 的 crawlers/sale/housefun_source.py 已驗證行為）：
  - 每次執行先讀 robots.txt 並驗證目標路徑
  - User-Agent 標明來源與用途，不偽裝瀏覽器
  - 請求間隔 >= 2 秒、頁數上限 3
  - 絕不觸碰 /building/building_street*（robots.txt 明文禁止的街道層級頁）
    因此 --road 是「回傳後對地址做子字串篩選」，不是請求街道頁。

用法：
    uv run tools/listing.py --city 桃園市 --district 桃園區 --road 永安路 --type 透天
    uv run tools/listing.py --city 桃園市 --district 平鎮區 --land --discount 0.12
"""
from __future__ import annotations

import re
import sys
from dataclasses import dataclass

from bs4 import BeautifulSoup

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

BASE_URL = "https://buy.housefun.com.tw"
ROBOTS_URL = f"{BASE_URL}/robots.txt"
USER_AGENT = (
    "EstateSpaceValuation/1.0 "
    "(+https://github.com/xxx789666/discord-personal-assistant)"
)
MIN_DELAY_SECONDS = 2.0
MAX_PAGES = 3


@dataclass(frozen=True)
class Listing:
    source_id: str
    url: str
    city: str
    district: str
    address: str
    total_price_twd: int
    area_ping: float
    unit_price_per_ping: int
    building_type: str | None = None
    layout: str | None = None
    floor: str | None = None
    has_parking: bool = False


def _split_location(address: str) -> tuple[str, str]:
    normalized = (address.strip()
                  .replace("台北市", "臺北市").replace("台中市", "臺中市")
                  .replace("台南市", "臺南市").replace("台東縣", "臺東縣"))
    match = re.match(r"^(?P<city>.{2,3}[市縣])(?P<district>.+?[區鄉鎮市])", normalized)
    if match is None:
        raise ValueError("address has no city/district")
    return match.group("city"), match.group("district")


def _number(text: str) -> float:
    return float(text.replace(",", "").strip())


def _classify(title: str) -> str | None:
    normalized = title.replace("工業地", "工業用地")
    for keyword in ("透天", "別墅", "華廈", "住宅大樓", "大樓", "公寓", "套房",
                    "農地", "建地", "工業用地", "土地"):
        if keyword in normalized:
            return keyword
    return None


def parse_list_page(html: str) -> list[Listing]:
    """把好房網列表頁 HTML 解析成 Listing。壞掉的卡片跳過，不拋例外。"""
    soup = BeautifulSoup(html, "html.parser")
    found: dict[str, Listing] = {}
    for card in soup.select("section.m-list-obj"):
        try:
            link = card.select_one('a[href^="/buy/house/"]')
            address_node = card.select_one("address.address")
            area_node = card.select_one(".ping-number .number")
            price_node = card.select_one(".discount-price .number")
            title_node = card.select_one(".casename a")
            if not all((link, address_node, area_node, price_node, title_node)):
                continue
            identifier = re.fullmatch(r"/buy/house/(\d+)", link.get("href", ""))
            if identifier is None:
                continue
            address = address_node.get_text(" ", strip=True)
            city, district = _split_location(address)
            area = _number(area_node.get_text(strip=True))
            total = int(_number(price_node.get_text(strip=True)) * 10_000)
            if area <= 0 or total <= 0:
                continue
            layout = card.select_one(".ping-pattern .pattern")
            floor = card.select_one(".ping-pattern .floor")
            found[identifier.group(1)] = Listing(
                source_id=identifier.group(1),
                url=f"{BASE_URL}{link['href']}",
                city=city,
                district=district,
                address=address,
                total_price_twd=total,
                area_ping=area,
                unit_price_per_ping=round(total / area),
                building_type=_classify(title_node.get_text(" ", strip=True)),
                layout=layout.get_text(" ", strip=True) if layout else None,
                floor=floor.get_text(" ", strip=True) if floor else None,
                has_parking=card.select_one(".ping-pattern .park") is not None,
            )
        except (ArithmeticError, TypeError, ValueError):
            continue
    return list(found.values())
```

- [ ] **Step 4: 執行測試，確認通過**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run --with pytest --with beautifulsoup4 pytest tests/test_listing.py -v'
```

預期：3 passed

- [ ] **Step 5: Commit**

```bash
git add EstateSpace/tools/listing.py EstateSpace/tests/test_listing.py
git commit -m "feat(estate): parse HouseFun listing pages

Pure function over HTML, no network. Malformed cards are skipped rather
than raising, so one bad card cannot lose a whole page."
```

---

## Task 3: 折算與統計（TDD）

**Files:**
- Modify: `tools/listing.py`
- Test: `tests/test_listing.py`

- [ ] **Step 1: 寫失敗的測試**

追加到 `tests/test_listing.py`：

```python
from listing import apply_discount, summarize  # noqa: E402


def test_apply_discount_default_is_eight_percent():
    assert apply_discount(1000, 0.08) == 920


def test_apply_discount_zero_is_identity():
    assert apply_discount(1000, 0.0) == 1000


def test_apply_discount_rejects_out_of_range():
    import pytest
    for bad in (-0.1, 1.0, 1.5):
        with pytest.raises(ValueError):
            apply_discount(1000, bad)


def test_summarize_even_count_uses_midpoint():
    stats = summarize([10, 20, 30, 40])
    assert stats["median"] == 25
    assert stats["mean"] == 25
    assert stats["min"] == 10
    assert stats["max"] == 40
    assert stats["count"] == 4


def test_summarize_single_value():
    assert summarize([42]) == {"median": 42, "mean": 42, "min": 42, "max": 42, "count": 1}


def test_summarize_empty_returns_none_not_raise():
    assert summarize([]) is None
```

- [ ] **Step 2: 執行測試，確認失敗**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run --with pytest --with beautifulsoup4 pytest tests/test_listing.py -v'
```

預期：`ImportError: cannot import name 'apply_discount'`

- [ ] **Step 3: 實作**

在 `tools/listing.py` 的 parser 之後加入：

```python
from statistics import mean, median


def apply_discount(unit_price: int, discount: float) -> int:
    """開價單價 × (1 − 議價空間)。discount 必須在 [0, 1)。"""
    if not 0 <= discount < 1:
        raise ValueError("discount must be in [0, 1)")
    return round(unit_price * (1 - discount))


def summarize(values: list[float]) -> dict[str, float] | None:
    """單價統計。空集合回 None（呼叫端負責顯示「無資料」），不拋例外。"""
    if not values:
        return None
    return {
        "median": median(values),
        "mean": mean(values),
        "min": min(values),
        "max": max(values),
        "count": len(values),
    }
```

- [ ] **Step 4: 執行測試，確認通過**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run --with pytest --with beautifulsoup4 pytest tests/test_listing.py -v'
```

預期：9 passed

- [ ] **Step 5: Commit**

```bash
git add EstateSpace/tools/listing.py EstateSpace/tests/test_listing.py
git commit -m "feat(estate): discount and summary helpers

apply_discount rejects out-of-range values rather than silently producing
a negative or unchanged price. summarize returns None on empty input so
the caller prints 'no data' instead of handling an exception."
```

---

## Task 4: 篩選（TDD）

`--road` 與 `--type` 是客戶端篩選 —— robots.txt 禁止街道層級頁，所以路名不能進 URL。

**Files:**
- Modify: `tools/listing.py`
- Test: `tests/test_listing.py`

- [ ] **Step 1: 寫失敗的測試**

```python
from listing import filter_listings  # noqa: E402


def _listing(**kw):
    base = dict(source_id="1", url="u", city="桃園市", district="桃園區",
                address="桃園市桃園區永安路100號", total_price_twd=1000,
                area_ping=10.0, unit_price_per_ping=100, building_type="透天")
    base.update(kw)
    return Listing(**base)


def test_filter_by_road_matches_substring_of_address():
    items = [_listing(), _listing(source_id="2", address="桃園市桃園區中山路5號")]
    assert [i.source_id for i in filter_listings(items, road="永安路")] == ["1"]


def test_filter_by_type():
    items = [_listing(), _listing(source_id="2", building_type="公寓")]
    assert [i.source_id for i in filter_listings(items, building_type="公寓")] == ["2"]


def test_filter_with_no_criteria_returns_all():
    items = [_listing(), _listing(source_id="2")]
    assert len(filter_listings(items)) == 2
```

- [ ] **Step 2: 執行測試，確認失敗**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run --with pytest --with beautifulsoup4 pytest tests/test_listing.py -v'
```

預期：`ImportError: cannot import name 'filter_listings'`

- [ ] **Step 3: 實作**

```python
def filter_listings(
    items: list[Listing],
    *,
    road: str = "",
    building_type: str = "",
) -> list[Listing]:
    """客戶端篩選。road 比對地址子字串 —— robots.txt 禁止街道層級頁，
    所以路名永遠不能出現在請求 URL 裡。"""
    result = items
    if road:
        result = [i for i in result if road in i.address]
    if building_type:
        result = [i for i in result if i.building_type and building_type in i.building_type]
    return result
```

- [ ] **Step 4: 執行測試，確認通過**

預期：12 passed

- [ ] **Step 5: Commit**

```bash
git add EstateSpace/tools/listing.py EstateSpace/tests/test_listing.py
git commit -m "feat(estate): client-side road and type filters

road filters the address string after fetching. HouseFun's robots.txt
disallows /building/building_street*, so a road name must never reach the
request URL."
```

---

## Task 5: 網路層與 CLI

不寫單元測試（屬整合行為），靠 Task 6 實跑驗證。

**Files:**
- Modify: `tools/listing.py`

- [ ] **Step 1: 實作抓取與 robots 驗證**

```python
import asyncio
import ssl
import time
import urllib.parse
from urllib.robotparser import RobotFileParser

import httpx
import truststore


class ListingFetchError(RuntimeError):
    pass


def region_url(city: str, district: str, page: int) -> str:
    """區級地區頁。<Task 1 Step 2 確認的格式>"""
    slug = urllib.parse.quote(f"{city}{district}_c")
    base = f"{BASE_URL}/region/{slug}/"
    return base if page == 1 else f"{base}?pg={page}"


async def _fetch_pages(city: str, district: str, max_pages: int) -> list[Listing]:
    client = httpx.AsyncClient(
        timeout=30,
        follow_redirects=False,
        verify=truststore.SSLContext(ssl.PROTOCOL_TLS_CLIENT),
    )
    last_request_at: float | None = None

    async def get(url: str) -> httpx.Response:
        nonlocal last_request_at
        if last_request_at is not None:
            remaining = MIN_DELAY_SECONDS - (time.monotonic() - last_request_at)
            if remaining > 0:
                await asyncio.sleep(remaining)
        last_request_at = time.monotonic()
        response = await client.get(url, headers={"User-Agent": USER_AGENT})
        response.raise_for_status()
        return response

    try:
        robots_text = (await get(ROBOTS_URL)).text
        robots = RobotFileParser()
        robots.set_url(ROBOTS_URL)
        robots.parse(robots_text.splitlines())
        first = region_url(city, district, 1)
        if not robots.can_fetch(USER_AGENT, first):
            raise ListingFetchError(f"robots.txt disallows {first}")

        found: dict[str, Listing] = {}
        for page in range(1, min(max_pages, MAX_PAGES) + 1):
            for item in parse_list_page((await get(region_url(city, district, page))).text):
                found[item.source_id] = item
        return list(found.values())
    finally:
        await client.aclose()
```

- [ ] **Step 2: 實作 CLI 與輸出**

```python
import argparse


def main() -> int:
    p = argparse.ArgumentParser(description="好房網銷售中物件查詢（開價扣議價空間）")
    p.add_argument("--city", required=True, help="縣市，如 桃園市")
    p.add_argument("--district", required=True, help="鄉鎮市區，如 桃園區")
    p.add_argument("--road", default="", help="路名／地段（對地址做子字串篩選）")
    p.add_argument("--type", dest="building_type", default="",
                   help="型態關鍵字，如 透天 / 公寓 / 華廈 / 住宅大樓")
    p.add_argument("--land", action="store_true", help="土地模式（型態預設比對土地類）")
    p.add_argument("--discount", type=float, default=0.08,
                   help="議價空間，預設 0.08（8%%）")
    p.add_argument("--limit", type=int, default=30, help="最多列出幾筆")
    p.add_argument("--max-pages", type=int, default=MAX_PAGES,
                   help=f"抓取頁數上限（硬上限 {MAX_PAGES}）")
    a = p.parse_args()

    if not 0 <= a.discount < 1:
        print("--discount 必須在 [0, 1)", file=sys.stderr)
        return 2

    try:
        items = asyncio.run(_fetch_pages(a.city, a.district, a.max_pages))
    except ListingFetchError as exc:
        print(f"[中止] {exc}", file=sys.stderr)
        return 1
    except httpx.HTTPError as exc:
        print(f"[網路失敗] {exc}", file=sys.stderr)
        return 1

    wanted_type = a.building_type or ("土地" if a.land else "")
    items = filter_listings(items, road=a.road, building_type=wanted_type)

    scope = f"{a.city}{a.district}" + (f" {a.road}" if a.road else "")
    print(f"[銷售中] {scope}　議價空間 {a.discount:.0%}　共 {len(items)} 筆\n")
    if not items:
        print("(無符合條件的銷售中物件 — 本次無銷售中參照)")
        return 0

    for item in items[: a.limit]:
        asking = item.unit_price_per_ping / 10_000
        after = apply_discount(item.unit_price_per_ping, a.discount) / 10_000
        print(f"  {item.address}　{item.building_type or '—'}　{item.area_ping:.2f} 坪　"
              f"開價 {asking:.2f} 萬/坪 → 折後 {after:.2f} 萬/坪")

    asking_stats = summarize([i.unit_price_per_ping / 10_000 for i in items])
    after_stats = summarize([apply_discount(i.unit_price_per_ping, a.discount) / 10_000
                             for i in items])
    fmt = "{:.2f}"
    print(f"\n[開價統計 萬/坪] 中位數 {fmt.format(asking_stats['median'])}　"
          f"平均 {fmt.format(asking_stats['mean'])}　"
          f"最低 {fmt.format(asking_stats['min'])}　最高 {fmt.format(asking_stats['max'])}")
    print(f"[折後統計 萬/坪] 中位數 {fmt.format(after_stats['median'])}　"
          f"平均 {fmt.format(after_stats['mean'])}　"
          f"最低 {fmt.format(after_stats['min'])}　最高 {fmt.format(after_stats['max'])}")
    if len(items) < 3:
        print("\n⚠ 樣本不足 3 筆，僅供參考，不納入落差示警判斷")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 3: 確認既有測試仍通過**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run --with pytest --with beautifulsoup4 pytest tests/test_listing.py -v'
```

預期：12 passed

- [ ] **Step 4: Commit**

```bash
git add EstateSpace/tools/listing.py
git commit -m "feat(estate): fetch layer and CLI for listing.py

robots.txt is checked on every run before any region page is requested,
and a disallow aborts instead of falling back. Requests are spaced by at
least 2s and capped at 3 pages. Output prints both asking and discounted
statistics so the discount is always auditable."
```

---

## Task 6: 實跑驗證

- [ ] **Step 1: 正常查詢**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run tools/listing.py --city 桃園市 --district 桃園區 --limit 5'
```

預期：印出 `[銷售中] 桃園市桃園區　議價空間 8%　共 N 筆`、數筆物件、兩組統計。

- [ ] **Step 2: 路名篩選**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run tools/listing.py --city 桃園市 --district 桃園區 --road 永安路'
```

預期：筆數少於 Step 1；若為 0 筆，應印出「無符合條件」而非報錯。

- [ ] **Step 3: 議價空間覆寫**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run tools/listing.py --city 桃園市 --district 桃園區 --discount 0.12 --limit 3'
```

預期：標頭顯示 `議價空間 12%`，折後單價相對 Step 1 更低。

- [ ] **Step 4: 錯誤輸入**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run tools/listing.py --city 桃園市 --district 桃園區 --discount 1.5; echo "exit=$?"'
```

預期：`--discount 必須在 [0, 1)`，`exit=2`

- [ ] **Step 5: 確認輸出長度不會撐爆 context**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run tools/listing.py --city 桃園市 --district 桃園區 | wc -c'
```

預期：小於 8000 字元（比照 `web.py` 的截斷門檻）。若超過，調降 `--limit` 預設值。

- [ ] **Step 6: Commit（若前述步驟需要微調）**

```bash
git add EstateSpace/tools/listing.py
git commit -m "fix(estate): adjust listing.py defaults from live run"
```

---

## Task 7: 實價登錄改 2 年

**Files:**
- Modify: `tools/lvr.py:226`
- Modify: `WebAccess.md:32`

- [ ] **Step 1: 改預設值**

`tools/lvr.py` 第 225-226 行：

```python
    if a.years is None:
        a.years = 3
```

改為：

```python
    if a.years is None:
        a.years = 2
```

- [ ] **Step 2: 驗證生效**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run tools/lvr.py --city 桃園市 --road 永安路 2>&1 | head -3'
```

預期：標頭出現「近 2 年」。

- [ ] **Step 3: 同步 `WebAccess.md`**

第 32 行：

```
`--years`（近幾年，**預設 3，房屋/土地皆同**；樣本不足才照 SOP 階梯放寬到 5）、
```

改為：

```
`--years`（近幾年，**預設 2，房屋/土地皆同**；樣本不足才照 SOP 階梯放寬到 4）、
```

第 27 行的土地範例 `--years 5` 改為 `--years 4`。
（第 13 行註解原本就寫「近 2 年」，改完即與實際一致。）

- [ ] **Step 4: 新增 `listing.py` 用法到 `WebAccess.md`**

在「## 備用：一般網頁抓取」之前插入新段落：

```markdown
## 銷售中物件參照 `tools/listing.py`

好房網公開地區頁的**銷售中物件開價**，扣議價空間後供交叉驗證。
資料性質與 `lvr.py` 互補：成交是事實但落後，開價即時但含賣方意圖。

```bash
# 區級查詢（robots.txt 禁止街道層級頁，--road 是回傳後的地址篩選）
uv run tools/listing.py --city 桃園市 --district 桃園區 --road 永安路 --type 透天

# 土地；議價空間改 12%（預設 8%）
uv run tools/listing.py --city 桃園市 --district 平鎮區 --land --discount 0.12
```

輸出含每筆（地址／型態／坪數／開價單坪／折後單坪）與兩組統計（開價、折後）。
查不到時印「無符合條件」並正常結束，**不阻斷估價**。

合規：每次執行先驗 robots.txt、User-Agent 標明來源、請求間隔 ≥2 秒、頁數上限 3。
```

- [ ] **Step 5: Commit**

```bash
git add EstateSpace/tools/lvr.py EstateSpace/WebAccess.md
git commit -m "feat(estate): default LVR window to 2 years, document listing.py

The comment on WebAccess.md line 13 already claimed 2 years while the
flag documentation said 3 and the code defaulted to 3; this makes all
three agree. Ladder fallback shortens from 5 to 4 years to stay
proportional."
```

---

## Task 8: `AGENTS.md` 方法論

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: 改查詢階梯（第 34-48 行 §查詢年限與樣本門檻）**

- 第 39 行「**先查近 3 年**（工具預設，不必帶 `--years`）」→「**先查近 2 年**（工具預設，不必帶 `--years`）」
- 第 44 行「才放寬年限 `--years 5`（先 3 年地段、再 3 年整區、最後才 5 年）」
  →「才放寬年限 `--years 4`（先 2 年地段、再 2 年整區、最後才 4 年）」
- 第 46 行「真的連 5 年整區」→「真的連 4 年整區」
- 第 48 行「放寬到『鄰近/整區』或『5 年』時」→「…或『4 年』時」

- [ ] **Step 2: 同步兩個 SOP 內的年限敘述**

- §建物 SOP 第 62-63 行：「（預設 3 年 → 不足先放寬整區 → 再 --years 5）」→「（預設 2 年 → 不足先放寬整區 → 再 --years 4）」
- §土地 SOP 第 96-100 行的範例註解：「先查同地段近 3 年（工具預設 3 年…）」→ 2 年；「還是 < 3 筆 → 才加 --years 5」→ `--years 4`

- [ ] **Step 3: 新增 §銷售中參照（放在 §土地 SOP 之後、§謄本設定金額 之前）**

```markdown
## §銷售中參照（開價扣議價空間）

每次估價都做：實價登錄查完後，再查一次附近**銷售中**物件的開價，扣議價空間
後與成交價交叉驗證。兩者性質不同 —— 成交是**事實**但有登錄時間差，開價是
賣方**意圖**且即時。

```bash
uv run tools/listing.py --city 桃園市 --district 桃園區 --road 永安路 --type 透天
```

**折算**：`折後單價 = 開價單價 × (1 − 議價空間)`。預設 **8%**；使用者若指明
（「這區議價空間約 12%」）就用他給的，以 `--discount 0.12` 傳入。
**回覆一律註明實際採用的百分比。**

**怎麼用（重要）**：

1. **估價金額仍以實價登錄成交中位數為基準。** 折後開價**不參與**計算。
   理由：成交是事實，折後開價多帶一層議價空間假設，兩者不該等權。
2. 折後開價只做**交叉驗證**：
   - 落差 ≤ 15% → 在回覆標「一致」，提高信心
   - 落差 > 15% → **示警**，並列出可能原因（屋主開價偏高／近期行情變動／
     樣本型態不一致），建議使用者實地確認
   - 落差計算：`|折後開價中位數 − 成交中位數| ÷ 成交中位數`
3. **土地例外**：土地本來就報區間，折後開價可參與區間**上緣**認定。
4. **樣本 < 3 筆**：仍可列出，但標「樣本不足、僅供參考」，**不**納入落差示警判斷。
5. **查不到**：明確寫「本次無銷售中參照」，估價照常以實價登錄進行，**不阻斷流程**。
6. robots.txt 禁止街道層級頁，所以只能查到「縣市＋區」，路名是回傳後篩選 ——
   若路名篩完筆數過少，在回覆中說明已放寬到整區。
```

- [ ] **Step 4: 更新回覆格式骨架（第 146-157 行）**

在【比價】與【估價】之間插入：

```
【銷售中參照】桃園區永安路周邊，3 筆在售（議價空間 8%）：
  ・永安路 xxx 號 透天 68.5 萬/坪（開價）→ 63.0 萬/坪（折後）
  ・…
  → 折後中位數：63.0 萬/坪
  ⚠ 與成交中位數 64.2 萬/坪 差 1.9%，一致
```

末行免責聲明改為：

```
※ 估值為實價登錄比價推估，非正式鑑價；標示部數據由使用者提供；
   銷售中為開價扣 8% 議價空間後之參照，非成交價。
```

- [ ] **Step 5: 更新目錄約定（第 169-179 行）**

```
├── tools/
│   ├── lvr.py     ← 實價登錄比價（官方 open data，純 HTTP；估價基準）
│   ├── listing.py ← 銷售中物件開價（好房網公開頁；交叉驗證用）
│   └── web.py     ← Steel Browser 一般網頁抓取（備用）
├── tests/         ← parser/折算/統計單元測試（uv run --with pytest）
└── Output/        ← 長輸出（成交清單、估價報告）
```

- [ ] **Step 6: 檢查全檔沒有殘留的「3 年」「5 年」**

```bash
cd "D:/discord 個人助理/EstateSpace" && grep -nE "3 年|5 年|years 5|預設 3" AGENTS.md WebAccess.md
```

預期：無輸出（或僅剩與年限無關的命中，需逐一確認）。

- [ ] **Step 7: Commit**

```bash
git add EstateSpace/AGENTS.md
git commit -m "feat(estate): add on-market listing reference to valuation SOP

Transactions remain the valuation basis; discounted asking prices only
cross-check, with a 15% gap threshold that triggers a warning rather than
moving the number. Land is the one exception, where the discounted figure
may inform the upper bound of the range that SOP already reports.

Query ladder shortens proportionally: 2 years on the road, then the whole
district at 2 years, then 4 years."
```

---

## Task 9: 收尾驗證

- [ ] **Step 1: 全套測試**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run --with pytest --with beautifulsoup4 pytest tests/ -v'
```

預期：12 passed

- [ ] **Step 2: 兩支工具都能跑**

```bash
docker exec openab-estate sh -c 'cd /workspace/EstateSpace && uv run tools/lvr.py --city 桃園市 --road 永安路 2>&1 | head -3 && echo "---" && uv run tools/listing.py --city 桃園市 --district 桃園區 --limit 3 2>&1 | head -6'
```

預期：`lvr.py` 標頭顯示「近 2 年」；`listing.py` 正常輸出。

- [ ] **Step 3: 在 Discord 實測一次完整估價**

在 `#不動產估價` 貼一筆標的（地址＋標示部），確認 agent：

1. 查了實價登錄（近 2 年）
2. 查了銷售中並折算，回覆註明議價空間百分比
3. 做了落差比較並標「一致」或示警
4. 估價金額仍來自實價登錄中位數，**不是**兩者平均
5. 附了免責聲明

**若 agent 沒有執行 `listing.py`**，代表 `AGENTS.md` 的指示不夠明確 —— 回頭在
§銷售中參照 開頭加強「每次估價都做」的措辭，不要靠使用者每次提醒。

- [ ] **Step 4: 推送**

```bash
cd "D:/discord 個人助理" && git push origin main
```
