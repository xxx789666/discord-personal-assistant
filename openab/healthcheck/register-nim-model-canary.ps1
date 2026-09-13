<#
  register-nim-model-canary.ps1 — 註冊 Windows 排程工作 OpenAB-NimModelCanary

  每天跑一次 nim-model-canary.ps1（NIM 模型下架探測）。
  不需要像 mount-watchdog 每 5 分鐘；下架是永久事件，一天一次夠用。

  -WhatIf：只印出將註冊的內容，不寫入工作排程器。

  沿用 register-mount-watchdog.ps1 踩過的坑：
  - 不要傳 -RepetitionDuration（[TimeSpan]::MaxValue 會被拒）
  - 不要用 schtasks /TR（含空白與中文的路徑會失敗）
  - 透過 run-hidden.vbs 啟動，否則每天跳一個 PowerShell 視窗
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'

$TaskName = 'OpenAB-NimModelCanary'
$ScriptPath = Join-Path $PSScriptRoot 'nim-model-canary.ps1'
# 透過 run-hidden.vbs 啟動，否則每天會跳出一個 PowerShell 視窗。
# -WindowStyle Hidden 不夠：主控台先建立、樣式後套用，仍會閃一下。
# vbs 裡用 bWaitOnReturn=True + WScript.Quit 把 exit code 傳回來，
# LastTaskResult 才能繼續當健康訊號用。
$LauncherPath = Join-Path $PSScriptRoot 'run-hidden.vbs'
$Arg = "//nologo `"$LauncherPath`" `"$ScriptPath`""

Write-Output "TaskName : $TaskName"
Write-Output "Execute  : wscript.exe (run-hidden.vbs -> powershell.exe, 無視窗)"
Write-Output "Argument : $Arg"
Write-Output 'Trigger  : daily at 09:40'
Write-Output 'Duration : omitted (daily trigger; do not pass [TimeSpan]::MaxValue)'
Write-Output 'Logon    : Interactive (跟 mount-watchdog 一樣需要使用者 session)'

if (-not (Test-Path $ScriptPath)) {
  throw "nim-model-canary.ps1 not found: $ScriptPath"
}
if (-not (Test-Path $LauncherPath)) {
  throw "run-hidden.vbs not found: $LauncherPath"
}

$action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument $Arg
$trigger = New-ScheduledTaskTrigger -Daily -At '09:40'
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
# 三次極小 chat/completions，正常數十秒；15 分鐘上限足夠，卡住時不擋後續觸發。
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Write-Output "Registered $TaskName"
} else {
  Write-Output 'WhatIf: not registered'
}
