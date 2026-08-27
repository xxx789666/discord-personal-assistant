# mount-watchdog 實作審查報告

**日期：** 2026-08-27
**審查者：** REVIEW worker（Claude Opus 5）
**被審查產出：** CODING worker（task_9f1de40e4a5c）
**判準：** `docs/mount_watchdog_spec_2026_08_27.md`
**工作樹：** `C:\Users\xx\orca\workspaces\discord 個人助理\mount-watchdog`
**性質：** review-only。**本次審查沒有修改任何被審查的檔案**，只新增這份文件。

---

## 0. 總評

實作品質好。規格點名的每一個「已知坑」都真的避開了，驗收報告也誠實——我逐項重跑
驗收 3/4/5/6/7，輸出與 CODING worker 宣稱值**一字不差**，沒有任何一項是推測混過去的。

兩個必須修的問題**都不在規格點名的坑裡**，而是規格沒展開的邊界條件：

| 編號 | 一句話 | 為什麼是必須修 |
|---|---|---|
| **A1** | profile 容器／已停容器 → 永久假 FAIL，且會被自動啟動 | 每 60 分鐘洗一則 Discord，會養成「又是那則假警報」的習慣，正好摧毀這套系統存在的理由 |
| **A2** | 自癒 abort 後沒有冷卻，3 分鐘後會再打一次 `wsl --shutdown` | 第二次會打斷第一次正在進行中的復原；違反規格 §6.2「不再重試」 |

另有 8 項建議（非阻斷）與 5 項我明確無法驗證的項目。

---

## 1. 必須修

### A1 — profile 容器／已停容器造成永久假 FAIL，且會被自動啟動

#### 位置

| 檔案:行號 | 內容 |
|---|---|
| `openab/healthcheck/mount-watchdog.ps1:37-50` | `$Mounts` 無條件包含 `openab-credit-report` |
| `openab/healthcheck/mount-watchdog.ps1:454-479` | `Invoke-Tier1Probe`：只看 `docker exec` 的 exit code 與 stdout |
| `openab/healthcheck/mount-watchdog.ps1:461-466` | `$r.Code -eq 0 -and $out -eq 'OK'` 才算 OK，其餘一律 FAIL |
| `openab/healthcheck/mount-watchdog.ps1:682-697` | `Invoke-ContainerRestart` 無條件 `docker restart` |
| `openab/docker-compose.yml:237-238` | `openab-credit-report:` / `profiles: ["credit-report"]` |

#### 觸發條件

1. **最常見**：任何一次 `docker compose up -d` **沒有帶** `--profile credit-report`。
   compose 不會建立 `openab-credit-report` 這隻容器，但 `$Mounts` 仍然要探測它。
   （CODING worker 自己的驗收就必須額外帶 `--profile credit-report` 才讓十隻都起來，
   見 `docs/mount_watchdog_acceptance_2026_08_27.md:40`——這正說明沒帶 profile 是常態路徑。）
2. `docker compose down` 之後、`up -d` 之前的維護空窗。
3. 使用者為了省資源或除錯，手動 `docker stop` 掉清單裡任何一隻容器。
4. 換機／新環境尚未建立全部容器。

#### 後果（實測，不是推論）

```
$ docker exec no-such-container-xyz sh -c "ls /vault >/dev/null 2>&1 && echo OK || echo FAIL"
Error response from daemon: No such container: no-such-container-xyz
exit=1

$ docker restart no-such-container-xyz
Error response from daemon: No such container: no-such-container-xyz
exit=1
```

順著程式走：

```
Invoke-Tier1Probe (:461)   docker exec → exit 1、stdout 空
        ↓ (:463-466)       $ok = $false  →  status = 'FAIL'
主流程 (:712)              $failed += 該筆
主流程 (:716-720)          $newStatus = 'FAIL'，跑 Tier 2
Invoke-Tier2Probe          host mnt 可讀（9p 沒事）→ Scope = 'container'
Get-ScopeAction (:148)     'container' → 'restart-failed'
主流程 (:759-760)          Invoke-ContainerRestart $failed
Invoke-ContainerRestart    docker restart → exit 1（容器不存在）
主流程 (:764-765)          重驗仍 FAIL → $newStatus 維持 'FAIL'
主流程 (:813)              exit 1
```

於是：

- **永久 FAIL**。`Get-AlertAction`（`:94-120`）判 OK→FAIL 發一次，之後每 60 分鐘再發一次，
  **永遠不會恢復**，因為那隻容器根本不打算被啟動。
- 腳本永遠 `exit 1`，排程工作歷史全是失敗。
- **副作用更需要注意**：若容器**存在但只是被停掉**（情境 3），`docker restart` 會**成功**——
  watchdog 會把使用者刻意停掉的容器自動開起來。規格沒有授權這個動作
  （§6.1 只授權「`Scope=container` → 只 `docker restart` 那一隻容器」，
  前提是那是「掛載壞了」的容器，不是「使用者關掉」的容器）。
- 更深的傷害：真正的 9p 崩潰發生時，使用者已經習慣忽略這則每小時一次的告警。

#### 建議的修法方向

核心概念：**把「容器沒在跑」與「掛載讀不到」分成兩種不同的結論**，
只有後者才是這套系統要偵測的東西。

**(a) 探測前先問容器狀態。** 在 `Invoke-Tier1Probe`（`:454`）迴圈內，`docker exec` 之前加一次

```
docker inspect -f '{{.State.Running}}' <container>
```

用既有的 `Invoke-Cmd`（`:374-399`）呼叫即可，逾時給 10 秒就夠（`inspect` 不碰 9p）。
三種結果：

| inspect exit | stdout | 判定 |
|---|---|---|
| ≠ 0 | — | `absent`（容器不存在） |
| 0 | `false` | `stopped` |
| 0 | `true` | 繼續原本的 `docker exec` 探測 |

**(b) 讓探測結果有第三種狀態。** 目前 `:471-476` 的結果物件只有布林 `Ok`。
建議改成帶一個 `Verdict` 欄位：`'ok' | 'mount-fail' | 'stopped' | 'absent'`，
`Ok` 保留給向後相容（`Ok = ($Verdict -eq 'ok')`）。

**(c) 只有 `mount-fail` 才進 `$failed`。** 主流程 `:711-712` 的收集條件從
`if (-not $r.Ok)` 改成 `if ($r.Verdict -eq 'mount-fail')`。
`stopped` / `absent` 走另一條路：寫進 log（例如 `[T1] openab-credit-report /workspace/CreditReportSpace => SKIP (not running)`），
**不觸發 Tier 2、不觸發告警狀態機、不觸發自癒、不觸發 `docker restart`**。

**(d) `Invoke-ContainerRestart`（`:682-697`）同步收斂。**
`Get-FailedContainerNames`（`:153-164`）餵進去的清單如果只剩 `mount-fail`，
這裡就自動安全了；但仍建議在 `:690` 前加一道 `Verdict -eq 'mount-fail'` 的防呆，
避免將來有人又把別的狀態塞進 `$failed`。

**(e) 在 `$Mounts` 標註 profile 容器。** 給 `openab-credit-report` 兩筆
（實際只有一筆，`:44`）加 `Optional = $true`，語意上明確表達「這隻沒起來是預期內的」。
其餘容器若 `absent`，仍值得在 log 留下痕跡，只是不告警。

**(f) 別完全靜音。** 「容器沒在跑」本身是有價值的資訊，只是不該由掛載守護來吵。
建議做法：`stopped` / `absent` 累計寫進 state（例如 `notRunning` 陣列），
若同一隻連續 24 小時都不在跑才發**一則**低優先資訊性訊息，或乾脆完全不發、只留 log。
**不要**讓它走 `Get-AlertAction` 的 FAIL 狀態機。

**(g) 要改到的地方（別漏）。** `Verdict` 這個新欄位會影響：

- `Invoke-Tier1Probe:471-476`（產生）
- 主流程 `:711-712`、`:754-755`、`:763-764`（三處都在數 `-not $r.Ok`）
- `Invoke-SelfHealLadder:670-672`（自癒後重驗也在數 `-not $r.Ok`）
- `Format-FailList:550-559`（告警內文）

**(h) SelfTest 補測（`Invoke-SelfTest:206-353`）。**
把判定邏輯抽成純函式，例如
`Get-MountVerdict -InspectExit <int> -RunningRaw <string> -ExecExit <int> -ExecOut <string>`，
然後加這幾條斷言：

```
inspect exit=1                      => 'absent'
inspect exit=0, running='false'     => 'stopped'
running='true', exec exit=0, out=OK => 'ok'
running='true', exec exit=0, out=FAIL => 'mount-fail'
running='true', exec exit=124       => 'mount-fail'   # 逾時＝9p 卡住，要算故障
```

再加一條整合斷言：一組含 `stopped` 的探測結果，`$failed` 必須是 0 筆、
`$newStatus` 必須是 `OK`。

---

### A2 — 自癒 abort 後沒有冷卻，下一個 3 分鐘 tick 會再打一次 `wsl --shutdown`

#### 位置

| 檔案:行號 | 內容 |
|---|---|
| `openab/healthcheck/mount-watchdog.ps1:639-644` | `abort-vmmem`（vmmemWSL 300 秒沒消失） |
| `openab/healthcheck/mount-watchdog.ps1:651-655` | `abort-exe`（找不到 Docker Desktop.exe） |
| `openab/healthcheck/mount-watchdog.ps1:662-667` | `abort-mount`（重開後 300 秒仍讀不到掛載） |
| `openab/healthcheck/mount-watchdog.ps1:742-746` | 主流程的自癒閘門，只看 `Get-HealBudget` |
| `openab/healthcheck/mount-watchdog.ps1:122-143` | `Get-HealBudget`：只有「24 小時內 2 次」總量上限，**沒有最小間隔** |
| `openab/healthcheck/register-mount-watchdog.ps1:34` | 排程重複間隔 3 分鐘 |
| 規格 `docs/mount_watchdog_spec_2026_08_27.md:206`、`§6.2 步驟 3` | 「超時 → 停手 … 結束（**不再重試**）」 |

#### 觸發條件

真的發生 VM 層級 9p 崩潰（`Scope=vm`），且第一次自癒在任何一個 abort 分支停手。

其中 `abort-vmmem` 特別容易中：規格 §6.5 自己就寫了「事故當下 `vmmemWSL` 超過 10 分鐘才消失」，
而 `$VmmemTimeoutSec = 300`（`:31`）只給 5 分鐘。**規格描述的實際事故，用規格給的逾時值會超時。**

#### 後果

三個 abort 分支目前只做兩件事：發告警 + `return`。回到主流程之後：

- `$newStatus` 仍是 `'FAIL'`（沒有人改它）
- `$scope` 仍是 `'vm'`
- `$state.healAt` 只用掉 1 筆，`Get-HealBudget` 下次仍回 `Allowed = $true`（上限 2）
- state 檔沒有任何「已經停手了、別再試」的紀錄

排程每 3 分鐘一次（`register-mount-watchdog.ps1:34`），`MultipleInstances IgnoreNew`（`:36`）
只擋住「執行中重疊」，擋不住「上一輪已結束、下一輪照跑」。所以：

```
T+0     偵測 FAIL / vm → 自癒 #1 → wsl --shutdown → 輪詢 300s → 超時 abort
T+5:00  告警「需要人工處理／重開機。不會自動重試」← 訊息內容與實際行為不符
T+5:00  腳本結束（healAt = 1 筆）
T+6:00  下一個 tick：仍 FAIL、仍 vm、budget 1/2 → 自癒 #2
T+6:00  第二次 wsl --shutdown ＋ 殺 Docker Desktop
        ← 此時第一次的 WSL 關機／Docker 重開很可能正在進行中，被硬生生打斷
T+11:00 第二次多半也 abort → healAt = 2 筆 → 熔斷器終於鎖住 24 小時
```

也就是說：**熔斷器擋得住「無限」重啟，擋不住「11 分鐘內連打兩次」。**
規格 §6.4 的「2 次/24h」是總量上限，不是節奏控制；規格 §6.2 要的「不再重試」沒有被實作。

而且第一次 abort 發出去的告警文字**明說**「不會自動重試」（`:640`、`:663`），
6 分鐘後卻又跑了一次——這比單純的 bug 更糟，是告警內容說謊。

#### 建議的修法方向

建議**兩層都做**，它們擋的是不同情境：

**(a) 閂鎖（latch）——擋「同一次事故的重試」。**

在 state schema 加兩個欄位：`manualRequired`（bool）、`manualRequiredAt`（ISO 8601 字串）。

三個 abort 分支（`:639-644`、`:651-655`、`:662-667`）在 `return` 之前：

```
$State.manualRequired   = $true
$State.manualRequiredAt = $Now.ToString('o')
Write-WatchdogState -State $State -Path $StateFile
```

主流程的自癒閘門（`:742`）改成先看閂鎖：

```
if ($action -eq 'self-heal') {
  if ($state.manualRequired -and 距 manualRequiredAt < 24h) {
      Write-Log '[ACTION] self-heal latched off (manual intervention required)'
      # 只走一般的 Get-AlertAction 去重告警，不進 ladder
  } elseif (-not $budget.Allowed) { ... }
  ...
}
```

**解除條件**：`$newStatus` 變成 `'OK'` 時清掉閂鎖（`manualRequired = $false`），
這樣人工修好之後、未來另一次真正的新事故仍然能自癒。
另外給 24 小時的自動過期當保險，避免閂鎖永久卡死。

**(b) 最小間隔——擋「修好後馬上又壞」的連打。**

`Get-HealBudget`（`:122-143`）加一個參數 `MinIntervalMinutes`（建議預設 60）：
若 `$recent` 裡最新的一筆距 `$Now` 小於該值，回 `Allowed = $false`，
並用一個新欄位（例如 `Reason = 'cooldown'`）跟 `Reason = 'cap'` 區分，
讓 `:745` 的告警文字能講清楚是「冷卻中」還是「已達 24 小時上限」。

**(c) 必踩的實作陷阱——新欄位會被主流程清掉。**

`:778-785` 的 `$newState` 是**用固定欄位清單重建**的，`:801-805` 也只回讀 `healAt`。
所以只要 ladder 把 `manualRequired` 寫進磁碟，主流程結束時的
`Write-WatchdogState`（`:807-808`）就會把它**清掉**——修了等於沒修。

新欄位必須同時加進**四個**地方，缺一不可：

| 檔案:行號 | 要加什麼 |
|---|---|
| `mount-watchdog.ps1:58-67` `Get-InitialWatchdogState` | 新欄位的預設值（`$false` / `$null`） |
| `mount-watchdog.ps1:429-436` `Read-WatchdogState` 的回傳物件 | 從 JSON 讀出新欄位（舊 state 檔沒有這兩個 key，要能吃 `$null`） |
| `mount-watchdog.ps1:442-449` `Write-WatchdogState` 的 `$payload` | 落盤 |
| `mount-watchdog.ps1:778-805` 主流程的 `$newState` | 從 `$state` 或回讀的 `$onDisk` 帶過來，不要漏 |

`:801-805` 那段目前只回讀 `healAt`，建議直接改成「整個 `$onDisk` 都拿來當基底」，
以後再加欄位就不會重蹈覆轍。

**(d) 順手修掉告警文字與現實不符。**
`:640`、`:663` 的「不會自動重試」在閂鎖做好之前是假的。閂鎖做好之後就變成真的，
不必改字；若決定只做 (b) 不做 (a)，那這兩句要改成「N 分鐘內不會再試」。

**(e) 一併考慮 `$VmmemTimeoutSec = 300`（`:31`）是否夠。**
規格 §6.5 記錄的實際事故是「超過 10 分鐘」。300 秒會讓 `abort-vmmem` 變成常態路徑，
而不是例外路徑。建議調到 600–900 秒，或至少在 README 註明這個值偏保守、
第一次真的觸發時要回頭看 log 調整。（此項屬於判斷題，交給 Coordinator 決定，
不是必須修的一部分。）

**(f) SelfTest 補測（`Invoke-SelfTest:206-353`）。**

```
Get-HealBudget -HealAt @(now.AddMinutes(-5))  -Now now -MinIntervalMinutes 60  => Allowed=$false, Reason='cooldown'
Get-HealBudget -HealAt @(now.AddMinutes(-90)) -Now now -MinIntervalMinutes 60  => Allowed=$true
Get-HealBudget -HealAt @(-2h, -1h)            -Now now                          => Allowed=$false, Reason='cap'
閂鎖：manualRequired=$true 且 5 分鐘前 → 自癒閘門回 'latched'（不進 ladder）
閂鎖：manualRequired=$true 且 25 小時前 → 過期，允許自癒
閂鎖：newStatus='OK' → 閂鎖被清除
```

---

## 2. 建議（8 項，非阻斷）

嚴重度：**中** = 會實際影響可用性或信任度，建議這輪一起修；**低** = 記錄下來，有空再處理。

### B1 — `Scope=container` 修好後不發「已恢復」（嚴重度：中）

**位置：** `mount-watchdog.ps1:726-736`（告警送出點）、`:759-766`（容器重啟與重驗）

**理由：** 主流程在 `:733` 就把 ⚠️ 失敗那則送出去了，**然後**才在 `:760` 重啟容器。
重啟成功後 `:765` 把 `$newStatus` 改回 `'OK'`，但 `$alert` 早在 `:722` 就算完了，
`$notice` 也早在 `:726-730` 就定型。結果 state 直接寫回 `OK`，下一輪是 OK→OK，
`Get-AlertAction` 回 `'none'`——**永遠不會有收尾訊息**。

使用者看到的是：一則「掛載檢查失敗」，然後沒有下文。VM 自癒階梯有收尾
（`:673-678` 會發「自癒完成」或「仍有 N 條失敗」），container 路徑卻沒有，行為不一致。

**方向：** 在 `:765` 判定恢復後補一則「已由重啟容器修復」的通知，
比照 ladder `:674` 的寫法。

### B2 — Docker 正常開關機各換來兩則 Discord（嚴重度：中）

**位置：** `mount-watchdog.ps1:722`（狀態機）、`:739-741`、`:767-769`（daemon 分支）

**理由：** 使用者關掉 Docker Desktop（或機器重開機、排程在 Docker 起來之前就跑）時：
12 條全部 `docker exec` 失敗 → Tier 2 也失敗 → `Scope='daemon'` → OK→FAIL **發一則**；
Docker 起來後 → FAIL→OK **再發一則「已恢復」**。
每次正常開關機都是兩則推播。長期下來與 A1 一樣會讓人麻痺。

**方向：** 加一個「連續 N 次 FAIL 才告警」的確認機制（N=2，等於 6 分鐘），
或針對 `Scope='daemon'` 特別給一次寬限（第一次只記 log，第二次才告警）。
state 加一個 `consecutiveFail` 計數即可，也很好寫 SelfTest。

### B3 — log 無輪替（嚴重度：低）

**位置：** `mount-watchdog.ps1:364-372` `Write-Log` → `Add-Content -Path $LogFile`

**理由：** 只 append，沒有任何截斷。每次執行約 14 行，每 3 分鐘一次
≈ 480 次/天 ≈ 6,700 行/天 ≈ 600 KB/天 ≈ 200 MB/年。
`.state/` 已 gitignore，所以不會污染版控，只是會慢慢吃磁碟。

**方向：** 寫入前檢查大小，超過（例如）5 MB 就 rename 成 `.log.1` 並重開，保留 1–2 份。

### B4 — `vmmemWSL` 行程名硬編，換名會 fail-open（嚴重度：中）

**位置：** `mount-watchdog.ps1:565` `Get-Process -Name 'vmmemWSL' -ErrorAction SilentlyContinue`

**理由：** 我在本機實測確認現在確實叫 `vmmemWSL`（1 個行程），所以**目前沒問題**。
風險在於這個名字歷史上變過（舊版 WSL2 叫 `vmmem`）。若換機或 Windows 更新後改名，
`Get-Process` 回 `$null` → `Wait-VmmemWslGone`（`:566-569`）會**立刻回 `$true`**，
判定「WSL 已經關乾淨了」，然後在 WSL 其實還活著的情況下直接跳到第 4 步殺 Docker Desktop。
這是 fail-open：偵測不到就當作成功，方向錯了。

**方向：** 同時比對 `vmmemWSL` 與 `vmmem`；
更保險的是加一道「兩者都找不到，且 `wsl --list --running` 也回空」的雙重確認，
或至少在找不到行程時 log 一行 `[WARN] no vmmem* process found — assuming already down`，
讓事後看 log 的人知道走了哪條路。

### B5 — SelfTest 有幾條是對常數自我斷言（嚴重度：低）

**位置：** `mount-watchdog.ps1:232-250`（掛載清單）、`:342-346`（自癒階梯文字）

**理由：**

- `:232` `Assert-Eq $Mounts.Count 12` — 只驗自己數自己。
- `:233-239` 「no probe path is a parent directory only」的黑名單只有
  `'/workspace'`、`'/'`、`'/run'` 三個字串。若有人把探測路徑寫成 `/workspace/Estate`（少一截）
  或 `/vault/..`，這條照樣 PASS。
- `:342-346` 「ladder has 7 steps」驗的是 `Get-SelfHealSteps`（`:177-187`）這個**純文字陣列**，
  它跟 `Invoke-SelfHealLadder`（`:620-680`）的實際行為之間沒有任何連結——
  改了 ladder 而忘了改文字，測試不會抓到。

**這不算違規**：規格 §8.3 明確只要求「狀態機、去重規則、熔斷器計數、Tier 2 判讀」，
那四項的測試是**真的**單元測試而且寫得好（`Get-AlertAction` / `Get-HealBudget` /
`Get-Tier2Scope` 都是純函式、都用注入假資料測邊界）。
CODING worker 在驗收報告裡的用詞也很準（「SelfTest 鎖住階梯文字」，沒有誇大成
「驗證了自癒邏輯」）。

**方向：** 真正有價值的補強是「`$Mounts` 與 `docker-compose.yml` 的 healthcheck 對不對得起來」——
這兩份清單將來一定會漂移。可以做一個離線檢查：讀 compose YAML、
把每個 `healthcheck.test` 裡 `ls ` 後面的路徑抓出來，跟 `$Mounts` 做集合比對。
不需要新相依（PS 5.1 沒有內建 YAML parser，但用 regex 抓 `ls /xxx` 就夠了）。

### B6 — 十段 healthcheck 都沒有 `start_period`（嚴重度：低）

**位置：** `openab/docker-compose.yml` 的十個 `healthcheck:` 區塊（檔案實際行號）

| 行 | 服務 |
|---|---|
| `:48` | `openab-kiro` |
| `:74` | `openab-nvidia-lab` |
| `:116` | `openab-url-intake` |
| `:134` | `openab-travel-nvidia` |
| `:165` | `openab-estate` |
| `:194` | `openab-travel-claude` |
| `:224` | `openab-astruct` |
| `:263` | `openab-credit-report` |
| `:342` | `pdf-publisher` |
| `:379` | `intake-publisher` |

**理由：** `interval: 30s` + `retries: 3` 且沒有 `start_period`，
表示容器啟動後 90 秒內若主程序還沒就緒就會被標成 `unhealthy`。
目前**影響有限**——我確認 compose 裡沒有任何 `depends_on` 用
`condition: service_healthy`，所以不會 cascade，只是 `docker ps` 顯示難看。

**方向：** 每段加 `start_period: 30s`（或依實際啟動時間）。規格沒要求，屬於順手。

### B7 — DryRun 的「would send」訊息會誤導（嚴重度：低）

**位置：** `mount-watchdog.ps1:525-537` `Send-WatchdogNotice`

**理由：** `if ($DryRun)` 這個分支（`:525-529`）排在
`if (-not $AlertCfg.Configured)`（`:530`）與 `if (-not $WouldSend)`（`:534`）**之前**。
所以在 `-DryRun` 下，即使該則告警實際上會被去重節流掉，
還是會印出 `[DRYRUN] would send Discord:` ——DryRun 的輸出因此無法用來驗證去重行為。

**方向：** 把 `$DryRun` 分支移到 `$WouldSend` 檢查之後，
或在訊息裡帶上 `WouldSend` 的值（例如 `[DRYRUN] would send (send=$WouldSend)`）。

### B8 — `Invoke-Cmd` 逾時只殺 CLI，容器內卡住的 `ls` 會殘留（嚴重度：低）

**位置：** `mount-watchdog.ps1:390-393`

**理由：** `$proc.Kill()` 殺的是 host 上的 `docker.exe`，
被 `docker exec` 起在容器裡、正卡在 9p 上的那個 `ls` 不會被回收。
9p 垂死時（正是規格 §4.3 描述的「卡住而不是報錯」情境），
每 3 分鐘就會多留一個殭屍 exec 行程。

**方向：** 探測 shell 前面加 `timeout 10 ls ...`（alpine/debian 都有 `timeout`），
讓容器內自己收尾；host 端的逾時當第二道保險。
注意三隻 `python:3.12-slim` 也有 `timeout`（coreutils 在 slim 裡有），
但若要保險可以先 `command -v timeout` 確認。

---

## 3. 我無法驗證的（5 項，明說，不假裝）

### D1 — `docker compose config` 的退出碼（規格 §8 驗收第 1 項）

**為什麼無法驗證：** worktree 的 `.local/` 目前只剩 `infra_alert.env.example`
（CODING worker 為了 compose 驗收暫時複製進來的 token env 已經清掉了），
而 `docker-compose.yml` 有 `env_file` 依賴。
本次是 review-only 任務，**我不新增檔案到工作樹**，所以無法重跑
`docker compose config` 而不製造出一個我不該建立的 `.local/*.env`。

**替代信心：** 十隻容器**現在正用這份 compose 跑著而且全部 healthy**（見 §5.2），
這等同於 config 曾經解析成功；而且我用 `docker inspect` 逐一比對了
執行中的 healthcheck 字串與 compose 檔內容一致（見 §4.2）。

### D2 — 真正的 9p 崩潰時 `ls` 掛載點的行為

**為什麼無法驗證：** 無法安全重現 WSL2 utility VM 崩潰。
規格 §1.1 的 `d?????????` 狀態是事故當下觀察到的，不能隨意製造。

**替代信心：** 我驗證了**可以驗證的部分**——12 條探測路徑全都是容器內真正的 mountpoint
（見 §4.1）。既然是 mountpoint，`ls` 就一定會進到 9p，不會被本地目錄項騙過。
至於「9p 死時是 EIO 還是卡住」，規格說是卡住，實作用
`Tier1TimeoutSec = 15`（`:33`）與 compose 的 `timeout: 10s` 兩層去接，設計方向正確，
但**我沒有實測 unhealthy 的翻轉**。CODING worker 也誠實標明了這一點
（`docs/mount_watchdog_acceptance_2026_08_27.md:198`）。

### D3 — Discord 訊息真的送得出去

**為什麼無法驗證：** worktree 沒有 `.local/infra_alert.env`，
所以頻道閘門會直接 skip。我**刻意不**把主 checkout 的 `infra_alert.env` 複製進來——
那會改動工作樹，也會在審查過程中真的往使用者頻道發訊息。

**替代信心：** 只做了程式碼比對：`:405` 的 User-Agent 字串格式與
`claude-oauth-check.ps1:86`（已知可用）一致、`:409` 確實帶進 `Headers`、
`:411` 用 `[Text.Encoding]::UTF8.GetBytes()` 送 body（中文不會爛）。
**沒有做真實 POST**，所以「Cloudflare 不會回 403」這件事我沒有實證。

### D4 — 自癒階梯實跑

**為什麼無法驗證：** 不可能也不該在審查中執行 `wsl --shutdown` +
殺 Docker Desktop——那會停掉使用者所有容器與 Ubuntu distro。
規格 §6.3 自己也聲明了這條路徑「未經實地驗證」。

**替代信心：** 我改為驗證階梯上每一個「打錯就整條失效」的細節：

- 三個 kill 目標的行程名是否真的存在（§4.3 之外的補充驗證，見下方）
- 中文空白路徑在 `docker run -v` 的引號處理（§4.4）
- 在有 `param` 區塊的函式內覆寫 `$args` 自動變數是否可行（§4.4）
- Tier 2 的 `nsenter` 指令本身在這台機器可不可執行（§4.3）

這些是「不跑也能驗」的部分，但**階梯的整體時序、Docker Desktop modal 對話框
會不會再次出現，仍然完全未驗證**。

### D5 — Tier 2 在真正 VM 崩潰時的輸出

**為什麼無法驗證：** 同 D2，無法製造 `d?????????`。

**替代信心：** 我實跑了 Tier 2 指令本身（見 §4.3），確認它在這台機器**可執行且 exit 0**。
這條若不成立，`Get-Tier2Scope`（`:82-83`）會因為 `ExitCode -ne 0` 而回 `'daemon'`，
**任何真實的 VM 崩潰都會被誤判成 daemon，自癒永遠不會觸發**——
所以這條值得單獨確認，而且我確認過了。
另外 `alpine` image 已在本機（13.1 MB），所以 `$Tier2TimeoutSec = 30`（`:34`）
不會因為要 pull image 而逾時誤判成 `daemon`。

**附帶觀察（不影響判讀）：** 規格 §1.1 寫的是 C:/D:/E: 三個磁碟，
現在 `/run/desktop/mnt/host/` 只列出 `c` / `d`（外加 `wsl` / `wslg`）。
`Get-Tier2Scope` 是用 regex `d\?{9}` 比對，不依賴磁碟數量，所以沒有影響。

---

## 4. 我額外做的 5 項驗證（規格沒要求，實際輸出）

### 4.1 — 12 條探測路徑是不是真的 mountpoint（驗「假 OK 陷阱」）

這是重點審查第 1 項。我沒有只讀程式碼，而是進到每個容器比對
`/proc/self/mountinfo` 的第 5 欄（mount point），確認 `$Mounts` 裡每一條路徑
都是**真正的掛載點**，而不是掛載點的父目錄或子目錄。

指令（對 12 條逐一執行）：

```
docker inspect <c> --format '{{range .Mounts}}{{if eq .Destination "<p>"}}{{.Source}}{{end}}{{end}}'
docker exec <c> sh -c "awk -v t='<p>' '\$5==t{print \"MOUNTPOINT\"}' /proc/self/mountinfo | head -1"
```

實際輸出：

```
openab-url-intake        /vault                               mountpoint=MOUNTPOINT   src=D:/discord 個人助理/URLIntake
intake-publisher         /vault                               mountpoint=MOUNTPOINT   src=D:/discord 個人助理/URLIntake
pdf-publisher            /vault                               mountpoint=MOUNTPOINT   src=D:/discord 個人助理/TravelMemory
openab-estate            /workspace/EstateSpace               mountpoint=MOUNTPOINT   src=/run/desktop/mnt/host/d/discord 個人助理/EstateSpace
openab-travel-claude     /workspace/TravelMemory              mountpoint=MOUNTPOINT   src=D:/discord 個人助理/TravelMemory
openab-travel-nvidia     /workspace/TravelMemory              mountpoint=MOUNTPOINT   src=D:/discord 個人助理/TravelMemory
openab-credit-report     /workspace/CreditReportSpace         mountpoint=MOUNTPOINT   src=D:/discord 個人助理/CreditReportSpace
openab-kiro              /workspace/KiroSpace                 mountpoint=MOUNTPOINT   src=D:/discord 個人助理/KiroSpace
openab-kiro              /workspace/TravelMemory              mountpoint=MOUNTPOINT   src=D:/discord 個人助理/TravelMemory
openab-nvidia-lab        /workspace/LabSpace                  mountpoint=MOUNTPOINT   src=D:/discord 個人助理/LabSpace
openab-astruct           /workspace/AStructSpace              mountpoint=MOUNTPOINT   src=/run/desktop/mnt/host/d/discord 個人助理/AStructSpace
openab-astruct           /workspace/AStructSpace/forward      mountpoint=MOUNTPOINT   src=/run/desktop/mnt/host/c/Users/xx/Desktop/tmf-strategy-lab-main/tmf-strategy-lab-main/data/forward
```

**結論：12/12 都是真掛載點，沒有一條是父目錄。**
規格 §5.1 最擔心的「`ls /workspace` 假 OK」沒有發生。
第 12 條（C: 磁碟的 `tmf-strategy-lab` forward）**確實有被涵蓋**，
而且來源路徑確認是 `/run/desktop/mnt/host/c/...`（C: 磁碟）。

### 4.2 — 執行中容器的實際 healthcheck 字串（驗「覆寫是否生效」）

`docker inspect <c> --format '{{json .Config.Healthcheck}}'` 對十隻逐一執行，實際輸出：

```
--- openab-url-intake ---
{"Test":["CMD-SHELL","grep -qa '/app/bot.py' /proc/1/cmdline && ls /vault >/dev/null 2>&1 || exit 1"],"Interval":30000000000,"Timeout":10000000000,"Retries":3}
--- intake-publisher ---
{"Test":["CMD-SHELL","grep -qa '/app/publish.py' /proc/1/cmdline && ls /vault >/dev/null 2>&1 || exit 1"],"Interval":30000000000,"Timeout":10000000000,"Retries":3}
--- pdf-publisher ---
{"Test":["CMD-SHELL","grep -qa '/app/publish.py' /proc/1/cmdline && ls /vault >/dev/null 2>&1 || exit 1"],"Interval":30000000000,"Timeout":10000000000,"Retries":3}
--- openab-estate ---
{"Test":["CMD-SHELL","pgrep -x openab >/dev/null && ls /workspace/EstateSpace >/dev/null 2>&1 || exit 1"],"Interval":30000000000,"Timeout":10000000000,"Retries":3}
--- openab-travel-claude ---
{"Test":["CMD-SHELL","pgrep -x openab >/dev/null && ls /workspace/TravelMemory >/dev/null 2>&1 || exit 1"],"Interval":30000000000,"Timeout":10000000000,"Retries":3}
--- openab-travel-nvidia ---
{"Test":["CMD-SHELL","pgrep -x openab >/dev/null && ls /workspace/TravelMemory >/dev/null 2>&1 || exit 1"],"Interval":30000000000,"Timeout":10000000000,"Retries":3}
--- openab-credit-report ---
{"Test":["CMD-SHELL","pgrep -x openab >/dev/null && ls /workspace/CreditReportSpace >/dev/null 2>&1 || exit 1"],"Interval":30000000000,"Timeout":10000000000,"Retries":3}
--- openab-kiro ---
{"Test":["CMD-SHELL","pgrep -x openab >/dev/null && ls /workspace/KiroSpace >/dev/null 2>&1 && ls /workspace/TravelMemory >/dev/null 2>&1 || exit 1"],"Interval":30000000000,"Timeout":10000000000,"Retries":3}
--- openab-nvidia-lab ---
{"Test":["CMD-SHELL","pgrep -x openab >/dev/null && ls /workspace/LabSpace >/dev/null 2>&1 || exit 1"],"Interval":30000000000,"Timeout":10000000000,"Retries":3}
--- openab-astruct ---
{"Test":["CMD-SHELL","pgrep -x openab >/dev/null && ls /workspace/AStructSpace >/dev/null 2>&1 && ls /workspace/AStructSpace/forward >/dev/null 2>&1 || exit 1"],"Interval":30000000000,"Timeout":10000000000,"Retries":3}
```

逐項核對規格 §4.3 的硬性要求：

| 要求 | 結果 |
|---|---|
| 12 條掛載全數涵蓋 | ✅ 8 隻單掛載 + `openab-kiro` 2 條 + `openab-astruct` 2 條 = 12 |
| 第 12 條（C: 的 forward）沒漏 | ✅ `openab-astruct` 第二段 `ls /workspace/AStructSpace/forward` |
| **保留**原程序檢查（不是取代） | ✅ 八隻 openab 全部保留 `pgrep -x openab >/dev/null &&` 在前 |
| 多掛載容器每條都檢查、`&&` 串接 | ✅ kiro 與 astruct 都是兩段 `ls` 用 `&&` 串 |
| `timeout ≥ 10s` | ✅ 全部 `10000000000` ns = 10s |
| 三隻沒有 healthcheck 的要新增、**不要假設程序名** | ✅ 新增了，且用 `grep -qa '/app/bot.py' /proc/1/cmdline`（`python:3.12-slim` 沒有 `pgrep`），不是硬套 `openab` |
| 不得改動 `volumes:` / `environment:` / `env_file:` / `image:` | ✅ `git diff openab/docker-compose.yml` 只有新增 `healthcheck:` 區塊與註解 |

### 4.3 — Tier 2 的 `nsenter` 指令實跑 + 自癒 kill 清單的行程名

**Tier 2 指令**（唯讀 `ls`）：

```
$ docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -u -n -i sh -c 'ls -la /run/desktop/mnt/host/'
total 2
drwxr-xr-x 6 root root 1024 Aug 27 09:04 .
drwxr-xr-x 4 root root 1024 Aug 27 09:04 ..
drwxrwxrwx 1 root root  512 Aug 27 07:52 c
drwxrwxrwx 1 root root 4096 Aug 22 02:55 d
drwxrwxrwt 4 root root  100 Aug 27 09:05 wsl
drwxrwxrwt 6 root root  280 Aug 27 09:04 wslg
EXIT=0
```

exit 0、輸出無 `d?????????` → `Get-Tier2Scope`（`:76-92`）會判 `'container'`，正確。
**這條很關鍵**：若指令本身跑不起來，`:82-83` 會因 `ExitCode -ne 0` 一律回 `'daemon'`，
自癒（只在 `'vm'` 觸發）就永遠不會啟動。

`alpine` image 已在本機：

```
$ docker image ls alpine --format '{{.Repository}}:{{.Tag}} {{.Size}}'
alpine:latest 13.1MB
```

所以 30 秒逾時不會被 image pull 吃掉。

**自癒 kill 清單的行程名**（`mount-watchdog.ps1:54`、`:565`）：

```
Docker Desktop -> 4 proc(s)
com.docker.backend -> 2 proc(s)
com.docker.build -> 1 proc(s)
vmmemWSL -> 1 proc(s)
```

四個名字全部正確（打錯任何一個，`Stop-DockerDesktopProcesses` 或
`Wait-VmmemWslGone` 就會靜默失效）。`vmmemWSL` 的 fail-open 風險見 B4。

**「不存在的容器」的行為**（A1 的證據）：

```
$ docker exec no-such-container-xyz sh -c "ls /vault >/dev/null 2>&1 && echo OK || echo FAIL"
Error response from daemon: No such container: no-such-container-xyz
exit=1

$ docker restart no-such-container-xyz
Error response from daemon: No such container: no-such-container-xyz
exit=1
```

### 4.4 — 自癒第 6 步的中文路徑引號處理 與 `$args` 自動變數覆寫

這是**驗收完全沒覆蓋到的路徑**：`Wait-HostMountReadable`（`:604-618`）是自癒第 6 步的核心，
但它只在真的自癒時才會執行，SelfTest 與 DryRun 都碰不到。
兩個可疑點：

1. `:607` 在**有 `param` 區塊的函式內**指派 `$args = @(...)` ——`$args` 是 PowerShell 的自動變數，
   覆寫它在某些情境會出問題。
2. `Invoke-Cmd:383` 的引號組裝要能正確處理 `D:/discord 個人助理/URLIntake:/vault`
   這種**同時含中文與空白**的路徑。

我在 scratchpad 建臨時 `.ps1`（**不在工作樹內**），原樣複製 `Invoke-Cmd` 與
`Wait-HostMountReadable` 的內容來跑。

**第一次（無 BOM 的臨時檔）：**

```
ARGS COUNT = 7
EXIT=125
OUT(first 200)=
ERR=docker: Error response from daemon: CreateFile D:\discord ??��????\URLIntake: The filename, directory name, or volume label syntax is incorrect.
```

**第二次（補上 UTF-8 BOM，與實際交付檔一致）：**

```
$ head -c 3 t2.ps1 | od -An -tx1
 ef bb bf
ARGS COUNT = 7
EXIT=0
OUT(first 200)=2026-08-10_1204_kitesurf-cloudflare-ai.md
2026-08-10_1234_john-s-algorithm-elon-musk.md
2026-08-10_1247_cloudflare-os-an-open-platform-for-agents-apps-and-work.md
2026-08-10_1253_how-workers-works.md
```

**結論：**

- `$args` 在有 `param` 區塊的函式內覆寫 → **正常**（`ARGS COUNT = 7`，7 個元素都在）。
- 中文空白路徑的 `docker run -v` 引號處理 → **正確**（exit 0，真的列出了 URLIntake 的檔案）。
- **附帶收穫（值得記錄）**：第一次失敗純粹是我的臨時檔沒有 BOM，導致 PS 5.1 把
  `個人助理` 讀成 mojibake。這反過來實證了規格 §7.2 的 BOM 要求**是真的會咬人**，
  不是形式主義——交付的兩支 `.ps1` 都有 BOM（見 §5.7），所以不受影響。
  我差點把這個誤報寫成 bug，補上 BOM 重測才確認不是。

### 4.5 — `.gitignore` 的 `.local/*` + `!.local/*.example` 是否真的生效

```
$ git check-ignore -v .local/infra_alert.env .local/infra_alert.env.example .local/discord_token.env
.gitignore:2:.local/*	.local/infra_alert.env
.gitignore:3:!.local/*.example	.local/infra_alert.env.example
.gitignore:2:.local/*	.local/discord_token.env

$ git add -A -n
add '.gitignore'
add 'openab/docker-compose.yml'
add 'openab/healthcheck/README.md'
add '.local/infra_alert.env.example'
add 'docs/mount_watchdog_acceptance_2026_08_27.md'
add 'docs/mount_watchdog_spec_2026_08_27.md'
add 'openab/healthcheck/mount-watchdog.ps1'
add 'openab/healthcheck/register-mount-watchdog.ps1'

$ git check-ignore -v openab/healthcheck/.state/mount-watchdog.json
openab/healthcheck/.gitignore:2:.state/	openab/healthcheck/.state/mount-watchdog.json
```

**結論：** 實檔被擋、只有 `.example` 進版控、`.state/` 也被擋。

特別說明：把 `.local/` 改寫成 `.local/*` + `!.local/*.example`（`.gitignore` diff 第 8–10 行）
是**必要且正確**的——若維持目錄形式 `.local/`，git 不會遞迴進該目錄，
否定規則 `!.local/*.example` 根本不會被評估。這個細節做對了。

**祕密外洩檢查的其餘結果：**

- `.local/infra_alert.env.example` 內容只有 placeholder `<使用者稍後提供>`
  與 token **變數名** `DISCORD_TOKEN_NVIDIA`，沒有任何實值。
- 沒有任何地方設 `ANTHROPIC_API_KEY`（規格 §7.3）。
- **非問題但先講明**：`mount-watchdog.ps1:27` 硬編
  `$OwnerId = '843428445802725388'`。這是**既有先例**，不是這次新增的外洩——
  `claude-oauth-check.ps1:34`、`openab/README.md:60`、`docker-compose.yml:99`
  早就把同一個 Discord user ID 放進版控了。要清就整批清，不該只挑這次開刀。

---

## 5. 驗收重跑（3/4/5/6/7）與 CODING worker 宣稱值的比對

驗收第 1 項（`docker compose config`）無法重跑，理由見 D1。
第 2 項與第 3–7 項如下。

### 5.1 比對總表

| §8 項目 | CODING worker 宣稱 | 我重跑的結果 | 比對 |
|---|---|---|---|
| 1 `docker compose config` | `config_exit=0` / `config_profile_exit=0` | **未重跑**（見 D1） | — |
| 2 12 條掛載 healthy | 十隻 `(healthy)` | `docker ps` 實看十隻全 `(healthy)`；`docker inspect` 十隻 healthcheck 字串與 compose 一致 | ✅ **屬實** |
| 3 `-SelfTest` | 45 項全過、`SelfTest PASSED`、`EXIT=0` | 45 個 `[PASS]`、0 FAIL、`SelfTest PASSED`、`EXIT=0` | ✅ **一字不差** |
| 4 `-DryRun` | 12 條全 OK、`send=False`、7 步階梯、state 未寫 | 逐行相符 | ✅ **一字不差** |
| 5 正式跑一次不發 Discord | Tier 1 全綠、`[SKIP] no alert channel configured`、`EXIT=0` | state 檔存在（17:41 寫入、`status: OK`）、log 有完整紀錄、skip 路徑我實跑確認 | ✅ **屬實** |
| 6 `register -WhatIf` | 輸出如報告、`EXIT=0`、**沒有真的註冊** | 輸出相符、`EXIT=0`；`Get-ScheduledTask` 確認 `OpenAB-MountWatchdog` **真的不存在** | ✅ **屬實（不是嘴上說說）** |
| 7 git 乾淨度 | 實檔不在待提交清單 | `git check-ignore -v` + `git add -A -n` 實測（見 §4.5） | ✅ **屬實** |

### 5.2 驗收 2 — `docker ps` 實際輸出

```
openab-kiro	Up 7 minutes (healthy)
openab-credit-report	Up 7 minutes (healthy)
openab-astruct	Up 7 minutes (healthy)
openab-estate	Up 7 minutes (healthy)
openab-nvidia-lab	Up 7 minutes (healthy)
openab-travel-nvidia	Up 7 minutes (healthy)
openab-travel-claude	Up 7 minutes (healthy)
searxng	Up 7 minutes
openab-url-intake	Up 12 minutes (healthy)
pdf-publisher	Up 12 minutes (healthy)
intake-publisher	Up 12 minutes (healthy)
```

十隻（＝12 條掛載）全部 `healthy`。
（同一份 `docker ps` 還顯示 `radar-scheduler (unhealthy)`、`radarbot Restarting`、
`openab-gateway Restarting`——那些屬於 quant／radar 系統，不是本 compose 專案，
與本次審查無關。）

**注意**：這個 healthy 狀態是在**帶了** `--profile credit-report` 的前提下取得的，
`openab-credit-report` 才會存在。這正是 A1 的根源。

### 5.3 驗收 3 — `-SelfTest` 我的重跑輸出（完整）

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
[PASS] OK->FAIL kind=fail
[PASS] FAIL sustain within 60m does not send
[PASS] FAIL sustain kind=throttled
[PASS] FAIL sustain at 60m sends reminder
[PASS] FAIL sustain kind=fail-repeat
[PASS] FAIL->OK sends recovered
[PASS] FAIL->OK kind=recovered
[PASS] OK->OK does not send
[PASS] OK->OK kind=none
[PASS] first-run OK does not send (no flip)
[PASS] first-run FAIL still alerts
[PASS] 0 heals in 24h => allowed
[PASS] 0 heals count
[PASS] 1 heal in 24h => allowed
[PASS] 1 heal count
[PASS] 2 heals in 24h => denied
[PASS] 2 heals count
[PASS] heal older than 24h is pruned
[PASS] pruned window count=1
[PASS] single healAt string still counts as 1
[PASS] single healAt count=1
[PASS] vm => self-heal
[PASS] container => restart-failed
[PASS] daemon => alert-only no heal
[PASS] unique failed containers
[PASS] restart list has kiro
[PASS] restart list has estate
[PASS] empty channel => skip
[PASS] null channel => skip
[PASS] placeholder channel => skip
[PASS] numeric channel => configured
[PASS] self-heal ladder has 7 steps
[PASS] ladder polls vmmemWSL not command return
[PASS] ladder states kill-then-start not CLI restart
SelfTest PASSED
EXIT=0
```

**比對：** 45 個 `[PASS]`、0 個 `[FAIL]`、`EXIT=0`。
CODING worker 的驗收報告（`docs/mount_watchdog_acceptance_2026_08_27.md:66-99`）
節錄了其中 27 行並註明「中間 PASS 行略，共 45 項全過」——
**我實跑的數量與內容完全吻合，節錄也沒有挑好看的講。**

品質評註：真正有價值的是 `Tier2 *`（4 條）、`OK->FAIL` 系列（12 條）、
`heals` 系列（10 條）、`channel` 系列（4 條）——這些是對純函式注入邊界值的
**真單元測試**，正是規格 §8.3 點名要的四類。
其餘（mount list、ladder steps）是常數自證，見 B5。

### 5.4 驗收 4 — `-DryRun` 我的重跑輸出（完整）

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

**比對：** 與驗收報告 `:105-132` **逐行相符**。

順帶驗證到的兩件事：

- 中文輸出全部正常，**無 mojibake** → `.ps1` 的 BOM 是對的。
- `[SKIP] no alert channel configured` 出現、`EXIT=0` → 規格 §5.2 要求的
  「頻道未設定要優雅跳過、不可崩潰」**確實成立**。
- 「12 條 FAIL 誤報」（驗收報告偏離第 1 點記載的 `Write-Output` 污染 bug）
  **已經修好**：`Write-Log:364-372` 改用 `Write-Host`，我重跑 12 條全 OK。

### 5.5 驗收 5 — 正式執行一次的痕跡

我沒有重跑不帶參數的正式執行（避免寫入 state 檔改變 CODING worker 的產出狀態），
改為檢查它留下的痕跡：

```
$ ls -la openab/healthcheck/.state/
-rw-r--r-- 1 xx 197121   196 Aug 27 17:41 mount-watchdog.json
-rw-r--r-- 1 xx 197121 10857 Aug 27 17:50 mount-watchdog.log

$ cat openab/healthcheck/.state/mount-watchdog.json
{
    "scope":  null,
    "healAt":  [

               ],
    "lastAlertAt":  null,
    "failedMounts":  [

                     ],
    "status":  "OK",
    "lastChangeAt":  null
}

$ tail -5 openab/healthcheck/.state/mount-watchdog.log
2026-08-27T17:50:56.1932542+08:00   - 啟動 C:\Program Files\Docker\Docker\Docker Desktop.exe
2026-08-27T17:50:56.1943250+08:00   - 輪詢 docker run --rm -v "D:/discord 個人助理/URLIntake:/vault" alpine ls /vault 直到成功，上限 300 秒
2026-08-27T17:50:56.1953576+08:00   - 重跑 Tier 1 全清單驗證，結果發 Discord
2026-08-27T17:50:56.1963868+08:00 （DryRun 結束，未執行 wsl --shutdown、未殺行程、未啟動 Docker Desktop、未發 Discord）
2026-08-27T17:50:56.2001327+08:00 [DRYRUN] state file not written
```

**比對：** state 檔的內容與驗收報告 `:149-158` 完全一致
（`status: OK`、`healAt` 空、`lastAlertAt` null ＝ 從未發過告警）。
17:41 的寫入時間點證明**確實有一次不帶參數的正式執行**發生過，不是編的。

附帶確認：state JSON 是 `Set-Content -Encoding utf8` 寫的，PS 5.1 會加 BOM；
我的 `-DryRun` 重跑印出 `prev=OK`，證明 `Read-WatchdogState:417-422` 的
`Get-Content -Raw` + `ConvertFrom-Json` 能正確吃掉自己寫的 BOM，**往返沒問題**。

### 5.6 驗收 6 — `register -WhatIf` 我的重跑輸出

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
--- existing task? ---
not registered (expected)
```

**比對：** 與驗收報告 `:162-171` 相符，`EXIT=0`。
最後兩行是**我額外做的驗證**：用 `Get-ScheduledTask -TaskName 'OpenAB-MountWatchdog'`
確認排程工作**真的不存在**——驗收報告聲稱「沒有真的註冊」（`:174`）是屬實的，
不是嘴上說說。

規格 §5.4 的兩個已知坑也確認避開了：
`register-mount-watchdog.ps1:34` 沒有傳 `-RepetitionDuration`；
`:31` 用 `New-ScheduledTaskAction -Execute powershell.exe -Argument '-File "<路徑>"'`
而不是 `schtasks /TR`（含中文空白的路徑因此沒問題）。

額外正面發現：`:36` 的 `-MultipleInstances IgnoreNew` 擋住了執行中重疊，
這對一次可能跑 10 分鐘以上的自癒很重要，而且有做到。
（但它擋不住「上一輪已結束、下一輪照跑」——這正是 A2。）

### 5.7 編碼檢查（規格 §7.2）

```
openab/healthcheck/mount-watchdog.ps1                    ef bb bf
openab/healthcheck/register-mount-watchdog.ps1           ef bb bf
openab/healthcheck/claude-oauth-check.ps1                ef bb bf
.local/infra_alert.env.example                           23 20 43
openab/healthcheck/README.md                             23 20 43
.gitignore                                               23 20 4c
```

兩支含中文的 `.ps1` 都是 **UTF-8 with BOM**（`ef bb bf`），與既有的
`claude-oauth-check.ps1` 一致；`.example` 與 `.md` 是**無 BOM**。全部符合規格 §7.2。
實跑輸出的中文也全部正常（見 §5.4）。

### 5.8 PowerShell 5.1 相容性（規格 §7.1）

| §7.1 條目 | 檢查結果 |
|---|---|
| `Start-Process -PassThru` 的 `ExitCode` 為 `$null` | ✅ 需要 exit code 的地方一律走 `Invoke-Cmd:374-399`（`System.Diagnostics.Process` + `ReadToEndAsync()` + `WaitForExit($ms)`）。唯一的 `Start-Process`（`:656` 開 Docker Desktop）不需要 exit code，也沒有 `-PassThru` |
| `Get-Content -Raw` 讀空檔回 `$null` | ✅ `Read-WatchdogState:417-420` 顯式 null 檢查後才 `.Trim()`；`Read-DotEnv:193-194` 也有 |
| 沒有 `&&` / `\|\|` / 三元 / `??` | ✅ 我 grep 過整份：`&&` 只出現在**加引號的 shell 字串**內（`:460` 探測字串、compose 的 healthcheck），PowerShell 語法區沒有誤用 |
| `Set-Content` / `Add-Content` 預設 ANSI | ✅ `:451` 與 `:371` 都顯式 `-Encoding utf8` |

額外：CODING worker 自己踩到並修掉的第五個坑（`Write-Output` 污染函式回傳值）
記在 `README.md` 與 `mount-watchdog.ps1:366-367` 的註解裡，
修法（改 `Write-Host`）我實跑驗證有效。這個坑規格沒寫，是實作時新發現的，記錄得很好。

---

## 6. 審查期間我動過的東西（透明起見）

- **沒有修改任何被審查的檔案。** 審查前後 `git status --short` 完全一致：

  ```
   M .gitignore
   M openab/docker-compose.yml
   M openab/healthcheck/README.md
  ?? .local/
  ?? docs/mount_watchdog_acceptance_2026_08_27.md
  ?? docs/mount_watchdog_spec_2026_08_27.md
  ?? openab/healthcheck/mount-watchdog.ps1
  ?? openab/healthcheck/register-mount-watchdog.ps1
  ```

  （本文件 `docs/mount_watchdog_review_2026_08_27.md` 是後續 REVIEW-REPORT 任務新增的，
  屬於新文件，不是對被審查程式碼的修改。）
- 執行了 `-SelfTest`（純函式，無副作用）、`-DryRun`（12 次唯讀 `docker exec`）、
  `register-mount-watchdog.ps1 -WhatIf`（未註冊任何排程）。
  這三者只會**追加**內容到 `openab/healthcheck/.state/mount-watchdog.log`
  （該目錄已被 `openab/healthcheck/.gitignore:2` 排除）。
- 執行了唯讀的 `docker inspect` / `docker exec ... ls` / `docker ps` /
  一次 Tier 2 的 `nsenter ls` / 一次 `docker run alpine ls /vault`。
- 在 scratchpad（**工作樹之外**）建了兩個臨時 `.ps1`，複製 `Invoke-Cmd` /
  `Wait-HostMountReadable` 的內容做 §4.4 的測試。
- **沒有**建立 `.local/infra_alert.env`、**沒有**發送任何 Discord 訊息、
  **沒有**註冊排程工作、**沒有**執行 `wsl --shutdown` 或殺任何行程。

---

## 7. 給 CODING worker 的修復順序建議

1. **A1**（假 FAIL）——影響日常，先修。牽動的函式最多，但邏輯單純。
2. **A2**（自癒無冷卻）——影響真出事時的行為，務必修。
   注意 §1 A2 (c) 那個「新欄位會被主流程清掉」的陷阱。
3. **B1 + B2**（告警體驗，中）——與 A1 同一類問題（信任度），建議一起做完。
4. **B4**（`vmmem` fail-open，中）——一行 `-or` 的事。
5. B3 / B5 / B6 / B7 / B8（低）——有餘裕再處理。

修完後建議重跑：`-SelfTest`（含 §1 建議新增的斷言）、`-DryRun`、
以及**新增一個負向驗證**：手動 `docker stop openab-credit-report`，
確認 watchdog 不再誤報 FAIL、不會自動把它開回來、`exit 0`。
這個負向測試是目前整套驗收最大的空缺——所有驗收都只測了「一切正常」的路徑。
