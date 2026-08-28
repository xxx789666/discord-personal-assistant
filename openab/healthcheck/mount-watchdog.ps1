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
# 規格 §6.5：事故當下舊 VM 可能很久才真正換掉。vmmemWSL 行程在汰換後仍可能一直存在
#（2026-08-28 維護實測：行程全程在、配額 31797→15991、uptime 68s）。900s 是退路不是成功條件。
$VmmemTimeoutSec = 900
$MountProbeTimeoutSec = 600
# 內層 timeout 10s；host 15s 當第二道保險。最壞 12×15s=180s，排程改 5 分鐘以免卡滿一個 interval。
$Tier1TimeoutSec = 15
$InnerLsTimeoutSec = 10
$Tier2TimeoutSec = 30
$LogMaxBytes = 5MB
# FIX-M0：耗時基線。K/M 只增加資訊與保守性，不降低自癒門檻。
$SlowMultiple = 5
$SlowPeerMin = 2
$DefaultBaselineSec = 0.5
$BaselineWindow = 12

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
    probeDurations    = @{}
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

function Convert-DurationMap {
  param($Value)
  $map = @{}
  if ($null -eq $Value) { return ,$map }
  if ($Value -is [hashtable]) {
    foreach ($k in @($Value.Keys)) {
      $nums = @()
      foreach ($x in (Convert-ToArray $Value[$k])) {
        if ($null -eq $x -or $x -eq '') { continue }
        $nums += [double]$x
      }
      $map[[string]$k] = $nums
    }
    return ,$map
  }
  foreach ($p in $Value.PSObject.Properties) {
    $nums = @()
    foreach ($x in (Convert-ToArray $p.Value)) {
      if ($null -eq $x -or $x -eq '') { continue }
      $nums += [double]$x
    }
    $map[[string]$p.Name] = $nums
  }
  return ,$map
}

function Get-MedianSec {
  param($Values)
  $arr = @()
  foreach ($v in (Convert-ToArray $Values)) {
    if ($null -eq $v -or $v -eq '') { continue }
    $arr += [double]$v
  }
  if ($arr.Count -eq 0) { return $null }
  $sorted = @($arr | Sort-Object)
  $n = $sorted.Count
  $mid = [int][Math]::Floor(($n - 1) / 2)
  if (($n % 2) -eq 1) { return [double]$sorted[$mid] }
  return (([double]$sorted[$mid] + [double]$sorted[$mid + 1]) / 2.0)
}

function Get-MountBaselineSec {
  param(
    [string]$Key,
    $DurationMap,
    [double]$Default = 0.5
  )
  $map = Convert-DurationMap $DurationMap
  if (-not $map.ContainsKey($Key)) { return $Default }
  $med = Get-MedianSec $map[$Key]
  if ($null -eq $med) { return $Default }
  return [double]$med
}

function Update-ProbeDurationMap {
  param($DurationMap, $Results, [int]$Window = 12)
  $map = Convert-DurationMap $DurationMap
  foreach ($r in (Convert-ToArray $Results)) {
    if ($null -eq $r) { continue }
    if ($r.Verdict -ne 'ok') { continue }
    if ($null -eq $r.DurationSec -or $r.DurationSec -eq '') { continue }
    $key = '{0}:{1}' -f $r.Container, $r.Path
    $list = @()
    if ($map.ContainsKey($key)) {
      foreach ($x in (Convert-ToArray $map[$key])) { $list += [double]$x }
    }
    $list += [double]$r.DurationSec
    if ($Window -gt 0 -and $list.Count -gt $Window) {
      $start = $list.Count - $Window
      $list = $list[$start..($list.Count - 1)]
    }
    $map[$key] = $list
  }
  return ,$map
}

function Format-ProbeDurationSec {
  param($Seconds)
  if ($null -eq $Seconds -or $Seconds -eq '') { return '' }
  return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.00}s', [double]$Seconds))
}

function Test-ProbeTimeout {
  param($Result)
  if ($null -eq $Result) { return $false }
  if ($Result.Verdict -ne 'mount-fail') { return $false }
  $detail = ''
  if ($null -ne $Result.Detail) { $detail = [string]$Result.Detail }
  if ($detail -match 'timeout') { return $true }
  if ($null -ne $Result.DurationSec -and $Result.DurationSec -ne '') {
    if ([double]$Result.DurationSec -ge [double]$Tier1TimeoutSec) { return $true }
  }
  return $false
}

function Get-ProbeLatencyAssessment {
  param($Results, $Baselines = $null)
  $map = Convert-DurationMap $Baselines
  $timeouts = @()
  $slowPeers = @()
  foreach ($r in (Convert-ToArray $Results)) {
    if ($null -eq $r) { continue }
    if (Test-ProbeTimeout $r) {
      $timeouts += $r
      continue
    }
    if ($r.Verdict -ne 'ok' -and $r.Verdict -ne 'mount-fail') { continue }
    if ($null -eq $r.DurationSec -or $r.DurationSec -eq '') { continue }
    $dur = [double]$r.DurationSec
    $key = '{0}:{1}' -f $r.Container, $r.Path
    $base = [double]$DefaultBaselineSec
    if ($map.ContainsKey($key)) {
      $med = Get-MedianSec $map[$key]
      if ($null -ne $med) { $base = [double]$med }
    }
    if ($base -le 0) { $base = [double]$DefaultBaselineSec }
    if ($dur -ge ([double]$SlowMultiple * $base)) { $slowPeers += $r }
  }
  $peerCount = @($slowPeers).Count
  $vm = (($timeouts.Count -gt 0) -and ($peerCount -ge [int]$SlowPeerMin))
  return [pscustomobject]@{
    HasTimeout    = ($timeouts.Count -gt 0)
    SlowPeerCount = $peerCount
    SlowPeers     = ,$slowPeers
    Timeouts      = ,$timeouts
    VmDegraded    = $vm
  }
}

function Format-VmDegradedNote {
  param($Decision)
  if ($null -eq $Decision) { return '' }
  if (-not [bool]$Decision.VmDegraded) { return '' }
  $n = [int]$Decision.SlowPeerCount
  return ('同一輪內另有 {0} 條掛載異常緩慢，可能是 VM 層級劣化而非單一容器問題' -f $n)
}

function Add-VmDegradedNotice {
  param([string]$Text, $Decision)
  $note = Format-VmDegradedNote $Decision
  if ($note -eq '') { return $Text }
  if ($null -eq $Text -or $Text -eq '') { return $note }
  return ($Text + "`n" + $note)
}

function Get-ProbeRunDecision {
  param(
    $Results,
    $Baselines = $null
  )
  $failed = Get-MountFailResults $Results
  $probed = Get-ProbedCount $Results
  $lat = Get-ProbeLatencyAssessment -Results $Results -Baselines $Baselines
  $vm = [bool]$lat.VmDegraded
  $peerN = [int]$lat.SlowPeerCount
  if ($failed.Count -gt 0) {
    return [pscustomobject]@{
      Status = 'FAIL'; NeedTier2 = $true; Probed = $probed
      ClearLatch = $false; AllowRecovered = $false; Reason = 'mount-fail'
      VmDegraded = $vm; SlowPeerCount = $peerN
    }
  }
  if ($probed -eq 0) {
    return [pscustomobject]@{
      Status = 'FAIL'; NeedTier2 = $true; Probed = 0
      ClearLatch = $false; AllowRecovered = $false; Reason = 'unprobed'
      VmDegraded = $false; SlowPeerCount = 0
    }
  }
  return [pscustomobject]@{
    Status = 'OK'; NeedTier2 = $false; Probed = $probed
    ClearLatch = $true; AllowRecovered = $true; Reason = 'ok'
    VmDegraded = $false; SlowPeerCount = $peerN
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
      $dur = Format-ProbeDurationSec $r.DurationSec
      if ($dur -ne '') { $dur = ' ' + $dur }
      $lines += ('• {0} {1} ({2}){3}' -f $r.Container, $r.Path, $r.Detail, $dur)
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
    [string]$OwnerMention = 'OWNER',
    $Baselines = $null
  )
  if ($null -eq $OwnerMention -or $OwnerMention -eq '') { $OwnerMention = 'OWNER' }
  $decision = Get-ProbeRunDecision $Results $Baselines
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
      Kind = 'ok'; Text = (Add-VmDegradedNotice $text $decision); Probed = $n; Total = $m
    }
  }
  if ($decision.Reason -eq 'unprobed') {
    $text = "<@$OwnerMention> ⚠️ **mount-watchdog** ${verb}後仍無法探測：$m 條全部 SKIP（probed=0，容器尚未恢復）。這不是成功。"
    return [pscustomobject]@{
      Decision = $decision; Failed = ,$failed; ClaimSuccess = $false
      Kind = 'unprobed'; Text = (Add-VmDegradedNotice $text $decision); Probed = $n; Total = $m
    }
  }
  if ($decision.Reason -eq 'mount-fail') {
    $failN = @($failed).Count
    $text = "<@$OwnerMention> ⚠️ **mount-watchdog** ${verb}後仍有 $failN 條掛載失敗：`n" + (Format-FailList $Results)
    return [pscustomobject]@{
      Decision = $decision; Failed = ,$failed; ClaimSuccess = $false
      Kind = 'mount-fail'; Text = (Add-VmDegradedNotice $text $decision); Probed = $n; Total = $m
    }
  }
  $text = "<@$OwnerMention> ⚠️ **mount-watchdog** ${verb}後僅 probed=$n/$m，先前失敗的掛載尚未全部可讀。這不是成功。"
  return [pscustomobject]@{
    Decision = $decision; Failed = ,$failed; ClaimSuccess = $false
    Kind = 'incomplete'; Text = (Add-VmDegradedNotice $text $decision); Probed = $n; Total = $m
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
  param(
    [string]$Scope,
    [bool]$VmDegraded = $false
  )
  if ($Scope -eq 'vm') { return 'self-heal' }
  if ($Scope -eq 'container') {
    if ($VmDegraded) { return 'observe' }
    return 'restart-failed'
  }
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

function Convert-WslListText {
  param([string]$Raw)
  if ($null -eq $Raw) { return '' }
  return ([string]$Raw -replace "`0", '')
}

function Get-WslRunningLineCount {
  param([string]$Output)
  $s = Convert-WslListText $Output
  $n = 0
  foreach ($ln in ($s -replace "`r", '' -split "`n")) {
    if ($ln.Trim() -ne '') { $n++ }
  }
  return $n
}

function Test-WslHasNoRunningDistro {
  param(
    [string]$Output,
    [int]$ExitCode = 0,
    [bool]$TimedOut = $false
  )
  if ($TimedOut) { return $false }
  if ($ExitCode -eq 124) { return $false }
  if ($ExitCode -eq 127) { return $false }
  if ($ExitCode -ne 0) { return $false }
  return ((Get-WslRunningLineCount $Output) -eq 0)
}

function Get-VmRecycleDecision {
  param($Before, $After)
  if ($null -eq $After) {
    return [pscustomobject]@{ Recycled = $false; Reason = 'pending' }
  }
  $vmmem = $true
  if ($null -ne $After.VmmemPresent) { $vmmem = [bool]$After.VmmemPresent }
  if (-not $vmmem) {
    return [pscustomobject]@{ Recycled = $true; Reason = 'vmmem-gone' }
  }

  $wslTimedOut = $false
  if ($null -ne $After.WslTimedOut) { $wslTimedOut = [bool]$After.WslTimedOut }
  $wslExit = 1
  if ($null -ne $After.PSObject.Properties['WslExit']) {
    try { $wslExit = [int]$After.WslExit } catch { $wslExit = 1 }
  }
  $wslOut = ''
  if ($null -ne $After.WslOut) { $wslOut = [string]$After.WslOut }
  if (Test-WslHasNoRunningDistro -Output $wslOut -ExitCode $wslExit -TimedOut $wslTimedOut) {
    return [pscustomobject]@{ Recycled = $true; Reason = 'wsl-empty' }
  }

  $beforeOk = $false
  if ($null -ne $Before -and [bool]$Before.Captured) { $beforeOk = $true }
  $afterDocker = $false
  if ([bool]$After.DockerOk) { $afterDocker = $true }
  if ($beforeOk -and $afterDocker) {
    $bBoot = ''
    $aBoot = ''
    if ($null -ne $Before.BootId) { $bBoot = [string]$Before.BootId }
    if ($null -ne $After.BootId) { $aBoot = [string]$After.BootId }
    if ($bBoot -ne '' -and $aBoot -ne '' -and $bBoot -ne $aBoot) {
      return [pscustomobject]@{ Recycled = $true; Reason = 'boot-id' }
    }
    $bUp = $null
    $aUp = $null
    if ($null -ne $Before.UptimeSec -and $Before.UptimeSec -ne '') {
      try { $bUp = [double]$Before.UptimeSec } catch { $bUp = $null }
    }
    if ($null -ne $After.UptimeSec -and $After.UptimeSec -ne '') {
      try { $aUp = [double]$After.UptimeSec } catch { $aUp = $null }
    }
    $sameBoot = ($bBoot -ne '' -and $aBoot -ne '' -and $bBoot -eq $aBoot)
    if (-not $sameBoot -and $null -ne $bUp -and $null -ne $aUp -and $aUp -lt $bUp) {
      return [pscustomobject]@{ Recycled = $true; Reason = 'uptime' }
    }
  }

  return [pscustomobject]@{ Recycled = $false; Reason = 'pending' }
}

function Get-SelfHealSteps {
  return @(
    'Discord 告警：偵測到 VM 層級掛載故障，開始自癒',
    'wsl --shutdown（不等待指令返回；關機前先取 VM boot_id／uptime 基準）',
    '輪詢 VM 汰換：boot_id 變更、wsl 無 running distro、或 vmmemWSL 消失（任一即可）；上限 900 秒。vmmemWSL 仍在不代表失敗。超時則停手並告警需要人工處理／重開機（不再重試，寫入 manualRequired 閂鎖）',
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
  Assert-True (-not $decOk.VmDegraded) 'mixed without duration/timeout is not VM-degraded'

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
  Assert-True ($joined -match 'vmmemWSL') 'ladder still names vmmemWSL as one recycle signal'
  Assert-True ($joined -match 'boot_id') 'ladder waits on VM identity not only vmmem process'
  Assert-True ($joined -match '900') 'ladder vmmem timeout is 900s not 300s'
  Assert-True ($joined -match '不用 docker desktop restart') 'ladder states kill-then-start not CLI restart'
  Assert-True ($joined -match 'manualRequired') 'ladder text mentions abort latch'
  Assert-Eq $VmmemTimeoutSec 900 'recycle wait timeout stays 900s (escape hatch kept)'

  # FIX-VMMEM：2026-08-28 維護實測 — vmmemWSL 全程存在，但 VM 已汰換（uptime 68s、配額腰斬）
  $beforeToday = [pscustomobject]@{ Captured = $true; BootId = 'old-boot-aaaaaaaa'; UptimeSec = 86400 }
  $afterToday = [pscustomobject]@{
    VmmemPresent = $true
    WslTimedOut  = $false
    WslExit      = 0
    WslOut       = "Windows Subsystem for Linux Distributions:`ndocker-desktop"
    DockerOk     = $true
    BootId       = 'new-boot-bbbbbbbb'
    UptimeSec    = 68
    Captured     = $true
  }
  $decToday = Get-VmRecycleDecision -Before $beforeToday -After $afterToday
  Assert-True $decToday.Recycled '2026-08-28 maintenance: vmmem still present but boot_id changed => recycled'
  Assert-Eq $decToday.Reason 'boot-id' 'today recycle reason is boot-id (not vmmem-gone)'

  $afterStuck = [pscustomobject]@{
    VmmemPresent = $true
    WslTimedOut  = $true
    WslExit      = 124
    WslOut       = ''
    DockerOk     = $false
    BootId       = ''
    UptimeSec    = $null
    Captured     = $false
  }
  $decStuck = Get-VmRecycleDecision -Before $beforeToday -After $afterStuck
  Assert-True (-not $decStuck.Recycled) 'stuck VM: vmmem present + wsl timeout + docker down => pending (will hit 900s abort)'
  Assert-Eq $decStuck.Reason 'pending' 'stuck VM reason=pending'

  $afterSame = [pscustomobject]@{
    VmmemPresent = $true
    WslTimedOut  = $false
    WslExit      = 0
    WslOut       = 'docker-desktop'
    DockerOk     = $true
    BootId       = 'old-boot-aaaaaaaa'
    UptimeSec    = 86410
    Captured     = $true
  }
  Assert-True (-not (Get-VmRecycleDecision -Before $beforeToday -After $afterSame).Recycled) 'same boot_id is not a recycle'

  $afterGone = [pscustomobject]@{
    VmmemPresent = $false; WslTimedOut = $false; WslExit = 0; WslOut = ''
    DockerOk = $false; BootId = ''; UptimeSec = $null
  }
  $decGone = Get-VmRecycleDecision -Before $beforeToday -After $afterGone
  Assert-True $decGone.Recycled 'vmmem gone remains a sufficient recycle signal'
  Assert-Eq $decGone.Reason 'vmmem-gone' 'vmmem-gone reason'

  $afterEmpty = [pscustomobject]@{
    VmmemPresent = $true; WslTimedOut = $false; WslExit = 0
    WslOut = ''; DockerOk = $false; BootId = ''; UptimeSec = $null
  }
  $decEmpty = Get-VmRecycleDecision -Before $beforeToday -After $afterEmpty
  Assert-True $decEmpty.Recycled 'wsl --list --running --quiet with 0 names => recycle (shutdown finished)'
  Assert-Eq $decEmpty.Reason 'wsl-empty' 'wsl-empty reason'

  Assert-True (Test-WslHasNoRunningDistro -Output '' -ExitCode 0 -TimedOut $false) 'zero non-empty lines is no running distro'
  Assert-True (-not (Test-WslHasNoRunningDistro -Output "docker-desktop`nUbuntu" -ExitCode 0 -TimedOut $false)) 'distro name lines are running'
  Assert-True (-not (Test-WslHasNoRunningDistro -Output '沒有正在執行的發佈。' -ExitCode 0 -TimedOut $false)) 'zh-TW prose is not the empty signal (line count only)'
  Assert-True (-not (Test-WslHasNoRunningDistro -Output 'There are no running distributions.' -ExitCode 0 -TimedOut $false)) 'English banner is not the empty signal (use --quiet)'
  Assert-True (-not (Test-WslHasNoRunningDistro -Output '' -ExitCode 127 -TimedOut $false)) 'exit 127 empty is a failed invocation not wsl-empty'
  Assert-True (-not (Test-WslHasNoRunningDistro -Output '' -ExitCode 124 -TimedOut $true)) 'wsl list timeout is NOT treated as empty'
  $nulOnly = "`0`0"
  Assert-True (Test-WslHasNoRunningDistro -Output $nulOnly -ExitCode 0 -TimedOut $false) 'NUL-only UTF-16 padding counts as zero lines'

  $beforeUp = [pscustomobject]@{ Captured = $true; BootId = ''; UptimeSec = 100000 }
  $afterUp = [pscustomobject]@{
    VmmemPresent = $true; WslTimedOut = $false; WslExit = 0; WslOut = 'docker-desktop'
    DockerOk = $true; BootId = ''; UptimeSec = 68
  }
  $decUp = Get-VmRecycleDecision -Before $beforeUp -After $afterUp
  Assert-True $decUp.Recycled 'uptime reset without boot_id (today: 68s) => recycled'
  Assert-Eq $decUp.Reason 'uptime' 'uptime-reset reason'

  $beforeNone = [pscustomobject]@{ Captured = $false }
  $afterOrphan = [pscustomobject]@{
    VmmemPresent = $true; WslTimedOut = $false; WslExit = 0; WslOut = 'docker-desktop'
    DockerOk = $true; BootId = 'xyz'; UptimeSec = 68
  }
  Assert-True (-not (Get-VmRecycleDecision -Before $beforeNone -After $afterOrphan).Recycled) 'no pre-shutdown baseline: docker coming back is not proof of recycle'

  Assert-Eq (Get-ScopeAction 'vm') 'self-heal' 'FIX-VMMEM does not lower Scope=vm heal trigger'

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

  # FIX-M0：探測耗時納入判定。2026-08-27 20:56 真實數字（非合成）。
  # 基線用 20:51 正常輪 ~0.17s；timeout 本身不計入 K，另有 11.0 / 2.5 / 1.8 三條超基線。
  $incident2056 = @(
    [pscustomobject]@{ Container = 'openab-url-intake'; Path = '/vault'; Verdict = 'mount-fail'; DurationSec = 15.0; Detail = 'timeout ls /vault (exit 124)' },
    [pscustomobject]@{ Container = 'intake-publisher'; Path = '/vault'; Verdict = 'ok'; DurationSec = 11.0; Detail = 'OK' },
    [pscustomobject]@{ Container = 'pdf-publisher'; Path = '/vault'; Verdict = 'ok'; DurationSec = 0.17; Detail = 'OK' },
    [pscustomobject]@{ Container = 'openab-estate'; Path = '/workspace/EstateSpace'; Verdict = 'ok'; DurationSec = 2.5; Detail = 'OK' },
    [pscustomobject]@{ Container = 'openab-travel-claude'; Path = '/workspace/TravelMemory'; Verdict = 'ok'; DurationSec = 1.8; Detail = 'OK' },
    [pscustomobject]@{ Container = 'openab-travel-nvidia'; Path = '/workspace/TravelMemory'; Verdict = 'ok'; DurationSec = 0.17; Detail = 'OK' },
    [pscustomobject]@{ Container = 'openab-credit-report'; Path = '/workspace/CreditReportSpace'; Verdict = 'ok'; DurationSec = 0.17; Detail = 'OK' },
    [pscustomobject]@{ Container = 'openab-kiro'; Path = '/workspace/KiroSpace'; Verdict = 'ok'; DurationSec = 0.17; Detail = 'OK' },
    [pscustomobject]@{ Container = 'openab-kiro'; Path = '/workspace/TravelMemory'; Verdict = 'ok'; DurationSec = 0.17; Detail = 'OK' },
    [pscustomobject]@{ Container = 'openab-nvidia-lab'; Path = '/workspace/LabSpace'; Verdict = 'ok'; DurationSec = 0.17; Detail = 'OK' },
    [pscustomobject]@{ Container = 'openab-astruct'; Path = '/workspace/AStructSpace'; Verdict = 'ok'; DurationSec = 0.17; Detail = 'OK' },
    [pscustomobject]@{ Container = 'openab-astruct'; Path = '/workspace/AStructSpace/forward'; Verdict = 'ok'; DurationSec = 0.17; Detail = 'OK' }
  )
  $base017 = @{}
  foreach ($row in $incident2056) {
    $base017[('{0}:{1}' -f $row.Container, $row.Path)] = @(0.17, 0.17, 0.18)
  }
  $decIncident = Get-ProbeRunDecision $incident2056 $base017
  Assert-Eq $decIncident.Status 'FAIL' '20:56 still FAIL (timeout is mount-fail)'
  Assert-Eq $decIncident.Reason 'mount-fail' '20:56 reason remains mount-fail'
  Assert-True ($null -ne $decIncident.VmDegraded) 'decision always exposes VmDegraded'
  Assert-True $decIncident.VmDegraded '20:56 timeout + 3 slow peers => VM-level suspicion'
  Assert-True ([int]$decIncident.SlowPeerCount -ge 2) '20:56 SlowPeerCount >= K=2'
  Assert-True ($decIncident.SlowPeerCount -ge 3) '20:56 with 0.17s baseline flags 11.0+2.5+1.8 (3 peers)'

  $normal017 = @()
  foreach ($row in $incident2056) {
    $normal017 += [pscustomobject]@{
      Container = $row.Container; Path = $row.Path; Verdict = 'ok'
      DurationSec = 0.17; Detail = 'OK'
    }
  }
  $decNormal = Get-ProbeRunDecision $normal017 $base017
  Assert-Eq $decNormal.Status 'OK' 'all-0.17s round stays OK'
  Assert-True (-not $decNormal.VmDegraded) 'all-0.17s must not flag VM-level suspicion'

  $isolated = @()
  foreach ($row in $incident2056) {
    $v = 'ok'; $d = 0.17; $det = 'OK'
    if ($row.Container -eq 'openab-url-intake') {
      $v = 'mount-fail'; $d = 15.0; $det = 'timeout ls /vault (exit 124)'
    }
    $isolated += [pscustomobject]@{
      Container = $row.Container; Path = $row.Path; Verdict = $v
      DurationSec = $d; Detail = $det
    }
  }
  $decIsolated = Get-ProbeRunDecision $isolated $base017
  Assert-Eq $decIsolated.Status 'FAIL' 'isolated timeout is still FAIL'
  Assert-True (-not $decIsolated.VmDegraded) 'isolated timeout (no slow peers) is not VM-level suspicion'

  $decCold = Get-ProbeRunDecision $incident2056 $null
  Assert-True $decCold.VmDegraded '20:56 still VM-suspicion on cold-start default baseline 0.5s (11.0 and 2.5)'

  Assert-Eq $SlowMultiple 5 'FIX-M0 M=5 is locked'
  Assert-Eq $SlowPeerMin 2 'FIX-M0 K=2 is locked'
  Assert-Eq $DefaultBaselineSec 0.5 'FIX-M0 cold-start baseline 0.5s is locked'
  $medOdd = Get-MedianSec @(0.16, 0.17, 0.18)
  Assert-True ([Math]::Abs([double]$medOdd - 0.17) -lt 0.0001) 'median of 3 samples is the middle'
  $medEven = Get-MedianSec @(0.10, 0.20)
  Assert-True ([Math]::Abs([double]$medEven - 0.15) -lt 0.0001) 'median of 2 samples is the mean'
  Assert-True ([Math]::Abs((Get-MountBaselineSec -Key 'missing:/x' -DurationMap @{} -Default 0.5) - 0.5) -lt 0.0001) 'missing key uses conservative default'

  $upd = Update-ProbeDurationMap @{} @(
    [pscustomobject]@{ Container = 'a'; Path = '/x'; Verdict = 'ok'; DurationSec = 0.17 }
  ) 12
  Assert-Eq @(Convert-ToArray $upd['a:/x']).Count 1 'ok duration is recorded'
  $upd2 = Update-ProbeDurationMap $upd @(
    [pscustomobject]@{ Container = 'a'; Path = '/x'; Verdict = 'mount-fail'; DurationSec = 15.0 }
  ) 12
  Assert-Eq @(Convert-ToArray $upd2['a:/x']).Count 1 'timeout duration must not enter baseline'
  $rtJson = @{ probeDurations = $upd } | ConvertTo-Json -Depth 6
  $rtBack = $rtJson | ConvertFrom-Json
  $rtMap = Convert-DurationMap $rtBack.probeDurations
  Assert-True ([Math]::Abs(([double](Get-MedianSec $rtMap['a:/x'])) - 0.17) -lt 0.0001) 'probeDurations survives JSON round-trip'

  $note = Format-VmDegradedNote $decIncident
  Assert-True ($note -match '同一輪內另有 \d+ 條掛載異常緩慢，可能是 VM 層級劣化而非單一容器問題') 'alert note uses the required VM-suspicion sentence'
  Assert-True ((Format-VmDegradedNote $decNormal) -eq '') 'OK round has no VM-suspicion sentence'

  # 同一判定必須同時作用於主流程與自癒／重啟（Get-InterventionOutcome 走同一份 Get-ProbeRunDecision）
  $ivHealM0 = Get-InterventionOutcome -Results $incident2056 -PrevFailed $incident2056 -Mode 'heal' -OwnerMention 'OWNER' -Baselines $base017
  $ivRestartM0 = Get-InterventionOutcome -Results $incident2056 -PrevFailed $incident2056 -Mode 'restart' -OwnerMention 'OWNER' -Baselines $base017
  Assert-True $ivHealM0.Decision.VmDegraded 'heal path sees VM-level suspicion (same judge)'
  Assert-True $ivRestartM0.Decision.VmDegraded 'restart path sees VM-level suspicion (same judge)'
  Assert-Eq $ivHealM0.Decision.VmDegraded $ivRestartM0.Decision.VmDegraded 'heal and restart VmDegraded identical'
  Assert-True ($ivHealM0.Text -match 'VM 層級劣化') 'heal notice mentions VM-level suspicion'
  Assert-True ($ivRestartM0.Text -match 'VM 層級劣化') 'restart notice mentions VM-level suspicion'

  # 自癒觸發門檻不可因 VmDegraded 降低：仍只有 Scope=vm 才 self-heal
  Assert-Eq (Get-ScopeAction 'vm') 'self-heal' 'vm => self-heal (threshold unchanged)'
  Assert-Eq (Get-ScopeAction 'vm' -VmDegraded $true) 'self-heal' 'VmDegraded must NOT promote/demote Scope=vm heal'
  Assert-Eq (Get-ScopeAction 'container') 'restart-failed' 'container without VmDegraded still restarts'
  Assert-Eq (Get-ScopeAction 'container' -VmDegraded $true) 'observe' 'container+VmDegraded skips restart (conservative)'
  Assert-Eq (Get-ScopeAction 'daemon' -VmDegraded $true) 'alert-only' 'daemon+VmDegraded still alert-only (no heal)'

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
  Assert-True ($ladderBody -notmatch 'VmDegraded') 'ladder does not invent a second latency judge'
  Assert-True ($ladderBody -notmatch 'Get-VmRecycleDecision') 'ladder body has no recycle judge (Wait-VmRecycled owns it)'
  Assert-True ($ladderBody.Contains('Send-WatchdogNotice')) 'ladder mid-flight still uses the single send'
  Assert-True ($ladderBody.Contains('Wait-VmRecycled')) 'ladder waits via Wait-VmRecycled not vmmem-only'
  Assert-True ($ladderBody.Contains('Get-VmRecycleSnapshot')) 'ladder captures pre-shutdown VM identity'
  $iSendFn = $src.LastIndexOf('function Send-WatchdogNotice {')
  $iWaitFn = $src.LastIndexOf('function Wait-VmRecycled')
  $sendBody = ''
  if ($iSendFn -ge 0 -and $iWaitFn -gt $iSendFn) { $sendBody = $src.Substring($iSendFn, $iWaitFn - $iSendFn) }
  $regInSend = ([regex]::Matches($sendBody, 'Register-SendAttempt')).Count
  Assert-Eq $regInSend 2 'Register-SendAttempt only lives beside Send-WatchdogNotice'
  Assert-Eq ([regex]::Matches($src, 'function Get-ProbeRunDecision \{')).Count 1 'exactly one Get-ProbeRunDecision (no second judge)'
  Assert-Eq ([regex]::Matches($src, 'function Get-VmRecycleDecision \{')).Count 1 'exactly one Get-VmRecycleDecision (no second recycle judge)'
  Assert-True ($src -match 'Get-ScopeAction -Scope \$scope -VmDegraded') 'main passes VmDegraded into Get-ScopeAction'
  Assert-True ($src.Contains('Format-VmDegradedNote')) 'single formatter for the VM-suspicion sentence'
  Assert-True ($src.Contains('Get-ProbeRunDecision $Results $Baselines')) 'intervention judge reuses Get-ProbeRunDecision + baselines'
  Assert-True ($src.Contains("psi.Arguments = '--list --running --quiet'")) 'wsl flags passed as one unquoted argument string'
  Assert-True ($src.Contains('[System.Text.Encoding]::Unicode')) 'wsl stdout decoded as UTF-16'
  $iSnap = $src.LastIndexOf('function Get-VmRecycleSnapshot {')
  $iStartWsl = $src.LastIndexOf('function Start-WslShutdownFireAndForget {')
  $snapBody = ''
  if ($iSnap -ge 0 -and $iStartWsl -gt $iSnap) { $snapBody = $src.Substring($iSnap, $iStartWsl - $iSnap) }
  Assert-True ($snapBody.Contains('Invoke-WslListRunning')) 'snapshot lists WSL via Invoke-WslListRunning'
  Assert-True ($snapBody -notmatch "Invoke-Cmd 'wsl.exe'") 'snapshot does not quote-wrap wsl.exe via Invoke-Cmd'
  $iWait = $src.LastIndexOf('function Wait-VmRecycled {')
  $iVmmem = $src.LastIndexOf('function Test-VmmemPresent {')
  $waitBody = ''
  if ($iWait -ge 0 -and $iVmmem -gt $iWait) { $waitBody = $src.Substring($iWait, $iVmmem - $iWait) }
  Assert-True ($waitBody -match 'try') 'V-3: Wait-VmRecycled wraps snapshot in try'
  Assert-True ($waitBody.Contains('recycle snapshot failed (will retry)')) 'V-3: snapshot throw retries the wait loop'

  $wslLive = Invoke-WslListRunning 15
  $liveLines = Get-WslRunningLineCount $wslLive.Out
  Write-Output ("[WSL-LIVE] exit={0} lines={1}" -f $wslLive.Code, $liveLines)
  Assert-True ($wslLive.Code -ne 127) 'wsl --list --running --quiet is flags not a distro command (exit!=127)'
  Assert-True ($wslLive.Code -ne 124) 'wsl list did not time out'
  $snap = Get-VmRecycleSnapshot
  $snapLines = Get-WslRunningLineCount $snap.WslOut
  Write-Output ("[SNAPSHOT-LIVE] wslExit={0} lines={1} dockerOk={2}" -f $snap.WslExit, $snapLines, $snap.DockerOk)
  Assert-True ($snap.WslExit -ne 127) 'Get-VmRecycleSnapshot wsl exit is not 127'
  Assert-Eq $snap.WslExit $wslLive.Code 'snapshot uses the same successful wsl invocation'

  if ($script:FailCount -gt 0) {
    Write-Output ("SelfTest FAILED: {0} assertion(s)" -f $script:FailCount)
  } else {
    Write-Output 'SelfTest PASSED'
  }
}

# ── 執行期 I/O ────────────────────────────────────────────────────────────

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

function Invoke-WslListRunning {
  param([int]$TimeoutSec = 10)
  # wsl.exe 不解析被引號包住的旗標；Invoke-Cmd 的逐參加引號會變成「在預設 distro 裡執行 --list」。
  # 必須整串傳 Arguments，並用 UTF-16 讀 stdout。
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'wsl.exe'
  $psi.Arguments = '--list --running --quiet'
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::Unicode

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
    probeDurations      = (Convert-DurationMap $obj.probeDurations)
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
    probeDurations      = (Convert-DurationMap $State.probeDurations)
  }
  $json = $payload | ConvertTo-Json -Depth 6
  Set-Content -Path $Path -Value $json -Encoding utf8
}

function Invoke-Tier1Probe {
  $results = @()
  foreach ($m in $Mounts) {
    $c = $m.Container
    $p = $m.Path
    $t0 = Get-Date
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
    $durationSec = ((Get-Date) - $t0).TotalSeconds
    $verdict = Get-MountVerdict -InspectExit $insp.Code -RunningRaw $insp.Out -ExecExit $execExit -ExecOut $execOut
    $detail = ($execOut).Trim()
    if ($detail -eq '') { $detail = ($execErr).Trim() }
    if ($verdict -eq 'absent') { $detail = 'container absent' }
    if ($verdict -eq 'stopped') { $detail = 'not running' }
    if ($execExit -eq 124) { $detail = "timeout ls $p (exit 124)" }
    $label = 'FAIL'
    if ($verdict -eq 'ok') { $label = 'OK' }
    if ($verdict -eq 'stopped' -or $verdict -eq 'absent') { $label = 'SKIP' }
    $durLabel = Format-ProbeDurationSec $durationSec
    Write-Log ("[T1] {0} {1} => {2} ({3}) {4}" -f $c, $p, $label, $detail, $durLabel)
    # Verdict 是唯一判定欄位。不再寫 Ok（舊欄位無人讀，避免被當成狀態機依據）。
    $results += [pscustomobject]@{
      Container   = $c
      Path        = $p
      Verdict     = $verdict
      Detail      = $detail
      DurationSec = $durationSec
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

function Wait-VmRecycled {
  param($Before, [int]$TimeoutSec = 900, [int]$PollSec = 5)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    $after = $null
    try {
      $after = Get-VmRecycleSnapshot
    } catch {
      Write-Log ("[WARN] recycle snapshot failed (will retry): {0}" -f $_.Exception.Message)
      Start-Sleep -Seconds $PollSec
      continue
    }
    $dec = Get-VmRecycleDecision -Before $Before -After $after
    if ($dec.Recycled) {
      Write-Log ("[HEAL] VM recycle confirmed reason={0} vmmem={1} dockerOk={2} boot_id={3} uptime={4}" -f $dec.Reason, $after.VmmemPresent, $after.DockerOk, $after.BootId, $after.UptimeSec)
      return $true
    }
    Write-Log ('[HEAL] VM recycle pending (vmmem={0} dockerOk={1} wslTimeout={2}), waiting...' -f $after.VmmemPresent, $after.DockerOk, $after.WslTimedOut)
    Start-Sleep -Seconds $PollSec
  }
  return $false
}

function Test-VmmemPresent {
  foreach ($n in @('vmmemWSL', 'vmmem')) {
    $got = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($null -ne $got) { return $true }
  }
  return $false
}

function Get-VmRecycleSnapshot {
  param([int]$WslTimeoutSec = 10, [int]$DockerTimeoutSec = 20)
  $vmmem = Test-VmmemPresent

  $wsl = Invoke-WslListRunning $WslTimeoutSec
  $wslTimedOut = ($wsl.Code -eq 124)
  $wslText = ''
  if ($null -ne $wsl.Out) { $wslText += [string]$wsl.Out }
  if ($null -ne $wsl.Err) { $wslText += [string]$wsl.Err }

  $dockerOk = $false
  $bootId = ''
  $uptimeSec = $null
  $shell = 'cat /proc/sys/kernel/random/boot_id; cat /proc/uptime'
  $dock = Invoke-Cmd 'docker' @('run', '--rm', 'alpine', 'sh', '-c', $shell) $DockerTimeoutSec
  if ($dock.Code -eq 0) {
    $dockerOk = $true
    $lines = @()
    $rawOut = ''
    if ($null -ne $dock.Out) { $rawOut = [string]$dock.Out }
    foreach ($ln in ($rawOut -replace "`r", '' -split "`n")) {
      $t = $ln.Trim()
      if ($t -ne '') { $lines += $t }
    }
    if ($lines.Count -ge 1) { $bootId = $lines[0] }
    if ($lines.Count -ge 2) {
      $upParts = $lines[1].Split(' ')
      if ($upParts.Count -ge 1 -and $upParts[0] -ne '') {
        try { $uptimeSec = [double]$upParts[0] } catch { $uptimeSec = $null }
      }
    }
  }

  return [pscustomobject]@{
    VmmemPresent = $vmmem
    WslTimedOut  = $wslTimedOut
    WslExit      = [int]$wsl.Code
    WslOut       = $wslText
    DockerOk     = $dockerOk
    BootId       = $bootId
    UptimeSec    = $uptimeSec
    Captured     = $dockerOk
  }
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

  Write-Log '[HEAL] step 2: capture VM identity then wsl --shutdown (fire and forget)'
  $before = $null
  try {
    $before = Get-VmRecycleSnapshot
  } catch {
    Write-Log ("[WARN] pre-shutdown VM snapshot failed: {0}" -f $_.Exception.Message)
    $before = [pscustomobject]@{ Captured = $false; BootId = ''; UptimeSec = $null }
  }
  if ([bool]$before.Captured) {
    Write-Log ("[HEAL] pre-shutdown boot_id={0} uptime={1}s" -f $before.BootId, $before.UptimeSec)
  } else {
    Write-Log '[HEAL] pre-shutdown docker identity unavailable; recycle wait will use wsl-empty/vmmem only'
  }
  try { [void](Start-WslShutdownFireAndForget) } catch {
    Write-Log ("[WARN] wsl --shutdown start failed: {0}" -f $_.Exception.Message)
  }

  Write-Log '[HEAL] step 3: poll VM recycle (boot_id / wsl-empty / vmmem) up to 900s'
  $gone = Wait-VmRecycled -Before $before -TimeoutSec $VmmemTimeoutSec
  if (-not $gone) {
    $msg = "<@$OwnerId> 🛑 **mount-watchdog** 自癒停手：900 秒內未能確認 VM 已汰換（boot_id 未變且 wsl 仍有發行版，vmmemWSL 仍在也不算完成）。需要人工處理／重開機。不會自動重試。"
    Send-WatchdogNotice -Text $msg -AlertCfg $AlertCfg -WouldSend $true
    Write-Log '[HEAL] abort: VM recycle timeout'
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

if ($SelfTest) {
  # 不要把 SelfTest 的 Write-Output 擷進變數（會把 PASS 行跟 exit code 混在一起）。
  Invoke-SelfTest
  if ($script:FailCount -gt 0) { exit 1 }
  exit 0
}

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
$durationMap = Convert-DurationMap $state.probeDurations
$decision = Get-ProbeRunDecision $tier1 $durationMap
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
  Write-Log ("[PROBE] reason={0} probed={1} scope={2} vmDegraded={3} slowPeers={4}" -f $decision.Reason, $decision.Probed, $scope, $decision.VmDegraded, $decision.SlowPeerCount)
} elseif ($decision.SlowPeerCount -gt 0) {
  Write-Log ("[LATENCY] slowPeers={0} vmDegraded={1} (no timeout this round)" -f $decision.SlowPeerCount, $decision.VmDegraded)
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
Write-Log ("[STATE] prev={0} new={1} scope={2} alert={3} send={4} probed={5} vmDegraded={6} slowPeers={7}" -f $state.status, $newStatus, $scope, $alert.Kind, $alert.Send, $decision.Probed, $decision.VmDegraded, $decision.SlowPeerCount)

$notice = $null
if ($newStatus -eq 'FAIL') {
  $failBody = Format-FailList $failed
  if ($failBody -eq '') {
    $failBody = ('（無 mount-fail 列；probed={0} reason={1}）' -f $decision.Probed, $decision.Reason)
  }
  $notice = "<@$OwnerId> ⚠️ **mount-watchdog** 掛載檢查失敗（Scope=$scope）`n" + $failBody
  $notice = Add-VmDegradedNotice $notice $decision
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
  $action = Get-ScopeAction -Scope $scope -VmDegraded ([bool]$decision.VmDegraded)
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
        $iv = Get-InterventionOutcome -Results $healOutcome.Results -PrevFailed $failedBeforeAction -Mode 'heal' -OwnerMention $OwnerId -Baselines $durationMap
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
  } elseif ($action -eq 'observe') {
    Write-Log '[ACTION] observe — same-round slow peers suggest VM-level stall; skip container restart (cannot fix 9p)'
  } elseif ($action -eq 'restart-failed') {
    if ($failed.Count -eq 0) {
      Write-Log '[ACTION] restart-failed skipped (no mount-fail rows)'
    } else {
      $again = Invoke-ContainerRestart $failed
      if ($again.Count -gt 0) {
        $iv = Get-InterventionOutcome -Results $again -PrevFailed $failedBeforeAction -Mode 'restart' -OwnerMention $OwnerId -Baselines $durationMap
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
  probeDurations      = (Update-ProbeDurationMap $durationMap $tier1 $BaselineWindow)
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
