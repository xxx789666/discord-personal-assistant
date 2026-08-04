# 工具與上網 — 估價工作區

⚠ **本容器沒有 curl / python3，只有 `uv` 和 `node`**。所有腳本一律用 `uv run`
（首次會自動準備 Python 與套件，稍慢屬正常）。

## 主力：實價登錄比價 `tools/lvr.py`

資料源是**內政部不動產交易實價查詢 open data**（公開、免登入、純 HTTP，
不需要瀏覽器）。它會下載對應縣市近 N 年的買賣資料、依路名比對、剔除特殊
交易、算出單價統計。

```bash
# 基本：某縣市某路名，近 2 年
uv run tools/lvr.py --city 桃園市 --road 永安路

# 收斂條件：型態 + 用途 + 屋齡範圍 + 年限
uv run tools/lvr.py --city 桃園市 --road 永安路 --years 4 \
    --type 透天 --use 住家用 --min-age 24 --max-age 34

# 限定鄉鎮市區、放大筆數
uv run tools/lvr.py --city 桃園市 --road 永安路 --town 桃園區 --limit 80

# 不剔除特殊交易（預設會剔除）
uv run tools/lvr.py --city 桃園市 --road 永安路 --include-special

# 土地/農地估價：加 --land，--road 填地段名，--zone 填使用分區（農/住/商/工）
uv run tools/lvr.py --city 桃園市 --road 賦北段 --land --zone 農 --years 4
```

## 銷售中物件參照 `tools/listing.py`

好房網公開地區頁的**銷售中物件開價**，扣議價空間後供交叉驗證。
與 `lvr.py` 互補：成交是事實但有登錄時間差，開價即時但含賣方意圖。

```bash
# 區級查詢（--district 是回傳後篩選，不是 URL 參數）
uv run tools/listing.py --city 桃園市 --district 桃園區

# 收斂型態；路名（樣本通常不足，會自動放寬回全區並在輸出說明）
uv run tools/listing.py --city 桃園市 --district 桃園區 --road 永安路 --type 住宅大樓

# 土地；議價空間改 12%（預設 8%）
uv run tools/listing.py --city 桃園市 --district 平鎮區 --land --discount 0.12
```

輸出含每筆（地址／型態／坪數／開價單坪／折後單坪）與兩組統計（開價、折後）。
查不到時印「無銷售中參照」並正常結束，**不阻斷估價**。

**只能查到城市級**：好房網沒有區級 URL，且未知地區代碼會**靜默回退**到別的縣市
（實測回台北市）而非報錯。工具已內建防護 —— 回傳縣市與請求不符即中止並報錯。
所以 `--city` 必須寫對（是「桃園市」不是「桃園縣」）。

型態是從樓層字串推論的（卡片沒有型態欄位）：`--/--` 是土地、`1~4/4` 是透天、
單層依總樓層分公寓／華廈／住宅大樓。公寓與華廈那條界線是依慣例推估，非站方標示。

合規：每次執行先驗 robots.txt、User-Agent 標明來源、請求間隔 ≥2 秒、頁數上限 3。

常用參數：`--type`（透天/公寓/華廈/住宅大樓）、`--use`（住家用/住商用/商業用）、
`--min-age`/`--max-age`（屋齡）、`--min-area`/`--max-area`（坪數）、
`--years`（近幾年，**預設 2，房屋/土地皆同**；樣本不足才照 SOP 階梯放寬到 4）、
`--limit`、`--refresh`（強制重抓）。
**土地模式**：`--land`（只比純土地交易、用土地面積算單價）、`--zone`（使用分區關鍵字）。
**鄰近類似物件**：`--road` 留空 ＋ `--town <區>` ＋ `--type`/`--zone` → 查整區同型態/同分區。

輸出含每筆成交（門牌/交易日/屋齡/坪數/總價/官方單價/型態/用途/標記）與
「非特殊交易」的單價統計（中位數/平均/min/max）。估價流程見 AGENTS.md。

下載的季別 CSV 會快取在 `tools/.lvr_cache/`，同縣市再查不重抓。

## 備用：一般網頁抓取 `tools/web.py`（Steel Browser）

需要讀其他網頁（建商資訊、新聞、Google 地圖周邊）時才用。走 compose 網路上
的 Steel Browser（`http://steel-api:3000`）。

```bash
uv run tools/web.py scrape https://example.com
uv run tools/web.py search "關鍵字"
```

注意：Steel 反偵測層停用中，搜尋引擎結果頁會擋 → 搜尋用 `search` 子指令
（走 SearXNG），不要 scrape Google。一次估價以 3～5 次 scrape 為限，避免撐爆 context。

## 鐵則

- **不查、不登入 pqt.ttt.nat.gov.tw / 地政電傳**（付費＋禁止自動化）。標示部由使用者提供。
- **沒有本次實際查到的資料，不得寫出任何成交價/單價/估值數字**。
