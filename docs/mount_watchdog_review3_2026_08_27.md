# mount-watchdog 第三輪複審（REVIEW-3）— GO / NO-GO

日期：2026-08-27
範圍：複審 FIX-2，review-only，未修改任何程式檔（本文件為唯一新增檔）
被審物：`openab/healthcheck/mount-watchdog.ps1`（1336 行）、`register-mount-watchdog.ps1`、`openab/docker-compose.yml`
前兩輪：`docs/mount_watchdog_review_2026_08_27.md`（第一輪 A1）、第二輪未寫檔（A1 修法製造 unprobed 靜默）

---

## 結論：**NO-GO（現狀）→ 修完 3 項後 GO**

**現在不要註冊排程。** 但要修的東西很小，不是設計問題。

判斷的分界線是這樣的：**這個 watchdog 不會亂動，但它會說謊。**

- 「亂動」＝誤觸 `wsl --shutdown`。我逐條追過所有能走到自癒的路徑（下方 §3），**沒有一條**能在 9p 健康時走到 `Scope=vm`。這條最壞情況已經被擋住了。
- 「說謊」＝在故障還在的時候送出綠燈訊息，然後靜音 60 分鐘。**這件事目前仍然會發生，而且就發生在剛剛 `wsl --shutdown` 完的那一刻**（BLOCKER-1）。再加上正式路徑其實一則 Discord 都送不出去（BLOCKER-2），現在上線等於裝了一個安靜的監控。

第二輪的教訓在 FIX-2 裡**只修了主流程，沒修自癒階梯**。同一個判定錯誤在 `Invoke-SelfHealLadder` step 7 原封不動地活著。

### GO 的條件（依序，全部做完才註冊）

| # | 必修項 | 為什麼非修不可 | 成本 |
|---|---|---|---|
| 1 | **BLOCKER-1**：ladder step 7 改用 `Get-ProbeRunDecision`，別再用 `Get-MountFailResults.Count -eq 0` 當成功判準 | 它在風險最高的位置（wsl --shutdown 之後）送假綠燈，然後 60 分鐘靜音 | 一行等級 |
| 2 | **BLOCKER-2**：先把兩支腳本落到 `D:\discord 個人助理\openab\healthcheck\`，從**那裡**註冊；註冊後跑一次非 DryRun，確認 log 出現 `[ALERT] Discord sent HTTP 200`，而不是 `[SKIP] no alert channel configured` | 現在從 worktree 註冊 → 任務指向一次性目錄，且**告警一則都不會發**（已實測） | 搬檔＋一次驗證 |
| 3 | **MEDIUM-4**：只有 Discord 真的回 2xx 才更新 `lastAlertAt` / `lastResidentAlertAt` | 目前送失敗也照樣蓋 throttle 章。token 一過期 watchdog 就永久靜音——本專案已經踩過一次同型的坑（Claude OAuth 自我清空） | 小 |

**HIGH-3（維護誤報）可以先上線再修**：它只造成吵，不會誤觸自癒（實測 `restart-failed skipped`）。但如果近期會做 compose 維護，它會每小時 @ 你一次，建議一併處理。

---

## 1. FIX-2 七項宣稱：逐項實跑驗證

全部在本 worktree 實跑，不是讀報告。TestAlert 送達由 coordinator 獨立驗證，未重驗。

| # | 宣稱 | 結果 | 證據 |
|---|---|---|---|
| 1 | 0 probed 算 FAIL（跑 Tier2、保留 latch、絕不發假 recovered） | 真 | SelfTest `all skip => FAIL` 等 6 條；實跑假容器 → `[PROBE] reason=unprobed probed=0` / `[STATE] new=FAIL` |
| 2 | Optional 語意翻轉 + 常駐容器 30m 資訊告警 + 60m 節流 | 真 | 兩輪實跑：run1 `notRunningSince` 只收非 Optional 兩筆、`ghost-opt` 被排除；回填 -31m 後 run2 觸發 `[INFO] resident container down >30m` |
| 3 | `-MountsFile` / `-StateDir` / `-TestAlert` | 真 | 三個參數都實際驅動了本次全部測試 |
| 4 | GNU timeout-124 探測分支 | 真 | SelfTest `running+exec timeout => mount-fail`；程式內層 `timeout 10s ls`，rc=124 → `exit 124` |
| 5 | compose `start_period:60s` 寫入但未 `up -d`（live 仍 0s） | 真 | `grep -c 'start_period: 60s'` = 10；`docker inspect` kiro/estate/url-intake 全部 `0s` |
| 6 | 排程 5 分鐘、`Tier1TimeoutSec` 15 | 真 | register 腳本 `New-TimeSpan -Minutes 5`；常數確認。`Get-ScheduledTask OpenAB-MountWatchdog` → **NOT REGISTERED**（尚未上線，正確） |
| 7 | TestAlert 不動狀態檔 | 真，**並補驗失敗路徑** | 用假 token 打出 HTTP 401 後：state SHA256 未變、log bytes `23654 → 23654` 未變。成功與失敗兩條路都只用 `Write-Host` |

SelfTest：`SelfTest PASSED`，exit 0。
DryRun（正式 12 掛載）：12/12 `OK`，`probed=12`，耗時 **2.67s**。

**第一輪的陷阱沒有以新形式復活。** `Write-WatchdogState` 的固定清單已包含 `notRunningSince` / `lastResidentAlertAt` / `consecutiveFail`，`Read-WatchdogState` 也讀得回來；實測跨兩次執行沒有被清掉。ladder 中途寫入的欄位也靠結尾的 `$base = Read-WatchdogState $StateFile` 保住了。

---

## 2. 這一輪找到的組合 bug

### BLOCKER-1（嚴重）— 自癒階梯 step 7 把 A1 的舊 bug 原封不動留著（`mount-watchdog.ps1:1082-1092`）

主流程用 `Get-ProbeRunDecision`（會檢查 probed 是否為 0），**階梯不用**：

```powershell
$results = Invoke-Tier1Probe
$remain = Get-MountFailResults $results     # 只問「有沒有 mount-fail」
if ($remain.Count -eq 0) {
  $msg = "自癒完成：Tier 1 全清單可讀。"     # 一條都沒探到時也會送
}
```

**觸發時序（很可能發生，不是理論）**：step 6 的 `Wait-HostMountReadable` 只要 `docker run --rm -v ... alpine ls /vault` 成功就往下走。Docker Desktop 重開後，daemon 一邊接受 API 一邊非同步復原 `restart: unless-stopped` 的容器——`docker run` 會先通，12 個應用容器不見得都回到 Running。此時全部 `absent`/`stopped` → `mount-fail` 數 = 0 → 送綠燈。

**實測證明**（用未修改的原函式，`purefn` harness）：

```
LADDER  : failN=0  -> "自癒完成：Tier 1 全清單可讀" (FALSE)
TRUTH   : Get-ProbeRunDecision => Status=FAIL Reason=unprobed Probed=0
```

**後果鏈**：主流程之後**確實**算出 `FAIL/unprobed`，狀態檔是對的、latch 保住了——但使用者在 Discord 上收到的最後一則訊息是綠燈。而 `$alert` 在本輪開頭就已計算並送出，`lastAlertAt` 已蓋章，接下來每 5 分鐘的 `prev=FAIL new=FAIL` 全部 `throttled`。**綠燈 + 60 分鐘靜音**，正好是第二輪要防的東西，只是搬到了剛執行完 `wsl --shutdown` 的那一刻。

值得注意的是：`Invoke-ContainerRestart` 那條平行路徑**有**改用 `Get-ProbeRunDecision`。所以 FIX-2 是把同一個修法套用得不一致，漏了風險最高的那條。

---

### BLOCKER-2（嚴重）— 現在註冊，會註冊到一次性 worktree，而且一則告警都發不出去

`register-mount-watchdog.ps1:18` 用 `$PSScriptRoot`：從哪裡跑就註冊哪裡。從本 worktree 註冊 → 任務指向 `C:\Users\xx\orca\workspaces\...\mount-watchdog\...`，worktree 一收掉任務就壞。

更嚴重的是告警：worktree 的 `.local/` **只有 `infra_alert.env.example`**，沒有實檔，也沒有 `discord_token.env`。實跑正式路徑印的是：

```
[STATE] prev=OK new=FAIL scope=container alert=fail send=True probed=0
[SKIP] no alert channel configured        <- 判定正確，訊息沒送出去
```

**TestAlert 之所以會成功，是因為它有一段只在 TestAlert 生效的硬寫死 fallback**（`:1121-1127`，找不到就改指 `D:\discord 個人助理\.local\`）。正式路徑沒有這段。所以 coordinator 驗過的那則 18:43 訊息，**不能拿來推論正式告警會送達**——它走的是不同的 env 解析分支。

修法：把 `mount-watchdog.ps1` / `register-mount-watchdog.ps1` 放進 `D:\discord 個人助理\openab\healthcheck\`（該目錄目前只有 `claude-oauth-check.ps1`），從那裡註冊。`D:\discord 個人助理\.local\infra_alert.env` 已存在且設定正確。

---

### HIGH-3 — 計畫性維護（`docker compose down`）會立刻誤報，並每小時 ping 一次

這正是題目問的那個情境。實測：

```
[T1] ghost-a /vault => SKIP (container absent)      x3
[T2] exit=0 scope=container
[PROBE] reason=unprobed probed=0 scope=container
[STATE] prev=OK new=FAIL scope=container alert=fail send=True probed=0
[ACTION] restart-failed skipped (no mount-fail rows)
```

關鍵在於 **scope 是 `container` 不是 `daemon`**——daemon 掛掉時 Tier2 會失敗，但維護時 daemon 活著、Tier2 exit=0 且看得到 host mnt。所以 `DaemonConfirmCount=2` 的兩次確認 grace **完全不適用**，第一輪就 `send=True`。

送出的訊息是 `<@owner> mount-watchdog 掛載檢查失敗（Scope=container）` 後面接**空的條列**（`Format-FailList` 對空清單回空字串），然後每 60 分鐘重複一次，直到維護結束。30 分鐘後常駐容器資訊告警再來第二串。

**不危險**：`restart-failed skipped (no mount-fail rows)` 實測擋住了重啟，`Scope` 不可能是 `vm`，所以不會自癒。純粹是誤報。

但它和驗收文件直接衝突——`docs/mount_watchdog_acceptance_2026_08_27.md:165` 明寫「使用者關掉的容器正確結論是 `SKIP (not running)`，**不是** `Scope=container`」。FIX-2 的 probed==0 規則讓「全部關掉」變成了 `Scope=container`。程式與驗收文件現在互相矛盾，**得挑一邊**。

建議修法：probed==0 **且** Tier2 exit=0 **且**沒有 `d?????????`（＝9p 健康、只是容器都不在）時，判成獨立的 `all-containers-down` 狀態，走資訊級告警（不 @、不進 FAIL 狀態機）；只有 Tier2 顯示 vm/daemon 異常時才 FAIL。這樣既保住第二輪要的「絕不靜默」，又不會把維護當事故。

---

### MEDIUM-4 — 告警沒送出去，也照樣蓋 throttle 章

```powershell
if ($alert.Send -and -not $DryRun) { $newState.lastAlertAt = $now.ToString('o') }
```

不管 Discord 有沒有收下。沒設頻道、token 找不到、401、Cloudflare 403、網路瞬斷——一律記成「已告警」然後靜音 60 分鐘。`lastResidentAlertAt` 同樣。

實測（BLOCKER-2 的 run1）：頻道未設定 → `[SKIP] no alert channel configured`，但狀態檔仍寫入 `"lastAlertAt": "2026-08-27T18:50:27..."`。

`Send-DiscordAlert` 的例外有被 catch 並記 `[WARN] Discord send failed`，但只進 log 檔，沒有人會去看。**這跟原始事故同一個病：監控自己以為回報過了。** token 過期是持續性的，不是瞬時的——一旦過期，這個 watchdog 就永久靜音，只有 log 知道。

---

### MEDIUM-5 — 「已由重啟容器修復」是同一個抽樣問題（較輕）

`Get-ProbeRunDecision` 只保證**全域** probed > 0，不保證**剛剛失敗的那幾條**有被重測。

實測（purefn harness）：kiro 兩條 `stopped` + estate/pdf 兩條 `ok` → `Status=OK Probed=2 ClearLatch=True AllowRecovered=True`。也就是說失敗的掛載根本沒複驗，就送出「已由重啟容器修復」並清掉 latch。

觸發需要 `docker restart` 本身逾時（`Invoke-Cmd ... 120` → Code=124）或容器沒回到 Running，機率比 BLOCKER-1 低（`docker restart` 通常會等到啟動完成）。5 分鐘後下一輪會抓回來，所以自我修正——但訊息會誤導，latch 也白清了。

建議：判 OK 之前，先確認上一輪 `$failed` 的每一條這輪的 Verdict 都是 `ok`。這同時也能一併修掉 BLOCKER-1。

---

### LOW-6 — daemon grace 對「每隔一輪才壞」的 flapping 免疫

`consecutiveFail` 在任何一次 OK 就歸零，所以「一次好一次壞」的間歇性 daemon 故障永遠到不了 `DaemonConfirmCount=2`，永遠不告警。低機率，可接受殘留風險。

### LOW-7 — 最壞單輪時間比註解寫的長

註解說「最壞 12×15s=180s」，但漏算每條掛載還有 10s 的 `docker inspect`：最壞 12×(10+15)=**300s**，等於整個排程間隔，加 Tier2 30s 會超過。`-MultipleInstances IgnoreNew` 會確實擋住重疊（這點有效），所以只是註解與參數說明不準，不是安全問題。正常情況實測 2.67s。

### LOW-8 — `-MountsFile` 是未驗證輸入（可接受）

- SelfTest 明確跳過 override（`-not $SelfTest -and $MountsFile -ne ''`），所以**12 筆斷言恆成立**——實測帶 `-MountsFile` 跑 SelfTest 仍 `[PASS] mount list has 12 entries`。代價是自訂清單永遠測不到。
- 畸形 JSON → 乾淨 throw、exit 1、**不寫狀態檔**（parse 發生在建立 StateDir 之前）。實測確認。
- `[]` → probed=0 → 走 HIGH-3 那條路，不自癒。實測確認。
- `Path` 會被字串插值進 `docker exec sh -c`，理論上是命令注入面；但只有操作者本人能提供這個檔，排程也不帶此參數。**無法用畸形 MountsFile 誤觸自癒**（最多做到 container-restart，`Scope=vm` 需要真的 9p 死掉）。

### LOW-9 — 文件漂移

- `acceptance:396` 風險第 6 條寫 vmmem「300s 超時」，程式是 **900s**（`$VmmemTimeoutSec = 900`，SelfTest 還特別斷言 900）。
- `acceptance:165` 與 HIGH-3 矛盾（見上）。

---

## 3. 為什麼「誤觸 wsl --shutdown」我判定已被擋住

逐條追過所有入口：

1. `Scope='vm'` 在全檔只有**一個**來源：`Get-Tier2Scope`，條件是 `ExitCode -eq 0` **且**輸出符合 `d\?{9}`。也就是 Tier2 成功執行、而且 host mnt 列出來是 `d?????????`——這只有 9p 真的死掉才會出現。`/run/desktop/mnt/host/` 底下是磁碟機代號（c/d/e），不可能自然長出這個字串。
2. `Get-ScopeAction 'vm' → 'self-heal'` 是 `Invoke-SelfHealLadder` 的**唯一**呼叫點（`:1229/:1244`）。
3. 失敗方向是安全的：Tier2 因任何理由失敗或逾時（daemon 掛、alpine image 被 prune 掉、privileged 被禁）→ `ExitCode -ne 0` → 判 `daemon` → `alert-only`，不自癒。
4. 維護情境（全部容器關掉、9p 健康）實測落在 `container`，不是 `vm`。
5. 畸形/惡意 MountsFile 最多做到 `container` → `docker restart`。
6. 就算真的走到，還有四道閂：24h 上限 2 次、60 分鐘冷卻、`manualRequired` 閂鎖（24h 過期）、`-DryRun`。
7. 自癒階梯本身的 `$args` 賦值（PowerShell 自動變數遮蔽）**實測不會炸**——我單獨跑了 `Wait-HostMountReadable -TimeoutSec 20`，回 True 無例外。這點很重要：它在 `wsl --shutdown` 和殺完 Docker Desktop **之後**才執行，那裡崩掉會留下最糟的狀態。

所以最壞情況（把好好的 WSL 關掉）我認為已經被擋住了。**真正沒被擋住的是「說謊」，不是「亂動」**——這也是為什麼結論是有條件 GO 而不是重新設計。

---

## 4. 到目前為止**仍然**沒有被端對端驗證的路徑

### 不可接受（上線前或上線當下必須處理）

| 路徑 | 為什麼不可接受 |
|---|---|
| **正式路徑（非 TestAlert）從未送出過任何一則 Discord** | 唯一送達的證據走的是 TestAlert 專屬的 env fallback 分支。正式路徑實測是 `[SKIP] no alert channel configured`。等於整條告警鏈從未端對端跑通過。→ BLOCKER-2；部署後跑一次非 DryRun 就能關掉這個缺口 |
| **自癒階梯 step 7 在真實復原時序下的行為** | 從未跑過，而 BLOCKER-1 讓它在最可能的時序下會說謊。修完之後，這條路徑仍然沒有實測——但至少判定邏輯會與主流程一致 |
| **Discord 送失敗時的正式路徑行為** | 我測了 TestAlert 的 401，沒測正式路徑送失敗。那正是 MEDIUM-4 的漏洞所在 |

### 可接受的殘留風險

| 路徑 | 為什麼可接受 |
|---|---|
| 真正的 `wsl --shutdown` 自癒階梯全程（step 2-7） | 為了測它得先弄壞 9p。純函式鎖住了階梯文字與熔斷器，DryRun 印得出 7 步。**這是本專案最大的單一殘留風險，但上線前跑一次它的代價高於它的價值**——真正該做的是修完 BLOCKER-1 之後，等第一次真實事故當現場驗證，並且盯著 log |
| 真正的 9p 死亡 → Tier2 出現 `d?????????` → `Scope=vm` | 只有合成字串測過。但 `d?????????` 是 9p 斷線時 `ls -la` 的標準表現，判定邏輯只有一行，風險低 |
| 熔斷器在真實情境累積 `healAt` | 純函式覆蓋充分（cap / cooldown / 24h 剪枝 / 單元素 JSON），且失敗方向是「不自癒」 |
| 容器層 healthcheck（新寫的 10 個） | 尚未 `up -d`，watchdog 完全不依賴它們。下次重新部署時才生效，屆時需另行驗收 |
| `Register-ScheduledTask` 真的註冊 + 真的被觸發 | `-WhatIf` 已驗；註冊本身是標準操作。但註冊後**必須**確認第一次觸發真的跑起來（`Get-ScheduledTaskInfo` 的 LastTaskResult） |

---

## 附：本輪測試怎麼跑的

全部在 `-DryRun` 或獨立 `-StateDir`（scratchpad）下進行，未觸碰正式狀態檔、未重啟任何容器、未執行 `wsl --shutdown`、未送出任何 Discord 訊息（除一次故意用假 token 打出的 401）。

- `-SelfTest` / `-SelfTest -MountsFile <bad>` — 斷言與 override 隔離
- `-DryRun` 正式 12 掛載 — 12/12 probed，2.67s
- `-DryRun -MountsFile <全假容器> -StateDir <tmp>` — 維護情境（HIGH-3）
- 非 DryRun `-MountsFile <全假容器> -StateDir <tmp>` x2（第二次回填 -31m）— 常駐容器告警與狀態持久化
- `-DryRun -MountsFile []` / `<garbage>` — 畸形輸入
- `-TestAlert -AlertEnv <假 token>` — 失敗路徑不寫檔
- 抽出原始函式定義建 harness（`purefn.ps1` / `runtimefn.ps1`），對未修改的 `Get-MountFailResults` / `Get-ProbeRunDecision` / `Wait-HostMountReadable` 直接施測
