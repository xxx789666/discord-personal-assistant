<#
  mount-watchdog.ps1 — Docker bind-mount 掛載守護（偵測 + 告警 + 自癒）

  規格：docs/mount_watchdog_spec_2026_08_27.md
  起因：2026-08-27 Docker Desktop WSL2 utility VM 崩潰，9p 全斷，既有
  healthcheck 只 pgrep 程序、完全不碰檔案系統，故障藏了約 9 小時。

  用法：
    .\mount-watchdog.ps1            # 偵測；FAIL 時依 Scope 告警／自癒
    .\mount-watchdog.ps1 -DryRun    # 偵測 + 印出自癒步驟，不執行、不發 Discord
    .\mount-watchdog.ps1 -SelfTest  # 純函式單元測試（不碰 Docker／行程）
    .\mount-watchdog.ps1 -TestAlert # 只發一則測試 Discord，不動狀態檔
#>
param(
  [switch]$SelfTest,
  [switch]$DryRun,
  [switch]$TestAlert,
  [string]$MountsFile = '',
  [string]$StateDir = '',
  [string]$AlertEnv = '',
  [string]$TokenEnv = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)  # repo root
$KnownCheckoutLocal = 'D:\discord 個人助理\.local'
# $EnvAlert / $EnvTokens：SelfTest 之後由 Resolve-AlertEnvPaths 填入（TestAlert 與正式路徑同一條）。
$EnvAlert = ''
$EnvTokens = ''
if ($StateDir -eq '') { $StateDir = Join-Path $PSScriptRoot '.state' }
$StateFile  = Join-Path $StateDir 'mount-watchdog.json'
$LogFile    = Join-Path $StateDir 'mount-watchdog.log'
$OwnerId    = '843428445802725388'
$RealertMin = 60
$HealMax    = 2
$HealWindowHours = 24
$HealMinIntervalMinutes = 60
$LatchExpireHours = 24
$DaemonConfirmCount = 2
$AllDownConfirmCount = 2
$ResidentDownMinutes = 30
$ResidentAlertEveryMinutes = 60
$DiscordFailExitCount = 3
# 規格 §6.5：事故當下 vmmemWSL 超過 10 分鐘才消失。300s 會讓 abort-vmmem 變常態。
$VmmemTimeoutSec = 900
$MountProbeTimeoutSec = 600
# 內層 timeout 10s；host 15s 當第二道保險。最壞 12×15s=180s，排程改 5 分鐘以免卡滿一個 interval。
$Tier1TimeoutSec = 15
$InnerLsTimeoutSec = 10
$Tier2TimeoutSec = 30
$LogMaxBytes = 5MB

# 規格 §4.1 完整掛載清單。Path 必須是掛載點本身，不可只 ls 父目錄。
# Optional：compose profile 服務，沒起來是預期內，不算掛載故障。
$Mounts = @(
  @{ Container = 'openab-url-intake';     Path = '/vault' },
  @{ Container = 'intake-publisher';      Path = '/vault' },
  @{ Container = 'pdf-publisher';         Path = '/vault' },
  @{ Container = 'openab-estate';         Path = '/workspace/EstateSpace' },
  @{ Container = 'openab-travel-claude';  Path = '/workspace/TravelMemory' },
  @{ Container = 'openab-travel-nvidia';  Path = '/workspace/TravelMemory' },
  @{ Container = 'openab-credit-report';  Path = '/workspace/CreditReportSpace'; Optional = $true },
  @{ Container = 'openab-kiro';           Path = '/workspace/KiroSpace' },
  @{ Container = 'openab-kiro';           Path = '/workspace/TravelMemory' },
  @{ Container = 'openab-nvidia-lab';     Path = '/workspace/LabSpace' },
  @{ Container = 'openab-astruct';        Path = '/workspace/AStructSpace' },
  @{ Container = 'openab-astruct';        Path = '/workspace/AStructSpace/forward' }
)

if (-not $SelfTest -and $MountsFile -ne '') {
  if (-not (Test-Path $MountsFile)) { throw "MountsFile not found: $MountsFile" }
  $mfRaw = Get-Content -Path $MountsFile -Raw
  if ($null -eq $mfRaw) { throw "MountsFile is empty: $MountsFile" }
  $mfParsed = $mfRaw.Trim() | ConvertFrom-Json
  $Mounts = @()
  foreach ($item in @($mfParsed)) {
    $h = @{ Container = [string]$item.Container; Path = [string]$item.Path }
    if ($item.Optional -eq $true) { $h.Optional = $true }
    $Mounts += $h
  }
}

$HostVaultProbe = 'D:/discord 個人助理/URLIntake'
$DockerDesktopExe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
$DockerKillNames = @('Docker Desktop', 'com.docker.backend', 'com.docker.build')

# ── 純函式（SelfTest 注入假資料；不含 Docker／行程／網路）──────────────────

function Get-InitialWatchdogState {
  return [pscustomobject]@{
    status            = 'OK'
    scope             = $null
    lastAlertAt       = $null
    lastChangeAt      = $null
    failedMounts      = @()
    healAt            = @()
    manualRequired    = $false
    manualRequiredAt  = $null
    notRunning        = @()
    notRunningSince   = @{}
    lastResidentAlertAt = $null
    consecutiveFail     = 0
    consecutiveAllDown  = 0
    lastAllDownAlertAt  = $null
    discordFailCount    = 0
    lastDiscordError    = $null
  }
}

function Get-CoercedInt {
  param($Value, [int]$Default = 0)
  if ($null -eq $Value -or $Value -eq '') { return $Default }
  return [int]$Value
}

function Get-CoercedBool {
  param($Value)
  if ($Value -eq $true) { return $true }
  return $false
}

function Convert-ToArray {
  param($Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Array]) { return @($Value) }
  return @($Value)
}

function Get-Tier2Scope {
  param(
    [int]$ExitCode,
    [string]$Output,
    [string]$ErrorOutput
  )
  if ($ExitCode -ne 0) {
    return 'daemon'
  }
  $combined = ''
  if ($null -ne $Output) { $combined += $Output }
  if ($null -ne $ErrorOutput) { $combined += $ErrorOutput }
  if ($combined -match 'd\?{9}') {
    return 'vm'
  }
  return 'container'
}

function Get-AlertAction {
  param(
    [string]$PreviousStatus,
    [string]$NewStatus,
    $LastAlertAt,
    [DateTime]$Now,
    [int]$RealertMinutes = 60
  )
  if ($NewStatus -eq 'FAIL' -and $PreviousStatus -ne 'FAIL') {
    return [pscustomobject]@{ Send = $true; Kind = 'fail' }
  }
  if ($NewStatus -eq 'OK' -and $PreviousStatus -eq 'FAIL') {
    return [pscustomobject]@{ Send = $true; Kind = 'recovered' }
  }
  if ($NewStatus -eq 'FAIL' -and $PreviousStatus -eq 'FAIL') {
    if ($null -eq $LastAlertAt -or $LastAlertAt -eq '') {
      return [pscustomobject]@{ Send = $true; Kind = 'fail-repeat' }
    }
    $last = [DateTime]$LastAlertAt
    $elapsed = ($Now - $last).TotalMinutes
    if ($elapsed -ge $RealertMinutes) {
      return [pscustomobject]@{ Send = $true; Kind = 'fail-repeat' }
    }
    return [pscustomobject]@{ Send = $false; Kind = 'throttled' }
  }
  return [pscustomobject]@{ Send = $false; Kind = 'none' }
}

function Get-MountVerdict {
  param(
    [int]$InspectExit,
    [string]$RunningRaw,
    [int]$ExecExit,
    [string]$ExecOut
  )
  if ($InspectExit -ne 0) { return 'absent' }
  $running = ''
  if ($null -ne $RunningRaw) { $running = $RunningRaw.Trim().ToLower() }
  if ($running -ne 'true') { return 'stopped' }
  if ($ExecExit -eq 124) { return 'mount-fail' }
  $out = ''
  if ($null -ne $ExecOut) { $out = $ExecOut.Trim() }
  if ($ExecExit -eq 0 -and $out -eq 'OK') { return 'ok' }
  return 'mount-fail'
}

function Get-MountFailResults {
  param($Results)
  $failed = @()
  foreach ($r in (Convert-ToArray $Results)) {
    if ($null -eq $r) { continue }
    if ($r.Verdict -eq 'mount-fail') { $failed += $r }
  }
  return ,$failed
}

function Get-ProbedCount {
  param($Results)
  $n = 0
  foreach ($r in (Convert-ToArray $Results)) {
    if ($null -eq $r) { continue }
    if ($r.Verdict -eq 'ok' -or $r.Verdict -eq 'mount-fail') { $n++ }
  }
  return $n
}

function Get-ProbeRunDecision {
  param($Results)
  $failed = Get-MountFailResults $Results
  $probed = Get-ProbedCount $Results
  if ($failed.Count -gt 0) {
    return [pscustomobject]@{
      Status = 'FAIL'; NeedTier2 = $true; Probed = $probed
      ClearLatch = $false; AllowRecovered = $false; Reason = 'mount-fail'
    }
  }
  if ($probed -eq 0) {
    return [pscustomobject]@{
      Status = 'FAIL'; NeedTier2 = $true; Probed = 0
      ClearLatch = $false; AllowRecovered = $false; Reason = 'unprobed'
    }
  }
  return [pscustomobject]@{
    Status = 'OK'; NeedTier2 = $false; Probed = $probed
    ClearLatch = $true; AllowRecovered = $true; Reason = 'ok'
  }
}

function Resolve-FirstExistingPath {
  param([string]$Explicit, [string[]]$Candidates)
  if ($null -ne $Explicit -and $Explicit -ne '') { return [string]$Explicit }
  foreach ($p in (Convert-ToArray $Candidates)) {
    if ($null -eq $p -or $p -eq '') { continue }
    if (Test-Path -LiteralPath $p) { return [string]$p }
  }
  foreach ($p in (Convert-ToArray $Candidates)) {
    if ($null -ne $p -and $p -ne '') { return [string]$p }
  }
  return ''
}

function Resolve-AlertEnvPaths {
  param(
    [string]$AlertEnv = '',
    [string]$TokenEnv = '',
    [string]$RepoRoot,
    [string]$KnownLocal = 'D:\discord 個人助理\.local'
  )
  $alertCandidates = @(
    (Join-Path $RepoRoot '.local\infra_alert.env'),
    (Join-Path $KnownLocal 'infra_alert.env')
  )
  $alertPath = Resolve-FirstExistingPath -Explicit $AlertEnv -Candidates $alertCandidates
  $tokenPath = $TokenEnv
  if ($null -eq $tokenPath) { $tokenPath = '' }
  if ($tokenPath -eq '') {
    $beside = ''
    if ($alertPath -ne '') { $beside = Join-Path (Split-Path -Parent $alertPath) 'discord_token.env' }
    $tokenCandidates = @(
      $beside,
      (Join-Path $RepoRoot '.local\discord_token.env'),
      (Join-Path $KnownLocal 'discord_token.env')
    )
    $tokenPath = Resolve-FirstExistingPath -Explicit '' -Candidates $tokenCandidates
  }
  return [pscustomobject]@{
    AlertPath       = $alertPath
    TokenPath       = $tokenPath
    AlertCandidates = $alertCandidates
  }
}

function Format-FailList {
  param($Results)
  $lines = @()
  foreach ($r in (Convert-ToArray $Results)) {
    if ($null -eq $r) { continue }
    if ($r.Verdict -eq 'mount-fail') {
      $lines += ('• {0} {1} ({2})' -f $r.Container, $r.Path, $r.Detail)
    }
  }
  return ($lines -join "`n")
}

function Get-AllDownDecision {
  param(
    [string]$DecisionReason,
    [string]$Scope,
    [int]$PrevConsecutive = 0,
    [int]$ConfirmCount = 2
  )
  $active = ($DecisionReason -eq 'unprobed' -and $Scope -eq 'container')
  if (-not $active) {
    return [pscustomobject]@{
      Active = $false; Consecutive = 0; SendInfo = $false; SuppressFail = $false
    }
  }
  $n = $PrevConsecutive + 1
  return [pscustomobject]@{
    Active = $true
    Consecutive = $n
    SendInfo = ($n -ge $ConfirmCount)
    SuppressFail = $true
  }
}

function Format-AllDownNotice {
  param([int]$Count)
  return ('ℹ️ **mount-watchdog** {0} 條全部無法探測（容器皆不存在）。這通常是 compose down / 維護，不是 9p 故障。不重啟、不自癒。' -f $Count)
}

function Test-HttpSuccess {
  param([int]$Code)
  return ($Code -ge 200 -and $Code -lt 300)
}

function Test-PreviousFailsNowOk {
  param($PrevFailed, $NewResults)
  $prev = @(Convert-ToArray $PrevFailed)
  if ($prev.Count -eq 0) { return $false }
  foreach ($f in $prev) {
    $c = $null
    $p = $null
    if ($f -is [string]) {
      $parts = $f.Split(':')
      $c = $parts[0]
      if ($parts.Count -gt 1) { $p = ($parts[1..($parts.Count - 1)] -join ':') }
    } else {
      $c = $f.Container
      $p = $f.Path
    }
    $found = $false
    foreach ($r in (Convert-ToArray $NewResults)) {
      if ($r.Container -eq $c -and $r.Path -eq $p) {
        $found = $true
        if ($r.Verdict -ne 'ok') { return $false }
      }
    }
    if (-not $found) { return $false }
  }
  return $true
}

# 自癒 / 重啟後的唯一判定＋文案。兩邊都必須走這裡，禁止各寫一份「成功了嗎」。
function Get-InterventionOutcome {
  param(
    $Results,
    $PrevFailed,
    [string]$Mode = 'heal',
    [string]$OwnerMention = 'OWNER'
  )
  if ($null -eq $OwnerMention -or $OwnerMention -eq '') { $OwnerMention = 'OWNER' }
  $decision = Get-ProbeRunDecision $Results
  $failed = Get-MountFailResults $Results
  $n = [int]$decision.Probed
  $m = @(Convert-ToArray $Results).Count
  $prevOk = Test-PreviousFailsNowOk $PrevFailed $Results
  $claim = ($decision.Status -eq 'OK' -and $prevOk)

  $verb = '自癒'
  if ($Mode -eq 'restart') { $verb = '重啟' }

  if ($claim) {
    $text = "<@$OwnerMention> ✅ **mount-watchdog** ${verb}完成：probed=$n/$m，先前失敗的掛載均已可讀。"
    if ($Mode -eq 'restart') {
      $text = "<@$OwnerMention> ✅ **mount-watchdog** 已由重啟容器修復（先前 Scope=container）。probed=$n/$m。"
    }
    return [pscustomobject]@{
      Decision = $decision; Failed = ,$failed; ClaimSuccess = $true
      Kind = 'ok'; Text = $text; Probed = $n; Total = $m
    }
  }
  if ($decision.Reason -eq 'unprobed') {
    $text = "<@$OwnerMention> ⚠️ **mount-watchdog** ${verb}後仍無法探測：$m 條全部 SKIP（probed=0，容器尚未恢復）。這不是成功。"
    return [pscustomobject]@{
      Decision = $decision; Failed = ,$failed; ClaimSuccess = $false
      Kind = 'unprobed'; Text = $text; Probed = $n; Total = $m
    }
  }
  if ($decision.Reason -eq 'mount-fail') {
    $failN = @($failed).Count
    $text = "<@$OwnerMention> ⚠️ **mount-watchdog** ${verb}後仍有 $failN 條掛載失敗：`n" + (Format-FailList $Results)
    return [pscustomobject]@{
      Decision = $decision; Failed = ,$failed; ClaimSuccess = $false
      Kind = 'mount-fail'; Text = $text; Probed = $n; Total = $m
    }
  }
  $text = "<@$OwnerMention> ⚠️ **mount-watchdog** ${verb}後僅 probed=$n/$m，先前失敗的掛載尚未全部可讀。這不是成功。"
  return [pscustomobject]@{
    Decision = $decision; Failed = ,$failed; ClaimSuccess = $false
    Kind = 'incomplete'; Text = $text; Probed = $n; Total = $m
  }
}

function Get-NextDiscordFailCount {
  param([int]$PrevCount, [bool]$SendFailedThisRun)
  if ($SendFailedThisRun) {
    if ($PrevCount -lt 1) { return 1 }
    return $PrevCount
  }
  return 0
}

function Test-ThisRunAbnormal {
  param([string]$NewStatus, [bool]$SendFailedThisRun)
  if ($NewStatus -eq 'FAIL') { return $true }
  if ($SendFailedThisRun) { return $true }
  return $false
}

function Convert-SinceMap {
  param($Value)
  $map = @{}
  if ($null -eq $Value) { return $map }
  if ($Value -is [hashtable]) {
    foreach ($k in $Value.Keys) { $map[[string]$k] = [string]$Value[$k] }
    return $map
  }
  foreach ($p in $Value.PSObject.Properties) {
    $map[[string]$p.Name] = [string]$p.Value
  }
  return $map
}

function Test-MountOptional {
  param([string]$Container, [string]$Path, $MountList)
  foreach ($m in (Convert-ToArray $MountList)) {
    if ($m.Container -eq $Container -and $m.Path -eq $Path) {
      if ($m.Optional -eq $true) { return $true }
    }
  }
  return $false
}

function Get-ResidentDownNotice {
  param(
    $Results,
    $MountList,
    $PrevSince,
    [DateTime]$Now,
    $LastAlertAt,
    [int]$DownMinutes = 30,
    [int]$ThrottleMinutes = 60
  )
  $since = Convert-SinceMap $PrevSince
  $next = @{}
  $overdue = @()
  foreach ($r in (Convert-ToArray $Results)) {
    if ($null -eq $r) { continue }
    if ($r.Verdict -ne 'stopped' -and $r.Verdict -ne 'absent') { continue }
    if (Test-MountOptional -Container $r.Container -Path $r.Path -MountList $MountList) { continue }
    $key = '{0}:{1}' -f $r.Container, $r.Path
    $prevTs = $since[$key]
    if ($null -eq $prevTs -or $prevTs -eq '') {
      $next[$key] = $Now.ToString('o')
    } else {
      $next[$key] = $prevTs
      $dt = [DateTime]$prevTs
      if (($Now - $dt).TotalMinutes -ge $DownMinutes) { $overdue += $key }
    }
  }
  $send = $false
  if ($overdue.Count -gt 0) {
    $send = $true
    if ($null -ne $LastAlertAt -and $LastAlertAt -ne '') {
      $last = [DateTime]$LastAlertAt
      if (($Now - $last).TotalMinutes -lt $ThrottleMinutes) { $send = $false }
    }
  }
  $lines = @()
  foreach ($k in $overdue) { $lines += ('• {0}' -f $k) }
  $text = 'ℹ️ **mount-watchdog** 常駐容器已停超過 ' + $DownMinutes + ' 分鐘（不重啟、不自癒）：' + "`n" + ($lines -join "`n")
  return [pscustomobject]@{
    Since = $next
    Send  = $send
    Lines = $lines
    Text  = $text
  }
}

function Get-HealBudget {
  param(
    $HealAt,
    [DateTime]$Now,
    [int]$MaxHeals = 2,
    [int]$WindowHours = 24,
    [int]$MinIntervalMinutes = 60
  )
  $cutoff = $Now.AddHours(-$WindowHours)
  $recent = @()
  foreach ($ts in (Convert-ToArray $HealAt)) {
    if ($null -eq $ts -or $ts -eq '') { continue }
    $dt = [DateTime]$ts
    if ($dt -ge $cutoff) { $recent += $dt }
  }
  $allowed = $true
  $reason = 'ok'
  if ($recent.Count -ge $MaxHeals) {
    $allowed = $false
    $reason = 'cap'
  } elseif ($recent.Count -gt 0 -and $MinIntervalMinutes -gt 0) {
    $latest = $recent[0]
    foreach ($dt in $recent) {
      if ($dt -gt $latest) { $latest = $dt }
    }
    if (($Now - $latest).TotalMinutes -lt $MinIntervalMinutes) {
      $allowed = $false
      $reason = 'cooldown'
    }
  }
  return [pscustomobject]@{
    Allowed = $allowed
    Count   = $recent.Count
    Recent  = $recent
    Reason  = $reason
  }
}

function Get-SelfHealGate {
  param(
    $State,
    [DateTime]$Now,
    $Budget,
    [int]$LatchExpireHours = 24
  )
  $latched = $false
  if (Get-CoercedBool $State.manualRequired) {
    $at = $State.manualRequiredAt
    if ($null -eq $at -or $at -eq '') {
      $latched = $true
    } else {
      $elapsedH = ($Now - [DateTime]$at).TotalHours
      if ($elapsedH -lt $LatchExpireHours) { $latched = $true }
    }
  }
  if ($latched) { return 'latched' }
  if (-not $Budget.Allowed) {
    if ($Budget.Reason -eq 'cooldown') { return 'cooldown' }
    return 'cap'
  }
  return 'allow'
}

function Get-ComposeHealthcheckLsPaths {
  param([string]$ComposeText)
  $paths = @()
  $rx = [regex]::Matches($ComposeText, 'ls\s+(/[^\s>"'']+)')
  foreach ($m in $rx) {
    $p = $m.Groups[1].Value
    if ($paths -notcontains $p) { $paths += $p }
  }
  return $paths
}

function Get-ScopeAction {
  param([string]$Scope)
  if ($Scope -eq 'vm') { return 'self-heal' }
  if ($Scope -eq 'container') { return 'restart-failed' }
  if ($Scope -eq 'daemon') { return 'alert-only' }
  if ($Scope -eq 'all-down') { return 'none' }
  return 'none'
}

function Get-FailedContainerNames {
  param($FailedMounts)
  $names = @()
  foreach ($m in (Convert-ToArray $FailedMounts)) {
    $c = $null
    if ($m -is [string]) { $c = $m }
    else { $c = $m.Container }
    if ($null -eq $c -or $c -eq '') { continue }
    if ($names -notcontains $c) { $names += $c }
  }
  return $names
}

function Test-AlertChannelConfigured {
  param([string]$ChannelId)
  if ($null -eq $ChannelId) { return $false }
  $c = [string]$ChannelId
  $c = $c.Trim()
  if ($c -eq '') { return $false }
  if ($c -match '^(<|PASTE_|YOUR_|placeholder|CHANGE_ME)') { return $false }
  if ($c -notmatch '^\d+$') { return $false }
  return $true
}

function Get-SelfHealSteps {
  return @(
    'Discord 告警：偵測到 VM 層級掛載故障，開始自癒',
    'wsl --shutdown（不等待指令返回，改輪詢 vmmemWSL）',
    '輪詢 vmmemWSL／vmmem 直到消失，上限 900 秒；超時則停手並告警需要人工處理／重開機（不再重試，寫入 manualRequired 閂鎖）',
    '殺掉殘留行程：Docker Desktop, com.docker.backend, com.docker.build（不用 docker desktop restart）',
    '啟動 C:\Program Files\Docker\Docker\Docker Desktop.exe',
    '輪詢 docker run --rm -v "D:/discord 個人助理/URLIntake:/vault" alpine ls /vault 直到成功，上限 600 秒',
    '重跑 Tier 1 全清單驗證，結果發 Discord'
  )
}

function Read-DotEnv {
  param([string]$Path)
  $map = @{}
  if (-not (Test-Path $Path)) { return $map }
  $lines = Get-Content -Path $Path
  if ($null -eq $lines) { return $map }
  foreach ($line in @($lines)) {
    if ($null -eq $line) { continue }
    if ($line -match '^([A-Z_][A-Z0-9_]*)=(.*)$') {
      $map[$Matches[1]] = $Matches[2].Trim()
    }
  }
  return $map
}

# ── SelfTest（必須在任何 I/O 副作用之前可獨立跑）──────────────────────────

function Invoke-SelfTest {
  $script:FailCount = 0
  function Assert-Eq {
    param($Actual, $Expected, [string]$Name)
    $a = [string]$Actual
    $e = [string]$Expected
    if ($a -ne $e) {
      Write-Output "[FAIL] $Name : expected '$e' got '$a'"
      $script:FailCount++
    } else {
      Write-Output "[PASS] $Name"
    }
  }
  function Assert-True {
    param([bool]$Cond, [string]$Name)
    if (-not $Cond) {
      Write-Output "[FAIL] $Name"
      $script:FailCount++
    } else {
      Write-Output "[PASS] $Name"
    }
  }

  Write-Output '=== mount-watchdog SelfTest ==='

  # 掛載點必須是清單本身，不可只掃 /workspace 或 /
  Assert-Eq $Mounts.Count 12 'mount list has 12 entries'
  $badParent = $false
  foreach ($m in $Mounts) {
    if ($m.Path -eq '/workspace' -or $m.Path -eq '/' -or $m.Path -eq '/run') {
      $badParent = $true
    }
  }
  Assert-True (-not $badParent) 'no probe path is a parent directory only'

  $kiroPaths = @()
  $astructPaths = @()
  foreach ($m in $Mounts) {
    if ($m.Container -eq 'openab-kiro') { $kiroPaths += $m.Path }
    if ($m.Container -eq 'openab-astruct') { $astructPaths += $m.Path }
  }
  Assert-True ($kiroPaths -contains '/workspace/KiroSpace') 'kiro probes KiroSpace itself'
  Assert-True ($kiroPaths -contains '/workspace/TravelMemory') 'kiro probes TravelMemory itself'
  Assert-True ($astructPaths -contains '/workspace/AStructSpace') 'astruct probes AStructSpace itself'
  Assert-True ($astructPaths -contains '/workspace/AStructSpace/forward') 'astruct probes C: forward mount itself'
  $crOptional = $false
  foreach ($m in $Mounts) {
    if ($m.Container -eq 'openab-credit-report' -and $m.Optional -eq $true) { $crOptional = $true }
  }
  Assert-True $crOptional 'credit-report is marked Optional (compose profile)'

  # A1: 容器沒在跑 ≠ 掛載故障
  Assert-Eq (Get-MountVerdict -InspectExit 1 -RunningRaw '' -ExecExit 0 -ExecOut 'OK') 'absent' 'inspect exit=1 => absent'
  Assert-Eq (Get-MountVerdict -InspectExit 0 -RunningRaw 'false' -ExecExit 0 -ExecOut 'OK') 'stopped' 'running=false => stopped'
  Assert-Eq (Get-MountVerdict -InspectExit 0 -RunningRaw 'true' -ExecExit 0 -ExecOut 'OK') 'ok' 'running+exec OK => ok'
  Assert-Eq (Get-MountVerdict -InspectExit 0 -RunningRaw 'true' -ExecExit 0 -ExecOut 'FAIL') 'mount-fail' 'running+exec FAIL => mount-fail'
  Assert-Eq (Get-MountVerdict -InspectExit 0 -RunningRaw 'true' -ExecExit 124 -ExecOut '') 'mount-fail' 'running+exec timeout => mount-fail'

  $mixed = @(
    [pscustomobject]@{ Container = 'pdf-publisher'; Path = '/vault'; Verdict = 'stopped' },
    [pscustomobject]@{ Container = 'openab-credit-report'; Path = '/workspace/CreditReportSpace'; Verdict = 'absent' },
    [pscustomobject]@{ Container = 'openab-estate'; Path = '/workspace/EstateSpace'; Verdict = 'ok' }
  )
  $onlyFail = Get-MountFailResults $mixed
  Assert-Eq $onlyFail.Count 0 'stopped/absent do not enter failed list'
  $decOk = Get-ProbeRunDecision $mixed
  Assert-Eq $decOk.Status 'OK' 'mixed stopped+absent+ok => status OK'
  Assert-True $decOk.ClearLatch 'probed>0 OK may clear latch'
  Assert-True $decOk.AllowRecovered 'probed>0 OK may send recovered'

  $allSkip = @(
    [pscustomobject]@{ Container = 'a'; Path = '/x'; Verdict = 'absent' },
    [pscustomobject]@{ Container = 'b'; Path = '/y'; Verdict = 'stopped' }
  )
  Assert-Eq (Get-ProbedCount $allSkip) 0 'all skip => probed 0'
  $decSkip = Get-ProbeRunDecision $allSkip
  Assert-Eq $decSkip.Status 'FAIL' 'all skip => FAIL (not silent OK)'
  Assert-True $decSkip.NeedTier2 'all skip => run Tier2'
  Assert-True (-not $decSkip.ClearLatch) 'all skip must not clear latch'
  Assert-True (-not $decSkip.AllowRecovered) 'all skip must not send recovered'
  Assert-Eq $decSkip.Reason 'unprobed' 'all skip reason=unprobed'

  $withMountFail = $mixed + [pscustomobject]@{ Container = 'openab-kiro'; Path = '/workspace/KiroSpace'; Verdict = 'mount-fail' }
  $onlyFail2 = Get-MountFailResults $withMountFail
  Assert-Eq $onlyFail2.Count 1 'only mount-fail enters failed list'
  Assert-Eq $onlyFail2[0].Container 'openab-kiro' 'failed list is the mount-fail row'

  # Tier 2 判讀
  $vmOut = @"
total 0
d????????? ? ? ? ? c
d????????? ? ? ? ? d
d????????? ? ? ? ? e
"@
  Assert-Eq (Get-Tier2Scope -ExitCode 0 -Output $vmOut -ErrorOutput '') 'vm' 'Tier2 d????????? => vm'
  $okOut = @"
total 16
drwxr-xr-x 1 root root  512 Aug 27 00:00 c
drwxr-xr-x 1 root root  512 Aug 27 00:00 d
drwxr-xr-x 1 root root  512 Aug 27 00:00 e
"@
  Assert-Eq (Get-Tier2Scope -ExitCode 0 -Output $okOut -ErrorOutput '') 'container' 'Tier2 readable host mnt => container'
  Assert-Eq (Get-Tier2Scope -ExitCode 1 -Output '' -ErrorOutput 'Cannot connect to the Docker daemon') 'daemon' 'Tier2 command fail => daemon'
  Assert-Eq (Get-Tier2Scope -ExitCode 124 -Output '' -ErrorOutput 'timeout') 'daemon' 'Tier2 timeout => daemon'

  # 告警去重
  $now = [DateTime]'2026-08-27T12:00:00'
  $a1 = Get-AlertAction -PreviousStatus 'OK' -NewStatus 'FAIL' -LastAlertAt $null -Now $now
  Assert-True $a1.Send 'OK->FAIL sends once'
  Assert-Eq $a1.Kind 'fail' 'OK->FAIL kind=fail'

  $a2 = Get-AlertAction -PreviousStatus 'FAIL' -NewStatus 'FAIL' -LastAlertAt $now.AddMinutes(-10) -Now $now
  Assert-True (-not $a2.Send) 'FAIL sustain within 60m does not send'
  Assert-Eq $a2.Kind 'throttled' 'FAIL sustain kind=throttled'

  $a3 = Get-AlertAction -PreviousStatus 'FAIL' -NewStatus 'FAIL' -LastAlertAt $now.AddMinutes(-60) -Now $now
  Assert-True $a3.Send 'FAIL sustain at 60m sends reminder'
  Assert-Eq $a3.Kind 'fail-repeat' 'FAIL sustain kind=fail-repeat'

  $a4 = Get-AlertAction -PreviousStatus 'FAIL' -NewStatus 'OK' -LastAlertAt $now.AddMinutes(-5) -Now $now
  Assert-True $a4.Send 'FAIL->OK sends recovered'
  Assert-Eq $a4.Kind 'recovered' 'FAIL->OK kind=recovered'

  $a5 = Get-AlertAction -PreviousStatus 'OK' -NewStatus 'OK' -LastAlertAt $null -Now $now
  Assert-True (-not $a5.Send) 'OK->OK does not send'
  Assert-Eq $a5.Kind 'none' 'OK->OK kind=none'

  $a6 = Get-AlertAction -PreviousStatus '' -NewStatus 'OK' -LastAlertAt $null -Now $now
  Assert-True (-not $a6.Send) 'first-run OK does not send (no flip)'

  $a7 = Get-AlertAction -PreviousStatus '' -NewStatus 'FAIL' -LastAlertAt $null -Now $now
  Assert-True $a7.Send 'first-run FAIL still alerts'

  # 熔斷器
  $b0 = Get-HealBudget -HealAt @() -Now $now
  Assert-True $b0.Allowed '0 heals in 24h => allowed'
  Assert-Eq $b0.Count 0 '0 heals count'

  $b1 = Get-HealBudget -HealAt @($now.AddHours(-1).ToString('o')) -Now $now
  Assert-True $b1.Allowed '1 heal in 24h => allowed'
  Assert-Eq $b1.Count 1 '1 heal count'

  $two = @($now.AddHours(-2).ToString('o'), $now.AddHours(-1).ToString('o'))
  $b2 = Get-HealBudget -HealAt $two -Now $now
  Assert-True (-not $b2.Allowed) '2 heals in 24h => denied'
  Assert-Eq $b2.Count 2 '2 heals count'
  Assert-Eq $b2.Reason 'cap' '2 heals reason=cap'

  $cd = Get-HealBudget -HealAt @($now.AddMinutes(-5).ToString('o')) -Now $now -MinIntervalMinutes 60
  Assert-True (-not $cd.Allowed) 'heal 5m ago => cooldown'
  Assert-Eq $cd.Reason 'cooldown' '5m ago reason=cooldown'

  $cd2 = Get-HealBudget -HealAt @($now.AddMinutes(-90).ToString('o')) -Now $now -MinIntervalMinutes 60
  Assert-True $cd2.Allowed 'heal 90m ago => allowed (past cooldown)'
  Assert-Eq $cd2.Reason 'ok' '90m ago reason=ok'

  $aged = @($now.AddHours(-25).ToString('o'), $now.AddHours(-1).ToString('o'))
  $b3 = Get-HealBudget -HealAt $aged -Now $now
  Assert-True $b3.Allowed 'heal older than 24h is pruned'
  Assert-Eq $b3.Count 1 'pruned window count=1'

  # PS 5.1 ConvertFrom-Json 單元素可能不是 array
  $b4 = Get-HealBudget -HealAt $now.AddHours(-3).ToString('o') -Now $now
  Assert-True $b4.Allowed 'single healAt string still counts as 1'
  Assert-Eq $b4.Count 1 'single healAt count=1'

  # Scope 動作
  Assert-Eq (Get-ScopeAction 'vm') 'self-heal' 'vm => self-heal'
  Assert-Eq (Get-ScopeAction 'container') 'restart-failed' 'container => restart-failed'
  Assert-Eq (Get-ScopeAction 'daemon') 'alert-only' 'daemon => alert-only no heal'

  $st = Get-InitialWatchdogState
  $st.manualRequired = $true
  $st.manualRequiredAt = $now.AddMinutes(-5).ToString('o')
  $budgetOk = Get-HealBudget -HealAt @() -Now $now
  Assert-Eq (Get-SelfHealGate -State $st -Now $now -Budget $budgetOk) 'latched' 'latch 5m ago => latched'
  $st.manualRequiredAt = $now.AddHours(-25).ToString('o')
  Assert-Eq (Get-SelfHealGate -State $st -Now $now -Budget $budgetOk) 'allow' 'latch 25h ago => expired allow'
  $st.manualRequired = $false
  $st.manualRequiredAt = $null
  $capBudget = Get-HealBudget -HealAt $two -Now $now
  Assert-Eq (Get-SelfHealGate -State $st -Now $now -Budget $capBudget) 'cap' 'gate cap'
  $cdBudget = Get-HealBudget -HealAt @($now.AddMinutes(-5).ToString('o')) -Now $now
  Assert-Eq (Get-SelfHealGate -State $st -Now $now -Budget $cdBudget) 'cooldown' 'gate cooldown'
  Assert-Eq (Get-SelfHealGate -State $st -Now $now -Budget $budgetOk) 'allow' 'gate allow'

  $cleared = Get-ProbeRunDecision @(
    [pscustomobject]@{ Verdict = 'ok' }
  )
  Assert-True $cleared.ClearLatch 'probed ok => ClearLatch'
  $keep = Get-ProbeRunDecision $allSkip
  Assert-True (-not $keep.ClearLatch) 'unprobed does not clear latch even if later grace sets OK'

  $resMounts = @(
    @{ Container = 'pdf-publisher'; Path = '/vault' },
    @{ Container = 'openab-credit-report'; Path = '/x'; Optional = $true }
  )
  $resResults = @(
    [pscustomobject]@{ Container = 'pdf-publisher'; Path = '/vault'; Verdict = 'stopped' },
    [pscustomobject]@{ Container = 'openab-credit-report'; Path = '/x'; Verdict = 'absent' }
  )
  $firstSeen = Get-ResidentDownNotice -Results $resResults -MountList $resMounts -PrevSince @{} -Now $now -LastAlertAt $null
  Assert-True (-not $firstSeen.Send) 'resident first seen does not send'
  $prev31 = @{ 'pdf-publisher:/vault' = $now.AddMinutes(-31).ToString('o') }
  $overdue = Get-ResidentDownNotice -Results $resResults -MountList $resMounts -PrevSince $prev31 -Now $now -LastAlertAt $null
  Assert-True $overdue.Send 'non-optional down 31m sends info'
  Assert-True ($overdue.Text -match 'pdf-publisher') 'info names pdf-publisher'
  Assert-True ($overdue.Text -notmatch 'credit-report') 'optional profile is silent'
  $throttled = Get-ResidentDownNotice -Results $resResults -MountList $resMounts -PrevSince $prev31 -Now $now -LastAlertAt $now.AddMinutes(-10).ToString('o')
  Assert-True (-not $throttled.Send) 'resident info throttled 60m'

  $failed = @(
    @{ Container = 'openab-kiro'; Path = '/workspace/KiroSpace' },
    @{ Container = 'openab-kiro'; Path = '/workspace/TravelMemory' },
    @{ Container = 'openab-estate'; Path = '/workspace/EstateSpace' }
  )
  $restart = Get-FailedContainerNames $failed
  Assert-Eq $restart.Count 2 'unique failed containers'
  Assert-True ($restart -contains 'openab-kiro') 'restart list has kiro'
  Assert-True ($restart -contains 'openab-estate') 'restart list has estate'

  Assert-True (-not (Test-AlertChannelConfigured '')) 'empty channel => skip'
  Assert-True (-not (Test-AlertChannelConfigured $null)) 'null channel => skip'
  Assert-True (-not (Test-AlertChannelConfigured '<使用者稍後提供>')) 'placeholder channel => skip'
  Assert-True (Test-AlertChannelConfigured '1536220007657373806') 'numeric channel => configured'

  $steps = Get-SelfHealSteps
  Assert-Eq $steps.Count 7 'self-heal ladder has 7 steps'
  $joined = $steps -join ' | '
  Assert-True ($joined -match 'vmmemWSL') 'ladder polls vmmemWSL not command return'
  Assert-True ($joined -match '900') 'ladder vmmem timeout is 900s not 300s'
  Assert-True ($joined -match '不用 docker desktop restart') 'ladder states kill-then-start not CLI restart'
  Assert-True ($joined -match 'manualRequired') 'ladder text mentions abort latch'

  Assert-Eq (Get-ScopeAction 'all-down') 'none' 'all-down => no restart/heal'

  # 自癒與重啟共用 Get-InterventionOutcome；同一批資料不能得出相反結論
  $healSkip = Get-InterventionOutcome -Results $allSkip -PrevFailed $allSkip -Mode 'heal' -OwnerMention 'OWNER'
  Assert-Eq $healSkip.Kind 'unprobed' 'heal unprobed is not success'
  Assert-True ($healSkip.Text -notmatch '均已可讀') 'heal unprobed must not claim recovered'
  Assert-True ($healSkip.Text -match '不是成功') 'heal unprobed says not success'
  $okRow = [pscustomobject]@{ Container = 'a'; Path = '/x'; Verdict = 'ok' }
  $healOk = Get-InterventionOutcome -Results @($okRow) -PrevFailed @($okRow) -Mode 'heal' -OwnerMention 'OWNER'
  Assert-Eq $healOk.Kind 'ok' 'heal prev-fails now ok is success'
  Assert-True ($healOk.Text -match 'probed=') 'heal success names probed N/M'
  $healFail = Get-InterventionOutcome -Results $withMountFail -PrevFailed $withMountFail -Mode 'heal' -OwnerMention 'OWNER'
  Assert-Eq $healFail.Kind 'mount-fail' 'heal mount-fail is not success'

  $prev3 = @(
    [pscustomobject]@{ Container = 'a'; Path = '/x'; Verdict = 'mount-fail' },
    [pscustomobject]@{ Container = 'b'; Path = '/y'; Verdict = 'mount-fail' },
    [pscustomobject]@{ Container = 'c'; Path = '/z'; Verdict = 'mount-fail' }
  )
  $partial = @(
    [pscustomobject]@{ Container = 'a'; Path = '/x'; Verdict = 'ok' },
    [pscustomobject]@{ Container = 'b'; Path = '/y'; Verdict = 'absent' },
    [pscustomobject]@{ Container = 'c'; Path = '/z'; Verdict = 'absent' }
  )
  $ivHeal = Get-InterventionOutcome -Results $partial -PrevFailed $prev3 -Mode 'heal' -OwnerMention 'OWNER'
  $ivRestart = Get-InterventionOutcome -Results $partial -PrevFailed $prev3 -Mode 'restart' -OwnerMention 'OWNER'
  Assert-True (-not $ivHeal.ClaimSuccess) 'heal 1ok+2absent does not claim success'
  Assert-True (-not $ivRestart.ClaimSuccess) 'restart uses the same judge (not success)'
  Assert-Eq $ivHeal.Kind $ivRestart.Kind 'heal and restart Kind identical on same data'
  Assert-True ($ivHeal.Text -notmatch '均已可讀') 'partial recover must not say all readable'

  Assert-Eq (Get-NextDiscordFailCount -PrevCount 5 -SendFailedThisRun $false) 0 'healthy tick resets discordFailCount'
  Assert-Eq (Get-NextDiscordFailCount -PrevCount 5 -SendFailedThisRun $true) 5 'failed send keeps count'
  Assert-True (-not (Test-ThisRunAbnormal -NewStatus 'OK' -SendFailedThisRun $false)) 'healthy tick is not abnormal'
  Assert-True (Test-ThisRunAbnormal -NewStatus 'FAIL' -SendFailedThisRun $false) 'FAIL this run is abnormal'
  Assert-True (Test-ThisRunAbnormal -NewStatus 'OK' -SendFailedThisRun $true) 'send fail this run is abnormal'

  # HIGH-3：probed=0 + daemon 健康（scope=container）→ 維護，不是空清單 FAIL
  $ad0 = Get-AllDownDecision -DecisionReason 'unprobed' -Scope 'container' -PrevConsecutive 0 -ConfirmCount 2
  Assert-True $ad0.Active 'all-down active when unprobed+container'
  Assert-True $ad0.SuppressFail 'all-down suppresses FAIL'
  Assert-True (-not $ad0.SendInfo) 'all-down first tick is grace'
  $ad1 = Get-AllDownDecision -DecisionReason 'unprobed' -Scope 'container' -PrevConsecutive 1 -ConfirmCount 2
  Assert-True $ad1.SendInfo 'all-down second tick sends info'
  $adDaemon = Get-AllDownDecision -DecisionReason 'unprobed' -Scope 'daemon' -PrevConsecutive 0 -ConfirmCount 2
  Assert-True (-not $adDaemon.Active) 'unprobed+daemon is NOT all-down (real outage)'
  $adVm = Get-AllDownDecision -DecisionReason 'unprobed' -Scope 'vm' -PrevConsecutive 0 -ConfirmCount 2
  Assert-True (-not $adVm.Active) 'unprobed+vm is NOT all-down'
  $adTxt = Format-AllDownNotice 12
  Assert-True ($adTxt -match '12 條全部無法探測') 'all-down text names the count'
  Assert-True ($adTxt -match '容器皆不存在') 'all-down text says containers missing'

  Assert-True (Test-HttpSuccess 200) 'HTTP 200 is success'
  Assert-True (Test-HttpSuccess 204) 'HTTP 204 is success'
  Assert-True (-not (Test-HttpSuccess 401)) 'HTTP 401 is not success'
  Assert-True (-not (Test-HttpSuccess 0)) 'HTTP 0 is not success'

  $mixedPrev = @(
    [pscustomobject]@{ Container = 'openab-kiro'; Path = '/workspace/KiroSpace'; Verdict = 'mount-fail' }
  )
  $mixedNow = @(
    [pscustomobject]@{ Container = 'openab-kiro'; Path = '/workspace/KiroSpace'; Verdict = 'stopped' },
    [pscustomobject]@{ Container = 'pdf-publisher'; Path = '/vault'; Verdict = 'ok' }
  )
  Assert-True (-not (Test-PreviousFailsNowOk $mixedPrev $mixedNow)) 'do not claim recovered if failed mount not ok'
  $nowOk = @(
    [pscustomobject]@{ Container = 'openab-kiro'; Path = '/workspace/KiroSpace'; Verdict = 'ok' }
  )
  Assert-True (Test-PreviousFailsNowOk $mixedPrev $nowOk) 'claim recovered only when previous fails are ok'

  Assert-Eq (Resolve-FirstExistingPath -Explicit 'C:\forced.env' -Candidates @('C:\nope.env')) 'C:\forced.env' 'explicit AlertEnv wins over search'
  Assert-Eq (Resolve-FirstExistingPath -Explicit '' -Candidates @($PSScriptRoot, 'C:\no-such-mw.env')) $PSScriptRoot 'search picks first existing path'

  $composeFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'docker-compose.yml'
  Assert-True (Test-Path $composeFile) 'compose file exists next to healthcheck'
  $composeText = Get-Content -Path $composeFile -Raw
  if ($null -eq $composeText) { $composeText = '' }
  $composePaths = Get-ComposeHealthcheckLsPaths $composeText
  $mountPaths = @()
  foreach ($m in $Mounts) {
    if ($mountPaths -notcontains $m.Path) { $mountPaths += $m.Path }
  }
  $missingInCompose = @()
  foreach ($p in $mountPaths) {
    if ($composePaths -notcontains $p) { $missingInCompose += $p }
  }
  $missingInMounts = @()
  foreach ($p in $composePaths) {
    if ($mountPaths -notcontains $p) { $missingInMounts += $p }
  }
  Assert-Eq $missingInCompose.Count 0 ('all Mounts paths appear in compose ls: ' + ($missingInCompose -join ','))
  Assert-Eq $missingInMounts.Count 0 ('all compose ls paths appear in Mounts: ' + ($missingInMounts -join ','))
  $spCount = ([regex]::Matches($composeText, 'start_period:\s*60s')).Count
  Assert-Eq $spCount 10 'compose has start_period 60s on 10 services (next-redeploy; no up -d this round)'
  $composeUtf8 = [System.IO.File]::ReadAllText($composeFile, (New-Object System.Text.UTF8Encoding $false))
  Assert-True ($composeUtf8.Contains($HostVaultProbe)) 'HostVaultProbe appears in compose bind source (self-heal step 6)'

  $srcPath = Join-Path $PSScriptRoot 'mount-watchdog.ps1'
  $src = [System.IO.File]::ReadAllText($srcPath, (New-Object System.Text.UTF8Encoding $true))
  $iLadder = $src.LastIndexOf('function Invoke-SelfHealLadder {')
  $iRestart = $src.LastIndexOf('function Invoke-ContainerRestart {')
  Assert-True ($iLadder -ge 0 -and $iRestart -gt $iLadder) 'can extract Invoke-SelfHealLadder body for structure lock'
  $ladderBody = ''
  if ($iLadder -ge 0 -and $iRestart -gt $iLadder) { $ladderBody = $src.Substring($iLadder, $iRestart - $iLadder) }
  Assert-True ($ladderBody -notmatch 'Get-ProbeRunDecision') 'ladder body has no health judge'
  Assert-True ($ladderBody -notmatch 'Get-InterventionOutcome') 'ladder body has no intervention judge'
  Assert-True ($ladderBody -notmatch 'Register-SendAttempt') 'ladder body does not bookkeep sends itself'
  Assert-True ($ladderBody.Contains('Send-WatchdogNotice')) 'ladder mid-flight still uses the single send'
  $iSendFn = $src.LastIndexOf('function Send-WatchdogNotice {')
  $iWaitFn = $src.LastIndexOf('function Wait-VmmemWslGone')
  $sendBody = ''
  if ($iSendFn -ge 0 -and $iWaitFn -gt $iSendFn) { $sendBody = $src.Substring($iSendFn, $iWaitFn - $iSendFn) }
  $regInSend = ([regex]::Matches($sendBody, 'Register-SendAttempt')).Count
  Assert-Eq $regInSend 2 'Register-SendAttempt only lives beside Send-WatchdogNotice'

  if ($script:FailCount -gt 0) {
    Write-Output ("SelfTest FAILED: {0} assertion(s)" -f $script:FailCount)
  } else {
    Write-Output 'SelfTest PASSED'
  }
}

if ($SelfTest) {
  # 不要把 SelfTest 的 Write-Output 擷進變數（會把 PASS 行跟 exit code 混在一起）。
  Invoke-SelfTest
  if ($script:FailCount -gt 0) { exit 1 }
  exit 0
}

# ── 執行期 I/O（以下不會在 -SelfTest 走到）──────────────────────────────────

function Write-Log {
  param([string]$Message)
  # Write-Host：不可用 Write-Output。函式一旦被 $x = Invoke-... 擷取，
  # 成功流裡的字串會跟回傳物件混在一起，被當成失敗掛載（PS 5.1）。
  $line = '{0} {1}' -f (Get-Date -Format 'o'), $Message
  Write-Host $Message
  if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
  if (Test-Path $LogFile) {
    $len = (Get-Item $LogFile).Length
    if ($len -ge $LogMaxBytes) {
      $bak = $LogFile + '.1'
      if (Test-Path $bak) { Remove-Item $bak -Force }
      Rename-Item $LogFile $bak
    }
  }
  Add-Content -Path $LogFile -Value $line -Encoding utf8
}

function Invoke-Cmd {
  param([string]$Exe, [string[]]$CmdArgs, [int]$TimeoutSec = 90)
  # 不用 Start-Process -PassThru：PS 5.1 不加 -Wait 時 ExitCode 永遠是 $null。
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName               = $Exe
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  foreach ($a in $CmdArgs) { $psi.Arguments += '"' + ($a -replace '"', '\"') + '" ' }

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
    try { $proc.Kill() } catch {}
    return @{ Code = 124; Out = ''; Err = "timeout after ${TimeoutSec}s" }
  }
  $out = $outTask.Result
  $err = $errTask.Result
  if ($null -eq $out) { $out = '' }
  if ($null -eq $err) { $err = '' }
  return @{ Code = [int]$proc.ExitCode; Out = [string]$out; Err = [string]$err }
}

function Send-DiscordAlert {
  param(
    [string]$Token,
    [string]$ChannelId,
    [string]$Text,
    [bool]$Mention = $true
  )
  # ⚠ User-Agent 必填：少了 DiscordBot (...) Cloudflare 回空 body 403。
  $ua = "DiscordBot (https://github.com/openabdev/openab, 1.0) openab-mount-watchdog"
  $mentions = @{ parse = @() }
  if ($Mention) { $mentions = @{ users = @($OwnerId) } }
  $body = @{ content = $Text; allowed_mentions = $mentions } | ConvertTo-Json -Depth 5 -Compress
  $resp = Invoke-WebRequest -Method Post `
    -Uri "https://discord.com/api/v10/channels/$ChannelId/messages" `
    -Headers @{ Authorization = "Bot $Token"; "User-Agent" = $ua } `
    -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
    -UseBasicParsing
  return @{ Code = [int]$resp.StatusCode; Body = [string]$resp.Content }
}

function Read-WatchdogState {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return Get-InitialWatchdogState }
  $raw = Get-Content -Path $Path -Raw
  if ($null -eq $raw) { return Get-InitialWatchdogState }
  $trim = $raw.Trim()
  if ($trim -eq '') { return Get-InitialWatchdogState }
  try {
    $obj = $trim | ConvertFrom-Json
  } catch {
    Write-Log '[WARN] state file unreadable, resetting'
    return Get-InitialWatchdogState
  }
  $status = [string]$obj.status
  if ($status -eq '') { $status = 'OK' }
  return [pscustomobject]@{
    status           = $status
    scope            = $obj.scope
    lastAlertAt      = $obj.lastAlertAt
    lastChangeAt     = $obj.lastChangeAt
    failedMounts     = @(Convert-ToArray $obj.failedMounts)
    healAt           = @(Convert-ToArray $obj.healAt)
    manualRequired   = (Get-CoercedBool $obj.manualRequired)
    manualRequiredAt = $obj.manualRequiredAt
    notRunning          = @(Convert-ToArray $obj.notRunning)
    notRunningSince     = (Convert-SinceMap $obj.notRunningSince)
    lastResidentAlertAt = $obj.lastResidentAlertAt
    consecutiveFail     = (Get-CoercedInt $obj.consecutiveFail 0)
    consecutiveAllDown  = (Get-CoercedInt $obj.consecutiveAllDown 0)
    lastAllDownAlertAt  = $obj.lastAllDownAlertAt
    discordFailCount    = (Get-CoercedInt $obj.discordFailCount 0)
    lastDiscordError    = $obj.lastDiscordError
  }
}

function Write-WatchdogState {
  param($State, [string]$Path)
  if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
  $payload = @{
    status           = $State.status
    scope            = $State.scope
    lastAlertAt      = $State.lastAlertAt
    lastChangeAt     = $State.lastChangeAt
    failedMounts     = @(Convert-ToArray $State.failedMounts)
    healAt           = @(Convert-ToArray $State.healAt)
    manualRequired   = (Get-CoercedBool $State.manualRequired)
    manualRequiredAt = $State.manualRequiredAt
    notRunning          = @(Convert-ToArray $State.notRunning)
    notRunningSince     = (Convert-SinceMap $State.notRunningSince)
    lastResidentAlertAt = $State.lastResidentAlertAt
    consecutiveFail     = (Get-CoercedInt $State.consecutiveFail 0)
    consecutiveAllDown  = (Get-CoercedInt $State.consecutiveAllDown 0)
    lastAllDownAlertAt  = $State.lastAllDownAlertAt
    discordFailCount    = (Get-CoercedInt $State.discordFailCount 0)
    lastDiscordError    = $State.lastDiscordError
  }
  $json = $payload | ConvertTo-Json -Depth 6
  Set-Content -Path $Path -Value $json -Encoding utf8
}

function Invoke-Tier1Probe {
  $results = @()
  foreach ($m in $Mounts) {
    $c = $m.Container
    $p = $m.Path
    $insp = Invoke-Cmd 'docker' @('inspect', '-f', '{{.State.Running}}', $c) 10
    $execExit = 0
    $execOut = ''
    $execErr = ''
    if ($insp.Code -eq 0 -and ($insp.Out).Trim() -eq 'true') {
      # 必須 ls 掛載點本身。ls 父目錄在 9p 已死時仍會成功（規格 §5.1）。
      # timeout 把 124 傳回 docker exec：9p 卡住時不是立刻 ENOENT。
      $shell = "if command -v timeout >/dev/null 2>&1; then timeout $InnerLsTimeoutSec ls $p >/dev/null 2>&1; rc=`$?; if [ `$rc -eq 0 ]; then echo OK; exit 0; fi; if [ `$rc -eq 124 ]; then echo TIMEOUT; exit 124; fi; echo FAIL; exit `$rc; else ls $p >/dev/null 2>&1 && echo OK || echo FAIL; fi"
      $r = Invoke-Cmd 'docker' @('exec', $c, 'sh', '-c', $shell) $Tier1TimeoutSec
      $execExit = $r.Code
      $execOut = $r.Out
      $execErr = $r.Err
    }
    $verdict = Get-MountVerdict -InspectExit $insp.Code -RunningRaw $insp.Out -ExecExit $execExit -ExecOut $execOut
    $detail = ($execOut).Trim()
    if ($detail -eq '') { $detail = ($execErr).Trim() }
    if ($verdict -eq 'absent') { $detail = 'container absent' }
    if ($verdict -eq 'stopped') { $detail = 'not running' }
    if ($execExit -eq 124) { $detail = "timeout ls $p (exit 124)" }
    $label = 'FAIL'
    if ($verdict -eq 'ok') { $label = 'OK' }
    if ($verdict -eq 'stopped' -or $verdict -eq 'absent') { $label = 'SKIP' }
    Write-Log ("[T1] {0} {1} => {2} ({3})" -f $c, $p, $label, $detail)
    # Verdict 是唯一判定欄位。不再寫 Ok（舊欄位無人讀，避免被當成狀態機依據）。
    $results += [pscustomobject]@{
      Container = $c
      Path      = $p
      Verdict   = $verdict
      Detail    = $detail
    }
  }
  return ,$results
}

function Invoke-Tier2Probe {
  $args = @(
    'run', '--rm', '--privileged', '--pid=host', 'alpine',
    'nsenter', '-t', '1', '-m', '-u', '-n', '-i',
    'sh', '-c', 'ls -la /run/desktop/mnt/host/'
  )
  $r = Invoke-Cmd 'docker' $args $Tier2TimeoutSec
  $scope = Get-Tier2Scope -ExitCode $r.Code -Output $r.Out -ErrorOutput $r.Err
  Write-Log ("[T2] exit={0} scope={1}" -f $r.Code, $scope)
  if (($r.Out).Trim() -ne '') {
    Write-Log ('[T2] out: ' + ($r.Out).Trim())
  }
  if (($r.Err).Trim() -ne '') {
    Write-Log ('[T2] err: ' + ($r.Err).Trim())
  }
  return [pscustomobject]@{
    Scope = $scope
    Code  = $r.Code
    Out   = $r.Out
    Err   = $r.Err
  }
}

function Get-AlertConfig {
  $alert = Read-DotEnv $EnvAlert
  $channel = $alert['INFRA_ALERT_CHANNEL_ID']
  $tokenVar = $alert['INFRA_ALERT_TOKEN_VAR']
  if ($null -eq $tokenVar -or $tokenVar -eq '') { $tokenVar = 'DISCORD_TOKEN_NVIDIA' }
  $tokens = Read-DotEnv $EnvTokens
  $token = $tokens[$tokenVar]
  return [pscustomobject]@{
    ChannelId = $channel
    TokenVar  = $tokenVar
    Token     = $token
    Configured = (Test-AlertChannelConfigured $channel)
  }
}

function Send-WatchdogNotice {
  param(
    [string]$Text,
    $AlertCfg,
    [bool]$WouldSend,
    [bool]$Mention = $true
  )
  # 唯一 Discord 出口。記帳在這裡做完，呼叫端禁止再旁路 Send-DiscordAlert。
  $ret = $null
  if (-not $WouldSend) {
    if ($DryRun) {
      Write-Log '[DRYRUN] would NOT send Discord (send=False)'
    } else {
      Write-Log '[SKIP] alert suppressed by dedup (no status flip / still throttled)'
    }
    $ret = @{ Sent = $false; Reason = 'suppressed'; Code = 0 }
  } elseif (-not $AlertCfg.Configured) {
    Write-Log '[SKIP] no alert channel configured (not stamping lastAlertAt)'
    $ret = @{ Sent = $false; Reason = 'no-channel'; Code = 0 }
  } elseif ($DryRun) {
    Write-Log '[DRYRUN] would send Discord (send=True):'
    Write-Log $Text
    $ret = @{ Sent = $false; Reason = 'dryrun'; Code = 0 }
  } elseif ($null -eq $AlertCfg.Token -or $AlertCfg.Token -eq '') {
    Write-Log ("[SKIP] token var {0} not found in discord_token.env (not stamping lastAlertAt)" -f $AlertCfg.TokenVar)
    $ret = @{ Sent = $false; Reason = 'no-token'; Code = 0 }
  } else {
    try {
      $sent = Send-DiscordAlert -Token $AlertCfg.Token -ChannelId $AlertCfg.ChannelId -Text $Text -Mention $Mention
      $code = [int]$sent.Code
      if (Test-HttpSuccess $code) {
        Write-Log ("[ALERT] Discord sent HTTP {0}" -f $code)
        $ret = @{ Sent = $true; Reason = 'ok'; Code = $code }
      } else {
        Write-Log ("[WARN] Discord send HTTP {0} (not stamping lastAlertAt)" -f $code)
        $ret = @{ Sent = $false; Reason = 'http'; Code = $code }
      }
    } catch {
      $resp = $_.Exception.Response
      $code = 0
      if ($null -ne $resp) { $code = [int]$resp.StatusCode }
      Write-Log ("[WARN] Discord send failed HTTP {0}: {1} (not stamping lastAlertAt)" -f $code, $_.Exception.Message)
      $ret = @{ Sent = $false; Reason = 'exception'; Code = $code }
    }
  }
  Register-SendAttempt $ret $WouldSend
  return $ret
}

function Register-SendAttempt {
  param($Result, [bool]$Intended)
  if (-not $Intended) { return }
  if ($DryRun) { return }
  if ($null -eq $Result) {
    $script:WatchdogSendFailed = $true
    $script:WatchdogFailCount = [int]$script:WatchdogFailCount + 1
    $script:WatchdogLastError = 'null-result'
    return
  }
  if ($Result.Sent) {
    $script:WatchdogSentOk = $true
    $script:WatchdogFailCount = 0
    $script:WatchdogLastError = $null
    return
  }
  if ($Result.Reason -eq 'suppressed' -or $Result.Reason -eq 'dryrun') { return }
  $script:WatchdogSendFailed = $true
  $script:WatchdogFailCount = [int]$script:WatchdogFailCount + 1
  $script:WatchdogLastError = [string]$Result.Reason
}

function Wait-VmmemWslGone {
  param([int]$TimeoutSec = 900, [int]$PollSec = 5)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $warnedEmpty = $false
  while ((Get-Date) -lt $deadline) {
    $found = @()
    foreach ($n in @('vmmemWSL', 'vmmem')) {
      $got = Get-Process -Name $n -ErrorAction SilentlyContinue
      if ($null -ne $got) { $found += @($got) }
    }
    if ($found.Count -eq 0) {
      if (-not $warnedEmpty) {
        Write-Log '[WARN] no vmmem* process found — assuming already down'
        $warnedEmpty = $true
      }
      Write-Log '[HEAL] vmmemWSL/vmmem gone'
      return $true
    }
    $ids = @()
    foreach ($p in $found) { $ids += $p.Id }
    Write-Log ('[HEAL] vmmem* still running (pid {0}), waiting...' -f ($ids -join ','))
    Start-Sleep -Seconds $PollSec
  }
  return $false
}

function Start-WslShutdownFireAndForget {
  # wsl --shutdown 會長時間無輸出但仍在作用。不可用「指令是否返回」判斷。
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'wsl.exe'
  $psi.Arguments = '--shutdown'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()
  return $proc
}

function Stop-DockerDesktopProcesses {
  foreach ($name in $DockerKillNames) {
    $procs = Get-Process -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $procs) { continue }
    foreach ($p in @($procs)) {
      Write-Log ("[HEAL] stopping {0} pid={1}" -f $name, $p.Id)
      try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {
        Write-Log ("[WARN] failed to stop {0} pid={1}: {2}" -f $name, $p.Id, $_.Exception.Message)
      }
    }
  }
}

function Wait-HostMountReadable {
  param([int]$TimeoutSec = 600, [int]$PollSec = 10)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $args = @('run', '--rm', '-v', "${HostVaultProbe}:/vault", 'alpine', 'ls', '/vault')
  while ((Get-Date) -lt $deadline) {
    $r = Invoke-Cmd 'docker' $args 30
    if ($r.Code -eq 0) {
      Write-Log '[HEAL] alpine ls /vault succeeded'
      return $true
    }
    Write-Log ("[HEAL] alpine ls /vault not ready (exit {0}): {1}{2}" -f $r.Code, ($r.Out).Trim(), ($r.Err).Trim())
    Start-Sleep -Seconds $PollSec
  }
  return $false
}

function Invoke-SelfHealLadder {
  param($AlertCfg, $State, [DateTime]$Now)
  Write-Log '[HEAL] starting VM self-heal ladder'

  $startText = "<@$OwnerId> ⚠️ **mount-watchdog** 偵測到 VM 層級掛載故障，開始自癒（先 wsl --shutdown，再殺 Docker Desktop 行程後重開；**不用** docker desktop restart）。"
  Send-WatchdogNotice -Text $startText -AlertCfg $AlertCfg -WouldSend $true

  $healAt = @(Convert-ToArray $State.healAt)
  $healAt += $Now.ToString('o')
  $State.healAt = $healAt
  Write-WatchdogState -State $State -Path $StateFile

  Write-Log '[HEAL] step 2: wsl --shutdown (fire and forget)'
  try { [void](Start-WslShutdownFireAndForget) } catch {
    Write-Log ("[WARN] wsl --shutdown start failed: {0}" -f $_.Exception.Message)
  }

  Write-Log '[HEAL] step 3: poll vmmemWSL/vmmem up to 900s'
  $gone = Wait-VmmemWslGone -TimeoutSec $VmmemTimeoutSec
  if (-not $gone) {
    $msg = "<@$OwnerId> 🛑 **mount-watchdog** 自癒停手：vmmemWSL 在 900 秒內未消失，需要人工處理／重開機。不會自動重試。"
    Send-WatchdogNotice -Text $msg -AlertCfg $AlertCfg -WouldSend $true
    Write-Log '[HEAL] abort: vmmemWSL timeout'
    $State.manualRequired = $true
    $State.manualRequiredAt = $Now.ToString('o')
    Write-WatchdogState -State $State -Path $StateFile
    return [pscustomobject]@{ Outcome = 'abort-vmmem'; Results = @() }
  }

  Write-Log '[HEAL] step 4: kill Docker Desktop leftover processes'
  Stop-DockerDesktopProcesses
  Start-Sleep -Seconds 3

  Write-Log '[HEAL] step 5: start Docker Desktop.exe'
  if (-not (Test-Path $DockerDesktopExe)) {
    $msg = "<@$OwnerId> 🛑 **mount-watchdog** 自癒停手：找不到 Docker Desktop.exe。需要人工處理。不會自動重試。"
    Send-WatchdogNotice -Text $msg -AlertCfg $AlertCfg -WouldSend $true
    $State.manualRequired = $true
    $State.manualRequiredAt = $Now.ToString('o')
    Write-WatchdogState -State $State -Path $StateFile
    return [pscustomobject]@{ Outcome = 'abort-exe'; Results = @() }
  }
  try { Start-Process -FilePath $DockerDesktopExe } catch {
    Write-Log ("[WARN] Start-Process Docker Desktop failed: {0}" -f $_.Exception.Message)
  }

  Write-Log '[HEAL] step 6: poll alpine ls /vault up to 600s'
  $readable = Wait-HostMountReadable -TimeoutSec $MountProbeTimeoutSec
  if (-not $readable) {
    $msg = "<@$OwnerId> 🛑 **mount-watchdog** 自癒停手：Docker 重開後 600 秒內仍無法 ls 掛載（可能卡在 modal 對話框）。需要人工處理／重開機。不會自動重試。"
    Send-WatchdogNotice -Text $msg -AlertCfg $AlertCfg -WouldSend $true
    Write-Log '[HEAL] abort: mount probe timeout'
    $State.manualRequired = $true
    $State.manualRequiredAt = $Now.ToString('o')
    Write-WatchdogState -State $State -Path $StateFile
    return [pscustomobject]@{ Outcome = 'abort-mount'; Results = @() }
  }

  Write-Log '[HEAL] step 7: re-run Tier 1 (judge+notify returned to main)'
  $results = Invoke-Tier1Probe
  return [pscustomobject]@{ Outcome = 'done'; Results = $results }
}

function Invoke-ContainerRestart {
  param($FailedResults)
  $mountFails = Get-MountFailResults $FailedResults
  $names = Get-FailedContainerNames $mountFails
  foreach ($n in $names) {
    $rowOk = $false
    foreach ($row in (Convert-ToArray $mountFails)) {
      if ($row.Container -eq $n -and $row.Verdict -eq 'mount-fail') { $rowOk = $true }
    }
    if (-not $rowOk) {
      Write-Log ("[FIX] skip restart {0} (not mount-fail)" -f $n)
      continue
    }
    if ($DryRun) {
      Write-Log ("[DRYRUN] would docker restart {0}" -f $n)
      continue
    }
    Write-Log ("[FIX] docker restart {0}" -f $n)
    $r = Invoke-Cmd 'docker' @('restart', $n) 120
    Write-Log ("[FIX] restart {0} exit={1}" -f $n, $r.Code)
  }
  if ($DryRun) { return @() }
  Start-Sleep -Seconds 5
  return Invoke-Tier1Probe
}

# ── 主流程 ────────────────────────────────────────────────────────────────

# TestAlert 與正式路徑共用：worktree .local → D:\discord 個人助理\.local（或 -AlertEnv/-TokenEnv）
$resolvedEnv = Resolve-AlertEnvPaths -AlertEnv $AlertEnv -TokenEnv $TokenEnv -RepoRoot $Root -KnownLocal $KnownCheckoutLocal
$EnvAlert = $resolvedEnv.AlertPath
$EnvTokens = $resolvedEnv.TokenPath

if ($TestAlert) {
  $alertCfg = Get-AlertConfig
  Write-Host '=== mount-watchdog -TestAlert ==='
  Write-Host ('alert env: ' + $EnvAlert)
  Write-Host ('token env: ' + $EnvTokens)
  Write-Host ('channel configured: ' + $alertCfg.Configured)
  Write-Host ('token var: ' + $alertCfg.TokenVar)
  if (-not $alertCfg.Configured) {
    Write-Host '[SKIP] no alert channel configured'
    exit 0
  }
  if ($null -eq $alertCfg.Token -or $alertCfg.Token -eq '') {
    Write-Host ('[SKIP] token var {0} not found' -f $alertCfg.TokenVar)
    exit 1
  }
  $iso = (Get-Date).ToString('o')
  $text = "ℹ️ **mount-watchdog TestAlert** — 這是測試訊息，可忽略。時間：$iso。不是真實掛載故障。"
  try {
    $sent = Send-DiscordAlert -Token $alertCfg.Token -ChannelId $alertCfg.ChannelId -Text $text -Mention $false
    Write-Host ('HTTP ' + $sent.Code)
    $bodyPreview = $sent.Body
    if ($null -eq $bodyPreview) { $bodyPreview = '' }
    if ($bodyPreview.Length -gt 200) { $bodyPreview = $bodyPreview.Substring(0, 200) }
    Write-Host ('body: ' + $bodyPreview)
    Write-Host 'TestAlert done (state file not touched; same env resolution as official path)'
    if (Test-HttpSuccess ([int]$sent.Code)) { exit 0 }
    exit 1
  } catch {
    $resp = $_.Exception.Response
    $code = ''
    if ($null -ne $resp) { $code = [int]$resp.StatusCode }
    Write-Host ('HTTP-ERROR ' + $code + ' ' + $_.Exception.Message)
    exit 1
  }
}

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }

$now = Get-Date
$state = Read-WatchdogState $StateFile
$alertCfg = Get-AlertConfig
$script:WatchdogSentOk = $false
$script:WatchdogSendFailed = $false
$script:WatchdogFailCount = Get-CoercedInt $state.discordFailCount 0
$script:WatchdogLastError = $state.lastDiscordError
$alertSent = $false
$residentSent = $false
$allDownSent = $false

Write-Log '=== mount-watchdog run ==='
Write-Log ("[CFG] alert env={0}" -f $EnvAlert)
Write-Log ("[CFG] token env={0}" -f $EnvTokens)
if ($DryRun) { Write-Log '[DRYRUN] detection will run; heal/kill/wsl/discord will not' }

$tier1 = Invoke-Tier1Probe
$decision = Get-ProbeRunDecision $tier1
$failed = Get-MountFailResults $tier1
$notRunning = @()
foreach ($r in (Convert-ToArray $tier1)) {
  if ($r.Verdict -eq 'stopped' -or $r.Verdict -eq 'absent') {
    $key = '{0}:{1}' -f $r.Container, $r.Path
    if ($notRunning -notcontains $key) { $notRunning += $key }
  }
}

$newStatus = $decision.Status
$scope = $null
if ($decision.NeedTier2) {
  $t2 = Invoke-Tier2Probe
  $scope = $t2.Scope
  Write-Log ("[PROBE] reason={0} probed={1} scope={2}" -f $decision.Reason, $decision.Probed, $scope)
}

# B2：Scope=daemon 第一次只記 log，不翻 FAIL（避免正常開關機洗版）
$consecutiveFail = Get-CoercedInt $state.consecutiveFail 0
if ($newStatus -eq 'FAIL' -and $scope -eq 'daemon') {
  $consecutiveFail = $consecutiveFail + 1
  if ($consecutiveFail -lt $DaemonConfirmCount) {
    Write-Log ("[NOTE] Scope=daemon miss {0}/{1} — grace, not flipping to FAIL" -f $consecutiveFail, $DaemonConfirmCount)
    $newStatus = 'OK'
    $scope = $null
  }
} elseif ($newStatus -eq 'OK') {
  $consecutiveFail = 0
} else {
  $consecutiveFail = $consecutiveFail + 1
}

# HIGH-3：probed=0 且 daemon/9p 健康 → 維護（全部停掉），不是空清單 FAIL
$allDown = Get-AllDownDecision -DecisionReason $decision.Reason -Scope $scope -PrevConsecutive (Get-CoercedInt $state.consecutiveAllDown 0) -ConfirmCount $AllDownConfirmCount
$consecutiveAllDown = $allDown.Consecutive
if ($allDown.Active) {
  Write-Log ("[NOTE] all-down {0}/{1} — daemon/9p healthy, nothing probed (maintenance or disaster)" -f $allDown.Consecutive, $AllDownConfirmCount)
  $newStatus = 'OK'
  $scope = 'all-down'
  $consecutiveFail = 0
}

$alert = Get-AlertAction -PreviousStatus $state.status -NewStatus $newStatus -LastAlertAt $state.lastAlertAt -Now $now -RealertMinutes $RealertMin
if (-not $decision.AllowRecovered -and $alert.Kind -eq 'recovered') {
  Write-Log '[SKIP] not sending recovered (no successful probe this run; latch kept)'
  $alert = [pscustomobject]@{ Send = $false; Kind = 'none' }
}
Write-Log ("[STATE] prev={0} new={1} scope={2} alert={3} send={4} probed={5}" -f $state.status, $newStatus, $scope, $alert.Kind, $alert.Send, $decision.Probed)

$notice = $null
if ($newStatus -eq 'FAIL') {
  $failBody = Format-FailList $failed
  if ($failBody -eq '') {
    $failBody = ('（無 mount-fail 列；probed={0} reason={1}）' -f $decision.Probed, $decision.Reason)
  }
  $notice = "<@$OwnerId> ⚠️ **mount-watchdog** 掛載檢查失敗（Scope=$scope）`n" + $failBody
} elseif ($alert.Kind -eq 'recovered') {
  $notice = "<@$OwnerId> ✅ **mount-watchdog** 掛載已恢復（先前 Scope=$($state.scope)）"
}

if ($null -ne $notice) {
  $nr = Send-WatchdogNotice -Text $notice -AlertCfg $alertCfg -WouldSend ([bool]$alert.Send)
  if ($nr.Sent) { $alertSent = $true }
} elseif (-not $alertCfg.Configured) {
  Write-Log '[CFG] alert channel not configured (ok if send=False this run)'
}

$healOutcome = $null
$failedBeforeAction = $failed
if ($newStatus -eq 'FAIL') {
  $action = Get-ScopeAction $scope
  Write-Log ("[ACTION] {0}" -f $action)
  if ($action -eq 'self-heal') {
    $budget = Get-HealBudget -HealAt $state.healAt -Now $now -MaxHeals $HealMax -WindowHours $HealWindowHours -MinIntervalMinutes $HealMinIntervalMinutes
    $gate = Get-SelfHealGate -State $state -Now $now -Budget $budget -LatchExpireHours $LatchExpireHours
    Write-Log ("[HEAL-GATE] {0}" -f $gate)
    if ($gate -eq 'latched') {
      Write-Log '[ACTION] self-heal latched off (manual intervention required)'
    } elseif ($gate -eq 'cap') {
      $cap = "<@$OwnerId> 🛑 **mount-watchdog** 已達自癒上限（24 小時內 $($budget.Count)/$HealMax 次），需要人工介入。本次不執行 wsl --shutdown / 重開 Docker。"
      [void](Send-WatchdogNotice -Text $cap -AlertCfg $alertCfg -WouldSend $true)
    } elseif ($gate -eq 'cooldown') {
      Write-Log '[ACTION] self-heal cooldown — not starting another wsl --shutdown'
    } elseif ($DryRun) {
      Write-Log '[DRYRUN] would run VM self-heal ladder:'
      foreach ($s in (Get-SelfHealSteps)) { Write-Log ("  - {0}" -f $s) }
    } else {
      $healOutcome = Invoke-SelfHealLadder -AlertCfg $alertCfg -State $state -Now $now
      if ($healOutcome.Outcome -eq 'done' -and $healOutcome.Results.Count -gt 0) {
        $iv = Get-InterventionOutcome -Results $healOutcome.Results -PrevFailed $failedBeforeAction -Mode 'heal' -OwnerMention $OwnerId
        Write-Log ("[HEAL] intervention kind={0} claim={1} probed={2}/{3}" -f $iv.Kind, $iv.ClaimSuccess, $iv.Probed, $iv.Total)
        $hr = Send-WatchdogNotice -Text $iv.Text -AlertCfg $alertCfg -WouldSend $true
        if ($hr.Sent) { $alertSent = $true }
        $tier1 = $healOutcome.Results
        $decision = $iv.Decision
        $failed = Get-MountFailResults $tier1
        if ($iv.ClaimSuccess) {
          $newStatus = 'OK'
          $scope = $null
        } else {
          $newStatus = 'FAIL'
        }
      }
    }
  } elseif ($action -eq 'restart-failed') {
    if ($failed.Count -eq 0) {
      Write-Log '[ACTION] restart-failed skipped (no mount-fail rows)'
    } else {
      $again = Invoke-ContainerRestart $failed
      if ($again.Count -gt 0) {
        $iv = Get-InterventionOutcome -Results $again -PrevFailed $failedBeforeAction -Mode 'restart' -OwnerMention $OwnerId
        Write-Log ("[FIX] intervention kind={0} claim={1} probed={2}/{3}" -f $iv.Kind, $iv.ClaimSuccess, $iv.Probed, $iv.Total)
        $tier1 = $again
        $decision = $iv.Decision
        $failed = Get-MountFailResults $tier1
        if ($iv.ClaimSuccess) {
          $newStatus = 'OK'
          $scope = $null
          $rr = Send-WatchdogNotice -Text $iv.Text -AlertCfg $alertCfg -WouldSend $true
          if ($rr.Sent) { $alertSent = $true }
        } else {
          Write-Log '[FIX] not claiming recovered — same judge as heal (Get-InterventionOutcome)'
        }
      }
    }
  } else {
    Write-Log '[ACTION] daemon/unknown: alert only, no self-heal'
  }
}

if ($DryRun) {
  Write-Log '若為真會執行的自癒步驟（Scope=vm 時）：'
  foreach ($s in (Get-SelfHealSteps)) { Write-Log ("  - {0}" -f $s) }
  Write-Log '（DryRun 結束，未執行 wsl --shutdown、未殺行程、未啟動 Docker Desktop、未發 Discord）'
}

if ($allDown.SendInfo) {
  $adThrottle = $false
  $prevAd = $state.lastAllDownAlertAt
  if ($null -ne $prevAd -and $prevAd -ne '') {
    if (($now - [DateTime]$prevAd).TotalMinutes -lt $ResidentAlertEveryMinutes) { $adThrottle = $true }
  }
  if ($adThrottle) {
    Write-Log '[INFO] all-down info throttled 60m'
  } else {
    $adText = Format-AllDownNotice @(Convert-ToArray $tier1).Count
    Write-Log '[INFO] all containers absent (no restart, no self-heal)'
    $adr = Send-WatchdogNotice -Text $adText -AlertCfg $alertCfg -WouldSend $true -Mention $false
    if ($adr.Sent) { $allDownSent = $true }
  }
}

$resident = Get-ResidentDownNotice -Results $tier1 -MountList $Mounts -PrevSince $state.notRunningSince -Now $now -LastAlertAt $state.lastResidentAlertAt -DownMinutes $ResidentDownMinutes -ThrottleMinutes $ResidentAlertEveryMinutes
if ($resident.Send) {
  Write-Log '[INFO] resident container down >30m (no restart, no self-heal)'
  $resr = Send-WatchdogNotice -Text $resident.Text -AlertCfg $alertCfg -WouldSend $true -Mention $false
  if ($resr.Sent) { $residentSent = $true }
}

# 以磁碟上的 state 當基底，避免 ladder 寫入的新欄位被固定清單清掉
$base = $state
if ($null -ne $healOutcome -and $healOutcome.Outcome) {
  $base = Read-WatchdogState $StateFile
}
$newState = [pscustomobject]@{
  status              = $newStatus
  scope               = $scope
  lastAlertAt         = $state.lastAlertAt
  lastChangeAt        = $state.lastChangeAt
  failedMounts        = @()
  healAt              = @(Convert-ToArray $base.healAt)
  manualRequired      = (Get-CoercedBool $base.manualRequired)
  manualRequiredAt    = $base.manualRequiredAt
  notRunning          = $notRunning
  notRunningSince     = $resident.Since
  lastResidentAlertAt = $state.lastResidentAlertAt
  consecutiveFail     = $consecutiveFail
  consecutiveAllDown  = $consecutiveAllDown
  lastAllDownAlertAt  = $state.lastAllDownAlertAt
  discordFailCount    = [int]$script:WatchdogFailCount
  lastDiscordError    = $script:WatchdogLastError
}
if ($failed.Count -gt 0) {
  foreach ($f in $failed) {
    $newState.failedMounts += ('{0}:{1}' -f $f.Container, $f.Path)
  }
}
# BLOCKER-3：只有確認送出成功才蓋時間戳
if ($alertSent) {
  $newState.lastAlertAt = $now.ToString('o')
}
if ($residentSent) {
  $newState.lastResidentAlertAt = $now.ToString('o')
}
if ($allDownSent) {
  $newState.lastAllDownAlertAt = $now.ToString('o')
}
if ($state.status -ne $newStatus) {
  $newState.lastChangeAt = $now.ToString('o')
} else {
  $newState.lastChangeAt = $state.lastChangeAt
}
if ($decision.ClearLatch -and $newStatus -eq 'OK') {
  $newState.manualRequired = $false
  $newState.manualRequiredAt = $null
}

if ($script:WatchdogSendFailed) {
  Write-Log ("[WARN] Discord send failed this run (count={0} error={1}); timestamps not stamped" -f $script:WatchdogFailCount, $script:WatchdogLastError)
} else {
  # F-2：本輪沒有送出失敗 → 歸零。健康輪不會送告警，不能只靠「送出成功」才清計數。
  $script:WatchdogFailCount = 0
  $script:WatchdogLastError = $null
  $newState.discordFailCount = 0
  $newState.lastDiscordError = $null
}

if (-not $DryRun) {
  Write-WatchdogState -State $newState -Path $StateFile
} else {
  Write-Log '[DRYRUN] state file not written'
}

# F-2：exit = 本輪有無異常，不是歷史 discordFailCount。
if (Test-ThisRunAbnormal -NewStatus $newStatus -SendFailedThisRun ([bool]$script:WatchdogSendFailed)) { exit 1 }
exit 0
