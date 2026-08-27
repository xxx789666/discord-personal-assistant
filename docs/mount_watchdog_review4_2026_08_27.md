# mount-watchdog 第四輪終審（REVIEW-4）— 最終 GO / NO-GO

日期：2026-08-27
範圍：複審 FIX-3，review-only，未修改任何被審查的程式檔（本文件為唯一新增檔）
被審物：`openab/healthcheck/mount-watchdog.ps1`（1623 行）、`register-mount-watchdog.ps1`、`openab/docker-compose.yml`、`.gitignore`
前三輪：`docs/mount_watchdog_review_2026_08_27.md`（第一輪）、第二輪未寫檔、`docs/mount_watchdog_review3_2026_08_27.md`（第三輪）

---

## 結論：**有條件 GO**

**可以搬到 D: 主 checkout 並註冊排程。** 三個 BLOCKER 都實測修好了，而且是真的修好，不是換個地方壞。

條件只有一條，而且是部署動作不是改碼：

> **註冊後 15 分鐘內，人工確認第一次觸發真的跑起來且 `LastTaskResult=0`。**
> 若拿到非 0，先看 `.state\mount-watchdog.log` 最後一段再決定要不要留著排程。

另外有 4 個 MEDIUM 建議上線後儘快補（見 §3），其中 **F-2（exit code 永久黏住 1）會讓上面那條驗收條件在某些情況下失效**，所以我把它排在第一個。它不影響安全性，但它壞掉的正好是你唯一的「監控的監控」訊號。

判斷的分界線和第三輪一樣，但兩邊都往好的方向移動了：

- **「亂動」（誤觸 `wsl --shutdown`）：確認被擋住。** 第三輪逐條追過的七道閘門這一輪沒有被新程式碼繞開，`Scope='vm'` 仍然只有 `Get-Tier2Scope` 一個來源。
- **「說謊」：這一輪從『會』變成『不會』。** 第三輪的 BLOCKER-1（自癒後送假綠燈）已修，正式告警路徑已被 coordinator 實測送達，送失敗不再蓋 throttle 章。

---

## 1. FIX-3 四項宣稱：逐項實跑驗證

全部在本 worktree 實跑。coordinator 已獨立驗證的三件事（正式路徑送達、:1308 改用 `Get-ProbeRunDecision`、TestAlert 硬編 fallback 移除）我沒有重驗，但在 §1.2 / §4 對其中兩件提出補充。

### 1.1 階梯第 7 步不再謊報「全清單可讀」— **真**

用第三輪的 harness 手法：以 `Get-Content -Encoding UTF8` 取出 `mount-watchdog.ps1` 第 91–586 行的**未修改**純函式定義，dot-source 後直接施測（第一次用 `sed` 切檔造成 mojibake 導致 parser error，已改回全程 PowerShell I/O，這是本專案 memory 裡記過的坑）。

| 情境 | 主流程 `Get-ProbeRunDecision` | 階梯 step 7 | 一致 | 舊邏輯會說健康 |
|---|---|---|---|---|
| A. `wsl --shutdown` 後容器尚未復原（3 條全 SKIP，probed=0）**← 第三輪 BLOCKER-1 的時序** | FAIL / unprobed / probed=0 | FAIL / unprobed / Kind=unprobed | ✅ | **True** |
| B. 部分容器復原（1 ok、1 absent） | OK / ok / probed=1 | OK / Kind=ok | ✅ | True |
| C. 9p 仍壞（1 mount-fail、1 ok） | FAIL / mount-fail | FAIL / Kind=mount-fail | ✅ | False |
| D. 真的修好 | OK / ok | OK / Kind=ok | ✅ | True |
| E. 空清單 | FAIL / unprobed | FAIL / Kind=unprobed | ✅ | True |

情境 A 現在送出的是：

```
<@OWNER> ⚠️ mount-watchdog 自癒後仍無法探測：3 條全部 SKIP（probed=0，容器尚未恢復）。這不是成功。
```

**BLOCKER-1 確認修復。** 這是三輪以來第一次，最高風險位置（剛跑完 `wsl --shutdown`）不再送綠燈。

### 1.2 統一設定解析 — **真**

`Resolve-AlertEnvPaths` 在 `:1345` 呼叫，**在 `if ($TestAlert)` 之前**，兩條路徑吃同一組 `$EnvAlert` / `$EnvTokens`。TestAlert 專屬硬編 fallback 已不存在（全檔 grep `KnownCheckoutLocal` / `KnownLocal` 只剩 `:28` 常數、`:255/259/270` 函式預設值、`:1345` 唯一呼叫點）。

實跑正式路徑（`-DryRun`，worktree）印出：

```
[CFG] alert env=D:\discord 個人助理\.local\infra_alert.env
[CFG] token env=D:\discord 個人助理\.local\discord_token.env
```

也就是 worktree 的 `.local\` 只有 `.example` 時，正式路徑會落到 D: 的實檔——這正是 coordinator 那則 11:09:40Z 訊息能送出的原因，**第三輪 BLOCKER-2 的「正式路徑一則都送不出去」已解除**。

### 1.3 `lastAlertAt` 只在 HTTP 2xx 才蓋 — **真**

用**真實頻道 ID ＋ 假 token** 打出真的 401（不是模擬）：

```
[STATE] prev=OK new=FAIL scope=container alert=fail send=True probed=2
[WARN] Discord send failed HTTP 401: ... (not stamping lastAlertAt)
[WARN] Discord send failed this run (count=1 error=exception); timestamps not stamped
EXIT=1
```

狀態檔：`lastAlertAt: null`、`lastResidentAlertAt: null`、`lastAllDownAlertAt: null`、`discordFailCount: 1`、`status: "FAIL"`。**與宣稱完全一致。** 這條是第三輪 MEDIUM-4，本專案踩過同型的坑（Claude OAuth 自我清空），修對了很重要。

> ⚠️ **這次測試有真實副作用，據實記錄**：我在 mounts.json 裡用了真實容器名配假路徑，觸發 `Scope=container → restart-failed`，實際 `docker restart` 了 `openab-url-intake` 與 `openab-estate`。兩者已確認回到 Running，事後全 12 條掛載複驗 12/12 `OK`。後續測試全部改用 ghost 容器名。

### 1.4 all-down 2 tick 寬限 — **真**

3 個不存在的容器，連跑 3 tick（獨立 StateDir）：

| tick | log | state |
|---|---|---|
| 1 | `[NOTE] all-down 1/2` → 無 INFO 送出 | `status=OK scope=all-down consecutiveAllDown=1` |
| 2 | `[NOTE] all-down 2/2` → `[INFO] all containers absent` | `consecutiveAllDown=2` |
| 3 | `[NOTE] all-down 3/2` → `[INFO]`（本次頻道未設定故未送） | `consecutiveAllDown=3` |

tick1 `new=OK send=False` 與宣稱一致。`[ACTION]` 完全沒出現——**不重啟、不自癒**，符合設計。

---

## 2. 系統性檢查：還有沒有第四個地方？

這是本輪最重要的一題。我把全檔所有「判斷整體是否健康」的位置列出來逐一確認。

### 2.1 判定「整體是否健康」的全部位置

| # | 位置 | 判定什麼 | 依據 | 是否單一來源 |
|---|---|---|---|---|
| 1 | `:1404` 主流程 | 本輪整體健康 | `Get-ProbeRunDecision` | ✅ 來源本身 |
| 2 | `:1308` 階梯 step 7 | 自癒後健康（決定訊息文字） | `Get-ProbeRunDecision` → `Get-HealStep7Notice` | ✅ 本輪修好 |
| 3 | `:1496` 自癒後回主流程 | 自癒後健康（決定 status） | `Get-ProbeRunDecision` | ✅ |
| 4 | `:1510` 重啟容器後 | 重啟後健康 | `Get-ProbeRunDecision` **＋ `Test-PreviousFailsNowOk`** | ✅ 最嚴格 |
| 5 | `:1438` all-down 判定 | 是否為維護而非事故 | `Get-AllDownDecision($decision.Reason, $scope)` | ✅ 衍生自 #1 |
| 6 | `:1424` daemon 寬限 | 是否寬限一輪 | `$newStatus` + `$scope` | ✅ 衍生自 #1 |
| 7 | `:1603` 清 manualRequired 閂鎖 | 是否可解閂 | `$decision.ClearLatch` | ✅ 衍生自 #1 |
| 8 | `:1619` exit code | 是否非 0 | `$newStatus` + `discordFailCount` | ✅ 衍生（但見 F-2） |

**沒有第四個地方在用 `Get-MountFailResults.Count` 或等價的「沒有 fail 就等於健康」。** 全檔 `Get-MountFailResults` 只剩三種正當用途：`Get-ProbeRunDecision` 內部（`:217`）、`Get-HealStep7Notice` 在已知是 mount-fail 分支時數數（`:315`）、`Invoke-ContainerRestart` 挑要重啟哪些容器（`:1318`），以及 `$failed` 拿去組訊息／寫 `failedMounts`（皆與 `$decision` 同源同批資料）。

**「整體是否健康」這件事，單一來源達成了。**

### 2.2 但是——同一個病換了個器官（F-1）

真正該問的不是「還有沒有第四個地方用舊判定」，而是「**這個錯誤為什麼躲得過三次修復**」。答案是結構的，不是某一行的：

> `Invoke-SelfHealLadder` 是「探測 → 判定 → 通知 → 記帳」這整條流水線的**第二份實作**。
> 每次主流程加一條新規則，都得手工鏡射一份到階梯裡，而每一輪都**剛好漏掉一份**。

- 第二輪加「probed==0 算 FAIL」→ 主流程有，階梯沒有 → 第三輪 BLOCKER-1
- 第三輪修好 BLOCKER-1（本輪確認）
- **本輪 FIX-3 加了兩條新規則，兩條都又只加在主流程：**

**F-1a：`Test-PreviousFailsNowOk` 只加在重啟路徑，沒加在自癒階梯。**

同一批資料餵給兩條路徑，結論相反（harness 實測）：

```
情境：先前 3 條全 mount-fail；自癒後 1 條 ok、2 條仍 absent
  Get-ProbeRunDecision    : Status=OK Reason=ok Probed=1 ClearLatch=True
  Test-PreviousFailsNowOk : False        <-- 先前失敗的那幾條根本沒複驗

  [路徑 A] Invoke-ContainerRestart 之後 (:1512 有用)  → 宣告已修復? False   ✅
  [路徑 B] 自癒階梯 step 7        (:1308 沒用)        → 宣告已修復? True    ❌
     送出：<@OWNER> ✅ mount-watchdog 自癒完成：Tier 1 全清單可讀。
     主流程 :1496 隨後 newStatus=OK、ClearLatch=True → manualRequired 閂鎖被清掉
```

觸發時序和 BLOCKER-1 同一個：step 6 只要 `docker run -v D:/... alpine ls /vault` 通過就往下走，而 `restart: unless-stopped` 的 12 個容器是非同步回來的。只要**恰好有 1 個**回來且可讀，step 7 就送「全清單可讀」——這句話在 probed=1/12 時字面上就是假的。

**嚴重度 MEDIUM，不是 blocker。** 理由：5 分鐘後下一輪會重測全部 12 條，若 9p 其實沒好會翻回 FAIL 並重新告警（`prev=OK → new=FAIL` 不受 throttle 影響，因為 `lastAlertAt` 只在成功送出時才蓋）。所以會自我修正。代價是一則假綠燈訊息＋閂鎖白清一次（但 24h 2 次上限與 60 分鐘冷卻仍在）。

**F-1b：`Register-SendAttempt` 記帳漏了階梯裡全部 4 個送出點。**

```
:1253  Send-WatchdogNotice「我要開始跑 wsl --shutdown 了」        ← 無 Register
:1269  Send-WatchdogNotice「vmmemWSL 900s 沒消失，需人工介入」    ← 無 Register
:1284  Send-WatchdogNotice「找不到 Docker Desktop.exe，需人工」   ← 無 Register
:1298  Send-WatchdogNotice「600s 仍無法 ls，需人工介入」          ← 無 Register
:1311  step 7 結果                                                ← 有 ✅
主流程 6 個送出點                                                  ← 全部有 ✅
```

10 個送出點漏了 4 個，而且**漏掉的正好是整個系統最重要的四則訊息**：三則「我停手了，需要你親自處理」，一則「我要動 WSL 了」。這四則若送失敗，`discordFailCount` 不會加、`WatchdogSendFailed` 不會設，只剩 log 裡一行 `[WARN]`。

**嚴重度 MEDIUM，不是 blocker。** 三個 abort 分支都會先寫 `manualRequired=true` 再 return（實測 §1.3 的狀態持久化機制有效），也就是**失敗方向是安全的：自癒被永久閂掉，不會反覆重試**；而且主流程隨後仍 `newStatus=FAIL → exit 1`。所以不會靜默地繼續亂動，只會靜默地停手。

**終結這個 pattern 的修法**（建議，不是上線條件）：讓 `Invoke-SelfHealLadder` **只回傳原始 `$results`**，把判定與送訊息全部交還主流程。現在階梯同時負責 judge 和 send，這就是三輪漏修的結構性根因。

---

## 3. 新增的東西帶來的新問題

### F-2（MEDIUM，建議最優先修）— `discordFailCount` 會把 exit code 永久黏在 1

**實測**：把狀態檔的 `discordFailCount` 設為 5，其餘一切正常，連跑兩輪：

```
[T1] openab-astruct /workspace/AStructSpace => OK (OK)
[STATE] prev=OK new=OK scope= alert=none send=False probed=1
TICK1: EXIT=1  status=OK discordFailCount=5
TICK2: EXIT=1  status=OK discordFailCount=5
```

一切健康、1/1 探測成功、沒有任何告警需要送——**exit 仍然是 1，而且 log 裡沒有任何一行說明為什麼**（`[WARN] Discord send failed this run` 只在本輪真的送失敗時才印）。

原因：`Register-SendAttempt` 只在「有意送出」時被呼叫，而計數只在**成功送出**時歸零（`:1170`）。系統健康時不會有任何告警要送，所以計數永遠不會歸零，`:1621` 的 `if ($WatchdogFailCount -ge 3) { exit 1 }` 就永久成立。

觸發路徑很現實：Discord token 過期（本專案踩過）→ 15 分鐘內累積 3 次失敗 → 你換好 token → 但故障也已經自己好了 → 沒有告警要送 → **計數永遠停在 3，排程工作永遠顯示失敗**。

這正好毀掉 coordinator 問的那個問題的答案。修法二選一：健康輪（`newStatus=OK` 且無待送告警）時把計數歸零；或改記「連續失敗輪數」而非「累計次數」。

### 回答：`discordFailCount` 會不會無限增長？

會，但不是溢位問題。真正的問題是上面的黏住。

- 上限：`[int]`，5 分鐘一次要約 20000 年才溢位，**實務上不會爆**。
- 但**每 tick 加 1**：實測 all-down 情境下頻道未設定，count 1 → 2 → 3…每輪都加。Discord 真的掛掉時就是每天 +288。
- 順帶：`consecutiveAllDown` 同樣無上限（實測 1→2→3…），只拿來跟 2 比大小，無害，但同一類。

### 回答：除了 EXIT=1 之外有沒有辦法讓人真的知道？

**目前沒有。** 這是本輪最大的殘留缺口，而且 F-2 讓僅有的那個訊號也不可靠。

現況三個訊號全部都不會主動觸達使用者：
1. exit code → 只在 `Get-ScheduledTaskInfo` 的 `LastTaskResult`，沒人會去看，且會被 F-2 黏住
2. `.state\mount-watchdog.log` 的 `[WARN]` → 沒人會去看
3. `lastDiscordError` 寫進狀態檔 → 沒人會去看

**建議（上線後補，非 GO 條件）**：連續失敗達 3 次時寫一筆 Windows 事件記錄檔——`Write-EventLog -LogName Application -Source 'OpenAB-MountWatchdog' -EntryType Error`。這是唯一不依賴 Discord 本身、又能被既有 Windows 工具（事件檢視器、`Get-WinEvent`）看到的頻道。次佳：在 `D:\discord 個人助理\` 根目錄放一個 `MOUNT-WATCHDOG-ALERT-FAILED.txt`，使用者開資料夾就會看到。

### 回答：all-down 2 tick 寬限（＝10 分鐘）會不會延誤真實故障？

**不會。coordinator 的推論正確，我從程式碼與實測兩邊確認：**

`Get-AllDownDecision` 只在 `Reason='unprobed'` **且** `Scope='container'` 時 Active。這兩個條件同時成立需要：

1. `Reason='unprobed'` ⇒ `probed=0` ⇒ **12 條全部是 `absent` 或 `stopped`** ⇒ 一個容器都沒在跑。
   真實 9p 崩潰時容器**仍在 Running**（本專案 2026-08-27 事故的紀錄就是「healthcheck 顯示 healthy 但檔案系統已死」），`docker exec` 打得進去，`timeout 10s ls` 卡住回 124 → `Get-MountVerdict` 判 `mount-fail` → `Reason='mount-fail'` ⇒ **all-down 分支根本不會 Active**。
2. `Scope='container'` ⇒ Tier2 `ls -la /run/desktop/mnt/host/` **exit=0 且輸出沒有 `d?????????`** ⇒ 9p 是活的。
   9p 死掉會讓 `-la` 對 `d` 的 stat 失敗印出 `d?????????` → `Scope='vm'`；若是卡住而非報錯 → 30s 逾時 → exit≠0 → `Scope='daemon'`。**兩者都不是 `container`。**

也就是說：**「9p 壞了」和「all-down 寬限」在邏輯上互斥**，10 分鐘寬限只會套用在「Docker 好好的、9p 好好的、但容器一個都不在」——那確實就是 `compose down` / 維護。

值得知道的副作用（可接受）：這也表示 all-down 寬限會延誤「容器全部意外掛掉但基礎設施正常」的通報 10 分鐘，且通報是 ℹ️ 級不 @ 人。第二道保險是 30 分鐘的常駐容器告警（`Get-ResidentDownNotice`，獨立於掛載判定，實測有效）。

### 回答：`Resolve-AlertEnvPaths` 在正式部署會不會解析到非預期的檔案？

**不會。** 實測正式版面：

```
PSScriptRoot = D:\discord 個人助理\openab\healthcheck
  => $Root   = D:\discord 個人助理
  候選順序   = D:\discord 個人助理\.local\infra_alert.env  |  D:\discord 個人助理\.local\infra_alert.env
  AlertPath  = D:\discord 個人助理\.local\infra_alert.env   exists=True
  TokenPath  = D:\discord 個人助理\.local\discord_token.env  exists=True
```

正式部署時**兩個候選塌縮成同一個路徑**，沒有優先序可爭議。`$KnownCheckoutLocal` 那條 fallback 在正式部署下是死碼（只有從別的 checkout 跑才會用到）。

一個 LOW 邊界：`$Root` 為空字串時（dot-source 或 `powershell -Command` 執行，`$PSScriptRoot` 為空）`Join-Path` 會直接拋例外。`register-mount-watchdog.ps1:19` 用的是 `-File`，`$PSScriptRoot` 必定有值，所以排程路徑不受影響；而 `$ErrorActionPreference='Stop'` 讓它在寫任何狀態檔之前就死掉，方向安全。只是錯誤訊息不好懂。

---

## 4. 硬編路徑：`:28 $KnownCheckoutLocal` 與 `:85 $HostVaultProbe`

**建議：兩個都維持硬編，不要參數化。但 `$HostVaultProbe` 應該加一條 SelfTest 斷言。**

理由：

**`:85 $HostVaultProbe = 'D:/discord 個人助理/URLIntake'`** 不是「不必要的硬編」，它是整個系統既有硬編的一部分。`docker-compose.yml` 本身就有 11 行硬編 `D:/discord 個人助理/...`（實測列出），`$Mounts` 也硬編了 12 組容器名與路徑。單機部署下把它參數化只是把同一份事實搬到第 13 個地方，反而多一個會不同步的來源。實測 `$HostVaultProbe` 與 `docker-compose.yml:113` / `:382` 的 bind source 逐字相符，今天 `docker run --rm -v "D:/discord 個人助理/URLIntake:/vault" alpine ls /vault` 也確認跑得通。

**但它有一個安靜的失效模式值得防**：這個常數只在自癒階梯 step 6 用到（`:1235`）。如果哪天 vault 搬家而這裡忘了改，症狀不是「報錯」，而是**在真實事故當下、剛跑完 `wsl --shutdown` 之後，卡滿 600 秒然後宣告 `abort-mount` + `manualRequired=true`**——把一次本來能自動復原的事故變成需要人工介入，而且是在最糟的時間點。

所以建議加一條 SelfTest 斷言：`$HostVaultProbe` 必須出現在 `docker-compose.yml` 的某個 bind source 裡（SelfTest 已經在讀 compose 做類似的交叉比對，成本幾乎是零）。這樣路徑漂移會在 SelfTest 就大聲失敗，而不是在事故現場安靜地失敗。

**`:28 $KnownCheckoutLocal`** 純粹是 fallback，正式部署下是死碼（見 §3）。留著的好處是任何 checkout／worktree 都能跑 `-TestAlert` 驗證告警鏈——這一輪和上一輪的驗證都靠它。留著。

---

## 5. 最終 GO / NO-GO

### **有條件 GO** — 可以合併到 D: 主 checkout 並註冊排程

#### (a) 為什麼相信它不會誤觸 `wsl --shutdown`

不是因為「看起來還好」，是因為只有一條路能走到那裡，而那條路我逐段確認過本輪沒有被改動或繞開：

1. `Scope='vm'` 全檔**唯一**來源是 `Get-Tier2Scope`（`:131`），條件是 Tier2 `ExitCode -eq 0` **且**輸出符合 `d\?{9}`。本輪實跑 Tier2 三次，真實輸出是正常的 `c / d / wsl / wslg` 目錄列表，判 `container`。
2. `Get-ScopeAction 'vm' → 'self-heal'` 是 `Invoke-SelfHealLadder` 的唯一呼叫點（`:1477-1499`）。
3. **失敗方向全部安全**：Tier2 因任何理由失敗或逾時 → `daemon` → `alert-only`。9p 若是「卡住」而非「報錯」，`ls -la` 會逾時 → 也是 `daemon` → 不自癒。
4. 新增的 all-down 分支**把 `newStatus` 設成 `OK`**（`:1443`），直接跳過整個 `if ($newStatus -eq 'FAIL')` 自癒區塊——實測 `[ACTION]` 一次都沒印。新程式碼是往「更不會動」的方向走。
5. 四道閂仍在：24h 上限 2 次、60 分鐘冷卻、`manualRequired` 閂鎖、`-DryRun`。三個 abort 分支都先寫閂再 return。

**誠實的但書**：`d?????????` 這個唯一觸發條件從頭到尾只用合成字串測過。真實 9p 崩潰若表現為「卡住」而非「報錯」，自癒**永遠不會啟動**，watchdog 會降級成純告警器。這對「不亂動」是加分，但代表**自癒能力本身仍是未驗證的**。上線後第一次真實事故就是它的現場驗收。

#### (b) 為什麼相信它不會在真故障時靜默

- 正式（非 TestAlert）路徑已由 coordinator 實測送達 #infra-alerts（11:09:40Z）。第三輪那個「唯一送達證據走的是 TestAlert 專屬分支」的缺口已關閉，我從程式碼確認 `Resolve-AlertEnvPaths` 在 `if ($TestAlert)` **之前**呼叫，兩條路徑共用同一組解析結果。
- 送失敗不再蓋 throttle 章（§1.3 真 401 實測）：`lastAlertAt` 保持 null ⇒ 下一輪仍會重送。**Discord 壞掉不會讓 watchdog 永久靜音**，這是原始事故的同型病，修對了。
- probed=0 不再被當成健康（§1.1、§2.1），latch 保住，不送假 recovered。
- 真實 9p 崩潰走 `mount-fail` 而非 all-down（§3 已從邏輯與實測兩邊確認），**寬限不適用，第一輪就 `send=True`**。

**殘留的靜默風險已知且有界**：F-1b 的四則階梯訊息送失敗不記帳（但仍 exit 1 且已閂掉自癒）；F-2 讓 exit code 這個訊號可能永久黏住。兩者都不會讓「掛載壞了」這件事本身被吞掉——主流程的告警每 5 分鐘都會重試。

#### (c) 為什麼相信它在正常時不會洗版

- 實測正常狀態 12/12 `OK`、`probed=12`、`alert=none send=False`、2.3–2.7 秒，不送任何訊息。
- 第三輪的 HIGH-3（`compose down` 維護會每小時誤報一次帶空條列的 FAIL）**已修**：現在走 all-down，ℹ️ 級、不 @、60 分鐘節流、不重啟不自癒。長時間維護每小時最多 2 則 info（all-down ＋ 常駐容器），不是 FAIL 洗版。
- throttle 邏輯本身沒動（`Get-AlertAction`，60 分鐘），SelfTest 覆蓋。

**已知的洗版風險，我認為值得你知道但不擋上線**：`DaemonConfirmCount=2` ＝ 10 分鐘寬限。若某次開機／休眠喚醒後 Docker Desktop 超過 10 分鐘才回應，會送一則 `Scope=daemon` 的 FAIL，Docker 起來後再送一則「已恢復」。一次重開機兩則。若第一週觀察到這件事真的發生，把 `DaemonConfirmCount` 調到 4（20 分鐘）即可，是一個常數。

#### 上線條件（只有一條，是部署動作）

1. 把 `mount-watchdog.ps1` 與 `register-mount-watchdog.ps1` 放到 `D:\discord 個人助理\openab\healthcheck\`，**從那裡**執行 `register-mount-watchdog.ps1`（`$PSScriptRoot` 決定排程指向誰；從 worktree 註冊會指向一次性目錄）。
2. 註冊前先在該目錄跑一次 `-SelfTest`（應 `SelfTest PASSED` / exit 0）與一次 `-DryRun`（應 12/12 `OK`、`[CFG] alert env=D:\...`）。
3. **註冊後 15 分鐘內**：`Get-ScheduledTaskInfo OpenAB-MountWatchdog` 確認 `LastRunTime` 有更新且 `LastTaskResult=0`，並確認 `D:\discord 個人助理\openab\healthcheck\.state\mount-watchdog.log` 有新的 `=== mount-watchdog run ===` 區塊。

#### 建議儘快補（非上線條件，依序）

| # | 項目 | 為什麼 | 成本 |
|---|---|---|---|
| F-2 | 健康輪把 `discordFailCount` 歸零（或改記連續失敗輪數） | 否則 exit code 永久黏 1，毀掉上面第 3 點的驗收訊號 | 一行 |
| F-3 | 連續送失敗 ≥3 時 `Write-EventLog` 或落一個顯眼的檔案 | 目前 Discord 掛掉時使用者**沒有任何**會主動看到的訊號 | 小 |
| F-1a | 階梯 step 7 加上 `Test-PreviousFailsNowOk`；`Get-HealStep7Notice` 的成功文字改成帶 `probed=N/M` | 消掉最後一處「一條 ok 就宣告全清單可讀」 | 小 |
| F-1b | 階梯 4 個送出點補 `Register-SendAttempt` | 最重要的四則訊息目前不記帳 | 4 行 |
| F-4 | SelfTest 斷言 `$HostVaultProbe` 出現在 compose bind source | 路徑漂移會在事故現場才安靜失敗（§4） | 小 |
| F-5 | 註冊時加 `-ExecutionTimeLimit (New-TimeSpan -Hours 1)` | 目前預設 72 小時；配 `IgnoreNew`，一次卡死會擋掉之後所有觸發 | 一行 |
| — | 修 `acceptance:165`（與 all-down 新語意矛盾）與 `acceptance:396`（寫 300s，程式是 900s） | 文件漂移，第三輪 LOW-9 未處理 | 小 |

---

## 6. 上線後第一週應該人工確認什麼

自動測試抓不到的，都是「時間」與「真實時序」相關的。按優先序：

**Day 1（註冊當天）**

1. **排程真的被觸發**：`Get-ScheduledTaskInfo OpenAB-MountWatchdog` 的 `LastRunTime` 每 5 分鐘前進、`LastTaskResult=0`。這是唯一自動測試不可能驗的東西（第三輪把它列為必驗，至今仍未驗）。
2. **log 有在長也有在轉檔**：`.state\mount-watchdog.log` 每 5 分鐘一個新區塊；接近 5MB 時確認輪替真的發生（`$LogMaxBytes` 從未在真實累積下驗過）。
3. **狀態檔欄位跨輪存活**：連看兩三輪的 `mount-watchdog.json`，確認 `notRunningSince` / `consecutiveFail` / `discordFailCount` 沒有被清成空——第一輪的 bug 就是欄位被固定清單洗掉。

**Day 1–2**

4. **重開機／休眠喚醒後的行為**（自動測試完全碰不到）：重開機一次，看有沒有收到 `Scope=daemon` 的假 FAIL。若有，`DaemonConfirmCount` 從 2 調到 4。同時確認 `LogonType Interactive` 的排程在重新登入後真的自己恢復。
5. **確認正式路徑真的還會送**：`lastAlertAt` 是 `null` 表示「從未成功送過任何告警」。第一週結束前若一則都沒送過，就主動跑一次 `-TestAlert` 驗證告警鏈還活著。**不要把「很安靜」當成「很健康」**——這正是原始事故的形狀。

**Day 2–7**

6. **一次計畫性維護的真實觀察**：下次 `docker compose down` / `up -d` 時盯著 Discord。應該看到 ℹ️ all-down（約 10 分鐘後），**不應該**看到 ⚠️ FAIL 或任何 `[ACTION] restart`。這是 §1.4 在真實 compose 而非 ghost 容器下的驗收。
7. **`start_period: 60s` 生效**：下次 `up -d` 後 `docker inspect` 確認不再是 `0s`（目前 live 仍是 0s，compose 改了但沒套用）。順帶確認新的 10 個 healthcheck 不會把容器判成 unhealthy。
8. **看一次完整的 log 而不是只看 Discord**：`Select-String '\[WARN\]|\[SKIP\]|\[NOTE\]' .state\mount-watchdog.log`。F-1b／F-2 的所有症狀只會出現在這裡。特別找 `no-channel`、`no-token`、`Discord send failed`。

**第一週結束時該回答的一個問題**

> 這七天裡，watchdog 有沒有送出過**任何一則**訊息？

- 有 → 告警鏈端對端驗證完成。
- 沒有 → 你只驗證了「它沒有洗版」，**還沒驗證「它會說話」**。跑一次 `-TestAlert`，並考慮做一次刻意的 `docker stop openab-astruct` 放 35 分鐘，看常駐容器告警是否如期送達。

---

## 附：本輪怎麼跑的

未修改任何被審查的程式檔。未執行 `wsl --shutdown`、未殺任何行程、未註冊排程、未觸碰正式狀態檔（全部用 `-StateDir` 導到 scratchpad）。

- `-SelfTest` → `SelfTest PASSED`，exit 0
- `-DryRun` 正式 12 掛載 ×2 → 12/12 `OK`、`probed=12`、2.3s／2.7s
- purefn harness（`Get-Content -Encoding UTF8` 取原檔 91–586 行未修改的函式定義 dot-source）→ §1.1 五情境、§2.2 F-1a 對照
- 真實頻道 ID ＋ 假 token 打出真 401 → §1.3（**副作用：實際 restart 了 2 個容器，已確認復原**）
- ghost 容器 ×3 連跑 3 tick → §1.4 all-down 寬限
- 人工植入 `discordFailCount=5` 後跑健康輪 ×2 → §3 F-2
- `Resolve-AlertEnvPaths` 三種 `$Root`（正式／worktree／空字串）→ §3
- `docker run --rm -v "D:/discord 個人助理/URLIntake:/vault" alpine ls /vault` → 確認自癒 step 6 探測今天可用
- `git check-ignore -v` 驗 `.gitignore` 新規則：三個真實 env 檔仍被忽略、只有 `.example` 進版控，無外洩
