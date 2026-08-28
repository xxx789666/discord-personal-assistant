<#
  register-mount-watchdog.ps1 — 註冊 Windows 排程工作 OpenAB-MountWatchdog

  每 5 分鐘跑一次 mount-watchdog.ps1。
  -WhatIf：只印出將註冊的內容，不寫入工作排程器。

  已知坑（先前註冊 OAuth 排程時踩過）：
  - 不要傳 -RepetitionDuration ([TimeSpan]::MaxValue 會被拒)
  - 不要用 schtasks /TR（含空白與中文的路徑會失敗）
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param()

$ErrorActionPreference = 'Stop'

$TaskName = 'OpenAB-MountWatchdog'
$ScriptPath = Join-Path $PSScriptRoot 'mount-watchdog.ps1'
$Arg = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

Write-Output "TaskName : $TaskName"
Write-Output "Execute  : powershell.exe"
Write-Output "Argument : $Arg"
Write-Output 'Trigger  : once at next minute, repetition every 5 minutes'
Write-Output 'Duration : omitted (indefinite; do not pass [TimeSpan]::MaxValue)'
Write-Output 'Logon    : Interactive (Docker Desktop 需要使用者 session)'

if (-not (Test-Path $ScriptPath)) {
  throw "mount-watchdog.ps1 not found: $ScriptPath"
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $Arg
$start = (Get-Date).AddMinutes(1)
$start = Get-Date -Year $start.Year -Month $start.Month -Day $start.Day -Hour $start.Hour -Minute $start.Minute -Second 0
$trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes 5)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
# ExecutionTimeLimit 1 小時：預設 72 小時配 IgnoreNew，一次卡死會擋掉之後所有觸發。
# 不可設得比 1 小時短——一次合法自癒最壞是 900s + 600s + 探測，約 30 分鐘。
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 1)

if ($PSCmdlet.ShouldProcess($TaskName, 'Register scheduled task')) {
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Write-Output "Registered $TaskName"
} else {
  Write-Output 'WhatIf: not registered'
}
