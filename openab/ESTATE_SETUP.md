# ESTATE_SETUP — #不動產估價 估價 bot（現況文件）

> 2026-06-20 建。實價登錄比價估價助理。半自動：使用者貼地址＋標示部，
> bot 自動查內政部實價登錄 open data、挑可比成交、算估價。

## 現況

- **服務**：`openab-estate`（image `openab-nvidia:qwen`，與 nvidia-lab 同殼／同模型 kimi-k2.6）。
- **頻道**：#不動產估價 = `1517804694901362752`（AA-agent 伺服器）。
- **bot 身分**：沿用 nvidia-bridge 應用（`DISCORD_TOKEN_NVIDIA`）——
  這是**第三個共用該 token 的容器**（另兩個：nvidia-lab、travel-nvidia），
  `allowed_channels` 互斥，所以不會互相重複回覆。頻道顯示名是 Nvidia-bridge。
  要獨立名稱 → 另開 Discord 應用、換 token 變數即可。
- **工作區**：`D:\discord 個人助理\EstateSpace`（AGENTS.md=估價 SOP、
  WebAccess.md=工具用法、tools/lvr.py=比價主力、tools/web.py=備用）。
- **config**：`config-estate.toml`。
- **volume**：`assistant_estate_qwen_state`（qwen state，非 external，compose 自建）。

## 設計重點（為何這樣做）

- **不碰 pqt.ttt.nat.gov.tw（北北桃地政電傳）**：付費按次計費，且站方公告
  113.07.19 明文禁止自動化擷取（違者停權）。故**標示部（屋齡/坪數/用途/
  建材/型態）由使用者人工提供**，bot 只做合規的實價登錄比價那段。
- **實價登錄不爬查詢站**：lvr.land.moi.gov.tw 是 frameset+SPA，查詢 API 參數
  CryptoJS 加密＋session token，無法用固定 URL 打。改用**官方 open data**
  （plvr.land.moi.gov.tw/DownloadSeason，每季每縣市一 CSV，門牌未遮蔽、欄位齊全），
  純 HTTP、免瀏覽器、合規穩定。tools/lvr.py 下載→篩路名→剔特殊交易→算單價統計。

## 重建步驟（新機器 / down -v 後）

```bash
cd "D:/discord 個人助理/openab"
# 1. 建 + chown qwen volume（root-owned 會 EACCES，同 NVIDIA_SETUP 坑 2）
docker volume create assistant_estate_qwen_state
docker run --rm -v assistant_estate_qwen_state:/v alpine chown -R 1000:1000 /v
# 2. 起容器
docker compose up -d openab-estate
# 3. 灌繁中 output-language（坑 4；MSYS_NO_PATHCONV 避免 Git Bash 改路徑）
docker cp ./qwen-output-language.md openab-estate:/home/node/.qwen/output-language.md
MSYS_NO_PATHCONV=1 docker exec -u root openab-estate chown 1000:1000 /home/node/.qwen/output-language.md
# 4. 驗證：log 應出現 discord bot connected user=Nvidia-bridge、channels=1
docker logs openab-estate --tail 20
```

## 冒煙測試

```bash
# 工具（容器內）— 應列出永安路成交與單價統計
MSYS_NO_PATHCONV=1 docker exec -w /workspace/EstateSpace openab-estate \
  uv run tools/lvr.py --city 桃園市 --road 永安路 --years 2 --type 透天

# Discord：在 #不動產估價 貼「桃園市桃園區永安路240號，屋齡26年，
# 242.13平方公尺，住商用，透天」→ bot 應回估價與採用的比價案。
```

## 踩坑

- **坑 SSL（2026-06-20）**：容器較嚴格的 OpenSSL 對政府站憑證鏈偶發
  `SSLError: Missing Subject Key Identifier`，會讓某一季別被丟掉。tools/lvr.py
  已加「SSLError → 關閉 verify 重試」（公開資料、完整性非機密）＋ 關閉警告。
- **季別發布有延遲**：最新一兩季（如查詢時的 115S2）尚未發布，下載失敗會被
  優雅跳過，不影響估價。
- 同 NVIDIA 殼共通坑（output-language 強制英文、qwen volume 權限、NIM 429
  限流、context 截斷）見 NVIDIA_SETUP.md。

## 維運

- 改 SOP / 工具 → 直接編 `EstateSpace/`（host 掛載，容器即時看到，不需 rebuild）。
- 新增白名單成員 → `config-estate.toml` 的 `allowed_users` 加 ID +
  `docker compose up -d --force-recreate openab-estate`。
- 換模型 → `config-estate.toml` 的 `OPENAI_MODEL`。
