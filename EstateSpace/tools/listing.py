# /// script
# requires-python = ">=3.10"
# dependencies = ["httpx", "beautifulsoup4", "truststore"]
# ///
"""好房網銷售中物件查詢 — 開價扣議價空間後，供估價交叉驗證。

與 tools/lvr.py 的分工：
  lvr.py     內政部實價登錄 open data → 過去的「成交價」（事實，但有登錄時間差）
  listing.py 好房網公開地區頁         → 當下的「開價」（即時，但含賣方意圖）
估價基準一律是 lvr.py 的成交中位數；本工具的折後開價只做交叉驗證（見 AGENTS.md）。

合規（沿用 property-case-radar crawlers/sale/housefun_source.py 已驗證的行為）：
  - 每次執行先讀 robots.txt 並驗證目標路徑
  - User-Agent 標明來源與用途，不偽裝瀏覽器
  - 請求間隔 >= 2 秒、頁數上限 10（見 MAX_PAGES 的說明）
  - 絕不觸碰 /building/building_street*（robots.txt 明文禁止的街道層級頁）

只能查到城市級（2026-08-04 實測）：
  /region/桃園市桃園區_c/ 回的是**台北市**物件 —— 未知地區 slug 不回 404，
  而是靜默回退到預設頁。城市頁自產的連結全是排序與分頁，沒有區級連結，
  區篩選是 JS 驅動的。因此只有 --city 進入請求 URL，--district / --road /
  --type 全部是回傳後的客戶端篩選，並以 _verify_city 擋住靜默回退。

用法：
    uv run tools/listing.py --city 桃園市 --district 桃園區
    uv run tools/listing.py --city 桃園市 --district 桃園區 --road 永安路 --type 透天
    uv run tools/listing.py --city 桃園市 --district 平鎮區 --land --discount 0.12
"""
from __future__ import annotations

import argparse
import asyncio
import re
import ssl
import sys
import time
import urllib.parse
from dataclasses import dataclass
from statistics import mean, median
from urllib.robotparser import RobotFileParser

import httpx
import truststore
from bs4 import BeautifulSoup

# Windows host console 是 cp950，印特殊字元會炸；容器內無影響
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

BASE_URL = "https://buy.housefun.com.tw"
ROBOTS_URL = f"{BASE_URL}/robots.txt"
USER_AGENT = (
    "EstateSpaceValuation/1.0 "
    "(+https://github.com/xxx789666/discord-personal-assistant)"
)
MIN_DELAY_SECONDS = 2.0
# 臺北市的 /region/ 有 271 頁（約 8100 筆），抓 N 頁只看得到 N×30 筆。
# 上游 Radar 的 CompliancePolicy 訂 3 頁，那是為「每天廣掃新案」設計的；
# 定點估價需要足夠的區級樣本，所以放寬到 10 頁（約 300 筆、20 秒）。
# 即使如此仍只是全市的 ~3.7% 抽樣 —— **找不到特定一棟是常態**，
# 使用者手上的個案資訊一律優先（AGENTS.md §銷售中參照）。
MAX_PAGES = 10
MIN_SAMPLES = 3

LAND_TYPES = ("土地", "農地", "建地", "工業用地")
# 行銷名稱裡出現就直接採信的關鍵字（順序即優先序，長詞在前）
TITLE_KEYWORDS = ("工業用地", "住宅大樓", "農地", "建地", "土地",
                  "別墅", "透天", "華廈", "公寓", "套房")


class ListingFetchError(RuntimeError):
    """抓取中止 —— robots 禁止、或回傳內容與請求的縣市不符。"""


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


# --- 解析（純函式） --------------------------------------------------------

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


def _classify(title: str, pattern: str | None, floor: str | None) -> str | None:
    """推論物件型態。

    好房網的列表卡片**沒有型態欄位**（2026-08-04 實測 30 張卡片確認），
    只能從樓層字串推論，行銷名稱僅作覆寫：

        --/-- 樓 或無樓層無格局   → 土地
        1~4/4 樓（範圍且到頂）    → 整棟 = 透天
        6/9 樓（單層）           → 集合住宅，依總樓層再分：
                                   ≤5 公寓、6~10 華廈、>10 住宅大樓

    集合住宅的細分是依台灣慣例（5 樓以下多無電梯）推估的，卡片沒有電梯資訊，
    所以那條界線本質上是猜測；土地與透天的判定則直接來自樓層格式，可靠得多。
    回 None 代表無法判斷 —— 指定 --type 時這些會被濾掉（無法確認符合），
    CLI 會回報濾掉幾筆，不靜默丟棄。
    """
    normalized = title.replace("工業地", "工業用地")
    for keyword in TITLE_KEYWORDS:
        if keyword in normalized:
            return keyword

    floor_text = (floor or "").strip()
    if not floor_text or "--/--" in floor_text:
        return "土地" if not pattern else None

    match = re.search(r"(?P<low>\d+)(?:~(?P<high>\d+))?/(?P<total>\d+)", floor_text)
    if match is None:
        return None
    total = int(match.group("total"))
    if match.group("high") and int(match.group("high")) >= total:
        return "透天"
    if total <= 5:
        return "公寓"
    if total <= 10:
        return "華廈"
    return "住宅大樓"


def parse_list_page(html: str) -> list[Listing]:
    """把好房網列表頁 HTML 解析成 Listing。

    壞掉的卡片跳過而非拋例外 —— 一張卡片的欄位缺失不該讓整頁作廢。
    """
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
            layout_node = card.select_one(".ping-pattern .pattern")
            floor_node = card.select_one(".ping-pattern .floor")
            # 元素可能存在但內容為空（土地物件的格局欄就是），統一成 None
            layout = (layout_node.get_text(" ", strip=True) or None) if layout_node else None
            floor = (floor_node.get_text(" ", strip=True) or None) if floor_node else None
            found[identifier.group(1)] = Listing(
                source_id=identifier.group(1),
                url=f"{BASE_URL}{link['href']}",
                city=city,
                district=district,
                address=address,
                total_price_twd=total,
                area_ping=area,
                unit_price_per_ping=round(total / area),
                building_type=_classify(
                    title_node.get_text(" ", strip=True), layout, floor),
                layout=layout,
                floor=floor,
                has_parking=card.select_one(".ping-pattern .park") is not None,
            )
        except (ArithmeticError, TypeError, ValueError):
            continue
    return list(found.values())


# --- 折算與統計（純函式） --------------------------------------------------

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


# --- 篩選（純函式） --------------------------------------------------------

def filter_listings(
    items: list[Listing],
    *,
    district: str = "",
    road: str = "",
    building_type: str = "",
    land_only: bool = False,
) -> list[Listing]:
    """客戶端篩選。

    road 比對地址子字串 —— robots.txt 禁止 /building/building_street*，
    路名永遠不能出現在請求 URL 裡。
    """
    result = items
    if district:
        result = [i for i in result if district in i.district]
    if road:
        result = [i for i in result if road in i.address]
    if land_only:
        result = [i for i in result if i.building_type in LAND_TYPES]
    if building_type:
        result = [i for i in result
                  if i.building_type and building_type in i.building_type]
    return result


# --- 抓取（網路層） --------------------------------------------------------

def region_url(city: str, page: int) -> str:
    """城市級地區頁。

    區級 URL 不存在 —— 未知 slug 會靜默回退到預設頁（實測回台北市），
    所以只有縣市能進 URL。
    """
    slug = urllib.parse.quote(f"{city}_c")
    base = f"{BASE_URL}/region/{slug}/"
    return base if page == 1 else f"{base}?pg={page}"


def _verify_city(items: list[Listing], requested_city: str) -> None:
    """擋住靜默回退。

    請求的縣市頁若回了別的縣市，代表 slug 沒被辨識而落到預設頁。
    比對的是「請求的縣市」而非硬編台北，所以站方改變回退目標時仍然有效。
    """
    if not items:
        return
    normalized = requested_city.replace("台", "臺")
    if not any(i.city == normalized for i in items):
        seen = sorted({i.city for i in items})
        raise ListingFetchError(
            f"請求 {requested_city} 但回傳的全是 {'、'.join(seen)} — "
            f"地區代碼未被辨識，站方靜默回退到預設頁。請確認縣市名稱。"
        )


async def _fetch_pages(city: str, max_pages: int) -> list[Listing]:
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
        robots = RobotFileParser()
        robots.set_url(ROBOTS_URL)
        robots.parse((await get(ROBOTS_URL)).text.splitlines())
        first = region_url(city, 1)
        if not robots.can_fetch(USER_AGENT, first):
            raise ListingFetchError(f"robots.txt 禁止 {first}")

        found: dict[str, Listing] = {}
        for page in range(1, min(max_pages, MAX_PAGES) + 1):
            for item in parse_list_page((await get(region_url(city, page))).text):
                found[item.source_id] = item
        items = list(found.values())
        _verify_city(items, city)
        return items
    finally:
        await client.aclose()


# --- CLI -------------------------------------------------------------------

def _print_stats(label: str, values: list[float]) -> None:
    stats = summarize(values)
    if stats is None:
        return
    print(f"[{label} 萬/坪] 中位數 {stats['median']:.2f}　平均 {stats['mean']:.2f}　"
          f"最低 {stats['min']:.2f}　最高 {stats['max']:.2f}")


def main() -> int:
    p = argparse.ArgumentParser(
        description="好房網銷售中物件查詢（開價扣議價空間，供估價交叉驗證）")
    p.add_argument("--city", required=True, help="縣市，如 桃園市")
    p.add_argument("--district", required=True, help="鄉鎮市區，如 桃園區")
    p.add_argument("--road", default="", help="路名／地段（對地址子字串篩選）")
    p.add_argument("--type", dest="building_type", default="",
                   help="型態關鍵字，如 透天 / 公寓 / 華廈 / 住宅大樓")
    p.add_argument("--land", action="store_true", help="土地模式（只取土地類物件）")
    p.add_argument("--discount", type=float, default=0.08,
                   help="議價空間，預設 0.08（8%%）")
    p.add_argument("--limit", type=int, default=20, help="最多列出幾筆（預設 20）")
    p.add_argument("--max-pages", type=int, default=MAX_PAGES,
                   help=f"抓取頁數上限（硬上限 {MAX_PAGES}）")
    a = p.parse_args()

    if not 0 <= a.discount < 1:
        print("--discount 必須在 [0, 1)", file=sys.stderr)
        return 2

    try:
        pool = asyncio.run(_fetch_pages(a.city, a.max_pages))
    except ListingFetchError as exc:
        print(f"[中止] {exc}", file=sys.stderr)
        return 1
    except httpx.HTTPError as exc:
        print(f"[網路失敗] {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    common = dict(district=a.district, building_type=a.building_type,
                  land_only=a.land)
    items = filter_listings(pool, road=a.road, **common)
    scope = f"{a.city}{a.district}" + (f" {a.road}" if a.road else "")
    widened = ""

    # 路名級樣本通常 0~2 筆（城市頁只有約 90 筆全市），不足就回退到區級，
    # 與 lvr.py「同路段不足就放寬整區」的階梯一致。
    if a.road and len(items) < MIN_SAMPLES:
        fallback = filter_listings(pool, **common)
        if len(fallback) > len(items):
            widened = f"（{a.road} 僅 {len(items)} 筆，已放寬到 {a.district} 全區）"
            items, scope = fallback, f"{a.city}{a.district}"

    print(f"[銷售中] {scope}{widened}　議價空間 {a.discount:.0%}　"
          f"共 {len(items)} 筆（全市樣本 {len(pool)} 筆）\n")
    if not items:
        print("(無符合條件的銷售中物件 — 本次無銷售中參照)")
        return 0

    for item in items[:a.limit]:
        asking = item.unit_price_per_ping / 10_000
        after = apply_discount(item.unit_price_per_ping, a.discount) / 10_000
        print(f"  {item.address}　{item.building_type or '—'}　"
              f"{item.area_ping:.2f} 坪　開價 {asking:.2f} → 折後 {after:.2f} 萬/坪")
    if len(items) > a.limit:
        print(f"  …（另有 {len(items) - a.limit} 筆未列出，統計含全部）")

    print()
    _print_stats("開價統計", [i.unit_price_per_ping / 10_000 for i in items])
    _print_stats("折後統計",
                 [apply_discount(i.unit_price_per_ping, a.discount) / 10_000
                  for i in items])
    if len(items) < MIN_SAMPLES:
        print(f"\n⚠ 樣本不足 {MIN_SAMPLES} 筆，僅供參考，不納入落差示警判斷")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
