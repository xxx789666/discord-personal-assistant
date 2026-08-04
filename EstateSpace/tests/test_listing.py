"""tools/listing.py 的單元測試 — 只測純函式（解析、折算、統計、篩選）。

不測網路層與 robots 抓取：那些是整合行為，mock 掉等於測 mock。
改用實跑驗證（見 docs/plans/2026-08-04-listing-reference.md Task 6）。

執行：
    uv run --with pytest --with beautifulsoup4 pytest tests/ -v
"""
from pathlib import Path
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

from listing import (  # noqa: E402
    LAND_TYPES,
    Listing,
    apply_discount,
    filter_listings,
    parse_list_page,
    summarize,
)

FIXTURE = Path(__file__).parent / "fixtures" / "housefun_list.html"


@pytest.fixture(scope="module")
def parsed():
    return parse_list_page(FIXTURE.read_text(encoding="utf-8"))


# --- parser ---------------------------------------------------------------

def test_parse_returns_listings(parsed):
    assert len(parsed) > 0
    assert all(isinstance(item, Listing) for item in parsed)


def test_parsed_fields_are_sane(parsed):
    first = parsed[0]
    assert first.city.endswith(("市", "縣"))
    assert first.district.endswith(("區", "鄉", "鎮", "市"))
    assert first.total_price_twd > 0
    assert first.area_ping > 0
    assert first.unit_price_per_ping == round(first.total_price_twd / first.area_ping)
    assert first.url.startswith("https://buy.housefun.com.tw/buy/house/")


def test_every_listing_has_city_and_district(parsed):
    assert all(item.city and item.district for item in parsed)


def test_land_listings_have_no_layout_and_placeholder_floor(parsed):
    """土地類物件沒有格局，樓層是 --/-- 佔位字串。"""
    land = [i for i in parsed if i.building_type in ("土地", "農地", "建地")]
    assert len(land) >= 2
    assert all(i.layout is None for i in land)
    assert all(i.floor is None or "--" in i.floor for i in land)


def test_whole_building_floor_implies_townhouse(parsed):
    """樓層形如 1~4/4（範圍且到頂）＝整棟 → 透天/別墅。

    例外：行銷名稱明講是工業用地／土地時以名稱為準（廠房也佔滿整棟）。
    """
    whole = [i for i in parsed
             if i.floor and "~" in i.floor and i.building_type not in LAND_TYPES]
    assert len(whole) >= 3
    assert all(i.building_type in ("透天", "別墅") for i in whole)


def test_classifier_leaves_nothing_unknown(parsed):
    """改用樓層推論後，fixture 裡應該每一筆都判得出型態。

    只比對行銷名稱時是全滅（行銷名多為「XX三房車」這類，不含型態字樣）。
    """
    assert [i for i in parsed if i.building_type is None] == []


def test_single_floor_classified_by_total_floors(parsed):
    """單層物件依總樓層分公寓/華廈/住宅大樓，不應留空。"""
    single = [i for i in parsed
              if i.floor and "~" not in i.floor and "--" not in i.floor]
    assert len(single) >= 10
    assert all(i.building_type in ("公寓", "華廈", "住宅大樓", "別墅", "透天")
               for i in single)


def test_malformed_card_is_skipped_not_raised():
    assert parse_list_page(
        "<html><body><section class='m-list-obj'></section></body></html>"
    ) == []


def test_empty_html_returns_empty_list():
    assert parse_list_page("") == []


# --- 折算 ------------------------------------------------------------------

def test_apply_discount_default_rate():
    assert apply_discount(1000, 0.08) == 920


def test_apply_discount_zero_is_identity():
    assert apply_discount(1000, 0.0) == 1000


@pytest.mark.parametrize("bad", [-0.1, 1.0, 1.5])
def test_apply_discount_rejects_out_of_range(bad):
    with pytest.raises(ValueError):
        apply_discount(1000, bad)


# --- 統計 ------------------------------------------------------------------

def test_summarize_even_count_uses_midpoint():
    stats = summarize([10, 20, 30, 40])
    assert stats["median"] == 25
    assert stats["mean"] == 25
    assert stats["min"] == 10
    assert stats["max"] == 40
    assert stats["count"] == 4


def test_summarize_single_value():
    assert summarize([42]) == {
        "median": 42, "mean": 42, "min": 42, "max": 42, "count": 1,
    }


def test_summarize_empty_returns_none_not_raise():
    assert summarize([]) is None


# --- 篩選 ------------------------------------------------------------------

def _listing(**overrides):
    base = dict(
        source_id="1",
        url="https://buy.housefun.com.tw/buy/house/1",
        city="桃園市",
        district="桃園區",
        address="桃園市桃園區永安路100號",
        total_price_twd=10_000_000,
        area_ping=30.0,
        unit_price_per_ping=333_333,
        building_type="透天",
    )
    base.update(overrides)
    return Listing(**base)


def test_filter_by_district():
    items = [_listing(), _listing(source_id="2", district="中壢區",
                                  address="桃園市中壢區中央路5號")]
    assert [i.source_id for i in filter_listings(items, district="桃園區")] == ["1"]


def test_filter_by_road_matches_address_substring():
    items = [_listing(), _listing(source_id="2", address="桃園市桃園區中山路5號")]
    assert [i.source_id for i in filter_listings(items, road="永安路")] == ["1"]


def test_filter_by_building_type():
    items = [_listing(), _listing(source_id="2", building_type="公寓")]
    assert [i.source_id for i in filter_listings(items, building_type="公寓")] == ["2"]


def test_filter_tolerates_missing_building_type():
    items = [_listing(source_id="2", building_type=None)]
    assert filter_listings(items, building_type="透天") == []


def test_filter_with_no_criteria_returns_all():
    items = [_listing(), _listing(source_id="2")]
    assert len(filter_listings(items)) == 2
