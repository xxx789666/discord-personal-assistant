# Claude OAuth 健康檢查（2026-08-23 建立）

## 為什麼有這東西

2026-08-23 使用者在 #travel-planner 問問題，bot 回 `⚠️ Internal Error
(code: -32603)` + `API Error: 401 OAuth access token has expired`。查下去發現
`travel-claudebridge` 的 access token 早在 **2026-06-12** 就過期了，
`.credentials.json` 的 mtime 停在發卡當天 —— refresh 兩個多月都沒生效，
而我們是「用到才發現」。

建這組檢查的當天，第一次跑就抓到 `openab-astruct` 也在 2026-08-21 掛掉了。
兩隻都是同一種故障模式（掛 Claude OAuth named volume 的 bridge）。

檢查刻意跑在**容器外面的 Windows 工作排程器**上 —— 要偵測的就是容器本身壞掉，
放在容器裡沒有意義。

## 監看對象

| 容器 | 頻道 | 認證方式 |
|---|---|---|
| `openab-travel-claude` | #travel-planner | 長效訂閱 token（env）✅ 2026-08-23 切換 |
| `openab-astruct` | #a-struct | 長效訂閱 token（env）✅ 2026-08-23 切換 |

**2026-08-23 起兩隻都已改用 `claude setup-token` 的長效訂閱 token**（`[agent] env`
注入 `CLAUDE_CODE_OAUTH_TOKEN`，值放 `.local/claude_oauth.env`），不再依賴會被清空
的 `.credentials.json`。舊的 OAuth state volume 刻意留著沒清，要退回 session login
只要把 config 的 `env = {...}` 那行註解掉再 `docker compose up -d` 即可。

astruct 原本已經壞到 `hasRefresh: false`（無法自動復原），這次是直接用長效 token
接管，沒有再走一次 `/login`。

要加新的就改 `claude-oauth-check.ps1` 開頭的 `$Targets`。

## 兩段式檢查

```powershell
# 便宜檢查：容器在跑嗎？.credentials.json 的 expiresAt 過期了嗎？
# 零 token 成本、零風險 → 每小時跑
.\claude-oauth-check.ps1

# 真實探測：docker exec <容器> claude -p "ok"
# 會花一點點額度 → 一天跑一次
.\claude-oauth-check.ps1 -Live
```

發現異常就用**該 bot 自己的 Discord token** 發到**它自己的頻道**並 @ owner。
用自己的 token 是因為壞的是 Claude OAuth 不是 Discord token；而且腳本在 host
上持有 token，容器整個掛掉也發得出通知。

同一個容器 12 小時內只通知一次（`-RealertHours` 可調），狀態檔在 `.state/`；
恢復正常會自動清掉，下次再壞立刻通知。

## 排程

```powershell
Get-ScheduledTask -TaskName 'OpenAB-ClaudeOAuth-*'
```

| 工作 | 頻率 | 動作 |
|---|---|---|
| `OpenAB-ClaudeOAuth-Check` | 每小時（:07） | 便宜檢查 |
| `OpenAB-ClaudeOAuth-LiveProbe` | 每天 09:20 | `-Live` 真實探測 |

兩個都是 `LogonType Interactive` —— 只在使用者登入時跑。這是刻意的：
Docker Desktop 本來就要使用者 session 才活著。

## 收到通知後怎麼修

```powershell
docker exec -it <容器> claude      # 進去打 /login
docker restart <容器>              # 一定要重啟！
```

⚠ **`/login` 完不重啟不會生效**：bridge 的 `claude-agent-acp` 子行程只在 spawn
時讀一次憑證（`[pool] session_ttl_hours = 2`），舊 session 會繼續拿過期 token
撞 401。

⚠ **`docker restart` 救不了，只有 `/login` 可以。** 2026-08-23 在 astruct 上實測：
重啟後憑證原封不動（bridge 要等有訊息進來才 spawn claude，不會主動 refresh）；
手動跑一次 `claude -p` 觸發 refresh 後，`.credentials.json` 從 537 bytes 變成
429 bytes —— **refresh 失敗後 Claude Code 會把 refreshToken 清空**，
`accessToken` 和過期的 `expiresAt` 留著但已無用。到這一步就沒有自動復原的路了。

判斷是不是走到這步：

```powershell
docker exec <容器> node -e "const o=require('/home/node/.claude/.credentials.json').claudeAiOauth;console.log('hasRefresh:',!!o.refreshToken)"
```

`hasRefresh: false` → 一定要人工 `/login`。

⚠ **絕不設 `ANTHROPIC_API_KEY`** —— Claude Code 會棄 OAuth 改走 API 計費。

## 寫這支腳本踩到的三個坑

1. **`Start-Process -PassThru` 的 `ExitCode` 永遠是 `$null`**（PS 5.1，不加
   `-Wait` 時），`HasExited` 卻是 `True`；但 `-Wait` 又沒有 timeout。
   → 改用 `System.Diagnostics.Process`，非同步讀 stdout/stderr 再 `WaitForExit(ms)`。
2. **`Get-Content -Raw` 讀空檔回 `$null` 而不是 `''`**，後面 `.Trim()` 直接炸。
   → 明確 `if ($null -eq $x) { $x = '' }`。
3. **Discord REST 沒帶 `User-Agent: DiscordBot (...)` 會被 Cloudflare 擋**，
   回一個**空 body 的 403**，看起來很像頻道權限不足，其實不是。

另外：`.ps1` 檔含中文時必須存成 **UTF-8 with BOM**，否則 PS 5.1 會當 ANSI 讀 → mojibake。

## 已知的非故障狀況

Pro 訂閱額度用完時 `claude -p` 會回 `You've hit your limit · resets <時間>`。
這會自己恢復，腳本認得這個 pattern，只記 `[NOTE]` 不發通知。

## 只有 Anthropic 有這問題嗎？（2026-08-23 實測）

要拆成三件事看：

| | 是否只有 Anthropic |
|---|---|
| refresh token 輪替的併發競態 | **不是** —— 通用 OAuth 風險，上游 ADR #1190 對 codex / anthropic / MCP 三種 tenant 都上了 flock |
| **refresh 失敗會清空憑證檔 → 無法自動復原** | **是** —— 只在 Claude Code 觀察到（上游 claude-code#37402、#65761）。這才是把我們鎖死的那一步 |
| 有長效訂閱 token 可逃生（`setup-token`） | **是** —— ADR §6 矩陣裡只有 `claude` 標了 `(+env token)` |

本 stack 各後端實測：

| 後端 | 容器 | 認證 | 實測結果 |
|---|---|---|---|
| Claude Code | travel-claude, astruct | Claude OAuth | ❌ 兩隻都被清空過憑證，需人工重登 |
| kiro-cli | kiro, estate | AWS Builder ID | ✅ estate 憑證擱置 14 天，一次呼叫就自動 refresh 回來（0.03 credits）|
| Codex | credit-report | ChatGPT OAuth | ✅ access token 從 2026-08-21 就過期，但 refresh token 還在；跑一次 `codex exec` 立刻換到新 token |
| qwen-code → NIM | travel-nvidia, nvidia-lab | `NVIDIA_API_KEY` | ✅ 純 API key，沒有 OAuth，不會過期 |
| Groq STT | 全部 | `GROQ_API_KEY` | ✅ 同上 |

結論：**只有 Claude Code 這條路需要長效 token 這種特殊處理**。其他三種後端的憑證
過期都能自己救回來，healthcheck 不必擴充到它們（Codex 那隻真要監看的話，判斷式
要看 `auth.json` 的 `refresh_token` 在不在，而不是 access token 過期沒 ——
access token 過期是它的常態）。

## 切換到長效 token 時踩到的坑（2026-08-23）

1. **`docker restart` 不夠，要 `docker compose up -d`。** env_file 是建立容器時才讀的，
   restart 不會重讀。
2. **`/home/node/.claude.json` 不在 volume 裡**，recreate 會清掉（Claude Code 會自己
   重建，只是第一次啟動會噴一行 "configuration file not found"）。以前只做 restart
   所以沒遇過。
3. **`docker exec <容器> claude -p` 驗證不了切換結果。** 它拿的是容器基礎 env，
   沒有 `[agent] env` 注入的 `CLAUDE_CODE_OAUTH_TOKEN`，會退回讀舊的
   `.credentials.json` —— 舊憑證本來就是死的，測了會誤判。正確做法是複製 agent
   子行程的條件：
   ```sh
   HOME=$(mktemp -d); export HOME              # 乾淨 HOME，沒有 .credentials.json
   export CLAUDE_CODE_OAUTH_TOKEN="$CLAUDE_CODE_OAUTH_TOKEN_<後綴>"
   claude -p "say ok"
   ```
   healthcheck 的 `-Live` 已經內建這個判斷。
4. **config.toml 裡 env 的 key 必須是 `CLAUDE_CODE_OAUTH_TOKEN`**（Claude Code 只認
   這個固定名字）。`_TRAVEL` / `_ASTRUCT` 後綴只在 host 端用來區分兩個帳號，
   所以是映射：`env = { CLAUDE_CODE_OAUTH_TOKEN = "${CLAUDE_CODE_OAUTH_TOKEN_TRAVEL}" }`。

---

# 掛載守護（mount-watchdog，2026-08-27）

## 為什麼有這東西

2026-08-27 Docker Desktop 的 WSL2 utility VM 崩潰，C:／D:／E: 三個磁碟的 9p
同時斷掉。容器內 `ls /vault` 變成 `Input/output error`，但 `docker ps` 仍顯示
`healthy`——因為 image 內建 healthcheck 是 `pgrep -x openab`，只驗程序活著、
完全不碰檔案系統。故障藏了約 9 小時。

完整事故與規格：`docs/mount_watchdog_spec_2026_08_27.md`。

## 三層防線

| 層 | 做什麼 | 檔案 |
|---|---|---|
| 1 | compose 覆寫 healthcheck：程序活著 **且** `ls` 掛載點本身 | `openab/docker-compose.yml` |
| 2 | 每 5 分鐘兩段式探測 + Discord 告警（去重） | `mount-watchdog.ps1` |
| 3 | 只有 `Scope=vm` 才走自癒階梯；24h 最多 2 次 | 同上 |

⚠ **Tier 1 絕對不可只 `ls` 父目錄。** 掛載點的目錄項在容器本地檔案系統一定存在，
`ls /workspace` 在 9p 已死時仍會成功。必須 `ls /workspace/EstateSpace` 這種掛載點本身。

## 用法

```powershell
cd openab\healthcheck
.\mount-watchdog.ps1 -SelfTest   # 純函式：狀態機 / 去重 / 熔斷器 / Tier 2 判讀
.\mount-watchdog.ps1 -DryRun     # 真的探測；只印出自癒步驟，不殺行程、不發 Discord
.\mount-watchdog.ps1             # 正式跑。狀態未翻轉就不發 Discord
.\mount-watchdog.ps1 -TestAlert # 只發一則測試 Discord，不動狀態檔
.\register-mount-watchdog.ps1 -WhatIf
.\register-mount-watchdog.ps1    # 註冊 OpenAB-MountWatchdog（每 5 分鐘）
```

排程是 `LogonType Interactive`——只在使用者登入時跑。Docker Desktop 本來就
需要使用者 session。

## 告警設定

複製 `.local/infra_alert.env.example` → `.local/infra_alert.env`（gitignore），
填入頻道 snowflake。Token 從 `.local/discord_token.env` 用
`INFRA_ALERT_TOKEN_VAR`（預設 `DISCORD_TOKEN_NVIDIA`）取出。

設定搜尋順序（`-TestAlert` 與正式執行**同一條**；沒有 TestAlert 專屬捷徑）：
1. `-AlertEnv` / `-TokenEnv` 若有給就用
2. 此 repo 的 `.local\infra_alert.env` + 同目錄 `discord_token.env`
3. `D:\discord 個人助理\.local\` 下同名檔（主 checkout）

`INFRA_ALERT_CHANNEL_ID` 未設定或仍是 placeholder 時，腳本**照常跑完偵測、寫
log**，只跳過 Discord，並記 `[SKIP] no alert channel configured (not stamping lastAlertAt)`。
**只有 Discord HTTP 2xx 才更新** `lastAlertAt` / `lastResidentAlertAt` / `lastAllDownAlertAt`；
送失敗會累計 `discordFailCount` 並本輪非零退出。**健康輪（本輪沒有送出失敗）會把計數歸零**，
exit code 只表示本輪異常，不是歷史上曾經失敗過。所有 Discord（含自癒中途）只走
`Send-WatchdogNotice`（內部記帳）。自癒／重啟是否「修好了」只走 `Get-InterventionOutcome`。

Discord REST **一定要帶** `User-Agent: DiscordBot (...)`，否則 Cloudflare 回
空 body 403。函式沿用 `claude-oauth-check.ps1` 的寫法。

去重：OK→FAIL 發一次；持續 FAIL 每 60 分鐘再發；FAIL→OK 發一次「已恢復」。
狀態在 `.state/mount-watchdog.json`（此目錄已 gitignore）。

## 自癒（第三層）——已知代價

**只有 Tier 2 看到 `/run/desktop/mnt/host/` 出現 `d?????????`（Scope=vm）才啟動。**

- `Scope=container` → 只 `docker restart` **掛載讀不到且仍在跑**的容器，然後重驗；修好會再發一則「已由重啟容器修復」
- `Scope=daemon` → 第一次只記 log（寬限一個 tick），連續兩次才當 FAIL 告警，避免正常開關機洗版
- 容器 `stopped` / `absent`：profile（`Optional=true`，如 credit-report）完全靜音；**常駐**容器停超過 30 分鐘發一則 ℹ️（不 @、不 restart、不自癒），60 分鐘節流
- **Docker 全死**（12 筆都 SKIP、0 筆 probed）→ 不算 OK：跑 Tier 2、不清 latch、不發假「已恢復」。Tier2 `scope=daemon` 走寬限；`scope=vm` 才自癒
- **全部容器不存在但 daemon/9p 健康**（compose down）→ `all-down`：連續 2 個 tick 才發 ℹ️「N 條全部無法探測（容器皆不存在）」，不 @、不進 FAIL、不重啟

階梯：告警 → `wsl --shutdown`（**不等待指令返回**，改輪詢 `vmmemWSL`／`vmmem` 消失，上限
900s——規格 §6.5 實測超過 10 分鐘）→ 殺掉 `Docker Desktop` / `com.docker.backend` /
`com.docker.build` → 啟動 `Docker Desktop.exe` → 輪詢 `alpine ls /vault` 上限 600s →
重跑 Tier 1（判定與通知交還主流程的 `Get-InterventionOutcome`，階梯不再自己宣判成功）。

自癒 abort 後寫入 `manualRequired` 閂鎖，**下一個 tick 不會再打** `wsl --shutdown`。
24 小時後閂鎖過期；**只有真正探測到掛載 OK**（probed>0）才清閂鎖。另外 60 分鐘最小間隔擋連打。

排程 5 分鐘不是 3 分鐘：Tier 1 最壞 12×15s=180s，3 分鐘 interval 會讓卡住時取樣率砍半。

⚠ **不可用 `docker desktop restart`。** 事故當下 Docker Desktop 彈了 modal
對話框等人工點擊，CLI 只會說 already running。必須先殺行程再開新的。
這個規避手法**未經實地驗證**；若對話框仍然出現，會在第 6 步超時後**乾淨退回
告警、不再重試**。

⚠ **`wsl --shutdown` 會長時間沒輸出。** 看起來像卡死，其實在作用。distro 會先
停，`vmmemWSL` 還要更久才消失。900 秒仍超時就停手、上閂鎖，發「需要人工處理／重開機」。

⚠ **自癒會殺掉 Ubuntu distro 與所有容器。** 這是已知且已被接受的代價：9p 崩了
本來也沒人能用那些容器。24 小時內最多自癒 2 次，超過只告警「已達自癒上限，
需要人工介入」。

## python slim 容器的程序檢查

`openab-url-intake` / `intake-publisher` / `pdf-publisher` 是 `python:3.12-slim`，
**沒有 pgrep**。2026-08-27 `docker top` 實測 PID 1：

| 容器 | PID 1 |
|---|---|
| `openab-url-intake` | `python -u /app/bot.py` |
| `intake-publisher` | `python -u /app/publish.py` |
| `pdf-publisher` | `python -u /app/publish.py` |

healthcheck 用 `grep -qa '/app/bot.py' /proc/1/cmdline`（或 publish.py）加上
`ls /vault`，不是假設程序名叫 `openab`。

## 實作時又踩到的 PS 5.1 坑

`Write-Output` 不能用在「會被 `$x = Invoke-Fn` 接回傳值」的函式裡。成功流的字串
會跟回傳物件混在一起，字串沒有 `.Verdict`，舊碼若寫 `-not $r.Ok` 會把 12 條
當成全掛（第一次 `-DryRun` 就是這樣炸的）。`Write-Log` 改走 `Write-Host` +
`.state` log 檔。結果物件**只有 `Verdict`**，沒有 `Ok` 欄位。

