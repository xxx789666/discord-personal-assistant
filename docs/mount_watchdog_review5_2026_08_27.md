# mount-watchdog 第五輪終審（REVIEW-5）— 結案

日期：2026-08-27
範圍：驗證 FIX-4，review-only，**未修改任何被審查的程式檔**（本文件為唯一新增檔）
被審物：`openab/healthcheck/mount-watchdog.ps1`（1711 行）、`register-mount-watchdog.ps1`、`openab/docker-compose.yml`
前四輪：`docs/mount_watchdog_review_2026_08_27.md`、（第二輪未寫檔）、`review3`、`review4`、`acceptance`

---

## 結論：**GO** — 可以合併到 D: 主 checkout 並註冊排程

**沒有 blocker。**

FIX-4 的兩大宣稱都經實跑確認為真，而且是這四輪來第一次「修對了根因而不是修對了症狀」：

- **F-2（exit code）修好了，而且語意正確。** `LastTaskResult=0` 現在真的代表「本輪沒事」，不代表「歷史上沒出過事」。這一項最重要，因為第四輪的 GO 條件整個靠它。
- **結構收斂是真的收斂。** 階梯不再自己判定、不再自己記帳；階梯中途那 4 則最關鍵的訊息現在走統一出口，會被記帳，而且**不可能被節流吃掉**。

本輪找到 4 個 MEDIUM、4 個 LOW，全部列入 §5 的跟進清單。其中沒有一個會讓系統「在真故障時說謊」或「在正常時做壞事」——最嚴重的那個（M-1）方向是**保守的**：它會在自癒其實成功時說「這不是成功」，而不是反過來。按本輪的出貨規則，這是跟進，不是 blocker。

---

## 1. FIX-4 驗證（全部實跑）

### 1.1 F-2：exit code 語意 — **真，而且比宣稱的更嚴謹**

宣稱：seed `discordFailCount=5` 後跑健康輪 → `EXIT=0` 且計數歸零。**複驗通過**：

```
TICK1: EXIT=0 status=OK discordFailCount=0 lastDiscordError=
TICK2: EXIT=0 status=OK discordFailCount=0 lastDiscordError=
```

但「歸零」不等於「語意正確」。我另外做了一組**三段式**測試，直接針對「本輪 vs 歷史」這個分界（獨立 `-StateDir`、ghost 容器、故意壞掉的 token env，全程無副作用、無真實 Discord 送出）：

| tick | 情境 | 結果 |
|---|---|---|
| T1 | 3 個 ghost 容器，all-down 1/2，**沒有任何訊息要送** | `EXIT=0` `status=OK` `failCount=0` |
| T2 | all-down 2/2 → **本輪真的嘗試送出且失敗**（`no-token`） | **`EXIT=1`** `status=OK` `failCount=1` `lastErr=no-token` |
| T3 | 換回健康掛載，本輪無告警 | **`EXIT=0`** `failCount=0` `lastErr=`（歷史被清乾淨） |

這正是需要的三個訊號：

- T2 證明 **`status=OK` 但本輪送出失敗 → exit 1**（Discord 壞掉不會被 exit code 吞掉）
- T3 證明 **前一輪的失敗不會黏到這一輪**（第四輪 F-2 的病灶）
- T1 證明 **沒有告警要送的健康輪不會被誤判成失敗**

程式面對應：`:1710` 改成 `Test-ThisRunAbnormal -NewStatus $newStatus -SendFailedThisRun $script:WatchdogSendFailed`，而 `$script:WatchdogSendFailed` 是每次執行開頭 `:1472` 重設為 `$false` 的 per-run 旗標，不從狀態檔繼承。**「歷史曾失敗」已經完全不影響 exit code。**

> **結論：第四輪的 GO 條件（`LastTaskResult=0`）現在是可信訊號。**

### 1.2 結構收斂四項 — **逐項確認**

| 宣稱 | 判定 | 證據 |
|---|---|---|
| `Get-InterventionOutcome` 是唯一的 post-heal/restart 成功判定 | ✅ **真** | 全檔只有 2 個執行期呼叫點：`:1575`（heal）、`:1596`（restart），兩邊傳同樣的 `-Results` / `-PrevFailed`，只差 `-Mode`。階梯函式體內 0 個（SelfTest 鎖住）。 |
| `Send-WatchdogNotice` 是唯一的 Discord 出口 | ✅ **真（監控流程內）** | `Send-DiscordAlert` 全檔只有 2 個呼叫點：`:1221`（在 `Send-WatchdogNotice` 內）與 `:1448`（`-TestAlert` 專屬分支，該分支不碰狀態檔且立刻 `exit`）。監控主流程 + 階梯共 10 個送出點全部經過 `Send-WatchdogNotice`。 |
| step 7 只回傳原始 Tier1 結果 | ✅ **真** | `:1393-1395`：`$results = Invoke-Tier1Probe; return @{ Outcome='done'; Results=$results }`。無判定、無組文案、無送出。 |
| SelfTest 鎖住結構 + compose 的 `HostVaultProbe` | ⚠️ **部分真** | 兩條斷言都存在且 `SelfTest PASSED`。但結構鎖只擋得住它被設計來擋的那一種改法，見 §3。 |

**特別確認：階梯那 4 個送出點（原 :1253/1269/1284/1298）真的走 `Send-WatchdogNotice` 了嗎？**

**是。** 現在是 `:1339`（「我要開始跑 wsl --shutdown」）、`:1355`（vmmemWSL 900s 未消失，需人工）、`:1370`（找不到 Docker Desktop.exe，需人工）、`:1384`（600s 仍無法 ls，需人工），四個全部是 `Send-WatchdogNotice -Text ... -AlertCfg $AlertCfg -WouldSend $true`。

因為 `Send-WatchdogNotice` 內部最後一行無條件呼叫 `Register-SendAttempt $ret $WouldSend`（`:1238`），這四則現在**自動被記帳**——送失敗會設 `WatchdogSendFailed`、會累加 `discordFailCount`、會讓 exit code 變 1。第四輪的 F-1b 已隨結構收斂一併消失，而且不是靠「記得補 4 行」，是靠「不可能漏」。

---

## 2. 這次重構有沒有製造新問題

### 2.1 時序：**沒有改變**（確認）

`Invoke-SelfHealLadder` 的順序是：

```
:1339  Send-WatchdogNotice「開始自癒」    ← 先發
:1342  healAt 記帳 + 落盤
:1346  Write-Log 'step 2: wsl --shutdown'
:1347  Start-WslShutdownFireAndForget     ← 後動手
```

我用**模擬自癒實跑**再確認一次（sandbox 副本，把 `wsl --shutdown` / 殺行程 / 啟動 Docker Desktop / 掛載輪詢四個破壞性動作全部 stub 掉，Tier2 強制回 `Scope=vm`，Tier1 第一次回 absent、第二次回 ok）。log 順序：

```
[ACTION] self-heal
[HEAL-GATE] allow
[HEAL] starting VM self-heal ladder
[SKIP] token var ... not found            ← 「開始自癒」那則的送出嘗試，在這裡
[SIM] step 2 stubbed (no wsl --shutdown)  ← 才輪到動手
```

**先發後動，沒有變成動手後才發。**

### 2.2 節流：**階梯訊息不可能被節流吃掉**（確認）

`Send-WatchdogNotice` 的抑制只有一條路徑：`if (-not $WouldSend) { ... Reason='suppressed' }`。而階梯 4 個送出點 + `cap` 上限訊息 + heal 結果訊息，**全部硬寫 `-WouldSend $true`**，`$alert.Send` / `Get-AlertAction` / `lastAlertAt` 的 60 分鐘節流完全碰不到它們。

> **「我要跑 `wsl --shutdown`」這則絕對送得出去**（除非頻道未設定或 token 不存在，而那兩種都會記帳 + exit 1）。

另外確認一個容易誤判的地方：主流程的 FAIL 告警（`:1547`，走 `$alert.Send`，可能被節流）與階梯的「開始自癒」是**兩則獨立訊息**。就算主流程那則因為 60 分鐘節流被 `[SKIP]` 掉，階梯這則照樣送。在上面的模擬 log 裡兩則各自嘗試了一次，互不影響。

### 2.3 語意抹平：**有一處被抹錯了 → M-1（本輪最重要的發現）**

第四輪的 F-1a 修法是「把重啟路徑的 `Test-PreviousFailsNowOk` 也套到自癒路徑」。這個方向對，但**兩條路徑的觸發條件不對稱，統一判定時沒有處理這個不對稱**：

- **重啟路徑**：只在 `if ($failed.Count -gt 0)` 內才會走（`:1590`）⇒ `$PrevFailed` **保證非空**。
- **自癒路徑**：觸發條件是 `newStatus=FAIL` 且 `Scope='vm'`。而 `FAIL` 有兩個來源：`Reason='mount-fail'`（有失敗清單）**和 `Reason='unprobed'`（probed=0，清單是空的）**。

而 `Test-PreviousFailsNowOk` 的第一行是：

```powershell
$prev = @(Convert-ToArray $PrevFailed)
if ($prev.Count -eq 0) { return $false }   # ← 空清單 = 不算成功
```

結果：**當自癒的觸發原因是 `unprobed`（容器全掛）時，就算自癒 100% 成功、全部掛載回來可讀，也會被判成「不是成功」。**

純函式 harness（用 `Get-Content -Encoding UTF8` 取原檔未修改的函式定義 dot-source）：

```
case 1: 自癒前沒有 mount-fail 列（probed=0 全 absent），自癒後 3/3 全部 ok
  decision=OK/ok probed=3/3 claim=False kind=incomplete
  TEXT: <@OWNER> ⚠️ mount-watchdog 自癒後僅 probed=3/3，先前失敗的掛載尚未全部可讀。這不是成功。

case 2: 自癒前有 mount-fail 列，自癒後 3/3 全部 ok
  claim=True kind=ok
  TEXT: <@OWNER> ✅ mount-watchdog 自癒完成：probed=3/3，先前失敗的掛載均已可讀。
```

而且這**不只是純函式層的問題**，模擬自癒實跑在完整主流程裡重現了它：

```
[PROBE] reason=unprobed probed=0 scope=vm
[STATE] prev=OK new=FAIL scope=vm alert=fail send=True probed=0
[ACTION] self-heal
...
[HEAL] step 7: re-run Tier 1
[HEAL] intervention kind=incomplete claim=False probed=3/3   ← 3/3 全好，卻說不是成功
EXIT=1                                                        ← status 留在 FAIL
```

**可達性**：需要 `Reason='unprobed'`（12 個容器全部 absent/stopped）**且** `Scope='vm'`（Tier2 `ls -la` exit=0 且輸出有 `d?????????`）。也就是「9p 死了，而且容器也全部掛掉了」。2026-08-27 那次事故容器是**還活著**的，所以那次不會踩到；但 9p 崩潰嚴重到容器被打掛或進入重啟迴圈，是完全合理的變體。注意 all-down 寬限救不了它——all-down 只在 `Scope='container'` 時 Active，這裡是 `vm`。

**為什麼不是 blocker**：

1. **方向是保守的**：它「少宣稱成功」，不是「假裝成功」。使用者收到的是一則要他去看的 ⚠️，去看之後發現其實好了。反過來（真壞了卻報綠燈）才是致命的，而那個方向本輪確認是關的（case 4：自癒後全 SKIP → `kind=unprobed` → 「這不是成功」）。
2. **不會導致亂動**：這一輪自癒已經跑完了，誤判只影響訊息與 `status`。下一輪 Tier1 全 OK ⇒ `newStatus=OK` ⇒ 送 ✅ 已恢復，5 分鐘自我修正。就算下一輪真的又 FAIL，60 分鐘冷卻 + 24h 上限 2 次仍然擋著第二次 `wsl --shutdown`。
3. **閂鎖沒被誤清**：`:1688` 是 `if ($decision.ClearLatch -and $newStatus -eq 'OK')`，這裡 `$newStatus='FAIL'`，不會誤清。

**唯一真正難受的地方是文案自相矛盾**：「僅 probed=3/3 ⋯ 尚未全部可讀」。在真實事故現場、剛跑完 `wsl --shutdown` 之後，這句話會讓人看不懂系統到底好了沒。所以它排在跟進清單第一。

### 2.4 M-3：`$healOutcome` 其實是個 2 元素陣列（靠運氣沒出事）

`:1339` 的 `Send-WatchdogNotice ...` 沒有 `[void]`，也沒有指派給變數。這個函式**有回傳值**（`return $ret`，一個 hashtable），所以它會被送進 `Invoke-SelfHealLadder` 的成功流。

實測這個 pattern：

```
type=Object[] count=2                 ← $healOutcome 是陣列，不是 pscustomobject
Outcome=[done] type=String
done? True
Results.Count=3
truthy-guard: True
```

**目前不會出事**，因為 PS 5.1 的成員列舉會跳過沒有該成員的元素，剛好把 hashtable 濾掉了。但這正是檔案裡 `:992-993` 那段註解親自警告過的坑（「函式一旦被 `$x = Invoke-...` 擷取，成功流裡的字串會跟回傳物件混在一起」）——作者在 `Write-Log` 上防住了，在這裡漏了。`:1566` 的 `[void](Send-WatchdogNotice ...)` 就寫對了，可見是疏漏而非刻意。

只要哪天 `Send-WatchdogNotice` 的回傳 hashtable 多一個 `Outcome` 或 `Results` 鍵，`$healOutcome.Outcome` 就會變成 2 元素陣列，`-eq 'done'` 的行為就變了。修法是 4 個字元：`:1339`、`:1355`、`:1370`、`:1384` 各加一個 `[void](...)`。

---

## 3. SelfTest 的結構斷言真的有效嗎 — **部分有效，宣稱要打折**

我做了 5 個假想改動，每個都建一份 sandbox 副本（`healthcheck/mount-watchdog.ps1` + 同層 `docker-compose.yml`，因為 SelfTest 會讀自己的原始碼與 compose），改完直接跑該副本的 `-SelfTest`：

| # | 假想改動 | SelfTest | 應該被抓嗎 |
|---|---|---|---|
| **D** | **對照組**：把 `Get-ProbeRunDecision` 加回階梯 step 7 | ✅ **FAILED** — `[FAIL] ladder body has no health judge` | 是 → **抓到** |
| **B** | 階梯裡直接呼叫 `Send-DiscordAlert`（繞過唯一出口，不記帳） | ❌ PASSED | 是 → **漏掉** |
| **C** | 階梯裡自己數 `Verdict -eq 'ok'` 然後送「healed!」（不用任何被列黑名單的函式名） | ❌ PASSED | 是 → **漏掉** |
| **A** | 只在自癒呼叫點加一條新規則（`if ($iv.Probed -lt 6) { $iv.ClaimSuccess = $false }`），重啟呼叫點不加 | ❌ PASSED | 是 → **漏掉** |
| **E** | 把階梯的判定搬進一個放在 `Invoke-ContainerRestart` **之後**的新函式 | ❌ PASSED | 是 → **漏掉** |

**所以「未來新規則不可能只加在階梯而不讓 SelfTest 失敗」這句話是誇大的。** 實際成立的是比較窄的一句：

> 「**用原本那三個函式名**、**寫在 `Invoke-SelfHealLadder` 與 `Invoke-ContainerRestart` 之間的文字區間內**，重建第二份判定或第二份記帳」——這一種會被抓到。

原因是這些斷言本質上是**在一段文字視窗上做函式名黑名單**（`$src.Substring($iLadder, $iRestart - $iLadder)` 再 `-notmatch 'Get-ProbeRunDecision'` 等等），不是結構不變式。換個名字、搬個位置、或改在主流程單邊加規則，它都看不見。

平心而論，`acceptance:33` 自己寫的其實就是這個窄版本，還誠實加了「若有人在主流程另外寫一行旁路⋯結構鎖管不到——只能靠 code review」。**文件沒有說謊，是宣稱在傳話過程中被放大了。** 這個保護不是假的，只是比聽起來小。

**最值得補的一條斷言（B 那格）**：`Send-DiscordAlert` 全檔出現次數必須是 3（1 個定義 + `Send-WatchdogNotice` 內 1 個 + TestAlert 分支 1 個）。一行 `Assert-Eq`，就能把「有人新增了一個不記帳的 Discord 出口」變成 SelfTest 紅燈。這比擴大階梯黑名單有價值得多，因為它守的是**唯一出口**這個真正的不變式。

---

## 4. 最終 GO / NO-GO

### **GO** — 可以合併到 `D:\discord 個人助理\` 並註冊排程

**真 blocker：0 個。**

三個「不能出貨」的判準，逐項確認：

1. **真故障時會不會說謊（報綠燈）？** 不會。
   - probed=0 一律 FAIL（`Get-ProbeRunDecision`），自癒後全 SKIP 送的是「這不是成功」（case 4 實測）。
   - `lastAlertAt` 只在 HTTP 2xx 才蓋（第四輪真 401 實測，本輪程式路徑複查未變）⇒ Discord 壞掉不會讓 watchdog 永久靜音。
   - 唯一的誤報方向是 M-1，**方向相反**（少宣稱成功）。
2. **正常時會不會做壞事（誤觸 `wsl --shutdown`）？** 不會。
   - `Scope='vm'` 全檔唯一來源仍是 `Get-Tier2Scope:144`；唯一消費路徑 `Get-ScopeAction:565 → :1573`，且外層有 `$newStatus -eq 'FAIL'` 與 `Get-SelfHealGate`（latched / cap 2次/24h / cooldown 60min）四道閂。本輪的結構收斂沒有動到這條線上的任何一段。
   - 實跑正式 12 掛載 `-DryRun`：12/12 `OK`、`probed=12`、`alert=none send=False`、`EXIT=0`，`[ACTION]` 一次都沒出現。
3. **監控的監控可不可信？** 可信（§1.1 三段式實測）。第四輪唯一的但書已解除。

**誠實的但書（沿用第四輪，本輪沒有改善也沒有惡化）**：`d?????????` 這個自癒的唯一觸發條件，四輪來從頭到尾只用合成字串測過。真實 9p 崩潰若表現為「卡住」而非「報錯」，Tier2 會逾時 → `Scope='daemon'` → **只告警不自癒**。這對「不亂動」是加分，但代表**自癒能力本身仍是未經真實驗收的**。上線後第一次真實事故就是它的現場驗收。

### 出貨動作（與第四輪相同，未變）

1. 把 `mount-watchdog.ps1` 與 `register-mount-watchdog.ps1` 放到 `D:\discord 個人助理\openab\healthcheck\`，**從那個目錄**執行 `register-mount-watchdog.ps1`（`$PSScriptRoot` 決定排程指向誰；從 worktree 註冊會指向一次性目錄）。
2. 註冊前在該目錄各跑一次：`-SelfTest`（應 `SelfTest PASSED` / exit 0）、`-DryRun`（應 12/12 `OK`、`[CFG] alert env=D:\...`）。
3. 註冊後 15 分鐘內做 §5(a) 的第 1 項。

---

## 5. 上線後清單

### (a) 第一週人工確認清單

承接第四輪那份，**更新兩處**（標 🔄），其餘不變。

**Day 1（註冊當天）**

1. 🔄 **排程真的被觸發，且 `LastTaskResult=0` 現在可以直接信。**
   `Get-ScheduledTaskInfo OpenAB-MountWatchdog` → `LastRunTime` 每 5 分鐘前進、`LastTaskResult=0`。
   *更新理由*：第四輪這一項附帶「但 F-2 可能讓它永久黏 1」的但書，所以當時拿到非 0 要先猜是不是假警報。**現在但書拿掉了** — 非 0 一律代表「本輪 FAIL 或本輪 Discord 送出失敗」，直接去看 `.state\mount-watchdog.log` 最後一段的 `[STATE]` 與 `[WARN]` 兩行就能分辨是哪一種。
2. **log 有在長也有在轉檔**：`.state\mount-watchdog.log` 每 5 分鐘一個新區塊；接近 5MB 時確認輪替真的發生（`$LogMaxBytes` 從未在真實累積下驗過）。
3. **狀態檔欄位跨輪存活**：連看兩三輪 `mount-watchdog.json`，確認 `notRunningSince` / `consecutiveFail` / `discordFailCount` 沒有被清空。

**Day 1–2**

4. **重開機／休眠喚醒後的行為**（自動測試碰不到）：重開機一次，看有沒有收到 `Scope=daemon` 的假 FAIL。若有，把 `$DaemonConfirmCount` 從 2 調到 4（20 分鐘）。同時確認 `LogonType Interactive` 的排程在重新登入後自己恢復。
5. **確認正式路徑真的還會送**：`lastAlertAt` 是 `null` 代表「從未成功送過任何告警」。第一週結束前若一則都沒送過，主動跑一次 `-TestAlert`。**不要把「很安靜」當成「很健康」**。

**Day 2–7**

6. **一次計畫性維護的真實觀察**：下次 `docker compose down` / `up -d` 時盯著 Discord。應該看到 ℹ️ all-down（約 10 分鐘後），**不應該**看到 ⚠️ FAIL 或任何 `[ACTION] restart`。
7. **`start_period: 60s` 生效**：下次 `up -d` 後 `docker inspect` 確認不再是 `0s`，並確認新的 10 個 healthcheck 不會把容器判成 unhealthy。
8. 🔄 **看一次完整的 log，特別找兩個新字串。**
   `Select-String '\[WARN\]|\[SKIP\]|\[NOTE\]|\[HEAL\]' .state\mount-watchdog.log`
   *更新理由*：新增兩個要特別找的樣態——
   - `[HEAL] intervention kind=incomplete claim=False probed=N/N`（分子等於分母卻說 incomplete）＝ **M-1 在真實環境踩到了**。看到這個就直接把 M-1 提到最前面修。
   - `[SKIP] token var ... not found` / `[SKIP] no alert channel configured` ＝ 告警鏈斷了但 Discord 當然不會告訴你（現在至少會讓 exit code 變 1，配合第 1 項就抓得到）。

**第一週結束時該回答的一個問題**（不變）

> 這七天裡，watchdog 有沒有送出過**任何一則**訊息？
> 有 → 告警鏈端對端驗證完成。沒有 → 你只驗證了「它沒有洗版」，**還沒驗證「它會說話」**。跑一次 `-TestAlert`，並考慮刻意 `docker stop openab-astruct` 放 35 分鐘，看常駐容器告警是否如期送達。

### (b) 跟進清單（MEDIUM / LOW，按價值排序）

| # | 級別 | 項目 | 為什麼值得 | 成本 |
|---|---|---|---|---|
| **M-1** | MEDIUM | `Test-PreviousFailsNowOk` 的空清單語意：`$PrevFailed` 為空時（自癒因 `unprobed` 觸發）不該直接判 `false`。建議在 `Get-InterventionOutcome` 裡分流：空清單時改以 `Probed/Total` 比例決定文案，例如 `probed=12/12` → ✅、`probed=1/12` → 「已可讀 1/12，其餘容器尚未起來」，兩者都不要說「先前失敗的掛載尚未全部可讀」（因為根本沒有「先前失敗的掛載」） | 唯一會在真實事故現場送出自相矛盾訊息的地方；§2.3 已端對端重現 | 小 |
| **M-2** | MEDIUM | SelfTest 加一條 `Assert-Eq (([regex]::Matches($src,'Send-DiscordAlert')).Count) 3 'single Discord exit'` | §3 的 B 案：目前任何人都能在任何地方新增一個不記帳、不管 2xx 的 Discord 出口而 SelfTest 全綠。這條守的是**唯一出口**這個真不變式，比擴大階梯黑名單有效 | 一行 |
| **M-3** | MEDIUM | `:1339` `:1355` `:1370` `:1384` 四個 `Send-WatchdogNotice` 加 `[void](...)` | `$healOutcome` 目前是 `Object[2]`，靠 PS 成員列舉的巧合才正確；檔案 `:992` 的註解親自警告過這個坑 | 4 個字元 ×4 |
| **M-4** | MEDIUM | `register-mount-watchdog.ps1` 的 `New-ScheduledTaskSettingsSet` 加 `-ExecutionTimeLimit (New-TimeSpan -Hours 1)`（第四輪 F-5，未處理） | 目前預設 72 小時，配 `-MultipleInstances IgnoreNew`，一次卡死會擋掉之後所有觸發。**注意不要設得比 1 小時短**：一次合法的自癒最壞是 900s + 600s + 探測 ≈ 30 分鐘 | 一行 |
| **L-1** | LOW | `Get-NextDiscordFailCount`（`:403`）與 `$DiscordFailExitCount`（`:45`）在執行期已成死碼，只剩 SelfTest 在測。而且 `:891` 的 `'failed send keeps count'` 斷言描述的行為**主流程並沒有實作**（實測一次執行內三次送出失敗會累加到 3，函式卻是回傳 `PrevCount` 不變）。建議刪掉函式與常數，或把主流程真的接上去 | 一個「測試在測不存在的實作」，會誤導下一個改這段的人 | 小 |
| **L-2** | LOW | `Send-DiscordAlert:1047` 的 `Invoke-WebRequest` 沒有 `-TimeoutSec`（PS 5.1 預設 ≈100 秒） | 「我要跑 `wsl --shutdown`」那則若遇到 Discord 卡住，會把自癒往後推最多約 100 秒。不致命，但這是整條流程裡唯一一個非自己控制的等待 | 一行 |
| **L-3** | LOW | 文件漂移：`acceptance:445/448` 仍寫 300s（實作是 900s/600s，`:527` 自己也承認了）；`acceptance:165` 與 all-down 新語意矛盾（第三輪 LOW-9 → 第四輪 → 仍在） | 下次事故時有人會照文件推論 | 小 |
| **L-4** | LOW | `Wait-HostMountReadable:1320` 用 `$args` 當區域變數名，遮蔽 PowerShell 自動變數 | 目前可運作（函式有 `param()`），純粹是會咬人的命名 | 一行 |

---

## 附：本輪怎麼跑的

**未修改任何被審查的程式檔。** 未執行 `wsl --shutdown`、未殺任何行程、未 restart 任何容器、未註冊排程、未觸碰正式 `.state`（全部用 `-StateDir` 導到 scratchpad）、**未送出任何真實 Discord 訊息**（所有送出路徑都用不存在的 token var 打成 `no-token`）。所有假想改動都在 `%TEMP%` 的 sandbox 副本上進行。

- `-SelfTest`（原檔）→ `SelfTest PASSED`，exit 0，含 5 條結構鎖斷言與 `HostVaultProbe` 斷言
- `-DryRun` 正式 12 掛載 → 12/12 `OK`、`probed=12`、`EXIT=0`
- F-2 複驗：seed `discordFailCount=5` → 健康輪 ×2 → `EXIT=0`、計數歸零
- F-2 語意三段式：ghost 容器 + 壞 token → `T1 EXIT=0` / `T2 EXIT=1（status=OK 但本輪送出失敗）` / `T3 EXIT=0（歷史清空）`
- 純函式 harness（`Get-Content -Encoding UTF8` 取原檔 91–606 行未修改的函式定義 dot-source）→ `Get-InterventionOutcome` 五情境，含 M-1
- **模擬自癒實跑**：sandbox 副本，10 處 anchor 替換掉破壞性動作，Tier2 強制 `vm`、Tier1 腳本化 → 完整走過 `[ACTION] self-heal → 階梯 → step 7 → Get-InterventionOutcome`，重現 M-1 並確認時序與記帳
- SelfTest 繞過測試：5 份 sandbox 副本（1 對照 + 4 繞過），見 §3
- pipeline pollution 最小重現 → 確認 `$healOutcome` 為 `Object[2]`
- 全檔 grep 交叉確認：`Send-DiscordAlert` 呼叫點、`Scope='vm'` 來源、`Get-InterventionOutcome` 呼叫點、`Register-SendAttempt` 位置

> 註：一開始用 bash heredoc 寫含中文路徑的 harness 造成 mojibake（本專案 memory 記過的坑），已改成全程 PowerShell I/O ＋ 把路徑當參數傳入、harness 檔案本身不含中文字元。
