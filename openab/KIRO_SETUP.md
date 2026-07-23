# KIRO_SETUP — #kiro-assistant（Kiro CLI 通用助理）

> 現況文件，2026-06-13 更新。**已部署運行中** — 本檔記錄目前設定、
> 重建步驟與踩坑。總覽見 README.md。

## 現況

```
Discord #kiro-assistant（1514819246838780095）＋ 私訊（免 @）
   └── kiro-bridge → openab-kiro 容器 → kiro-cli acp --trust-all-tools
         image：openab-kiro:tools（Dockerfile.kiro = 上游 openab + python3/ffmpeg/yt-dlp）
         工作區：D:\discord 個人助理\KiroSpace\（working_dir）
                ＋ D:\discord 個人助理\TravelMemory\（旅遊 vault，跨頻道協作）
         認證：AWS Builder ID（volume aiquant_kiro_auth，已登入）
```

- **角色**：通用問答＋**旅遊查證主力**＋ YouTube 轉錄。旅遊主題的查證
  成果**自動**寫進 `TravelMemory/Trips/<slug>/research_notes.md`
  （規則在 KiroSpace/AGENTS.md §跨頻道 ＋ `.kiro/steering/travel/`）。
- **上網**：SearXNG（搜尋）＋ Steel（讀頁）的 curl 版技能 —
  `KiroSpace/.kiro/skills/steel-browser/SKILL.md`（含禁編數字等鐵則）。
- **YouTube 逐字稿**：`python3 tools/yt.py <url>`（字幕優先 → yt-dlp +
  ffmpeg 壓縮 + Groq Whisper；長片 OK）。GROQ_API_KEY 由 config
  [agent].env 注入。
- 實測成本參考：一次查證任務約 0.05–0.2 AWS credits、約 50–90 秒。

## 直驅模式（不走 Discord）

由本機直接派工給 Kiro（Claude Code 維運時常用）：

```powershell
docker exec -w /workspace/KiroSpace openab-kiro kiro-cli chat --no-interactive --trust-all-tools "<任務描述>"
```

## 重建步驟（容器/image 掛了才需要）

```powershell
# image 重建（改了 Dockerfile.kiro 後同樣跑這個）
docker compose -f "D:\discord 個人助理\openab\docker-compose.yml" up -d --build openab-kiro
```

**AWS 重新登入**（只有 aiquant_kiro_auth volume 被清才需要）：

```powershell
docker exec -it openab-kiro kiro-cli login --use-device-flow
# 依輸出開啟 URL、確認代碼、AWS Builder ID 登入，然後：
docker compose -f "D:\discord 個人助理\openab\docker-compose.yml" restart openab-kiro
```

## 長期記憶 / 技能

- **長期記憶**：`KiroSpace\.kiro\steering\<主題>\*.md` — 每 session 自動讀。
  現有：`travel/research-output.md`（旅遊成果自動寫 vault 的規則）。
- **技能**：`KiroSpace\.kiro\skills\<name>\SKILL.md`（相容 Claude Code 格式）。
  現有：`steel-browser`（上網 + YouTube）。
- thread 內可用 `/models`、`/agents` 斜線指令。

## 故障排查

| 症狀 | 看哪裡 |
| --- | --- |
| bot 不上線 | `docker logs openab-kiro`：token 問題（.local/discord_token.env）|
| 上線但已讀不回 | 不在白名單？頻道不對（只聽 #kiro-assistant；私訊可）？頻道主訊息沒 @？ |
| 回覆 auth 錯誤 | AWS 憑證失效/volume 被清 → 重跑上面 device-flow |
| 說做不了逐字稿 | 舊 session 記著舊技能 — 開新對話 |
| 查證沒寫進 vault | 看 steering 規則是否被讀（新 session 才載入）；補一句「存進 vault」|
