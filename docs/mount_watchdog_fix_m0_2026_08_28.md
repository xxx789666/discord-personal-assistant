# FIX-M0 交付報告：探測耗時納入判定

**日期：** 2026-08-28
**檔案：** `openab/healthcheck/mount-watchdog.ps1`（主 checkout，未 commit / 未 push）
**編碼：** UTF-8 with BOM（`BOM=239,187,191`）

## 做了什麼

同一輪探測的耗時進入 **唯一判定函式** `Get-ProbeRunDecision`（自癒／重啟仍經 `Get-InterventionOutcome` → 同一函式）。沒有第二份判定。

規則（只增加資訊與保守性，**不降低** `wsl --shutdown` 門檻）：

| 參數 | 值 | 理由 |
|---|---|---|
| 基線 | 每條掛載最近 12 次 **成功** 探測的中位數；冷啟動 0.5s | 中位數抗 11s 這種單次離群；0.5s 比正常 0.17s 保守，但仍能抓住 20:56 的 11.0s 與 2.5s |
| M | 5 | 正常 0.17–0.22s 不會誤觸；5×0.17≈0.85s |
| K | 2 | 「另有 ≥2 條」才標 VM 層級疑慮，避免單一 timeout + 一次毛刺 |

**20:56 真實數字**（timeout 本身不計入 K）：

- `openab-url-intake` 15.0s timeout
- `intake-publisher` 11.0s OK（計入）
- `openab-estate` 2.5s OK（計入）
- `openab-travel-claude` 1.8s OK（計入；基線 0.17s 時 1.8/0.17≈10.6×）
- 其餘 8 條 0.17s

→ `VmDegraded=true`，`SlowPeerCount=3`。Scope 仍由 Tier2 決定（**不會**因為這條規則變成 `Scope=vm`）。

處置：

- `Get-ScopeAction 'vm' -VmDegraded $true` 仍是 `self-heal`（門檻不變）
- `Get-ScopeAction 'container' -VmDegraded $true` 改為 `observe`：**不**自動 `docker restart`（重啟解不了 9p 卡頓）
- 告警附加：「同一輪內另有 N 條掛載異常緩慢，可能是 VM 層級劣化而非單一容器問題」
- 每條 `[T1]` log 都帶 `0.20s` 這類耗時；state 的 `probeDurations` 只收 `Verdict=ok`

## SelfTest

```
powershell.exe -NoProfile -File "D:\discord 個人助理\openab\healthcheck\mount-watchdog.ps1" -SelfTest
```

**結果：exit 0，`SelfTest PASSED`**

FIX-M0 相關斷言（節錄）：

```
[PASS] 20:56 still FAIL (timeout is mount-fail)
[PASS] 20:56 reason remains mount-fail
[PASS] decision always exposes VmDegraded
[PASS] 20:56 timeout + 3 slow peers => VM-level suspicion
[PASS] 20:56 SlowPeerCount >= K=2
[PASS] 20:56 with 0.17s baseline flags 11.0+2.5+1.8 (3 peers)
[PASS] all-0.17s round stays OK
[PASS] all-0.17s must not flag VM-level suspicion
[PASS] isolated timeout is still FAIL
[PASS] isolated timeout (no slow peers) is not VM-level suspicion
[PASS] 20:56 still VM-suspicion on cold-start default baseline 0.5s (11.0 and 2.5)
[PASS] FIX-M0 M=5 is locked
[PASS] FIX-M0 K=2 is locked
[PASS] FIX-M0 cold-start baseline 0.5s is locked
[PASS] heal path sees VM-level suspicion (same judge)
[PASS] restart path sees VM-level suspicion (same judge)
[PASS] heal and restart VmDegraded identical
[PASS] heal notice mentions VM-level suspicion
[PASS] restart notice mentions VM-level suspicion
[PASS] vm => self-heal (threshold unchanged)
[PASS] VmDegraded must NOT promote/demote Scope=vm heal
[PASS] container without VmDegraded still restarts
[PASS] container+VmDegraded skips restart (conservative)
[PASS] daemon+VmDegraded still alert-only (no heal)
[PASS] ladder does not invent a second latency judge
[PASS] exactly one Get-ProbeRunDecision (no second judge)
[PASS] main passes VmDegraded into Get-ScopeAction
[PASS] intervention judge reuses Get-ProbeRunDecision + baselines
SelfTest PASSED
```

TDD：先加 20:56 斷言，舊碼在 `decision always exposes VmDegraded` 失敗（屬性不存在），再實作後全綠。

## -DryRun（實際輸出）

```
=== mount-watchdog run ===
[CFG] alert env=D:\discord 個人助理\.local\infra_alert.env
[CFG] token env=D:\discord 個人助理\.local\discord_token.env
[DRYRUN] detection will run; heal/kill/wsl/discord will not
[T1] openab-url-intake /vault => OK (OK) 0.20s
[T1] intake-publisher /vault => OK (OK) 0.18s
[T1] pdf-publisher /vault => OK (OK) 0.18s
[T1] openab-estate /workspace/EstateSpace => OK (OK) 0.18s
[T1] openab-travel-claude /workspace/TravelMemory => OK (OK) 0.17s
[T1] openab-travel-nvidia /workspace/TravelMemory => OK (OK) 0.18s
[T1] openab-credit-report /workspace/CreditReportSpace => OK (OK) 0.18s
[T1] openab-kiro /workspace/KiroSpace => OK (OK) 0.19s
[T1] openab-kiro /workspace/TravelMemory => OK (OK) 0.16s
[T1] openab-nvidia-lab /workspace/LabSpace => OK (OK) 0.20s
[T1] openab-astruct /workspace/AStructSpace => OK (OK) 0.17s
[T1] openab-astruct /workspace/AStructSpace/forward => OK (OK) 0.18s
[STATE] prev=OK new=OK scope= alert=none send=False probed=12 vmDegraded=False slowPeers=0
若為真會執行的自癒步驟（Scope=vm 時）：
  - Discord 告警：偵測到 VM 層級掛載故障，開始自癒
  - wsl --shutdown（不等待指令返回，改輪詢 vmmemWSL）
  - 輪詢 vmmemWSL／vmmem 直到消失，上限 900 秒；超時則停手並告警需要人工處理／重開機（不再重試，寫入 manualRequired 閂鎖）
  - 殺掉殘留行程：Docker Desktop, com.docker.backend, com.docker.build（不用 docker desktop restart）
  - 啟動 C:\Program Files\Docker\Docker\Docker Desktop.exe
  - 輪詢 docker run --rm -v "D:/discord 個人助理/URLIntake:/vault" alpine ls /vault 直到成功，上限 600 秒
  - 重跑 Tier 1 全清單驗證，結果發 Discord
（DryRun 結束，未執行 wsl --shutdown、未殺行程、未啟動 Docker Desktop、未發 Discord）
[DRYRUN] state file not written
```

exit 0。正常輪全部 ~0.17–0.20s，`vmDegraded=False`，未誤判。

## 正式執行（實際輸出）

```
=== mount-watchdog run ===
[CFG] alert env=D:\discord 個人助理\.local\infra_alert.env
[CFG] token env=D:\discord 個人助理\.local\discord_token.env
[T1] openab-url-intake /vault => OK (OK) 0.20s
[T1] intake-publisher /vault => OK (OK) 0.17s
[T1] pdf-publisher /vault => OK (OK) 0.19s
[T1] openab-estate /workspace/EstateSpace => OK (OK) 0.19s
[T1] openab-travel-claude /workspace/TravelMemory => OK (OK) 0.17s
[T1] openab-travel-nvidia /workspace/TravelMemory => OK (OK) 0.18s
[T1] openab-credit-report /workspace/CreditReportSpace => OK (OK) 0.21s
[T1] openab-kiro /workspace/KiroSpace => OK (OK) 0.17s
[T1] openab-kiro /workspace/TravelMemory => OK (OK) 0.17s
[T1] openab-nvidia-lab /workspace/LabSpace => OK (OK) 0.19s
[T1] openab-astruct /workspace/AStructSpace => OK (OK) 0.19s
[T1] openab-astruct /workspace/AStructSpace/forward => OK (OK) 0.17s
[STATE] prev=OK new=OK scope= alert=none send=False probed=12 vmDegraded=False slowPeers=0
```

exit 0。state 已寫入 `probeDurations`（12 條各 1 筆成功耗時），`status` 仍為 `OK`，未發 Discord，未重啟、未自癒。

## 自癒門檻未變

- 仍只有 `Scope=vm`（Tier2 `d?????????`）才 `self-heal`
- `VmDegraded` **不**把 Scope 改成 vm，也 **不**放寬 `Get-SelfHealGate` / `$HealMax` / `$DaemonConfirmCount`
- `$VmmemTimeoutSec=900`、`$MountProbeTimeoutSec=600` 未改

## 剩餘

- 未 commit、未 push（依指示）
- 排程 `OpenAB-MountWatchdog` 仍停用，由 coordinator 維護完後再啟

---

## Coordinator 附註（2026-08-28 合併後）

上方「剩餘」寫於合併前，現況如下：

- 已合併進 `D:\discord 個人助理`，排程 `OpenAB-MountWatchdog` **已重新啟用**，`LastTaskResult=0`
- 審查結論：**GO，無 blocker**。關鍵論證是 `VmDegraded` 在結構上不可能製造誤報——
  它需要先有 mount-fail，而 mount-fail 本來就會強制 FAIL。因此「誤報侵蝕信任」那條路是封死的
- 合併時排程曾短暫停用，驗證 SelfTest 與正式執行皆 exit 0 後才啟用
