<#
  register-wslg-trace-cleanup.ps1 — 註冊 Windows 排程工作 OpenAB-WslgTraceCleanup

  每小時跑一次 wslg-trace-cleanup.ps1（保留 24 小時內的追蹤檔）。
  背景與為什麼不用 guiApplications=false 關掉 WSLg，見 wslg-trace-cleanup.ps1 開頭。

  -WhatIf：只印出將註冊的內容，不寫入工作排程器。

  沿用 register-mount-watchdog.ps1 踩過的坑：
  - 不要傳 -RepetitionDuration（[TimeSpan]::MaxValue 會被拒）
  - 不要用 schtasks /TR（含空白與中文的路徑會失敗）
  - 透過 run-hidden.vbs 啟動，否則每小時跳一個 PowerShell 視窗
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'

$TaskName = 'OpenAB-WslgTraceCleanup'
$ScriptPath = Join-Path $PSScriptRoot 'wslg-trace-cleanup.ps1'
$LauncherPath = Join-Path $PSScriptRoot 'run-hidden.vbs'
$Arg = "//nologo `"$LauncherPath`" `"$ScriptPath`""

Write-Output "TaskName : $TaskName"
Write-Output "Execute  : wscript.exe (run-hidden.vbs -> powershell.exe, 無視窗)"
Write-Output "Argument : $Arg"
Write-Output 'Trigger  : once at next hour, repetition every 1 hour'
Write-Output 'Duration : omitted (indefinite; do not pass [TimeSpan]::MaxValue)'
Write-Output 'Logon    : Interactive (追蹤檔在使用者的 %LOCALAPPDATA%\Temp 下)'

if (-not (Test-Path $ScriptPath)) {
  throw "wslg-trace-cleanup.ps1 not found: $ScriptPath"
}
if (-not (Test-Path $LauncherPath)) {
  throw "run-hidden.vbs not found: $LauncherPath"
}

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $Arg
$start = (Get-Date).AddMinutes(2)
$start = Get-Date -Year $start.Year -Month $start.Month -Day $start.Day -Hour $start.Hour -Minute $start.Minute -Second 0
$trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Hours 1)
# 追蹤檔在使用者 profile 底下，必須用互動式登入身分，跟 mount-watchdog 一致。
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
# 實測刪 4363 個檔約 5 秒；15 分鐘上限足夠，且卡住時不會擋掉後續觸發。
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Write-Output "Registered $TaskName"
} else {
  Write-Output 'WhatIf: not registered'
}
