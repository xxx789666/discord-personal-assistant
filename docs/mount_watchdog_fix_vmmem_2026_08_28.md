# FIX-VMMEM 交付報告：自癒 VM 汰換判定

**日期：** 2026-08-28
**工作目錄：** worktree `C:\Users\xx\orca\workspaces\discord 個人助理\mount-watchdog-m0`
**檔案：** `openab/healthcheck/mount-watchdog.ps1`（未 commit / 未 push）
**未改：** 主 checkout `D:\discord 個人助理`（排程仍在跑；仍是舊的 `Wait-VmmemWslGone`）

## 選擇與失效情境

判定收斂成 **一個** 純函式 `Get-VmRecycleDecision`（`Wait-VmRecycled` 輪詢只呼叫它；ladder 不內嵌第二份）。任一可靠訊號成立即完成；900 秒仍是超時退路。

| 訊號 | 為什麼採用 | 失效情境 |
|---|---|---|
| **關機前 boot_id + 關機後不同**（`docker run --rm alpine cat /proc/sys/kernel/random/boot_id`） | 容器與 Docker Desktop VM 共用 kernel；今天維護 uptime 歸零、配額腰斬，就是這層換了。Docker 關機期間不可用，所以**先取基準**再 `wsl --shutdown` | 關機前 docker 已死 → `Captured=false`，此訊號放棄（不把「docker 後來又活了」當成汰換） |
| **uptime 變小** | 今天實測 68s；boot_id 讀不到時的備援 | 沒有基準不能用；**同一 boot_id** 時不用 uptime（避免誤判） |
| **`wsl --list --running` 顯示無發行版**（英／中，並剝 UTF-16 NUL） | 正常關機的短暫空窗 | VM 卡死時此指令會掛 → **每次 10s timeout，不當成 empty** |
| **vmmemWSL／vmmem 消失** | 保留為充分條件 | **今天證明它不是必要條件**——行程可在整段汰換中一直存在 |

今天維護測資（vmmem 仍在 + 新 boot_id + uptime 68s + docker-desktop 已回來）→ `Recycled=true, Reason=boot-id`。
卡死測資（vmmem 在 + wsl timeout + docker 掛）→ `pending`，輪詢到 900s 走既有 abort／`manualRequired`。

**沒有**降低 `Scope=vm` → `self-heal` 的觸發門檻。`Get-ProbeRunDecision` 仍是唯一健康判定。

## SelfTest（實際輸出，exit 0）

```
powershell.exe -NoProfile -File "...\mount-watchdog-m0\openab\healthcheck\mount-watchdog.ps1" -SelfTest
```

FIX-VMMEM 節錄：

```
[PASS] ladder waits on VM identity not only vmmem process
[PASS] recycle wait timeout stays 900s (escape hatch kept)
[PASS] 2026-08-28 maintenance: vmmem still present but boot_id changed => recycled
[PASS] today recycle reason is boot-id (not vmmem-gone)
[PASS] stuck VM: vmmem present + wsl timeout + docker down => pending (will hit 900s abort)
[PASS] same boot_id is not a recycle
[PASS] vmmem gone remains a sufficient recycle signal
[PASS] wsl --list --running empty => recycle (shutdown finished)
[PASS] Chinese wsl empty list is recycle
[PASS] UTF-16 NUL-padded English empty list parses
[PASS] wsl list timeout is NOT treated as empty
[PASS] uptime reset without boot_id (today: 68s) => recycled
[PASS] no pre-shutdown baseline: docker coming back is not proof of recycle
[PASS] FIX-VMMEM does not lower Scope=vm heal trigger
[PASS] ladder body has no recycle judge (Wait-VmRecycled owns it)
[PASS] exactly one Get-VmRecycleDecision (no second recycle judge)
SelfTest PASSED
```

TDD：先加斷言，舊碼在 `Get-VmRecycleDecision` 不存在處炸掉，再實作後全綠。

## -DryRun（實際輸出，exit 0；未執行 wsl --shutdown）

```
=== mount-watchdog run ===
[CFG] alert env=D:\discord 個人助理\.local\infra_alert.env
[CFG] token env=D:\discord 個人助理\.local\discord_token.env
[DRYRUN] detection will run; heal/kill/wsl/discord will not
[T1] openab-url-intake /vault => OK (OK) 0.20s
[T1] intake-publisher /vault => OK (OK) 0.16s
[T1] pdf-publisher /vault => OK (OK) 0.17s
[T1] openab-estate /workspace/EstateSpace => OK (OK) 0.18s
[T1] openab-travel-claude /workspace/TravelMemory => OK (OK) 0.20s
[T1] openab-travel-nvidia /workspace/TravelMemory => OK (OK) 0.17s
[T1] openab-credit-report /workspace/CreditReportSpace => OK (OK) 0.17s
[T1] openab-kiro /workspace/KiroSpace => OK (OK) 0.18s
[T1] openab-kiro /workspace/TravelMemory => OK (OK) 0.18s
[T1] openab-nvidia-lab /workspace/LabSpace => OK (OK) 0.16s
[T1] openab-astruct /workspace/AStructSpace => OK (OK) 0.18s
[T1] openab-astruct /workspace/AStructSpace/forward => OK (OK) 0.19s
[STATE] prev=OK new=OK scope= alert=none send=False probed=12 vmDegraded=False slowPeers=0
若為真會執行的自癒步驟（Scope=vm 時）：
  - Discord 告警：偵測到 VM 層級掛載故障，開始自癒
  - wsl --shutdown（不等待指令返回；關機前先取 VM boot_id／uptime 基準）
  - 輪詢 VM 汰換：boot_id 變更、wsl 無 running distro、或 vmmemWSL 消失（任一即可）；上限 900 秒。vmmemWSL 仍在不代表失敗。超時則停手並告警需要人工處理／重開機（不再重試，寫入 manualRequired 閂鎖）
  - 殺掉殘留行程：Docker Desktop, com.docker.backend, com.docker.build（不用 docker desktop restart）
  - 啟動 C:\Program Files\Docker\Docker\Docker Desktop.exe
  - 輪詢 docker run --rm -v "D:/discord 個人助理/URLIntake:/vault" alpine ls /vault 直到成功，上限 600 秒
  - 重跑 Tier 1 全清單驗證，結果發 Discord
（DryRun 結束，未執行 wsl --shutdown、未殺行程、未啟動 Docker Desktop、未發 Discord）
[DRYRUN] state file not written
```

## 剩餘

- 未 commit、未 push
- 真正的 `wsl --shutdown` 依指示沒跑；成功路徑靠 SelfTest 的今天維護測資鎖定
- 主 checkout 排程仍跑舊 waiter，合併前自癒成功路徑仍會靜默降級

---

## Coordinator 附註（2026-08-28 合併後）

上方「剩餘」寫於合併前，現況如下：

- **此版本曾被審查判為 NO-GO**，原因是 `Invoke-Cmd` 會替每個參數加引號，而 `wsl.exe`
  不解析被引號包住的旗標——它會把那串當成「在預設 distro 內執行的指令」。後果：
  `wsl --list --running` 回 exit 127（wsl-empty 是 dead code），且**每 5 秒輪詢就啟動一次 Ubuntu**，
  再拿自己開的 VM 去滿足 boot-id 檢查。自癒會從「永遠超時」變成「假裝成功」。
- 已於 FIX-VMMEM-2 修正：`psi.Arguments = '--list --running --quiet'` 整串原樣傳入、
  stdout 以 UTF-16 解碼、判定改為數非空行數（不比對中文字串）。
- 已合併進 `D:\discord 個人助理`，排程運作中，`LastTaskResult=0`。
- **未能直接驗證的一點**：「輪詢不會啟動 Ubuntu」這個副作用無法演示——
  Docker Desktop 的 WSL 整合會在 Ubuntu 被 terminate 後立刻把它拉回來，造不出觀測窗口。
  能證明的是機制：SelfTest 有實跑斷言 `exit != 127`，代表旗標未被當成 distro 內指令。
