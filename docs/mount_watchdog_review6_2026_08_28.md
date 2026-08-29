# 第六輪審查：FIX-M0（已上線）+ FIX-VMMEM（未上線）

**日期：** 2026-08-28
**審查對象：**
- FIX-M0 = `D:\discord 個人助理\openab\healthcheck\mount-watchdog.ps1`（**正式環境運行中**，排程 5 分鐘）
- FIX-M0 + FIX-VMMEM = worktree `...\mount-watchdog-m0\openab\healthcheck\mount-watchdog.ps1`

**結論：**
- **FIX-M0（已上線）：GO — 沒有 blocker，繼續跑。** 一個 MEDIUM 跟進（M-1）。
- **FIX-VMMEM（未上線）：NO-GO — 一個 HIGH 缺陷（V-1），修法約 4 行。**

---

## 0. 我實際跑過什麼

| 驗證 | 結果 |
|---|---|
| `-SelfTest` on `D:`（M-0 上線版） | `SelfTest PASSED` exit 0 |
| `-SelfTest` on worktree（M-0+VMMEM） | `SelfTest PASSED` exit 0 |
| `Get-ScheduledTask OpenAB-MountWatchdog` | `State=Ready`、`LastTaskResult=0`、`LastRunTime 09:41:01`、`NextRunTime 09:46` |
| 正式 log 最近數輪 | 全 `OK 0.17–0.20s`，`vmDegraded=False slowPeers=0` |
| 正式 `mount-watchdog.json` | `probeDurations` 12 條各已累積 5 筆（0.16–0.24s），JSON 結構正確 |
| `wsl.exe` 引數／編碼實測 | **發現 V-1、V-2**（見下） |
| `docker run --rm alpine cat /proc/sys/kernel/random/boot_id` | exit 0，回 `097e966b-…` + uptime — boot_id 訊號本身可用 |

---

## 1. FIX-M0（已上線）— GO

### 1.1 誤報風險：結構上封死了，這是本次最重要的結論

`VmDegraded` **不可能製造出一則本來不會發的告警**。

`Get-ProbeLatencyAssessment` 的 `$vm` 需要 `$timeouts.Count -gt 0`，也就是至少一條 `mount-fail`；而任何一條 `mount-fail` 都已經讓 `Get-ProbeRunDecision` 回 `Status=FAIL`，告警本來就會送。`VmDegraded` 只做兩件事：

1. 在**已經成立**的告警後面加一句「同一輪內另有 N 條掛載異常緩慢…」
2. 把 `Get-ScopeAction 'container'` 從 `restart-failed` 改成 `observe`

它不新增告警、不提高頻率、不改 `Get-AlertAction` 的 60 分鐘節流。所以「誤報 → 使用者開始忽略 #infra-alerts → 回到事故原點」這條路徑**不通**。這是 M-0 可以帶著已知缺點上線的根本理由。

冷啟動同理：沒有歷史 → `$DefaultBaselineSec = 0.5` → 門檻 2.5s。機器剛開機／容器剛重啟／備份／防毒掃描造成的全面變慢，**只要沒有 timeout 就什麼都不會發生**（最多在 log 留一行 `[LATENCY] slowPeers=N`，那是 log 不是告警）。

### 1.2 自癒門檻確實沒動

- `Get-ScopeAction 'vm'` = `self-heal`；`Get-ScopeAction 'vm' -VmDegraded $true` 仍是 `self-heal`（斷言鎖住）
- Tier2 的 `d?{9}` 判定、`$HealMax=2`、`$HealWindowHours=24`、`$HealMinIntervalMinutes=60`、`$VmmemTimeoutSec=900`、`$MountProbeTimeoutSec=600` 全部未動
- `daemon` / `all-down` 分支不受 `VmDegraded` 影響

### 1.3 第一輪的 state 陷阱：沒有踩到

`probeDurations` 在 `Read-WatchdogState`（L1524）與 `Write-WatchdogState`（L1548）兩側都經 `Convert-DurationMap`，而既有的固定清單邏輯只寫 `failedMounts`（L2158/L2174），兩者不相干，不會互相清掉。JSON round-trip 有斷言，且正式 state 檔已實證。

### 1.4 M-1（MEDIUM，跟進不是 blocker）：基線會把劣化學進去，導致自我致盲

L2170 的 `Update-ProbeDurationMap $durationMap $tier1 $BaselineWindow` 是**無條件**呼叫的，且只要 `Verdict=ok` 就收 —— 包含劣化那一輪的 11.0s / 2.5s / 1.8s，也包含冷啟動後第一輪偏慢的樣本。

具體算一次：機器剛開機、state 空，第一輪 12 條各 3.0s（全 ok，沒 timeout，不告警也不標 VmDegraded）。基線寫進 3.0s。**下一輪門檻變成 5×3.0 = 15s = `$Tier1TimeoutSec`** —— 也就是任何「還沒到 timeout」的耗時都不可能達標，慢鄰居偵測完全失效。要等中位數被正常樣本壓回去：window=12，需要 7 筆正常樣本，約 35 分鐘。同樣機制也適用於「劣化持續 7 輪以上」。

**為什麼不是 blocker：** 方向是漏報不是誤報。timeout 仍然是 `mount-fail`、仍然 FAIL、仍然告警 —— 退化成 M-0 之前的行為，不會說謊。

**最小修法：** 只在乾淨的一輪才更新基線 —— 把 L2170 改成僅當 `$decision.Status -eq 'OK' -and -not $decision.VmDegraded` 時才呼叫 `Update-ProbeDurationMap`，否則沿用 `$durationMap`。可再加一道：已有基線時，拒收 ≥ M× 基線的樣本，以擋掉冷啟動那一輪。

### 1.5 M-2（LOW）：20:56 只有 1 條慢鄰居時會漏報

K=2 是刻意的保守選擇。若當時只有 1 條慢鄰居 → `VmDegraded=false` → `Scope=container` → 走 `restart-failed`，重啟解不了 9p，白重啟一次。代價是一次無效重啟 + 告警少一句話；告警本身照樣送出。**不建議調低 K** —— 那是用誤報換漏報，方向錯。

### 1.6 M-3（LOW）：`observe` 會讓真正的單一容器故障失去自動修復

觸發條件是「同一輪有 1 條 15s timeout **且** 另有 2 條 ≥5× 自身中位數」。要湊齊需要一個 15s timeout 同時發生，機率低；而且 `observe` 分支只是 `Write-Log` 後什麼都不做，告警在動作區塊**之前**就已經送出（L2036-2050），狀態維持 FAIL、exit 1。人一定會看到。可接受。

---

## 2. FIX-VMMEM（未上線）— NO-GO as-is

### 2.1 V-1（HIGH，合併阻斷）：`wsl --list --running` 從來沒有真的被執行，而且每次輪詢會啟動一個 WSL 發行版

`Invoke-Cmd`（L1444）對**每一個**引數加引號：

```powershell
foreach ($a in $CmdArgs) { $psi.Arguments += '"' + ($a -replace '"', '\"') + '" ' }
```

`wsl.exe` 不把加引號的引數當旗標 —— 它會把它們當成「要在**預設發行版**裡執行的指令」。本機實測：

```
ARGS=["--list" "--running" ]  EXIT=127
  OUT=[]  ERR=[/bin/bash: line 1: --list: command not found]
ARGS=[--list --running]       EXIT=0   → 真的列出 Ubuntu / docker-desktop
```

兩個後果：

1. **`wsl-empty` 訊號是死碼。** `Test-WslHasNoRunningDistro -Output '' -ExitCode 127 -TimedOut $false` → `127 -ne 0` → `$false`。三個訊號實際只剩兩個。（這一半是安全的：不會誤判為完成。）
2. **副作用不安全。** `Wait-VmRecycled` 在 `wsl --shutdown` 之後每 ~5 秒呼叫一次 `Get-VmRecycleSnapshot`，最長 900 秒。每一次都在**預設發行版（本機是 Ubuntu）啟動一個 bash** —— 也就是把我們剛剛叫它關掉的 WSL2 VM 重新拉起來，一百多次，並讓 `vmmemWSL` 一直活著。接著它多半會用自己剛拉起來的那個 VM 的新 boot_id 判定 `Recycled=true`，於是「等待汰換」是靠自己造成的汰換而成功的，然後階梯就對一個正在開機的 VM 去 kill / 重啟 Docker Desktop。

`SelfTest` 看不到這個：它只把手寫字串餵給純函式 `Get-VmRecycleDecision`，從不執行真正的 `wsl.exe`。這正是「判定層測到了、邊界沒測到」那一類。

### 2.2 V-2（MEDIUM，同一個呼叫點）：中文分支在本機不可能成立

本機 `Get-Culture = zh-TW`、`[Text.Encoding]::Default = big5`。`wsl.exe` 輸出 UTF-16LE，而 `Invoke-Cmd` 用 Big5 預設編碼讀 pipe：ASCII 因為夾 NUL 所以剝 NUL 救得回來（英文分支之所以會過就是這個原因），但中文位元組 ≥0x80 會被當成 Big5 雙位元組吃掉、變成亂碼且不含 NUL —— `沒有正在執行中的發行版` 永遠不會 match。

而且**字串本身也對不上這個版本**：把 `StandardOutputEncoding` 設成 Unicode 之後，標題正確解碼為「Windows 子系統 Linux 版**發佈**:」，本機用的是「發佈」不是「發行版」。

### 2.3 V-1 + V-2 的修法（已在本機驗證可用）

在 `Get-VmRecycleSnapshot` 裡不要走 `Invoke-Cmd` 的加引號迴圈：

```powershell
$psi.Arguments = '--list --running --quiet'          # 原樣，不加引號
$psi.StandardOutputEncoding = [Text.Encoding]::Unicode
```

實測：`QUIET EXIT=0 LINES=2 [Ubuntu|docker-desktop]`。`--quiet` 一行一個發行版名、沒有任何發行版時輸出為空，**與語系無關** —— 於是英／中兩條字串比對可以整個刪掉，改成「非空行數 == 0」。`wsl --list` 是唯讀的，不會啟動任何發行版。

### 2.4 V-3（LOW）：輪詢裡的例外沒有接

`Invoke-Cmd` 沒有把 `$proc.Start()` 包 try/catch，exe 起不來時直接丟 Win32Exception（我實測撞到：「系統找不到指定的檔案」）。階梯裡**關機前**那次 `Get-VmRecycleSnapshot` 有 try/catch，**`Wait-VmRecycled` 迴圈裡那次沒有**。真的丟出來的話會在自癒中途穿出 `Invoke-SelfHealLadder`：沒有 `manualRequired` 閂鎖、沒有停手告警。建議同樣包起來，快照失敗一律視為 `pending`。

### 2.5 V-4（LOW）：輪詢的 `docker run --rm alpine` 會留孤兒容器

每次輪詢建一個容器；`Invoke-Cmd` 逾時時 `$proc.Kill()` 殺的是 docker **CLI**，不是容器。daemon 半死時，900 秒可累積約 25 個孤兒容器。

### 2.6 檢查過、確實沒問題的部分

- **900 秒退路與 `manualRequired` 閂鎖完好。** `$VmmemTimeoutSec = 900` 未改且有斷言；`-not $gone` 分支照舊送 Discord 停手訊息、寫 `manualRequired=$true` + `manualRequiredAt`、`Write-WatchdogState`、return。不自動重試。
- **`Scope=vm` 觸發門檻確實沒變。** 兩份 SelfTest 都有斷言；Tier2 `d?{9}` 未動。
- **boot_id 基準的取得時機正確。** `$before` 在 `Start-WslShutdownFireAndForget` **之前**取，包 try/catch，`Captured = $dockerOk`。關機前 docker 已死 → `Captured=false` → boot-id 與 uptime 兩個訊號都放棄，且明確不把「docker 後來又活了」當成汰換（有斷言）。
  **誠實的但書：** 全面崩潰時正是 docker 已死的時候，也就是這個新訊號最派不上用場的時候；退路只剩 vmmem-gone（2026-08-28 已證明不是必要條件）與 wsl-empty（依 V-1 是壞的）→ 走到 900 秒 abort → 叫人。所以修掉 V-1 對這條路徑是有實質意義的，不只是潔癖。
- **wsl 逾時不會被當成 empty。** `Invoke-Cmd` 逾時確實回 `Code=124` 並 `$proc.Kill()`；`Test-WslHasNoRunningDistro` 的 `if ($TimedOut) { return $false }` 是第一道。正確。
- **uptime 訊號有防呆。** `-not $sameBoot` 擋住了「boot_id 相同卻用 uptime 判定」；`aUp -lt bUp` 在 VM uptime 單調遞增下是可靠的。
- **每輪輪詢實際間隔是 5–35 秒**（wsl ≤10s + docker ≤20s + sleep 5），900 秒約 25 次，預算夠。

---

## 3. 老問題：還是第二份實作嗎 — 不是

兩項都收斂到單一判定函式，而且結構鎖是真的（L1383-1397 從原始碼文字區間切出來的）：

- `exactly one Get-ProbeRunDecision` / `exactly one Get-VmRecycleDecision`
- 階梯本體 `-notmatch` `Get-ProbeRunDecision` / `Get-InterventionOutcome` / `Register-SendAttempt` / `VmDegraded` / `Get-VmRecycleDecision`
- 階梯本體必須 `Contains` `Wait-VmRecycled` 與 `Get-VmRecycleSnapshot`
- 主流程必須 `Get-ScopeAction -Scope $scope -VmDegraded`
- 只有一個 `Format-VmDegradedNote` 格式化器
- `Get-InterventionOutcome` 必須 `Get-ProbeRunDecision $Results $Baselines`

兩份 SelfTest 我都跑過，exit 0。**這是四輪以來第一次「加一條新規則」而沒有長出第二條流水線。**

沿用第五輪的但書：這些鎖是文字區間式的，寫在 `Invoke-SelfHealLadder` **之外**的旁路仍然抓不到，只能靠 code review。

---

## 4. GO / NO-GO

| 項目 | 判斷 | 理由 |
|---|---|---|
| **FIX-M0（已上線）** | **GO，繼續跑** | 沒有 blocker。誤報路徑結構上封死（不新增任何告警）；自癒門檻未動；state 陷阱未踩；正式環境已連跑數輪 `LastTaskResult=0`。M-1 當跟進。 |
| **FIX-VMMEM（未上線）** | **NO-GO as-is** | V-1：`wsl --list --running` 因引號被當成「在預設發行版執行指令」，訊號是死碼，且每 5 秒把剛關掉的 VM 拉回來。修法約 4 行。 |

**FIX-VMMEM 的放行條件：**
1. 修 V-1 + V-2：`$psi.Arguments = '--list --running --quiet'` 原樣 + `StandardOutputEncoding = Unicode` + 改判「非空行數 == 0」，刪掉英／中字串比對
2. 修 V-3：`Wait-VmRecycled` 內的快照包 try/catch，失敗視為 pending
3. 補一條 SelfTest：驗證這個呼叫**真的**執行了 `wsl --list`（例如斷言 exit code 為 0 且輸出可解析），而不是只驗純函式
4. 重跑 `-SelfTest` 與 `-DryRun`
