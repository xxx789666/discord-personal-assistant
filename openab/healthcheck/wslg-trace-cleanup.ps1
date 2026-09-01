<#
  wslg-trace-cleanup.ps1 — 清掉 WSLg 無上限成長的 WPP 追蹤檔

  背景：
    %LOCALAPPDATA%\Temp\DiagOutputDir\RdClientAutoTrace 裡的檔案不是遠端桌面
    產生的。寫入者是 WSLg 的 msrdc.exe（`msrdc.exe /wslg /silent /v:<vm-id>`，
    父程序 wslhost.exe），也就是 WSL 把 Linux 視窗畫到 Windows 的那條 RDP 通道。

    msrdc 一啟動就開 WPP autotrace，速率固定為每分鐘一個約 8.9 MB 的 .etl，
    跟機器在做什麼無關（實測 1429 / 1648 / 1597 檔 ≈ 每天 1440 檔）。
    2026-08-31 量到 4748 檔 / 42 GB，佔掉 C: 剩餘空間的一半。

  為什麼要排程刪，而不是關掉 WSLg：
    `guiApplications=false` 可以讓 msrdc 完全不啟動，但那是 .wslconfig 的全機器
    設定，會連帶讓其他專案不能從 WSL 開 Linux GUI 程式。為了本專案的磁碟去砍掉
    整台機器的能力，代價擺錯地方，所以不採用。

    msrdc 也沒有任何原生的保留上限：2026-08-31 查過
    HKCU\Software\Microsoft\Terminal Server Client、RdClientRadc、MSRDC 與
    HKLM 的 Terminal Services 原則，全域搜尋 "AutoTrace" 也是零筆。
    沒有可設定的 cap，只能自己刪。

    msrdc 重啟不會清舊檔（2026-08-30 13:11 重啟過，08-27 的檔案仍在），
    所以要當成無上限成長處理。

  行為：
    只刪 RdClientAutoTrace-*.etl 中修改時間早於 -RetentionHours 的。
    正在寫入的那一個會被鎖住，計入 locked 而不算失敗——那是預期狀況。

  用法：
    .\wslg-trace-cleanup.ps1 -WhatIf      # 只看會刪幾個
    .\wslg-trace-cleanup.ps1              # 實際清理（保留 24 小時）
    .\wslg-trace-cleanup.ps1 -RetentionHours 6    # 想壓小就調這個
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [ValidateRange(1, 720)]
  # 24 小時：08-27 那次掛載崩潰是隔了 9 小時才被發現的，保留窗口必須
  # 撐得過「晚上出事、隔天早上才查」。代價是穩態約 12.8 GB。
  [int]$RetentionHours = 24
)

$ErrorActionPreference = 'Stop'

# 只清這個前綴。MSRDCEventProcessor_*.etl 是 msrdc 自己輪替的小環狀檔
# （各 4 KB、持續開著），不在清理範圍內。
$Pattern = 'RdClientAutoTrace-*.etl'
$ExpectedSuffix = 'DiagOutputDir\RdClientAutoTrace'

if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
  Write-Error 'LOCALAPPDATA 是空的，不猜路徑。'
  exit 1
}
$TraceDir = Join-Path $env:LOCALAPPDATA (Join-Path 'Temp' $ExpectedSuffix)

# 保險絲：解析出來的路徑一定要以預期後綴結尾才動手。
# 環境變數異常時寧可什麼都不做，也不要對錯的目錄下 Remove-Item -Force。
if (-not $TraceDir.EndsWith($ExpectedSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
  Write-Error "路徑不像追蹤目錄，中止：$TraceDir"
  exit 1
}

$StateDir = Join-Path $PSScriptRoot '.state'
$LogPath = Join-Path $StateDir 'wslg-trace-cleanup.log'

function Write-Log {
  param([string]$Message)
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Output $line
  if ($WhatIfPreference) { return }
  try {
    if (-not (Test-Path -LiteralPath $StateDir)) {
      New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    # 日誌自己也要有上限，否則就變成第二個同類問題。
    if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 256KB)) {
      $keep = @(Get-Content -LiteralPath $LogPath -Tail 200)
      Set-Content -LiteralPath $LogPath -Value $keep -Encoding UTF8
    }
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
  } catch {
    # 寫不了日誌不該讓清理失敗。
  }
}

function Format-Size {
  param([long]$Bytes)
  if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
  if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
  return ('{0:N0} B' -f $Bytes)
}

if (-not (Test-Path -LiteralPath $TraceDir)) {
  # WSLg 沒跑過就不會有這個目錄，不是錯誤。
  Write-Log "skip: 目錄不存在 $TraceDir"
  exit 0
}

$cutoff = (Get-Date).AddHours(-$RetentionHours)
$stale = @(Get-ChildItem -LiteralPath $TraceDir -Filter $Pattern -File -ErrorAction SilentlyContinue |
           Where-Object { $_.LastWriteTime -lt $cutoff })

$deleted = 0
$locked = 0
$freed = [long]0

foreach ($f in $stale) {
  if (-not $PSCmdlet.ShouldProcess($f.Name, 'Remove')) { continue }
  try {
    $size = $f.Length
    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
    $deleted++
    $freed += $size
  } catch {
    # 正在寫入的那一個必然鎖住；下一輪就會被清掉。
    $locked++
  }
}

$remain = @(Get-ChildItem -LiteralPath $TraceDir -Filter $Pattern -File -ErrorAction SilentlyContinue)
$remainBytes = [long]0
foreach ($r in $remain) { $remainBytes += $r.Length }

if ($WhatIfPreference) {
  Write-Log ("WhatIf: 符合刪除條件 {0} 個（早於 {1:yyyy-MM-dd HH:mm}），目前總計 {2} 個 / {3}" -f `
    $stale.Count, $cutoff, $remain.Count, (Format-Size $remainBytes))
} else {
  Write-Log ("deleted={0} locked={1} freed={2} remain={3} 個 / {4} (retention={5}h)" -f `
    $deleted, $locked, (Format-Size $freed), $remain.Count, (Format-Size $remainBytes), $RetentionHours)
}

exit 0
