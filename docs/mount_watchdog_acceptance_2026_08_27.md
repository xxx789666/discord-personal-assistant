# mount-watchdog 驗收紀錄（規格 §8）

**日期：** 2026-08-27  
**工作樹：** `C:\Users\xx\orca\workspaces\discord 個人助理\mount-watchdog`  
**未 commit、未 push。**

## FIX-4（task_33be8269a28e，同日晚）

第四輪有條件 GO 的驗收訊號是 `LastTaskResult=0`。F-2 會讓健康輪永遠 exit 1，毀掉這個條件。另把自癒階梯從「第二份 judge+notify」收成與主流程共用。未 commit、未 push、未註冊、未動正式服務。

### F-2 — discordFailCount 不再黏住 exit 1

exit code = **本輪** `FAIL` 或 **本輪** Discord 送出失敗。健康輪把 `discordFailCount` 歸零。

實測：獨立 `-StateDir` seed `discordFailCount=5`，正式 12 掛載全 OK、不送告警：

```
[STATE] prev=OK new=OK scope= alert=none send=False probed=12
F2-healthy EXIT=0
```

事後 state：`discordFailCount: 0`、`lastDiscordError: null`。worktree 正式 `.state` SHA256 未變。

SelfTest：`healthy tick resets discordFailCount`、`healthy tick is not abnormal`。

### 根治 — 階梯不再是第二份實作

- **Judge：** `Get-InterventionOutcome` 是自癒與重啟「修好了沒」的唯一函式（含 `Get-ProbeRunDecision` + `Test-PreviousFailsNowOk`）。同一批「1 ok + 2 absent」資料，heal 與 restart 的 `Kind` 相同、都不宣判成功。
- **Notify：** `Send-WatchdogNotice` 是唯一 Discord 出口，內部必呼叫 `Register-SendAttempt`。階梯 4 則中途訊息自動受送出失敗保護。
- **Ladder step 7：** 只跑 `Invoke-Tier1Probe` 把 `$results` 交還主流程，**不含** `Get-ProbeRunDecision` / `Get-InterventionOutcome`。
- **SelfTest 結構鎖：** 抽出 `Invoke-SelfHealLadder` 函式本體，斷言沒有健康判定、沒有自己記帳、中途仍走 `Send-WatchdogNotice`；`Register-SendAttempt` 只出現在 `Send-WatchdogNotice` 旁邊。

**未來新增一條規則還會不會只加一邊？** 針對四輪來的那個錯誤（階梯自己判定／自己組成功文案／漏記帳）：**不會。** 階梯裡加第二份 judge 會被 SelfTest 結構鎖打掉；新的 Discord 送出如果不走 `Send-WatchdogNotice` 就沒有記帳也沒有 UA／2xx 規則。若有人在主流程另外寫一行旁路 `if ($decision.Status -eq 'OK') { 送全清單可讀 }`，那是第三份實作，結構鎖管不到——只能靠 code review。重構成功的標準是「第二份流水線消失且被測試鎖住」，不是「PowerShell 無法寫錯」。

### HostVaultProbe

SelfTest：`HostVaultProbe appears in compose bind source`（UTF-8 讀 compose，與 `D:/discord 個人助理/URLIntake` bind 對上）。

### 其餘驗收

```
SelfTest PASSED / EXIT=0
DryRun 12/12 OK probed=12 / EXIT=0
register -WhatIf：every 5 minutes / EXIT=0 / 未註冊
pdf-publisher / openab-kiro 仍 healthy
```

---

## FIX-3（task_e1b7bef74dcb，同日晚）

第三輪 NO-GO：watchdog「不會亂動，但會說謊」。修完 3 個 blocker + HIGH-3 維護誤報。未註冊排程、未 commit、未 push、未動正式服務。

### Blocker 1 — 自癒 step 7

`Invoke-SelfHealLadder` 改用 `Get-ProbeRunDecision` + `Get-HealStep7Notice`。unprobed 時文案是「這不是成功」，不再「全清單可讀」。SelfTest：

```
[PASS] ladder step7 all-skip is unprobed not success
[PASS] ladder step7 must not claim all readable when unprobed
[PASS] ladder step7 unprobed says not success
[PASS] ladder step7 probed ok is success
[PASS] ladder step7 mount-fail is not success
```

（真實 wsl --shutdown 階梯仍未端對端跑，與前幾輪相同殘留風險。）

### Blocker 2 — 正式路徑與 TestAlert 同一條 env

移除 TestAlert 專屬 `D:\` fallback。`Resolve-AlertEnvPaths`：`-AlertEnv` → worktree `.local` → `D:\discord 個人助理\.local`。DryRun 正式 12 掛載已印：

```
[CFG] alert env=D:\discord 個人助理\.local\infra_alert.env
[CFG] token env=D:\discord 個人助理\.local\discord_token.env
```

**正式路徑（非 TestAlert、未傳 -AlertEnv）實送 Discord：** 獨立 `-StateDir` + 3 個幽靈容器、`consecutiveAllDown=1` 讓第二 tick 發 ℹ️：

```
[CFG] alert env=D:\discord 個人助理\.local\infra_alert.env
[NOTE] all-down 2/2 — daemon/9p healthy, nothing probed (maintenance or disaster)
[STATE] prev=OK new=OK scope=all-down alert=none send=False probed=0
[INFO] all containers absent (no restart, no self-heal)
[ALERT] Discord sent HTTP 200
official EXIT=0
```

state：`lastAllDownAlertAt` 有值，`lastAlertAt` 仍 null（這則是資訊、不是 FAIL 狀態機）。worktree 正式 `.state/mount-watchdog.json` SHA256 未變 `9F68A2747F37D3C1B6D2189E5638E89AF2D9E45AD438C7BCF71345BB960365BF`。

### Blocker 3 — 送失敗不蓋時間戳

假 token + 真頻道格式 → HTTP 401：

```
[WARN] Discord send failed HTTP 401: ... Unauthorized. (not stamping lastAlertAt)
[WARN] Discord send failed this run (count=1 error=exception); timestamps not stamped
fail-send EXIT=1
```

state：`lastAlertAt: null`、`lastAllDownAlertAt: null`、`discordFailCount: 1`、`lastDiscordError: exception`。下一輪會重試。

### HIGH-3 — compose down 不在第一 tick 空清單 FAIL

tick1 DryRun（幽靈容器、daemon 活）：

```
[PROBE] reason=unprobed probed=0 scope=container
[NOTE] all-down 1/2 — daemon/9p healthy, nothing probed (maintenance or disaster)
[STATE] prev=OK new=OK scope=all-down alert=none send=False probed=0
tick1 EXIT=0
```

第二 tick 才發「N 條全部無法探測（容器皆不存在）」（正式路徑那則 HTTP 200）。daemon/vm 的 unprobed 仍走 FAIL，不是 all-down。

驗收文件舊句「關掉的容器不是 Scope=container」已改成：單個容器 SKIP；全部停掉走 all-down。vmmem 超時註記改回 900s。

### 其餘驗收

```
SelfTest PASSED / EXIT=0
DryRun 12/12 OK probed=12 / EXIT=0
register -WhatIf：repetition every 5 minutes / EXIT=0 / 未註冊
pdf-publisher / openab-kiro 仍 healthy；無 mw-* 臨時容器
git add -n -- .local 只會 add example
```

---

## FIX-2（task_69387885c3dd，同日晚）

第二輪審查 blocking：daemon 全死時 12 筆 SKIP → 0 筆 mount-fail → 當成 OK、清 latch、發假「已恢復」。本輪連同常駐容器 ℹ️、清單注入、timeout 124、compose `start_period`、排程 5 分鐘、`-TestAlert` 一起收。

**排程 vs timeout：** 選 **interval 5 分鐘**，`$Tier1TimeoutSec` 維持 15（內層 `timeout 10 ls`）。12×15s=180s 剛好等於舊的 3 分鐘 interval；真卡住時下一個 tick 還沒輪到、取樣率砍半。降到 12s 只省 36s，對 9p 卡住仍不夠，還會讓 inner 10s 幾乎沒緩衝。5 分鐘讓最壞探測仍塞得進一個 tick。

**B6：** YAML 寫入 `start_period: 60s` ×10，**沒有 `up -d`**。live inspect `pdf-publisher StartPeriod=0s`、`openab-kiro StartPeriod=0s`，正式服務未 recreate。

**Ok 欄位：** 結果物件只留 `Verdict`；註解寫明不再寫 `Ok`。

臨時容器 `mw-synth-124-fix2` 已 `docker rm -f`。未動正式服務。未 commit、未 push。

### 逐項實際輸出

#### SelfTest

`powershell -File mount-watchdog.ps1 -SelfTest` → **SelfTest PASSED / EXIT=0**（含 unprobed FAIL、latch 不清、resident 31m / 節流 / optional 靜音、`start_period: 60s` ×10）。

```
=== mount-watchdog SelfTest ===
[PASS] mount list has 12 entries
[PASS] credit-report is marked Optional (compose profile)
[PASS] running+exec timeout => mount-fail
[PASS] all skip => probed 0
[PASS] all skip => FAIL (not silent OK)
[PASS] all skip => run Tier2
[PASS] all skip must not clear latch
[PASS] all skip must not send recovered
[PASS] all skip reason=unprobed
[PASS] unprobed does not clear latch even if later grace sets OK
[PASS] resident first seen does not send
[PASS] non-optional down 31m sends info
[PASS] info names pdf-publisher
[PASS] optional profile is silent
[PASS] resident info throttled 60m
[PASS] compose has start_period 60s on 10 services (next-redeploy; no up -d this round)
SelfTest PASSED
SelfTest EXIT=0
```

（其餘既有 PASS 行略；本次完整跑過零 FAIL。）

#### DryRun（正式 12 掛載）

```
[T1] openab-url-intake /vault => OK (OK)
[T1] intake-publisher /vault => OK (OK)
[T1] pdf-publisher /vault => OK (OK)
[T1] openab-estate /workspace/EstateSpace => OK (OK)
[T1] openab-travel-claude /workspace/TravelMemory => OK (OK)
[T1] openab-travel-nvidia /workspace/TravelMemory => OK (OK)
[T1] openab-credit-report /workspace/CreditReportSpace => OK (OK)
[T1] openab-kiro /workspace/KiroSpace => OK (OK)
[T1] openab-kiro /workspace/TravelMemory => OK (OK)
[T1] openab-nvidia-lab /workspace/LabSpace => OK (OK)
[T1] openab-astruct /workspace/AStructSpace => OK (OK)
[T1] openab-astruct /workspace/AStructSpace/forward => OK (OK)
[STATE] prev=OK new=OK scope= alert=none send=False probed=12
[DRYRUN] state file not written
DryRun EXIT=0
```

#### 合成 timeout 124（`-MountsFile` + `-StateDir` + `-DryRun`）

容器 `mw-synth-124-fix2`（`python:3.12-slim`）把 `/usr/bin/ls` 換成 `exec sleep 999`。GNU `timeout 10 ls /tmp` 直測 `rc=124`（10562ms）。watchdog：

```
[T1] mw-synth-124-fix2 /tmp => FAIL (timeout ls /tmp (exit 124))
[T2] exit=0 scope=container
[PROBE] reason=mount-fail probed=1 scope=container
[STATE] prev=OK new=FAIL scope=container alert=fail send=True probed=1
[ACTION] restart-failed
[DRYRUN] would docker restart mw-synth-124-fix2
synth124 EXIT=1
```

cleanup：`docker rm -f mw-synth-124-fix2`。`pdf-publisher` / `openab-kiro` 仍 healthy。

#### 全 SKIP 不清 latch（假容器 + 獨立 StateDir，非 DryRun）

seed `manualRequired=true` / `status=FAIL`，清單只有 `mw-does-not-exist-fix2`：

```
[T1] mw-does-not-exist-fix2 /vault => SKIP (container absent)
[PROBE] reason=unprobed probed=0 scope=container
[STATE] prev=FAIL new=FAIL scope=container alert=fail-repeat send=True probed=0
[ACTION] restart-failed skipped (no mount-fail rows)
unprobed EXIT=1
```

事後 state：`manualRequired: true`（`manualRequiredAt` 仍是 seed 的 `2026-08-27T11:00:00`）、`status: FAIL`、沒有 recovered。Docker 仍通所以 Tier2 `scope=container`（不是 daemon）；daemon 死時 Tier2 `exit≠0` → `scope=daemon` → B2 寬限仍會走。

#### `-TestAlert`（主 checkout env，不動狀態檔）

```
.\mount-watchdog.ps1 -TestAlert -AlertEnv "D:\discord 個人助理\.local\infra_alert.env" -TokenEnv "D:\discord 個人助理\.local\discord_token.env"
=== mount-watchdog -TestAlert ===
channel configured: True
token var: DISCORD_TOKEN_NVIDIA
HTTP 200
body: {"type":0,"content":"\u2139\ufe0f **mount-watchdog TestAlert** \u2014 \u9019\u662f\u6e2c\u8a66\u8a0a\u606f\uff0c\u53ef\u5ffd\u7565\u3002\u6642\u9593\uff1a2026-08-27T18:43:30.4221169+08:00\u3002\u4e0d\
TestAlert done (state file not touched)
TestAlert EXIT=0
```

`.state/mount-watchdog.json` SHA256 前後相同 `9F68A2747F37D3C1B6D2189E5638E89AF2D9E45AD438C7BCF71345BB960365BF`，LastWriteTime 仍是 2026-08-27 10:18:06 UTC。

#### register `-WhatIf`

```
Trigger  : once at next minute, repetition every 5 minutes
WhatIf: not registered
register WhatIf EXIT=0
```

#### git

`git add -n -- .local` 只會 `add '.local/infra_alert.env.example'`。沒有把 `infra_alert.env` / token 放進 worktree。

### 本輪改檔

| 路徑 | 動作 |
|---|---|
| `openab/healthcheck/mount-watchdog.ps1` | unprobed FAIL、resident ℹ️、MountsFile/StateDir/TestAlert、timeout 124 傳回 |
| `openab/healthcheck/register-mount-watchdog.ps1` | 重複間隔 5 分鐘 |
| `openab/healthcheck/README.md` | 5 分鐘、全 SKIP、resident、TestAlert |
| `openab/docker-compose.yml` | 10 段 `start_period: 60s`（未 up -d） |
| `docs/mount_watchdog_acceptance_2026_08_27.md` | 本節 |

---

## 審查修復 round（task_3d71d80d98d2，同日稍晚）

依 `docs/mount_watchdog_review_2026_08_27.md`。blocking A1/A2 已修；8 項建議見下。

### A1 怎麼修

抽出純函式 `Get-MountVerdict`：`inspect` 失敗 → `absent`，`Running=false` → `stopped`，running + `ls` 逾時/FAIL → `mount-fail`，running + OK → `ok`。只有 `mount-fail` 進入 `$failed`／Tier 2／告警／`docker restart`。`openab-credit-report` 標 `Optional = $true`。`Invoke-ContainerRestart` 再擋一道 `Verdict -eq 'mount-fail'`。

### A2 怎麼修

abort 三分支寫 `manualRequired` + `manualRequiredAt` 後落盤。`Get-SelfHealGate`：latched（24h 內）／cap／cooldown（60 分鐘）／allow。`status=OK` 清閂鎖。`$newState` 改以 `$base`（含 ladder 寫入後的 on-disk）為基底，避免新欄位被固定清單清掉。`vmmemWSL` 逾時從 300s 調到 **900s**（規格 §6.5 實測 >10 分鐘）；掛載探測 600s。

### 8 項建議

| # | 決定 | 理由 |
|---|---|---|
| B1 | **修** | container 路徑重啟成功後補「已由重啟容器修復」 |
| B2 | **修** | 只對 `Scope=daemon` 寬限：第一次不翻 FAIL，連續 2 次才告警。container/vm 第一次仍告警 |
| B3 | **修** | log ≥ 5MB 轉成 `.log.1` |
| B4 | **修** | 同時看 `vmmemWSL` 與 `vmmem`；找不到時 log `[WARN] no vmmem* process found — assuming already down` |
| B5 | **修** | SelfTest 用 regex 把 compose `ls /...` 跟 `$Mounts` 做集合比對 |
| B6 | **FIX-2 改寫 YAML、未 up -d** | `start_period: 60s` ×10 寫進 compose；live `StartPeriod` 仍 0s |
| B7 | **修** | `Send-WatchdogNotice` 先看 `WouldSend`，DryRun 不再在會被節流的訊息上印 would send |
| B8 | **修** | 探測改 `timeout 10 ls`（`pdf-publisher` 確認有 `/usr/bin/timeout`） |

### 負向測試（授權：只停 pdf-publisher）

A1 修好後，「使用者關掉**單個**容器、其餘仍 probed」正確結論是 `SKIP (not running)`，status OK，**不是** `Scope=container`。`Scope=container` 只屬於「容器仍在跑、掛載讀不到」。

FIX-3 補上另一邊：若 **全部** 探測列都不存在、但 daemon/9p 健康（`docker compose down`），不再把 `probed=0` 當空清單 FAIL 每小時 @ 一次；改走 `all-down`（連續 2 個 tick 才發 ℹ️「N 條全部無法探測（容器皆不存在）」）。任務原文要 Scope=container 與 A1 衝突——單個容器以 A1 為準；全停以 FIX-3 為準。

```
=== BEFORE stop ===
Running=true Health=healthy Status=running
=== docker stop pdf-publisher ===
Running=false Status=exited
=== mount-watchdog.ps1 (live) ===
[T1] pdf-publisher /vault => SKIP (not running)
（其餘 11 條 OK）
[STATE] prev=OK new=OK scope= alert=none send=False
WATCHDOG_EXIT=0
=== AFTER watchdog ===
Running=false Status=exited
=== docker start pdf-publisher ===
pdf-publisher
```

沒有 `[HEAL]`、沒有 `wsl --shutdown`、沒有 `[FIX] docker restart pdf-publisher`。

一個 interval 後：`Running=true Health=healthy`；`pdf-publisher Up 54 seconds (healthy)`。

**pdf-publisher 已確認恢復。** 沒停其他容器，沒測 vm 路徑。

### 重跑 §8（修復後）

| 項 | 結果 |
|---|---|
| 1 compose config | 本 round 未重跑：worktree `.local/` 只剩 `.example`，缺 `env_file` 會 exit 1。compose YAML 這輪沒改 |
| 2 healthy | pdf-publisher 恢復後 healthy；kiro healthy；其餘 `docker ps` 均 healthy |
| 3 SelfTest | 全 PASS、`SelfTest PASSED`、`EXIT=0` |
| 4 DryRun | 12/12 OK、`send=False`、階梯 900s/600s + latch、`EXIT=0` |
| 5 正式跑 | 恢復後 12/12 OK、`alert=none`、`EXIT=0` |
| 6 register -WhatIf | `EXIT=0`、未註冊 |
| 7 git | `.local/infra_alert.env` 不在待提交清單 |

---

## 改了哪些檔（worktree）

| 路徑 | 動作 |
|---|---|
| `docs/mount_watchdog_spec_2026_08_27.md` | 從主 checkout 複製進來 |
| `openab/docker-compose.yml` | 10 個服務加 `healthcheck:`（12 條掛載） |
| `openab/healthcheck/mount-watchdog.ps1` | 新增（UTF-8 with BOM） |
| `openab/healthcheck/register-mount-watchdog.ps1` | 新增（UTF-8 with BOM） |
| `openab/healthcheck/README.md` | 增補 mount-watchdog 章節 |
| `.local/infra_alert.env.example` | 新增（UTF-8 無 BOM） |
| `.gitignore` | `.local/*` + `!.local/*.example` |

**主 checkout 額外動作（未 commit）：** 把同一份 `docker-compose.yml` 複製到 `D:\discord 個人助理\openab\` 並從那邊 `up -d` 一次。原因：第一次從 worktree `up -d` 後，`./config-*.toml` 綁到 Orca worktree；刪 worktree 會讓 live 容器失去 config。重套用後 `openab-estate` 的 config 來源回到：

```
/run/desktop/mnt/host/d/discord 個人助理/openab/config-estate.toml -> /etc/openab/config.toml
```

## §8 逐項實際輸出

### 1. `docker compose config` 解析成功

在 worktree `openab/`（需有 gitignored 的 `../.local/*.env` 才能過 `env_file`；**沒有**建立 `infra_alert.env`）：

```
config_exit=0
config_profile_exit=0
```

`docker compose --profile credit-report config` 可見 10 段 healthcheck，全部 `timeout: 10s`，`ls` 的是掛載點本身。

### 2. 正常狀態下 12 條掛載對應容器顯示 healthy

`docker compose --profile credit-report up -d` 後等待 ≥ 一個 interval（40s）。10 個容器（12 條掛載）：

```
openab-kiro            Up About a minute (healthy)
openab-credit-report   Up About a minute (healthy)
openab-astruct         Up About a minute (healthy)
openab-estate          Up About a minute (healthy)
openab-nvidia-lab      Up About a minute (healthy)
openab-travel-nvidia   Up About a minute (healthy)
openab-travel-claude   Up About a minute (healthy)
openab-url-intake      Up 6 minutes (healthy)
pdf-publisher          Up 7 minutes (healthy)
intake-publisher       Up 7 minutes (healthy)
```

inspect：十隻都是 `healthy running`。先前沒有 healthcheck 的 url-intake / intake-publisher / pdf-publisher 現在也是 healthy。

python slim **沒有 pgrep**。2026-08-27 `docker top` / `/proc/1/cmdline` 實測：

- `openab-url-intake` PID 1 = `python -u /app/bot.py`
- `intake-publisher` / `pdf-publisher` PID 1 = `python -u /app/publish.py`

healthcheck 用 `grep -qa '/app/....py' /proc/1/cmdline && ls /vault`，不是猜程序名叫 `openab`。

### 3. `mount-watchdog.ps1 -SelfTest`

```
=== mount-watchdog SelfTest ===
[PASS] mount list has 12 entries
[PASS] no probe path is a parent directory only
[PASS] kiro probes KiroSpace itself
[PASS] kiro probes TravelMemory itself
[PASS] astruct probes AStructSpace itself
[PASS] astruct probes C: forward mount itself
[PASS] Tier2 d????????? => vm
[PASS] Tier2 readable host mnt => container
[PASS] Tier2 command fail => daemon
[PASS] Tier2 timeout => daemon
[PASS] OK->FAIL sends once
[PASS] FAIL sustain within 60m does not send
[PASS] FAIL sustain at 60m sends reminder
[PASS] FAIL->OK sends recovered
[PASS] OK->OK does not send
[PASS] first-run OK does not send (no flip)
[PASS] first-run FAIL still alerts
[PASS] 0 heals in 24h => allowed
[PASS] 2 heals in 24h => denied
[PASS] heal older than 24h is pruned
[PASS] vm => self-heal
[PASS] container => restart-failed
[PASS] daemon => alert-only no heal
[PASS] placeholder channel => skip
[PASS] self-heal ladder has 7 steps
[PASS] ladder polls vmmemWSL not command return
[PASS] ladder states kill-then-start not CLI restart
SelfTest PASSED
EXIT=0
```

（中間 PASS 行略，共 45 項全過。）

### 4. `-DryRun`

修正 Write-Output 污染後（見下方偏離）：

```
=== mount-watchdog run ===
[DRYRUN] detection will run; heal/kill/wsl/discord will not
[T1] openab-url-intake /vault => OK (OK)
[T1] intake-publisher /vault => OK (OK)
[T1] pdf-publisher /vault => OK (OK)
[T1] openab-estate /workspace/EstateSpace => OK (OK)
[T1] openab-travel-claude /workspace/TravelMemory => OK (OK)
[T1] openab-travel-nvidia /workspace/TravelMemory => OK (OK)
[T1] openab-credit-report /workspace/CreditReportSpace => OK (OK)
[T1] openab-kiro /workspace/KiroSpace => OK (OK)
[T1] openab-kiro /workspace/TravelMemory => OK (OK)
[T1] openab-nvidia-lab /workspace/LabSpace => OK (OK)
[T1] openab-astruct /workspace/AStructSpace => OK (OK)
[T1] openab-astruct /workspace/AStructSpace/forward => OK (OK)
[STATE] prev=OK new=OK scope= alert=none send=False
[SKIP] no alert channel configured
若為真會執行的自癒步驟（Scope=vm 時）：
  - Discord 告警：偵測到 VM 層級掛載故障，開始自癒
  - wsl --shutdown（不等待指令返回，改輪詢 vmmemWSL）
  - 輪詢 vmmemWSL 直到消失，上限 300 秒；超時則停手並告警需要人工處理／重開機
  - 殺掉殘留行程：Docker Desktop, com.docker.backend, com.docker.build（不用 docker desktop restart）
  - 啟動 C:\Program Files\Docker\Docker\Docker Desktop.exe
  - 輪詢 docker run --rm -v "D:/discord 個人助理/URLIntake:/vault" alpine ls /vault 直到成功，上限 300 秒
  - 重跑 Tier 1 全清單驗證，結果發 Discord
（DryRun 結束，未執行 wsl --shutdown、未殺行程、未啟動 Docker Desktop、未發 Discord）
[DRYRUN] state file not written
EXIT=0
```

### 5. 正式跑一次（Tier 1 全綠、不發 Discord）

```
=== mount-watchdog run ===
[T1] ... 12/12 OK ...
[STATE] prev=OK new=OK scope= alert=none send=False
[SKIP] no alert channel configured
EXIT=0
```

worktree **沒有** `.local/infra_alert.env`（主 checkout 有，故意不複製）。因此 Discord 在設定閘門就被 skip。去重「狀態未翻轉不發」由 SelfTest 的 OK→OK 與本次 `alert=none send=False` 覆蓋。**沒有**對 Discord REST 做真實發送測試。

狀態檔（gitignore `.state/`）：

```json
{
    "scope":  null,
    "healAt":  [],
    "lastAlertAt":  null,
    "failedMounts":  [],
    "status":  "OK",
    "lastChangeAt":  null
}
```

### 6. `register-mount-watchdog.ps1 -WhatIf`

```
TaskName : OpenAB-MountWatchdog
Execute  : powershell.exe
Argument : -NoProfile -ExecutionPolicy Bypass -File "C:\Users\xx\orca\workspaces\discord 個人助理\mount-watchdog\openab\healthcheck\mount-watchdog.ps1"
Trigger  : once at next minute, repetition every 3 minutes
Duration : omitted (indefinite; do not pass [TimeSpan]::MaxValue)
Logon    : Interactive (Docker Desktop 需要使用者 session)
What if: Performing the operation "Register scheduled task" on target "OpenAB-MountWatchdog".
WhatIf: not registered
EXIT=0
```

**沒有**真的註冊排程（避免把 worktree 路徑寫進使用者的工作排程器）。合併進 D: 後請在 `D:\discord 個人助理\openab\healthcheck` 再跑一次不帶 `-WhatIf` 的 register。

### 7. git status 乾淨度（worktree）

```
 M .gitignore
 M openab/docker-compose.yml
 M openab/healthcheck/README.md
?? .local/infra_alert.env.example
?? docs/mount_watchdog_spec_2026_08_27.md
?? openab/healthcheck/mount-watchdog.ps1
?? openab/healthcheck/register-mount-watchdog.ps1
```

`git add -n -- .local` 只會 `add '.local/infra_alert.env.example'`。  
`.local/infra_alert.env`、`.local/discord_token.env` 被 `.local/*` 擋住，**不在待提交清單**。

## 沒測什麼、為什麼、替代信心

| 項目 | 為什麼沒測 | 替代 |
|---|---|---|
| 真的 VM 自癒（wsl --shutdown + 殺 Docker Desktop） | 會停掉 Ubuntu distro 與全部容器；規格 §6.3 自己也說殺行程再開「未經實地驗證」 | SelfTest 鎖住階梯文字／熔斷器；DryRun 印出 7 步且明確說未執行；超時退路寫在 `Wait-VmmemWslGone` / `Wait-HostMountReadable` 失敗分支 |
| Discord 真的送出訊息 | worktree 沒設頻道；不把主 checkout 的 `infra_alert.env` 拷進來 | 函式沿用 oauth-check 的 UA + Bot header；SelfTest 覆蓋 placeholder skip 與去重 |
| 真的 Register-ScheduledTask | -WhatIf 已夠驗收；真註冊會指向 worktree 路徑 | `-WhatIf` exit 0，省略 RepetitionDuration |
| 掛載真的死掉時 docker ps → unhealthy | 無法安全弄壞 9p | compose 覆寫 `ls` 掛載點 + timeout 10s；healthy 路徑已實測 |

## 偏離與風險

1. **第一次 `-DryRun` 誤報 12 條 FAIL。** 原因：`Write-Log` 用 `Write-Output`，被 `$tier1 = Invoke-Tier1Probe` 擷進成功流，字串沒有 `.Ok` 被當成失敗。已改 `Write-Host` + log 檔。README 有記。
2. **python slim 不用 `pgrep`。** 規格說先 inspect 再寫，不要假設程序名。
3. **live 相對路徑曾短暫指向 worktree。** 已從 D: 再 `up -d` 拉回。主 checkout `openab/docker-compose.yml` 因此變成未提交修改（沒 commit）。
4. **為了 compose config/up，把主 checkout 的 token env 複製進 worktree `.local/`（gitignore）。** 沒複製 `infra_alert.env`。
5. **`docker compose up` 有重建 searxng**（`./searxng-settings.yml` 路徑變了）。steel-api/ui 未動。quant/radar 堆疊不是這個 compose 專案。
6. 規格 §6.3 的「先殺行程就不會跳 modal」**仍然未經實地驗證**。實作有 **900s** vmmem 超時後停手告警、不重試（不是 300s）。

---

## 文件漂移更正（2026-08-28，L-3）

本文件中的 DryRun／SelfTest 輸出是**當時工具實際印出的內容**，保留原樣不修改。
但實作已經改過，以下以此處為準：

| 項目 | 本文擷取內容 | 現行實作 |
|---|---|---|
| 輪詢 VM 汰換的上限 | 300 秒 | **900 秒**（規格 §6.5：事故當下遠超 300 秒）|
| 輪詢掛載恢復的上限 | 300 秒 | **600 秒** |
| VM 汰換判定方式 | 輪詢 `vmmemWSL` 消失 | **`Get-VmRecycleDecision`**：boot_id 變更／`wsl --list --running` 無發行版／vmmem 消失，任一成立即完成。<br>2026-08-28 實測證明 `vmmemWSL` 可在整段汰換中持續存在，**不是必要條件** |
| all-down（probed=0）語意 | 早期版本視為 OK | **視為 FAIL**，daemon 健康時走 2 tick 寬限後發資訊告警，不重啟、不自癒 |
| 排程間隔 | 3 分鐘 | **5 分鐘** |
| 排程 ExecutionTimeLimit | 未設定（預設 72 小時）| **1 小時**（M-4；配 `IgnoreNew`，一次卡死會擋掉後續所有觸發）|

後續變更請見 `mount_watchdog_fix_m0_2026_08_28.md`、`mount_watchdog_fix_vmmem_2026_08_28.md`
與 `mount_watchdog_review5_2026_08_27.md` 的跟進清單。
