# URL intake 設定與維運

## 已部署配置

- Discord：`#url-intake`，ID `1536220007657373806`
- Listener：`openab-url-intake`（py-cord；Nvidia-bridge token；NVIDIA NIM 整理）
- Obsidian：`../URLIntake/*.md`
- PDF：`intake-publisher` 監看 Markdown，每 10 秒轉檔並上傳；本機副本在
  `../URLIntake/PDF/`
- YouTube：字幕優先；無字幕時使用 yt-dlp + Groq Whisper
- X／Twitter：FxTwitter 優先（含 Article）；失敗才退 KiteSurf／Jina
- 一般網頁：Cloudflare KiteSurf 遠端渲染；正文太薄時退 Jina Reader；
  不使用本機 Steel
- PDF 渲染：KiteSurf 優先，只有遠端失敗才退本機 Steel

## Cloudflare 憑證

複製 `cloudflare.env.example` 的兩個鍵到 `../.local/cloudflare.env`：

```dotenv
CLOUDFLARE_ACCOUNT_ID=<Cloudflare Account ID>
CLOUDFLARE_API_TOKEN=<具 Browser Rendering - Edit 權限的 token>
```

未填入時，listener 會清楚記錄 KiteSurf 未啟用，文章只使用 Jina／直接下載
等輕量退路；PDF 則使用本機 Steel，避免服務中斷。

## 操作

在 `#url-intake` 直接貼一個或多個 URL，不必 @bot。每個 URL 會建立獨立
筆記；agent 先回覆摘要，PDF publisher 隨後另發一則附檔訊息。

## 維運

```powershell
docker compose -f "D:\discord 個人助理\openab\docker-compose.yml" \
  up -d openab-url-intake intake-publisher

docker logs openab-url-intake --tail 50
docker logs intake-publisher --tail 50
```

## 驗收

1. `docker compose config` 無錯。
2. 兩個容器皆為 running，listener log 顯示只監聽 channel
   `1536220007657373806`，並顯示 `web renderer: Cloudflare KiteSurf`。
3. 貼一般文章後，`URLIntake/` 出現 Markdown。
4. 10 秒左右 `URLIntake/PDF/` 出現 `%PDF` 檔案，Discord 收到同名附件。
5. 同一份 Markdown 未變更時，重啟 publisher 不會重發。
