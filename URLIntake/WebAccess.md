# 網頁擷取路徑

`openab-url-intake` 是專用 Discord listener，擷取順序如下：

1. 一般文章：Cloudflare Browser Run 的
   `/markdown?browser=kitesurf` 遠端渲染 → Jina Reader。URL intake 預設不
   使用本機 Steel／Chromium。
2. X／Twitter status：優先走 FxTwitter（`api.fxtwitter.com`），可取得貼文
   正文與內嵌 X Article；失敗才退 KiteSurf／Jina。
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
