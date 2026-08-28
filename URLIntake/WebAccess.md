# 網頁擷取路徑

`openab-url-intake` 是專用 Discord listener，擷取順序如下：

1. 一般文章：Cloudflare Browser Run 的
   `/markdown?browser=kitesurf` 遠端渲染 → Jina Reader → 本機網路出口直連
   原站（`direct_scrape`：瀏覽器 UA + trafilatura 抽取；每跳重導向都再跑
   `ensure_public_url()`）→ 僅當 `ALLOW_STEEL_FALLBACK` 時才用本機
   Steel／Chromium。direct 不花本機 CPU、也不依賴 Jina，比 Steel 便宜；
   Steel 對 techorange 這類站同樣會被擋，所以留在最後。URL intake 預設不
   使用本機 Steel。
   任何一段擷取結果若被判定為反機器人阻擋頁（`looks_blocked()`：4000 字以內
   且含 Cloudflare／challenge 特徵字串），一律捨棄不計入正文長度，讓後續退路
   繼續執行。阻擋頁通常有 500–900 字，會誤過長度門檻——2026-08-28
   techorange.com 那次就是 KiteSurf 回傳 851 字阻擋頁，Jina 因此從未被呼叫，
   最後把阻擋頁本身整理成筆記。`direct_scrape` 另外有密度檢查（連結文字佔比
   過高，或短行且連結也夠密），用來擋「很長但只是導覽列」的抽取結果；零連結
   的短段落散文不算導覽列。HTML 位元組直接交給 trafilatura 偵測編碼，不自行
   decode。這道閘只套在 direct，不套 KiteSurf／Jina。
2. X／Twitter status：優先走 FxTwitter（`api.fxtwitter.com`），可取得貼文
   正文與內嵌 X Article；失敗才退 KiteSurf／Jina／direct。
3. YouTube：官方字幕（繁中優先、人工字幕優先）→ 任意語言字幕 →
   yt-dlp 音訊 → ffmpeg 16 kHz Opus → Groq Whisper。
4. PDF URL：直接下載（30 MB 上限）→ pypdf 文字抽取。
5. 其他影片網址：正文不足時嘗試 yt-dlp + Groq Whisper。
6. Markdown→PDF：Cloudflare `/pdf?browser=kitesurf`；只有遠端服務失敗時
   才退回本機 Steel，確保 Discord 仍能收到 PDF。

KiteSurf 需要 `.local/cloudflare.env` 的 Account ID 與具
`Browser Rendering - Edit` 權限的 API token。擷取內容交給 NVIDIA NIM
整理；來源過長時保留前 75% 與末 25%，並在筆記限制段標記。私網、
loopback 與保留位址會在擷取前拒絕。
