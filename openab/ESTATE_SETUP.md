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

## 後端：kiro-cli（2026-08-09 改，原為 qwen-code→NIM）

換的理由是**規則遵守**不是速度。同一個估價標的實測：

| 後端 | 整輪 | shell | 結果 |
|---|---|---|---|
| minimax-m3（NIM） | 7分10秒 | 9 | 11 條規則全過 |
| gpt-oss-20b（NIM） | 11 秒 | 2 | 跳過大半 SOP、表格重複列、給出無依據數字 |
| gpt-oss-120b（NIM） | 11 秒 | 2 | 同上 |
| **kiro-cli** | **2分13秒** | **10** | **全部規則通過，含 minimax 解不掉的中間訊息** |

**2026-08-09 實測結果（同一標的，第四輪）**：Kiro 比 minimax 快 3.2 倍且品質更好。

- **中間訊息問題解決了。** minimax 四次改 prompt 都失敗（它在 ACP 下沒有獨立
  推理通道，規劃只能走 assistant text），Kiro 一次就照規則 3 的格式輸出
  `⋯ 查同棟建案資訊　⋯ 放寬查整區…`——一行進度、無數字。搭配
  `tool_display = "compact"`，十行指令變成 `✅ 10 tool(s)`。
- **成本 1.32 credits／次**（8 個計費事件加總；context 只用了 200k 的 3.9%）。
  對照 KIRO_SETUP.md 記的簡單查證 0.05–0.2，估價一輪貴 7~25 倍。
  **KIRO FREE（AWS Builder ID）每月 50 credits** → 約 37 次估價／月，
  且與 #kiro-assistant 共用同一帳號額度。PRO $20/月＝1000 credits，
  超額 add-on $0.04/credit。`kiro-cli` 查不到用量（`user profile` 只服務
  IAM Identity Center／外部 IdP），要上 kiro.dev 後台看。
  **現行決定：只有估價頻道用 kiro，nvidia-lab／travel-nvidia 維持 NIM 免費。**
- 它自己發現了前幾輪都沒人提的關鍵事實：「門牌巷弄（451巷），非八德路正面臨路」
  —— 這對一樓店面估值影響很大。

**登入的坑（花了四次才過）**：`kiro-cli whoami` 顯示已登入**不代表能推論**。
先用 `x011training@gmail.com` 登入成功但推論回 `Authentication failed`（該
Builder ID 沒有 Kiro 推論權限）。改用 `xxx69579575@gmail.com` 時前三次都失敗，
因為瀏覽器已登入舊帳號會直接沿用身分授權，且該帳號是 **Google 註冊**的 ——
打 email+密碼會被擋（"already associated with a different sign-in method"）。
**正解：無痕視窗 ＋ 點「Sign in with Google」。**
驗證一定要跑兩步：`kiro-cli whoami` 看 email，再 `kiro-cli chat` 實際推論一次。

兩個 gpt-oss 都只跑 `lvr.py` 就下結論，沒查同棟錨點、沒跑 `listing.py`。
**單回合 benchmark 完全預測不了八回合的表現**（20b 在 benchmark 上是最快且
工具呼叫 4/4，實測最糟）。詳見 `config-estate.toml` 的註解。

`openab-kiro:tools` 這個 image 2026-08-09 加裝了 `uv`（EstateSpace 的工具全走
`uv run`），所以 kiro 頻道與估價頻道共用同一個 image。

## 重建步驟（新機器 / down -v 後）

```bash
cd "D:/discord 個人助理/openab"
# 1. 起容器（volume 由 compose 自建；image 內 /home/agent 已是 agent:agent，
#    不需要像舊的 qwen volume 那樣先 chown）
docker compose up -d openab-estate

# 2. AWS Builder ID 登入（**必做**，否則 agent 回 auth 錯誤）
#    刻意不共用 kiro 頻道的 aiquant_kiro_auth：避免兩容器同時 refresh token
#    的競態，也不加深對 AIQuant volume 的耦合。
docker exec -it openab-estate kiro-cli login --use-device-flow
#    依輸出開啟 URL、確認代碼、用 AWS Builder ID 登入，然後驗證：
docker exec openab-estate kiro-cli whoami

# 3. 驗證：log 應出現 discord bot connected user=Nvidia-bridge、channels=1
docker logs openab-estate --tail 20
```

**退回 NIM 後端**：`config-estate.toml` 改 `command="qwen"` / `args=["--acp"]`、
env 加回 `OPENAI_*` 三件套（`OPENAI_MODEL = "minimaxai/minimax-m3"`），
compose 改回 `image: openab-nvidia:qwen` 與 `assistant_estate_qwen_state`
（那個 volume 沒刪，內容還在），並加回 `../.local/nvidia.env`。

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
