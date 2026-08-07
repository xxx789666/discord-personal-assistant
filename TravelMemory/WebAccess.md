# WebAccess — 上網與 YouTube 逐字稿

容器沒有內建搜尋，但 compose 網路上跑著 Steel Browser（自架瀏覽器沙箱）。

⚠ **本容器沒有 curl / ffmpeg / python3**，只有 `uv` 和 `node`。上網一律用
工作區的 `tools/` 腳本（`uv run` 會自動準備 Python 與套件，首次較慢屬正常）。

- Steel API（容器內）：`http://steel-api:3000`
- 人類的即時畫面 viewer（請使用者在自己瀏覽器開）：`http://localhost:5173`

## 抓網頁 / 截圖 / PDF

```bash
# 網頁 → Markdown（讀文章、攻略首選；背後是真 Chrome，JS 頁面也行）
uv run tools/web.py scrape https://example.com
# 動態內容慢的頁面加等待（毫秒）
uv run tools/web.py scrape https://example.com --delay 2000

# 截圖 / 整頁 PDF
uv run tools/web.py screenshot https://example.com /tmp/shot.png
uv run tools/web.py pdf https://example.com /tmp/page.pdf
```

## 不要 scrape 反爬站

`tools/web.py scrape` 內建網域黑名單（樂屋網、591），打到會直接 exit 2 並要你改用
`search`。**這不是保守，是踩過的坑**：2026-08-04 一次抓樂屋網失敗後，被擋的
Cloudflare 挑戰頁留在瀏覽器裡自己重試，Steel 連續三天對該站發出約 15000 個請求
（每天 5000），吃掉 1.1 GB 記憶體與 11% CPU，直到手動重啟才停。

現在抓回空白時會自動 `sessions/release` 關掉殘留分頁。要新增黑名單網域，
改 `tools/web.py` 的 `BLOCKED_HOSTS`。

這些站的資料**用 `search` 的摘要通常就拿得到**，不需要 scrape。

## 搜尋的做法

**搜尋一律用 search 子指令**（走自架 SearXNG 的 JSON API）：

```bash
uv run tools/web.py search "關鍵字"
uv run tools/web.py search "부산 ipass 가격" --limit 5
```

回傳「標題 / URL / 摘要」清單 — 挑可信來源（官網優先）再用 scrape 讀
一手內容。

**禁止用 scrape 抓 Google / DuckDuckGo 等搜尋結果頁** — 它們都會丟
機器人驗證（2026-06-12 實測），只會浪費 scrape 次數。
也不要自己猜官網 URL（例如 busan.go.kr/ipass 這種拼出來的路徑多半
404）— 先 search 拿到真實連結再進去。

## YouTube → 逐字稿

使用者丟 YouTube 連結時用這個（鏈路移植自 quant 專案的 intake）：
先抓現成字幕（繁中優先、手動優於自動），字幕被關才退到
yt-dlp 下載音軌 + Groq Whisper 轉錄：

```bash
uv run tools/yt.py "https://www.youtube.com/watch?v=XXXX" --out /tmp/transcript.txt
```

拿到逐字稿後再做你的事（找地點、摘要、寫筆記）。注意：

- STT 退路需要 GROQ_API_KEY（容器已注入）；音軌上限約 24MB
  （容器沒 ffmpeg 不能重壓），約 1 小時以上的長片可能放不進去 —
  超過就如實回報，請使用者用本機工具轉錄後丟進工作區。
- 影片標題/說明欄常已含重點（地點清單、時間軸）— 先
  `uv run tools/web.py scrape <影片URL>` 看 watch 頁，夠用就不必轉錄。

## 登入態任務（session + 人工介入）

```bash
# 1. 開 session（self-host 一次只能一個活躍 session）
uv run tools/web.py session start

# 2. 請使用者開 http://localhost:5173 ，在 live viewer 裡手動登入，
#    完成後回 Discord 告訴你。

# 3. 繼續 scrape / screenshot 取登入後的頁面。

# 4. 結束釋放
uv run tools/web.py session release
```

登入 cookies 存在 Steel 的快取 volume，通常下次還在；但別假設一定活著 —
先試抓目標頁，看到登入牆再走人工介入。

## 注意事項

1. 一次一個 session；`uv run tools/web.py session status` 可查，開新的前先 release。
2. 500 錯誤多半是 Steel 的 Chrome 重啟中，等幾秒重試。
3. Steel 反偵測層目前停用（上游 bug workaround），Cloudflare 嚴格的站
   可能擋 — 被擋就如實回報，不要硬試。
4. 連續抓頁間隔 1–2 秒，避免觸發目標網站風控。
5. **控制 context 用量**：scrape 預設只回前 8000 字元（被截斷會提示）。
   一個問題以 3–5 次 scrape 為限 — 抓太多頁會撐爆模型 context
   （症狀：回覆中斷、Internal Error）。查不到就直接回報查不到，
   並建議使用者提供更精確的名稱或網址。
6. **絕對禁止憑記憶報數字**：價格、票價、營業時間、時刻表 — 沒有本次
   實際抓到的網頁佐證，就不得寫出具體數字，「免責聲明」也不行。
   查證失敗時的正確回覆是：「查不到，原因是 X，建議你 Y」。
   寧可沒有答案，不要錯的答案 — 使用者會拿它訂行程。
