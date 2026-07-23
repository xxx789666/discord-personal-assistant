---
name: steel-browser
description: 上網能力 — 用 SearXNG 搜尋（http://searxng:8080）、用 Steel Browser 抓網頁/截圖（http://steel-api:3000）。需要查網路資訊、讀取網頁內容、或使用者要求登入某網站操作時使用本技能。
---

# steel-browser — 上網能力（curl 版）

你的容器沒有內建網頁搜尋，但同一個 Docker 網路上有兩個服務：
**SearXNG 管「找連結」，Steel Browser 管「讀內容」**。全部用 `curl`。

- 所有查到的即時資訊（價格、營業時間、新聞）回覆時**標註查證日期**。
- **絕對禁止憑記憶報數字**：價格、票價、營業時間 — 沒有本次實際抓到的
  網頁佐證就不得寫出具體數字。查不到就老實說查不到＋建議使用者怎麼辦。

## 第一步：搜尋（SearXNG）

```bash
# JSON 結果：每筆有 title / url / content（摘要）；中文關鍵字用
# --data-urlencode 自動處理編碼
curl -sG "http://searxng:8080/search" --data-urlencode "q=釜山 觀光巴士 價格" --data-urlencode "format=json" | head -c 6000
```

從結果挑可信來源（官網優先），再用 Steel 讀內容。
**禁止用 Steel 抓 Google / DuckDuckGo 結果頁** — 會被機器人驗證擋。
**禁止自己猜官網 URL**（拼出來的路徑多半 404）— 先搜尋拿真實連結。

## 第二步：讀內容（Steel）

```bash
# 網頁 → Markdown（head -c 截尾防止內容爆量；需要更多就調大）
curl -s -X POST http://steel-api:3000/v1/scrape \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","format":["markdown"],"delay":2000}' | head -c 9000

# 截圖
curl -s -X POST http://steel-api:3000/v1/screenshot \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com"}' --output /tmp/shot.png
```

一個問題以 3–5 次 scrape 為限；查不到就回報查不到。

## 登入態任務（session + 人工介入）

```bash
# 1. 開 session（一次只能一個活躍 session）
curl -s -X POST http://steel-api:3000/v1/sessions -H "Content-Type: application/json" -d '{}'
# 2. 請使用者在自己的瀏覽器開 http://localhost:5173 ，在 live viewer
#    手動登入，完成後回 Discord 告訴你。
# 3. 繼續 scrape 取登入後的頁面。
# 4. 結束釋放
curl -s -X POST http://steel-api:3000/v1/sessions/release -H "Content-Type: application/json" -d '{}'
```

## 注意事項

1. `curl http://steel-api:3000/v1/health` 回 ok 表示 Steel 活著；
   500 多半是它的 Chrome 重啟中，等幾秒重試。
2. Steel 反偵測層目前停用（上游 bug workaround），Cloudflare 嚴格的站
   可能擋 — 被擋就如實回報，不要硬試。
3. 連續抓頁間隔 1–2 秒。
4. **YouTube → 逐字稿**：使用者丟影片連結時用工作區的 tools/yt.py
   （python3 與所有依賴已裝在容器裡）：
   ```bash
   python3 tools/yt.py "https://www.youtube.com/watch?v=XXXX" --out /tmp/transcript.txt
   ```
   字幕優先（繁中 > 英文、手動 > 自動），無字幕自動退 yt-dlp + Groq
   Whisper（ffmpeg 壓縮，長片也行）。拿到逐字稿再做你的事（找地點、
   摘要、寫筆記）；旅遊主題照 steering 規則把成果寫進 TravelMemory。
