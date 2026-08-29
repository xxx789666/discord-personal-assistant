# FIX-VMMEM-2 交付報告：wsl.exe 不可加引號

**日期：** 2026-08-28
**工作目錄：** worktree `C:\Users\xx\orca\workspaces\discord 個人助理\mount-watchdog-m0`
**檔案：** `openab/healthcheck/mount-watchdog.ps1`
**未改：** `D:\discord 個人助理`（排程仍跑舊碼）
**未執行：** `wsl --shutdown`

## 修了什麼

`Invoke-Cmd` 仍對 docker 逐參加引號（不動）。WSL 改走專用 `Invoke-WslListRunning`：

- `psi.Arguments = '--list --running --quiet'`（整串、不加引號）
- `psi.StandardOutputEncoding = Unicode`
- 空清單 = **非空行數為 0** 且 exit=0（不比對中文；exit 127 / 124 / timeout 不當成 empty）
- `Wait-VmRecycled` 對 snapshot 包 try/catch，單次失敗只重試

另外：`Get-CoercedInt 0` 在 PS 裡因 `0 -eq ''` 會變成預設值 1，會讓 wsl-empty 永遠 pending。WslExit 改直接 `[int]` 轉型，不經 Get-CoercedInt。

## 1. Get-VmRecycleSnapshot 真實 wsl 呼叫

SelfTest 內實際執行：

```
[WSL-LIVE] exit=0 lines=2
[PASS] wsl --list --running --quiet is flags not a distro command (exit!=127)
[SNAPSHOT-LIVE] wslExit=0 lines=2 dockerOk=True
[PASS] Get-VmRecycleSnapshot wsl exit is not 127
```

exit **0**，不是 127。`--quiet` 兩行：`Ubuntu`、`docker-desktop`。

## 2. 輪詢前後 distro 清單（最重要）

正確呼叫（`Arguments = '--list --running --quiet'` + Unicode）：

**BEFORE（SelfTest / snapshot 之前）：**
```
exit=0
lines=2
names:
Ubuntu
docker-desktop
```

**中間：** SelfTest 內 `Invoke-WslListRunning` + `Get-VmRecycleSnapshot`，再加 3 次同樣的 list 輪詢。

**AFTER：**
```
exit=0
lines=2
names:
Ubuntu
docker-desktop
```

三次加碼輪詢每一次都是同一份清單。沒有多出 distro、沒有把新的 Ubuntu 拉起來。  
（本機 BEFORE 時 Ubuntu 已在跑，所以這項證明的是「正確的 --list 不會用 127 路徑去 exec 預設 distro」；exit 0 + 清單不變。）

## 3. SelfTest

`SelfTest PASSED`（exit 0）。含 exit!=127、行數判定、zh-TW 字串不是 empty 訊號、timeout/127 不當成 empty、V-3 try/catch 結構鎖。

## 4. -DryRun

```
=== mount-watchdog run ===
[DRYRUN] detection will run; heal/kill/wsl/discord will not
[T1] ... 12/12 OK ...
[STATE] prev=OK new=OK ... probed=12 vmDegraded=False slowPeers=0
（DryRun 結束，未執行 wsl --shutdown、未殺行程、未啟動 Docker Desktop、未發 Discord）
[DRYRUN] state file not written
```

exit 0。

## 剩餘

未 commit、未 push。主 checkout 仍是會 127 / 誤開 Ubuntu 的舊呼叫。
