# CREDIT_REPORT_SETUP — #聯徵報告製作（Codex / OpenAB）

> 初始實作：2026-07-23。這份文件只涵蓋 Discord/OpenAB 整合層；報告範本、
> 欄位規則、OCR/文件生成與品質檢查由 `/workspace/CreditReportSpace` 的
> agent 流程負責。服務尚未連線 live Discord，且 compose profile 預設關閉。

## 架構

```text
Discord #聯徵報告製作
  │  @專用 bot + PDF/圖片附件
  ▼
openab-credit-report
  ├─ OpenAB（Discord gateway / thread session / sender_context）
  ├─ root-only Discord broker（唯一持有 bot token；entrypoint 監視）
  ├─ token-free codex-acp → 真實 Codex app-server / Codex 模型
  ├─ /workspace/AGENTS.md（本整合層契約）
  ├─ /opt/credit-report/discord-files.mjs
  │    ├─ 依 sender_context 的 message_id 回抓原始 Discord 附件
  │    └─ 只收 PDF/圖片；最終只准上傳工作區內的 DOCX
  └─ /workspace/CreditReportSpace（host bind mount；報告 agent 流程）
         ├─ tmp/docs/intake/<message_id>/manifest.json + 原始附件
         ├─ tools/gen_report.py / tools/render_docx.py
         └─ output/doc/<workflow output>.docx
                         │
                         └─ Discord REST API → 原 thread（DOCX）
```

OpenAB 本身負責文字回覆與 session；DOCX 不是靠 OpenAB relay，而是依上游
建議用 `sender_context.thread_id`（無則 `channel_id`）直接呼叫 Discord
Create Message API 上傳。token 不硬編，只存在 root PID 1/OpenAB 與
root-owned broker 的環境；agent wrapper 在降權到 UID 1000 前清除 token，
Codex/helper client 只可呼叫 channel-locked Unix socket API。

## Codex / OpenAB 相容性結論（本機已驗證）

不要設定 `command = "codex"` 搭配 `args = ["--acp"]`：本機 Codex CLI
`0.145.0` 的 help 沒有 `--acp`，image 內 Codex CLI `0.128.0` 也沒有。

實際採用 `openab-codex:with-uv`，本機 image ID
`sha256:0677ae0af7c0e8b805619129473b9a1e1d1562dae4bf460c29abc50343e2192c`。
離線 inspect / ephemeral container 驗證：

- `openab` binary 存在，預設 entrypoint 是
  `openab run -c /etc/openab/config.toml`。
- `codex-acp` 存在，package 是 `@zed-industries/codex-acp 0.11.1`。
- image 內 Codex CLI 是 `0.128.0`；既有唯讀測試 volume 的
  `codex login status` 回報 `Logged in using ChatGPT`，證明此 image 的
  Codex/ChatGPT OAuth 路徑可用。新服務仍使用自己的 state volume，不共用憑證。
- OpenAB upstream 也以 `command = "codex-acp"` 作為 Codex 正式接法：
  <https://github.com/openabdev/openab/blob/main/Dockerfile.codex>
- 衍生 image 以版本鎖定的 Debian 套件安裝 Python 3.11、Poppler 22.12、
  LibreOffice Writer 7.4.7 與 AR PL UKai TW；再依 hash-locked
  `credit-report/requirements.lock` 安裝與 B 一致的 `python-docx` 1.2.0、
  pytest 9.0.2、jsonschema 4.26.0 及全部 transitive dependencies。
  fontconfig 把 WORD 的「標楷體/DFKai-SB」映射到該繁中楷體。
- `/etc/profile.d/credit-report-venv.sh` 固定把
  `/opt/credit-report/venv/bin` 放在 PATH 最前方；image build 會分別以
  `bash -lc` 與 `sh -lc` 驗證 interpreter 及上述三個 Python 套件，避免
  login shell 重設 PATH 後誤用系統 Python。

不硬編模型名稱；`codex-acp` 使用該專用 Codex state 的 account/default model。
這避免 image 內較舊 CLI 被指定到它不認得的未來模型。要固定模型時，先在隔離
容器確認該 CLI/account 可見，再把 `-c model="..."` 加入
`config-credit-report.toml` 的 `args`。

### 為何另加附件 helper

本機 OpenAB binary 已驗證會 encode 圖片（10 MB 上限）與 inline 文字附件，
但其 binary 字串明確含 `skipping non-image attachment`，PDF 會被舊版路徑
略過。聯徵輸入不能依賴這個缺口，因此 parent `AGENTS.md` 強制 agent 用
`sender_context` 的 message/channel ID 回讀原始 Discord message，再把 PDF/
圖片落到 CreditReportSpace。這不是假設附件 URL 會被 OpenAB 放進 prompt。
使用者已明確接受此 channel-locked sender_context helper 方案，不升級或重編
OpenAB。

## 檔案與服務

| 路徑 | 用途 |
|---|---|
| `config-credit-report.toml` | 專用頻道、Codex ACP、白名單、單 session |
| `Dockerfile.credit-report` / `credit-report/requirements.lock` | 鎖定 Python/DOCX/PDF/LibreOffice/字型與 Python hashes，加 helper、broker、wrapper 與 parent AGENTS |
| `credit-report/AGENTS.md` | intake 與 DOCX 回傳契約；報告規則仍由內層 AGENTS 負責 |
| `credit-report/discord-files.mjs` | broker client、附件下載驗證、manifest、安全清理、OOXML DOCX 上傳 |
| `credit-report/discord-broker.mjs` | root-only Discord REST broker；Codex 不取得 token |
| `credit-report/*entrypoint.sh` / `venv-profile.sh` | runtime config、broker/OpenAB 雙程序監視、login-shell venv、token 清除與 Codex 降權 |
| `credit-report/runtime-config.mjs` | 確定性展開 token/channel，驗證 effective allowed_channels |
| `credit-report/discord-broker.integration.test.mjs` | root download → UID 1000 PDF read/render/message-scoped clean 權限整合測試 |
| `credit-report/bootstrap.ps1` | 安全提示輸入 token，建立 gitignored env |
| `docker-compose.yml` | `openab-credit-report` profile、workspace/auth volumes |

## Discord bootstrap（尚未執行）

已決定使用**新的專用 Discord bot**，不共用 NVIDIA/Kiro/Claude token。
建立應用與頻道仍是 live 變更，必須由 coordinator/user 手動完成；本次實作
不會建立頻道。

Bot 至少需要：

- View Channels
- Read Message History
- Send Messages
- Send Messages in Threads
- Attach Files
- Add Reactions
- Message Content Intent（Developer Portal 的 privileged intent）

建立 `#聯徵報告製作` 後複製 channel ID，從 repo root 執行：

```powershell
.\openab\credit-report\bootstrap.ps1 -ChannelId "<17-20 位 channel ID>"
```

腳本用 secure prompt 接 token，寫到
`.local/credit_report.env`（gitignored）：

```dotenv
DISCORD_TOKEN_CREDIT_REPORT=<secret>
CREDIT_REPORT_CHANNEL_ID=<channel id>
```

不要把 token 放在 TOML、compose、PowerShell history、issue 或聊天訊息。
輪替 token 時重新執行並明確加 `-Force`。

## 首次部署與 Codex 登入

下列步驟只針對新 profile，不會重建既有 live containers：

```powershell
cd "D:\discord 個人助理\openab"

# 1. 建 image（不啟動服務）
docker compose --profile credit-report build openab-credit-report

# 2. 建立專用 state，並修正新 named volume 的 root ownership
docker volume create assistant_creditreport_codex_state
docker run --rm --network none --user root `
  -v assistant_creditreport_codex_state:/home/node/.codex `
  --entrypoint sh assistant-credit-report-codex:dev `
  -c "chown -R 1000:1000 /home/node/.codex"

# 3. 一次性 ChatGPT device auth，憑證只進專用 volume
docker compose --profile credit-report run --rm --no-deps `
  --entrypoint /opt/credit-report/agent-entrypoint.sh `
  openab-credit-report codex login --device-auth

# 4. 確認登入狀態
docker compose --profile credit-report run --rm --no-deps `
  --entrypoint /opt/credit-report/agent-entrypoint.sh `
  openab-credit-report codex login status

# 5. 只啟動新服務
docker compose --profile credit-report up -d openab-credit-report
docker logs openab-credit-report --tail 50
```

entrypoint 會先把 TOML template 安全寫成 root-only runtime config，並驗證
effective `allowed_channels` **恰好等於** `CREDIT_REPORT_CHANNEL_ID`，缺值、
格式錯誤、placeholder 數量或錯頻道一律在連 Discord 前終止。預期 log 有
Discord connected、allowed channels=1，且 agent command 是降權 wrapper。
device auth/status 也刻意經同一 wrapper，避免把 compose env 中的 Discord
token 暴露給 Codex CLI。
禁止用不帶 service name 的 `up -d --build` 作首次部署。

## 實際訊息工作流

1. 白名單使用者在 `#聯徵報告製作` 主頻道 @bot，附 PDF/圖片並描述需求。
2. OpenAB 建 thread、啟動一個 Codex ACP session，加入 `sender_context`。
3. parent AGENTS 強制先執行：

   ```sh
   node /opt/credit-report/discord-files.mjs download \
     --channel-id "<thread_id 或 channel_id>" \
     --message-id "<message_id>" \
     --dest /workspace/CreditReportSpace/tmp/docs/intake
   ```

4. helper 只接受 PDF、PNG/JPEG/WebP/GIF/TIFF/HEIC/HEIF，驗證副檔名/MIME、
   magic bytes、檔數與大小，再寫 message-scoped manifest。預設每檔 25 MB、
   每訊息總量 100 MB、20 檔。
5. Codex 同時看到 parent transport contract 與內層
   `CreditReportSpace/AGENTS.md`；依內層規則抽取 JSON，執行
   `python tools/gen_report.py ... --check-only`、產 DOCX，再用
   `python tools/render_docx.py ...` 逐頁目視檢查。
6. parent AGENTS 強制用 helper 把**工作區內**的 `.docx` 回傳原 thread；
   helper 拒絕其他副檔名、generic ZIP、workspace traversal 與 symlink。
7. 成功上傳或已回報不再重試的終止錯誤後，執行 `discord-files.mjs clean`
   只清該 `<message_id>` 目錄；helper 會先隔離目錄並拒絕 symlink tree。

`tmp/**` 已由 CreditReportSpace ignore；不再建立未忽略的 `.discord-inbox`。
不可用手寫 `rm -rf` 代替 message-scoped clean，也不可清除其他 session。

## 離線驗證（不碰 live Discord）

```powershell
# Compose 結構（不讀取任何 .local env 檔）
docker compose -f .\openab\docker-compose.yml --profile credit-report `
  config --no-env-resolution --quiet

# TOML 語法
python -c "import tomllib, pathlib; tomllib.loads(pathlib.Path(r'openab/config-credit-report.toml').read_text(encoding='utf-8')); print('TOML OK')"

# Node helper/runtime config：語法 + mock Discord HTTP 正負向單元測試
node --check .\openab\credit-report\discord-files.mjs
node --check .\openab\credit-report\discord-broker.mjs
node --test .\openab\credit-report\discord-files.test.mjs `
  .\openab\credit-report\runtime-config.test.mjs

# PowerShell bootstrap 只 parse，不執行（不寫 .local）
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path .\openab\credit-report\bootstrap.ps1),
  [ref]$null,
  [ref]$errors
) | Out-Null
if ($errors.Count) { $errors | Format-List; exit 1 }

# 建 image 後確認兩種 login shell 都使用 venv（ephemeral、network none）
docker run --rm --network none --entrypoint bash `
  assistant-credit-report-codex:dev -lc `
  "command -v python; python -c 'import docx,jsonschema,pytest'; pdftoppm -v; soffice --version"
docker run --rm --network none --entrypoint sh `
  assistant-credit-report-codex:dev -lc `
  "command -v python; python -c 'import docx,jsonschema,pytest'; codex --version; codex-acp --help"

# root broker → node 權限、PDF 轉換及 message-scoped cleanup（mock HTTP）
docker run --rm --network none --entrypoint node `
  assistant-credit-report-codex:dev --test `
  /opt/credit-report/discord-broker.integration.test.mjs

# B worktree 必須 ro mount；先以 bash -lc 執行，再把 entrypoint 改為 sh 重跑
docker run --rm --network none --user 1000:1000 --entrypoint bash `
  -v "D:/discord 個人助理/CreditReportSpace:/workspace/CreditReportSpace:ro" `
  -w /workspace/CreditReportSpace -e PYTHONDONTWRITEBYTECODE=1 `
  assistant-credit-report-codex:dev -lc `
  "python -m pytest tests -q -p no:cacheprovider && \
   mkdir -p /tmp/credit-report-smoke && \
   python tools/gen_report.py fixtures/sample_report.json \
     -o /tmp/credit-report-smoke/sample.docx && \
   python tools/render_docx.py /tmp/credit-report-smoke/sample.docx \
     --outdir /tmp/credit-report-smoke/render"
```

2026-07-23 在 A worktree 的第二輪衍生 image 離線實跑結果：

- helper/runtime config 15 項正負向 Node 測試全過；
- container 內 broker 權限整合測試通過：root 下載後的目錄為
  `root:node 0750`、檔案為 `root:node 0640`，UID 1000 可用 Poppler
  轉換 PDF 並只清除指定 message；其他使用者無任何權限；
- B worktree 以唯讀 mount 執行目前完整 `pytest`：bash/sh login shell
  各自 `91 passed`，兩者的 `command -v python` 都是
  `/opt/credit-report/venv/bin/python`；
- 去識別 fixture 的 `--check-only`、DOCX 產生、LibreOffice → PDF →
  Poppler PNG render 在 bash/sh 均成功，人工目視 PNG 的繁中字型、表格及
  刪除線正常；
- network-none 啟動 OpenAB 時，log 顯示 `allow_all_channels=false`、
  `channels=1`、`allow_dm=false`；缺少/格式錯誤的 channel 在 Discord
  adapter 啟動前失敗，錯誤不含 token；
- UID 1000 無法讀 root-only runtime TOML/PID 1 environment，
  agent wrapper 的 child environment 與 Codex prompt 都不含 Discord token；
  prompt 同時含 parent helper 契約與內層 CreditReportSpace AGENTS 規則。
- 強制終止 broker 後 entrypoint 立即向 OpenAB 發 SIGTERM；若 OpenAB 的
  Discord shutdown 卡住，5 秒後 SIGKILL，容器以非零狀態退出，不會讓
  token broker 已死的服務繼續接受工作。

## Live 冒煙測試（部署核准後才做）

1. 在新頻道 @bot 並附一個無敏感資料的最小 PDF。
2. 確認 thread 出現，log 無 token/auth/ACP error。
3. 確認
   `CreditReportSpace/tmp/docs/intake/<message_id>/manifest.json` 與 PDF 存在。
4. 要求測試流程產出 DOCX；確認 helper 回傳 DOCX 到同一 thread。
5. 上傳 `.zip` 或偽裝副檔名，確認 helper 拒絕且不落地。
6. 非白名單帳號 @bot，確認只得到拒絕反應、不啟動 Codex session。
7. 完成後確認該 message intake 已清除，且其他 message 目錄未受影響。

## 維運 / 重建

```powershell
# 只重建這個 image/service
docker compose --profile credit-report build openab-credit-report
docker compose --profile credit-report up -d --no-deps openab-credit-report

# 看 log / 狀態
docker compose --profile credit-report ps openab-credit-report
docker logs openab-credit-report --tail 100

# 停止新服務（不影響其他 bot）
docker compose --profile credit-report stop openab-credit-report
```

- 改 `credit-report/AGENTS.md` 或 helper 要 rebuild image。
- 改 runtime config renderer、broker、entrypoint 或鎖定依賴也必須 rebuild。
- 改 `config-credit-report.toml` 後只 recreate 本服務。
- Codex auth 壞掉：重跑 device auth；不要掛載 `aiquant_codex_state` 偷共用。
- `Permission denied: /home/node/.codex`：漏了首次 chown；停止本服務後重跑
  上述 step 2（不必刪 volume）。
- `Connection Lost`：先看 `codex login status`，再以 network-none 確認
  `codex-acp --help`；不要改成 `codex --acp`。
- PDF 沒落地：確認 bot 有 Read Message History、sender_context IDs 正確、
  檔案在 allowlist/大小限制內；helper 不會接受任意 URL。
- 若 log 出現 `Discord broker exited unexpectedly`，服務會 fail closed 並由
  compose restart policy 重啟；先查 broker/runtime config 原因，不要繞過監視。
- DOCX 沒回傳：確認 bot 有 Attach Files / Send Messages in Threads，且輸出
  路徑確實在 `/workspace/CreditReportSpace` 下並是完整 WordprocessingML
  package（不是只改副檔名的 ZIP）。
