# openab — Discord 個人助理 stack 總覽

> 最後更新：2026-07-23（新增 #聯徵報告製作 Codex 服務，預設 profile 關閉）。
> 本資料夾是整套系統的
> 部署中心；compose 專案名 `discord-assistant`，與 D:\AIQuant 的 quant stack 完全分離。
>
> **本檔 = stack 的唯一真相來源**（服務、頻道、維運、機密、volumes）。
> 找 bot 產出的筆記在哪 → [../INDEX.md](../INDEX.md)（Obsidian vault 首頁）。

## 一鍵維運

```powershell
# 全部啟動 / 停止 / 看狀態
docker compose -f "D:\discord 個人助理\openab\docker-compose.yml" up -d
docker compose -f "D:\discord 個人助理\openab\docker-compose.yml" stop
docker ps --filter "label=com.docker.compose.project=discord-assistant"

# 看某隻 bot 的 log
docker logs openab-kiro --tail 30
```

## 服務一覽（11 個 compose services）

| 服務 | 角色 | 頻道/端口 | 詳細文件 |
|---|---|---|---|
| openab-kiro | Kiro CLI 通用助理＋旅遊查證主力＋YouTube 轉錄 | #kiro-assistant | KIRO_SETUP.md |
| openab-nvidia-lab | qwen-code → NVIDIA NIM 免費模型（實驗） | #nvidia-lab | NVIDIA_SETUP.md |
| openab-travel-nvidia | 同上殼（旅遊查證副手） | #travel-planner | NVIDIA_SETUP.md |
| openab-travel-claude | Claude Code 行程彙整（獨立 Pro 帳號） | #travel-planner | TRAVEL_SETUP.md |
| openab-estate | 同 nvidia 殼（實價登錄比價估價；標示部使用者人工貼） | #不動產估價 | ESTATE_SETUP.md |
| openab-astruct | Claude Code 夜盤閘門法審核 | #a-struct | config-astruct.toml / workspace AGENTS.md |
| openab-credit-report | Codex CLI；Discord PDF/圖片 → CreditReportSpace → DOCX 回傳 | #聯徵報告製作 | CREDIT_REPORT_SETUP.md |
| steel-api / steel-ui | 瀏覽器沙箱（讀網頁/截圖/登入態）＋live viewer | 127.0.0.1:3000/9223、5173 | STEEL_SETUP.md |
| searxng | 搜尋 JSON API（自架 metasearch） | 127.0.0.1:8081 | STEEL_SETUP.md §5.5 |
| pdf-publisher | 行程變動自動轉 PDF 發 Discord | （無端口） | 本檔 §pdf-publisher |

## Discord 配置（伺服器「AA-agent」 1514818023737790614）

**6 個頻道、7 個 bot 容器** —— 不是一對一。#travel-planner 由兩個容器共用，
所以「服務數」不等於「頻道數」。

| 頻道 | ID | 容器 | Bot |
|---|---|---|---|
| #kiro-assistant | 1514819246838780095 | openab-kiro | kiro-bridge |
| #nvidia-lab | 1514819234448933117 | openab-nvidia-lab | Nvidia-bridge |
| #travel-planner | 1514819240631206072 | **openab-travel-nvidia ＋ openab-travel-claude** | Nvidia-bridge（查證，免費額度）＋ travel-claudebridge（行程彙整）—— 主頻道靠 @ 指定要哪一隻 |
| #不動產估價 | 1517804694901362752 | openab-estate | Nvidia-bridge（2026-06-20 建）|
| #a-struct | 1518874308716265643 | openab-astruct | openab-astruct |
| #聯徵報告製作 | `${CREDIT_REPORT_CHANNEL_ID}` | openab-credit-report | 專用 Codex bot。**已上線**（2026-08-01 手機實測通過）；頻道 ID 不寫死在 config，由 `.local/` 經環境變數注入 |
| #一般 | 1514818024467726471 | — | （無 bot 服務） |

- **觸發規則**：頻道主訊息要 @（上游硬限制）；討論串內免 @；
  既有助理私訊免 @；**聯徵 bot 明確 `allow_dm = false`，只接受 bootstrap
  指定的單一頻道及其討論串**
- **核心使用者白名單**（七份 config 都包含這兩人；a-struct 另有測試帳號）：
  - `843428445802725388` anxxxiii（owner）
  - `1488170559865884684` qmini20
- 新增成員：把 user ID 加進五份 config → `up -d --force-recreate` 各 bot 容器

## 機密（../.local/，gitignore）

| 檔案 | 內容 |
|---|---|
| discord_token.env | DISCORD_TOKEN_NVIDIA / _TRAVEL_CLAUDE / _KIRO / _ASTRUCT |
| credit_report.env | DISCORD_TOKEN_CREDIT_REPORT / CREDIT_REPORT_CHANNEL_ID |
| nvidia.env | NVIDIA_API_KEY（build.nvidia.com 免費）|
| groq.env | GROQ_API_KEY（語音 STT + yt.py Whisper 退路）|

## 帳號 / 額度來源（互不干擾）

| 後端 | 帳號 | 認證存放 |
|---|---|---|
| Kiro CLI | AWS Builder ID | volume `aiquant_kiro_auth`（device-flow 登入）|
| NVIDIA NIM | nvapi key | env（nvidia.env）|
| Claude Code | **X011training@gmail.com（Pro，獨立帳號）** | volume `assistant_travelclaude_state`（容器內 /login）|
| Codex | ChatGPT device auth（專用 state，不共用 AIQuant） | volume `assistant_creditreport_codex_state` |

⚠ 硬規則：**任何容器都不准設 ANTHROPIC_API_KEY**（Claude Code 會棄 OAuth 改走 API 計費）。

## 跨頻道工作流（旅遊）

```
DM kiro-bridge「查 XXX」──自動──▶ TravelMemory/Trips/<slug>/research_notes.md
DM travel-claudebridge「排行程」─▶ Trips/<slug>/itinerary.md
        └─ pdf-publisher（≤20 秒）─▶ itinerary.pdf 存回 vault ＋ 發到 #travel-planner 📄
```

Kiro 的「旅遊主題自動寫 vault」規則在 `KiroSpace/AGENTS.md` ＋
`KiroSpace/.kiro/steering/travel/research-output.md`（雙保險）。

## pdf-publisher

確定性監看（不依賴 LLM 記得）：輪詢 vault `Trips/*/itinerary.md`（20 秒），
變動 → md→HTML →（容器內部 HTTP 給 Steel 抓，Steel 不收 data: URL）→
`/v1/pdf` 真 Chrome 渲染（CJK 字型已驗證）→ PDF 存回 trip 資料夾 ＋
以 travel-claudebridge 身分發到 #travel-planner。已發佈 hash 存
`assistant_pdfpub_state` volume，重啟不重發。程式：`pdf-publisher/publish.py`。

## 聯徵報告工作流

`openab-credit-report` 放在 `credit-report` compose profile，完成新 bot token、
channel ID 與 Codex device auth 前不會被平常的 `docker compose up -d` 啟動。
**bootstrap 已完成、服務已上線**；profile 閘門保留是刻意的，避免這隻 bot 被
無意間隨全體啟動——要起它必須明確帶 `--profile credit-report`。
OpenAB 將 Discord session 交給 `codex-acp`；整合 helper 依
`sender_context` 回抓原始 PDF/圖片到
`CreditReportSpace/tmp/docs/intake/<message_id>/`，再由該工作區 agent 流程
驗證、產出及渲染 DOCX 並回傳原 thread。image 內以 hash lock 鎖定
Python 3、python-docx、pytest/jsonschema，並鎖定 Poppler、LibreOffice
與繁中楷體 fallback；login shell 仍固定使用專用 venv。root-only broker
持有 Discord token，`codex-acp` 子行程只看得到受限 Unix socket；entrypoint
同時監視 broker/OpenAB，任一死亡即 fail closed。
完整 bootstrap、安全邊界與測試見 `CREDIT_REPORT_SETUP.md`。

## 工作區工具（agent 用）

| 工具 | 用途 | kiro（python3 直跑） | nvidia（uv run） |
|---|---|---|---|
| tools/web.py | SearXNG 搜尋 / Steel scrape（8000 字截斷）/ 截圖 / PDF / 登入 session | （kiro 用 curl 版技能，見其 SKILL.md） | ✅ |
| tools/yt.py | YouTube → 逐字稿（字幕優先 → yt-dlp+Groq Whisper） | ✅ 含 ffmpeg 壓縮（長片 OK） | ✅（無 ffmpeg，限 24MB） |

副本位置：LabSpace/tools、TravelMemory/tools、KiroSpace/tools（改一份要同步三份）。

## 本資料夾檔案

| 檔案 | 用途 |
|---|---|
| docker-compose.yml | stack 定義（服務、volume、port — 唯一真相來源）|
| config-*.toml ×7 | 各 bot 的 OpenAB 設定（頻道、agent 指令、env、白名單）|
| Dockerfile.kiro | kiro 衍生 image（+python3/ffmpeg/yt-dlp）|
| Dockerfile.nvidia | nvidia 衍生 image（+qwen-code）|
| Dockerfile.credit-report / credit-report/ | Codex bridge＋附件 intake/DOCX upload helper |
| qwen-output-language.md | qwen 強制繁中範本（灌進 qwen volumes 用）|
| searxng-settings.yml | SearXNG 設定（formats 加了 json）|
| pdf-publisher/ | 自動 PDF 服務（Dockerfile + publish.py）|
| *_SETUP.md ×6 | 各子系統的現況、重建步驟、踩坑紀錄（含 CREDIT_REPORT_SETUP.md）|
| MAIL_CLEANUP_FRAMEWORK.md | 信箱清理框架（**規劃中**）：三層分工，Layer 3 等 OpenAB 0.10.0-beta.3 |

## Named volumes（全部 external — `down -v` 不會清，但勿手動 prune）

| volume | 內容 | 丟了會怎樣 |
|---|---|---|
| aiquant_kiro_auth | AWS Builder ID 憑證 | 重跑 device-flow 登入（KIRO_SETUP §3）|
| aiquant_kiro_state | Kiro 設定/session | 無痛 |
| assistant_travelclaude_state | Pro 帳號 OAuth | 容器內重跑 /login |
| assistant_creditreport_codex_state | 專用 Codex/ChatGPT OAuth | 先 chown 1000，再重跑 `codex login --device-auth` |
| aiquant_*_qwen_state ×2 + assistant_estate_qwen_state | qwen 設定＋**強制繁中檔** | 重 chown 1000 + 重灌 output-language（NVIDIA_SETUP §4/§7、ESTATE_SETUP）|
| aiquant_steel_cache | Steel Chrome cookies（登入態）| 各網站重登 |
| assistant_pdfpub_state | 已發佈 PDF 的 hash | 會把現有行程重發一次（無害）|

## 與 AIQuant 僅剩的依賴

base image `openab-codex:with-uv`（Dockerfile.nvidia 的 FROM；quant 那邊
build 的）。若被刪：到 D:\AIQuant\openab 用 Dockerfile.codex.ext 重建。
