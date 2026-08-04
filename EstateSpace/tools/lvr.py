# /// script
# requires-python = ">=3.10"
# dependencies = ["requests"]
# ///
"""實價登錄比價工具 — 內政部「不動產交易實價查詢」官方 open data。

為什麼用 open data 而不是爬 lvr.land.moi.gov.tw 的查詢頁？
  那個查詢站是 frameset + SPA，查詢 API 的參數是 CryptoJS 加密 + 每次連線
  的 session token（2026-06-20 實測），無法用固定 URL 直接打；而 open data
  是官方公開、免登入、欄位齊全（門牌未遮蔽、有型態/用途/完工年月/總價/單價/
  備註），且純 HTTP，本容器不需要瀏覽器即可取得。合規且穩定。

資料來源：https://plvr.land.moi.gov.tw/DownloadSeason  （每季每縣市一檔）
  檔名 {CITY}_lvr_land_A.csv  → A=買賣、B=預售屋、C=租賃。本工具只取 A（買賣）。

用法（容器內走 uv，會自動準備 python 與套件）：
    uv run tools/lvr.py --city 桃園市 --road 永安路
    uv run tools/lvr.py --city 桃園市 --road 永安路 --years 4 --type 透天
    uv run tools/lvr.py --city 桃園市 --road 永安路 --use 住家用 --min-area 60
    uv run tools/lvr.py --city 桃園市 --road 永安路 --include-special   # 不剔除特殊交易

輸出：符合條件的成交案逐筆（門牌/交易日/型態/用途/屋齡/建物坪/總價萬/單價萬每坪/
      備註），並附「非特殊交易」的單價統計（中位數/平均/min/max）供估價參考。
預設會剔除備註含「親友、員工、共有人或其他特殊關係」字樣的交易（標 [特殊]）。
"""
from __future__ import annotations

import argparse
import csv
import io
import os
import sys
import zipfile
from datetime import date
from statistics import mean, median

import requests

try:                              # 關閉 verify 重試時的 InsecureRequestWarning 噪音
    requests.packages.urllib3.disable_warnings()  # type: ignore[attr-defined]
except Exception:
    pass

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

PINGS_PER_M2 = 0.3025          # 1 平方公尺 = 0.3025 坪
M2_PER_PING = 3.305785         # 1 坪 = 3.305785 平方公尺
BASE = "https://plvr.land.moi.gov.tw/DownloadSeason"
CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".lvr_cache")
TIMEOUT = 120

# lvr 縣市代碼（2026-06-20 自查詢頁 option value 取得，open data 檔名同此字母）
CITY_CODE = {
    "基隆市": "C", "臺北市": "A", "台北市": "A", "新北市": "F", "桃園市": "H",
    "新竹市": "O", "新竹縣": "J", "苗栗縣": "K", "臺中市": "B", "台中市": "B",
    "南投縣": "M", "彰化縣": "N", "雲林縣": "P", "嘉義市": "I", "嘉義縣": "Q",
    "臺南市": "D", "台南市": "D", "高雄市": "E", "屏東縣": "T", "宜蘭縣": "G",
    "花蓮縣": "U", "臺東縣": "V", "台東縣": "V", "澎湖縣": "X", "金門縣": "W",
    "連江縣": "Z",
}

# 特殊關係交易的備註關鍵字（預設剔除）
SPECIAL_KW = ["親友", "員工", "共有人", "特殊關係", "債權", "債務", "瑕疵",
              "二親等", "關係人", "急買急賣", "毛胚"]


def city_to_code(s: str) -> str:
    s = s.strip()
    if s.upper() in {v for v in CITY_CODE.values()} and len(s) == 1:
        return s.upper()
    if s in CITY_CODE:
        return CITY_CODE[s]
    raise SystemExit(f"未知縣市：{s}（可用：{'、'.join(k for k in CITY_CODE if len(k)==3)}）")


def recent_seasons(years: int) -> list[str]:
    """從今天回推，產生足以涵蓋 years 年成交資料的季別清單（民國 yyySq）。"""
    today = date.today()
    ry, rq = today.year - 1911, (today.month - 1) // 3 + 1
    out, y, q = [], ry, rq
    for _ in range(years * 4 + 2):   # +2 容許最新一兩季尚未發布（下載失敗會跳過）
        out.append(f"{y}S{q}")
        q -= 1
        if q == 0:
            q, y = 4, y - 1
    return out


def fetch_season(code: str, season: str, refresh: bool) -> str | None:
    """下載某縣市某季的買賣 CSV 文字；快取於 .lvr_cache。失敗回 None。"""
    os.makedirs(CACHE, exist_ok=True)
    cached = os.path.join(CACHE, f"{code}_{season}_A.csv")
    if os.path.exists(cached) and os.path.getsize(cached) > 1000 and not refresh:
        with open(cached, encoding="utf-8") as f:
            return f.read()
    params = {"season": season, "fileName": f"{code}_lvr_land_A.csv", "type": "zip"}
    r = None
    # 政府站憑證鏈在容器較嚴格的 OpenSSL 下偶發 SSLError（Missing Subject Key
    # Identifier）；公開資料、完整性非機密，故 SSLError 時退而關閉憑證驗證重試，
    # 避免某一季別被靜默丟掉。一般連線錯誤也重試一次。
    for attempt, verify in ((1, True), (2, False), (3, False)):
        try:
            r = requests.get(BASE, params=params, timeout=TIMEOUT, verify=verify)
            break
        except requests.exceptions.SSLError:
            continue
        except requests.RequestException as e:
            if attempt >= 3:
                print(f"  [warn] {season} 下載失敗：{e}", file=sys.stderr)
                return None
    if r is None:
        print(f"  [warn] {season} 下載失敗：SSL/連線重試後仍失敗", file=sys.stderr)
        return None
    if not r.ok or len(r.content) < 1000:
        return None
    data = r.content
    text = None
    if data[:2] == b"PK":                       # 是 zip → 取出第一個 csv
        try:
            zf = zipfile.ZipFile(io.BytesIO(data))
            name = next((n for n in zf.namelist() if n.lower().endswith(".csv")), None)
            if name:
                text = zf.read(name).decode("utf-8-sig", "replace")
        except zipfile.BadZipFile:
            return None
    else:                                        # 直接就是 csv
        text = data.decode("utf-8-sig", "replace")
    if text and "土地位置建物門牌" in text:
        with open(cached, "w", encoding="utf-8") as f:
            f.write(text)
        return text
    return None


def roc_to_parts(s: str) -> tuple[int, int]:
    """民國日期字串（如 1140116 / 0740812）→ (西元年, 月)。無法解析回 (0,0)。"""
    s = "".join(ch for ch in (s or "") if ch.isdigit())
    if len(s) < 5:
        return 0, 0
    y, m = int(s[:-4]), int(s[-4:-2])
    return y + 1911, max(m, 1)


def parse_rows(text: str):
    """讀 CSV（首列中文表頭、次列英文表頭、其後為資料），yield dict。"""
    reader = csv.reader(io.StringIO(text))
    rows = list(reader)
    if len(rows) < 3:
        return
    header = rows[0]
    idx = {name: i for i, name in enumerate(header)}

    def g(row, key):
        i = idx.get(key)
        return row[i].strip() if i is not None and i < len(row) else ""

    for row in rows[2:]:                          # 跳過英文表頭列
        if not any(row):
            continue
        yield {
            "town": g(row, "鄉鎮市區"),
            "addr": g(row, "土地位置建物門牌"),
            "deal_int": int("".join(c for c in g(row, "交易年月日") if c.isdigit()) or "0"),
            "deal_raw": g(row, "交易年月日"),
            "target": g(row, "交易標的"),
            "shape": g(row, "建物型態"),
            "use": g(row, "主要用途"),
            "material": g(row, "主要建材"),
            "done": g(row, "建築完成年月"),
            "area_m2": _f(g(row, "建物移轉總面積平方公尺")),
            "land_area_m2": _f(g(row, "土地移轉總面積平方公尺")),
            "zone": g(row, "都市土地使用分區") or g(row, "非都市土地使用編定")
                    or g(row, "非都市土地使用分區"),
            "total": _f(g(row, "總價元")),
            "unit_m2": _f(g(row, "單價元平方公尺")),
            "park_total": _f(g(row, "車位總價元")),
            "remark": g(row, "備註"),
            "main_area": _f(g(row, "主建物面積")),
        }


def _f(s: str) -> float:
    try:
        return float(s)
    except (ValueError, TypeError):
        return 0.0


def main() -> int:
    p = argparse.ArgumentParser(description="實價登錄買賣比價（官方 open data）")
    p.add_argument("--city", required=True, help="縣市，如 桃園市（或代碼 H）")
    p.add_argument("--road", default="",
                   help="地址關鍵字（門牌子字串比對）；建物給路名如 永安路，土地給地段如 賦北段。"
                        "可留空 → 配合 --town＋--type/--zone 查整區『鄰近類似物件』")
    p.add_argument("--town", default="", help="鄉鎮市區關鍵字，如 桃園區 / 平鎮區（--road 留空時必填）")
    p.add_argument("--land", action="store_true",
                   help="土地模式：比對純『土地』交易、用土地面積算單價（屋齡/型態/用途不適用）")
    p.add_argument("--zone", default="",
                   help="土地模式用：使用分區關鍵字，如 農（農業區）/ 住 / 商 / 工")
    p.add_argument("--years", type=int, default=None,
                   help="近 N 年成交（未指定預設 2 年，房屋與土地皆同）")
    p.add_argument("--low-ratio", type=float, default=None,
                   help="土地模式：剔除單價低於『中位數×此比例』的畸零地/道路用地"
                        "（預設 0.4；設 0 關閉）")
    p.add_argument("--type", default="", help="建物型態關鍵字，如 透天 / 公寓 / 住宅大樓 / 華廈")
    p.add_argument("--use", default="", help="主要用途關鍵字，如 住家用 / 商業用 / 住商用")
    p.add_argument("--min-age", type=float, default=None, help="屋齡下限（年）")
    p.add_argument("--max-age", type=float, default=None, help="屋齡上限（年）")
    p.add_argument("--min-area", type=float, default=None, help="建物坪數下限")
    p.add_argument("--max-area", type=float, default=None, help="建物坪數上限")
    p.add_argument("--include-special", action="store_true", help="不剔除特殊關係交易")
    p.add_argument("--building-only", action="store_true", default=True,
                   help="只取含建物的交易（預設開；--no-building-only 關閉）")
    p.add_argument("--no-building-only", dest="building_only", action="store_false")
    p.add_argument("--limit", type=int, default=50, help="最多列出幾筆（預設 50）")
    p.add_argument("--refresh", action="store_true", help="強制重新下載（忽略快取）")
    a = p.parse_args()

    if not a.road and not a.town:
        print("請至少指定 --road（路名/地段）或 --town（鄉鎮市區）。", file=sys.stderr)
        return 2

    # 預設年限：房屋與土地都先查 3 年（不足再由 SOP 階梯放寬）
    if a.years is None:
        a.years = 2
    # 畸零地剔除比例：土地預設 0.4，建物不啟用
    low_ratio = a.low_ratio if a.low_ratio is not None else (0.4 if a.land else 0.0)

    code = city_to_code(a.city)
    today = date.today()
    # deal_int 是民國日期整數（yyymmdd），cutoff 也用民國：今年(民國) - years
    cutoff = (today.year - 1911 - a.years) * 10000 + today.month * 100 + today.day

    seasons = recent_seasons(a.years)
    mode = "土地" if a.land else "建物"
    scope = a.road if a.road else (a.town + " 整區" if a.town else "")
    print(f"[查詢-{mode}] {a.city} {scope}  近 {a.years} 年（交易日 >= 民國 {cutoff}）"
          f"{('  分區~'+a.zone) if a.land and a.zone else ''}"
          f"{('  型態~'+a.type) if (not a.land and a.type) else ''}"
          f"{('  用途~'+a.use) if (not a.land and a.use) else ''}")
    print(f"[季別] 嘗試 {seasons[-1]} ~ {seasons[0]}（下載+快取於 tools/.lvr_cache）\n")

    comps = []
    got_seasons = []
    for season in seasons:
        text = fetch_season(code, season, a.refresh)
        if not text:
            continue
        got_seasons.append(season)
        for r in parse_rows(text):
            if a.road not in r["addr"]:
                continue
            # 鄉鎮市區是獨立欄位（土地門牌不含區名），故比對 town 欄＋門牌兩者
            if a.town and a.town not in (r["town"] + r["addr"]):
                continue
            if r["deal_int"] < cutoff:
                continue

            if a.land:
                # 土地模式：只取純土地交易（排除含建物的房地），用土地面積算單價
                if "土地" not in r["target"] or "建物" in r["target"]:
                    continue
                if a.zone and a.zone not in (r["zone"] or ""):
                    continue
                ping = r["land_area_m2"] * PINGS_PER_M2
                age = None
            else:
                # 建物模式：含建物的交易，用建物面積算單價
                if a.building_only and "建物" not in r["target"]:
                    continue
                if a.type and a.type not in r["shape"]:
                    continue
                if a.use and a.use not in r["use"]:
                    continue
                ping = r["area_m2"] * PINGS_PER_M2
                done_y, done_m = roc_to_parts(r["done"])
                deal_y, deal_m = roc_to_parts(r["deal_raw"])
                age = None
                if done_y and deal_y:
                    age = (deal_y + deal_m / 12) - (done_y + done_m / 12)
                if a.min_age is not None and (age is None or age < a.min_age):
                    continue
                if a.max_age is not None and (age is None or age > a.max_age):
                    continue

            if ping <= 0:
                continue
            if a.min_area is not None and ping < a.min_area:
                continue
            if a.max_area is not None and ping > a.max_area:
                continue

            special = any(kw in r["remark"] for kw in SPECIAL_KW)
            unit_per_ping = (r["unit_m2"] * M2_PER_PING / 10000) if r["unit_m2"] else 0.0  # 官方單價→萬/坪
            tot_per_ping = (r["total"] / 10000) / ping if ping else 0.0                    # 總價/坪→萬/坪
            comps.append({
                "addr": r["addr"], "deal": r["deal_raw"], "shape": r["shape"],
                "use": r["use"], "zone": r["zone"], "age": age, "ping": ping,
                "total_wan": r["total"] / 10000, "unit": unit_per_ping,
                "tot_unit": tot_per_ping, "park": r["park_total"] > 0,
                "special": special, "remark": r["remark"],
            })

    if not got_seasons:
        print("查無任何可下載的季別資料 — 可能網路不通或最新季別尚未發布。", file=sys.stderr)
        return 1
    print(f"[已取得季別] {'、'.join(got_seasons)}")

    if not comps:
        broaden = ("--road 留空＋--town＋--zone 查整區同分區農地"
                   if a.land else "--road 留空＋--town＋--type 查整區同型態物件")
        print(f"\n找不到符合條件的{mode}成交案：{a.city} {scope}（近 {a.years} 年）。"
              f"\n依 SOP 放寬：①先查鄰近/整區類似物件（{broaden}）；②仍不足再 --years 4；"
              f"③或確認縣市/地段名是否正確。")
        return 0

    # 標記畸零地/道路用地：單價明顯低於中位數者（土地模式預設啟用，low_ratio>0）。
    # 用「中位數×比例」當門檻，對單位無關、不受極端值影響，比絕對金額穩健。
    base = [c["unit"] for c in comps if not c["special"] and c["unit"] > 0]
    low_cut = (median(base) * low_ratio) if (base and low_ratio > 0) else 0.0
    for c in comps:
        c["low"] = bool(low_cut) and 0 < c["unit"] < low_cut
    n_low = sum(1 for c in comps if c["low"])

    comps.sort(key=lambda c: c["deal"], reverse=True)
    print(f"\n=== 符合條件{mode}成交 {len(comps)} 筆（依交易日新→舊，最多 {a.limit} 筆）===")
    if a.land:
        print("交易日   | 土地坪 | 總價(萬) | 單價(萬/坪) | 分區 | 地段地號  [標記]")
        print("-" * 84)
        for c in comps[:a.limit]:
            flags = []
            if c["special"]:
                flags.append("特殊")
            if c["low"]:
                flags.append("偏低")
            flag_s = ("  [" + ",".join(flags) + "]") if flags else ""
            print(f"{c['deal']:>7} | {c['ping']:7.2f} | {c['total_wan']:7.0f} "
                  f"| {c['unit']:6.2f} (官) | {c['zone'] or '-':<3} | {c['addr']}{flag_s}")
    else:
        print("交易日   | 屋齡 | 建物坪 | 總價(萬) | 單價(萬/坪) | 型態 / 用途 | 門牌  [標記]")
        print("-" * 92)
        for c in comps[:a.limit]:
            age_s = f"{c['age']:.0f}" if c["age"] is not None else " ?"
            flags = []
            if c["special"]:
                flags.append("特殊")
            if c["park"]:
                flags.append("含車位")
            flag_s = ("  [" + ",".join(flags) + "]") if flags else ""
            print(f"{c['deal']:>7} | {age_s:>3} | {c['ping']:6.2f} | {c['total_wan']:7.0f} "
                  f"| {c['unit']:6.1f} (官) | {c['shape']}／{c['use']} | {c['addr']}{flag_s}")

    # 統計（排除特殊交易、畸零地偏低、單價 0 者）
    valid = [c["unit"] for c in comps if not c["special"] and not c["low"] and c["unit"] > 0]
    if low_cut:
        print(f"\n[畸零地過濾] 單價 < 中位數×{low_ratio:g} = {low_cut:.2f} 萬/坪 者標 [偏低]"
              f"並排除統計，共剔除 {n_low} 筆（如要保留：--low-ratio 0）")
    # 可比案門檻提示（SOP：至少 3 筆有效可比案，不足要放寬地段/年限）
    n_valid = len(valid)
    if n_valid >= 3:
        print(f"\n[可比案] 有效可比案 {n_valid} 筆，已達 3 筆門檻 ✓")
    else:
        print(f"\n[可比案] ⚠ 有效可比案僅 {n_valid} 筆，未達 3 筆門檻 — 依 SOP 放寬："
              f"先試鄰近地段/類似物件（--road 留空＋--town{'＋--zone' if a.land else '＋--type'}），"
              f"仍不足再 --years 4")
    if valid:
        unit_fmt = "{:.2f}" if a.land else "{:.1f}"
        print(f"\n=== 單價統計（官方單價，萬/坪；已排除特殊交易"
              f"{'＋畸零偏低' if low_cut else ''}，n={len(valid)}）===")
        print(("  中位數 " + unit_fmt + "　平均 " + unit_fmt + "　最低 " + unit_fmt
               + "　最高 " + unit_fmt).format(median(valid), mean(valid), min(valid), max(valid)))
        if a.land:
            print("  估價建議：取同地段/鄰近、相同使用分區（如農業區）的數筆，算單價中位數或平均，"
                  "再乘上標的土地坪數。臨路寬窄、地形、可建性差異大時請人工斟酌。")
        else:
            print("  估價建議：取與標的『屋齡/型態/用途』最接近的數筆，算其單價均值或中位數，"
                  "再乘上標的建物坪數。特殊交易與含車位案請人工斟酌。")
    else:
        print("\n（可比對的非特殊交易單價不足，請放寬條件或人工挑選上方清單。）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
