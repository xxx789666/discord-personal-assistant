<#
  nim-model-canary.ps1 — NVIDIA NIM 模型下架 canary（一天一次）

  起因：2026-09-09 minimaxai/minimax-m3 永久下架（HTTP 410 EOL，已從
  /v1/models 消失），#url-intake 三層備援實際只剩兩層且沒有任何告警。
  這是第三次 NIM 無預警下架（前兩次 kimi-k2.6、nemotron-3-nano）。

  對 compose 裡 openab-url-intake 設定的三個模型各送一個極小的
  POST /v1/chat/completions。只有確實收到 410/404 才當永久失效並告警
  #infra-alerts。503／429／逾時／連線失敗／空回應是「無法判定」，不告警。
  不准把「不等於 200」當成下架——探測失敗絕不可跟一個成功的「否」撞值。

  用法：
    .\nim-model-canary.ps1            # 探測；410/404 才告警
    .\nim-model-canary.ps1 -DryRun    # 解析模型清單，不打 API、不發 Discord
    .\nim-model-canary.ps1 -SelfTest  # 純函式單元測試（不碰網路／.local 內容）
    .\nim-model-canary.ps1 -TestAlert # 只發一則測試 Discord，不探測模型
#>
param(
  [switch]$SelfTest,
  [switch]$DryRun,
  [switch]$TestAlert,
  [string]$AlertEnv = '',
  [string]$TokenEnv = '',
  [string]$NvidiaEnv = '',
  [string]$ComposeFile = '',
  [string]$StateDir = ''
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)  # worktree / repo root
$KnownCheckoutLocal = 'D:\discord 個人助理\.local'
# $EnvAlert / $EnvTokens / $EnvNvidia：SelfTest 之後由 Resolve-* 填入
# （TestAlert 與正式路徑同一條：worktree .local → D:\discord 個人助理\.local）。
$EnvAlert = ''
$EnvTokens = ''
$EnvNvidia = ''
if ($StateDir -eq '') { $StateDir = Join-Path $PSScriptRoot '.state' }
$LogFile = Join-Path $StateDir 'nim-model-canary.log'
$OwnerId = '843428445802725388'
$DefaultNimBase = 'https://integrate.api.nvidia.com/v1'
$ProbeTimeoutSec = 20
if ($ComposeFile -eq '') {
  $ComposeFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'docker-compose.yml'
}

# ── 純函式（SelfTest 注入假資料；不含網路／Discord／讀 .local 內容）────────

function Convert-ToArray {
  param($Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Array]) { return @($Value) }
  return @($Value)
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

function Resolve-NvidiaEnvPath {
  param(
    [string]$NvidiaEnv = '',
    [string]$RepoRoot,
    [string]$KnownLocal = 'D:\discord 個人助理\.local'
  )
  $candidates = @(
    (Join-Path $RepoRoot '.local\nvidia.env'),
    (Join-Path $KnownLocal 'nvidia.env')
  )
  return Resolve-FirstExistingPath -Explicit $NvidiaEnv -Candidates $candidates
}

function Read-DotEnv {
  param([string]$Path)
  $map = @{}
  if ($null -eq $Path -or $Path -eq '') { return $map }
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

function Test-HttpSuccess {
  param([int]$Code)
  return ($Code -ge 200 -and $Code -lt 300)
}

function Get-RetirementVerdict {
  param($StatusCode, [string]$Body = '')
  # 第三態：只有確實收到 410/404 才是 retired。連線失敗、逾時、空回應、
  # 503/429 一律 undetermined。不准用「不等於 200 就是壞了」。
  if ($null -eq $StatusCode) { return 'undetermined' }
  if ($StatusCode -is [string] -and ([string]$StatusCode).Trim() -eq '') {
    return 'undetermined'
  }
  $code = 0
  try { $code = [int]$StatusCode } catch { return 'undetermined' }
  if ($code -le 0) { return 'undetermined' }
  if ($code -eq 410 -or $code -eq 404) { return 'retired' }
  if ($code -eq 200) {
    if ($null -eq $Body -or ([string]$Body).Trim() -eq '') { return 'undetermined' }
    return 'alive'
  }
  return 'undetermined'
}

function Test-ShouldAlertRetirement {
  param([string]$Verdict)
  return ($Verdict -eq 'retired')
}

function Get-ComposeServiceEnvironment {
  param([string]$Text, [string]$ServiceName)
  $envMap = @{}
  if ($null -eq $Text -or $Text -eq '') { return $envMap }
  $inService = $false
  $inEnv = $false
  $serviceIndent = -1
  $envIndent = -1
  foreach ($raw in ($Text -replace "`r", '' -split "`n")) {
    $stripped = $raw.TrimStart(' ')
    $indent = $raw.Length - $stripped.Length
    if (-not $inService) {
      if ($stripped.StartsWith('#') -or $stripped -eq '') { continue }
      if ($stripped.TrimEnd() -eq ($ServiceName + ':')) {
        $inService = $true
        $serviceIndent = $indent
      }
      continue
    }
    if ($stripped -ne '' -and -not $stripped.StartsWith('#') -and $indent -le $serviceIndent) {
      break
    }
    if (-not $inEnv) {
      if ($stripped.StartsWith('#') -or $stripped -eq '') { continue }
      if ($stripped.TrimEnd() -eq 'environment:') {
        $inEnv = $true
        $envIndent = $indent
      }
      continue
    }
    if ($stripped -ne '' -and -not $stripped.StartsWith('#') -and $indent -le $envIndent) {
      $inEnv = $false
      if ($indent -le $serviceIndent) { break }
      continue
    }
    if ($stripped -match '^([A-Z][A-Z0-9_]*):\s*"([^"]*)"') {
      $envMap[$Matches[1]] = $Matches[2]
    } elseif ($stripped -match '^([A-Z][A-Z0-9_]*):\s*([^#\s]+)') {
      $envMap[$Matches[1]] = $Matches[2]
    }
  }
  return $envMap
}

function Get-UrlIntakeNimModels {
  param([string]$ComposeText)
  $envMap = Get-ComposeServiceEnvironment -Text $ComposeText -ServiceName 'openab-url-intake'
  $keys = @('NVIDIA_MODEL', 'NVIDIA_FALLBACK_MODEL', 'NVIDIA_FINAL_FALLBACK_MODEL')
  $models = @()
  foreach ($k in $keys) {
    if (-not $envMap.ContainsKey($k)) { continue }
    $v = [string]$envMap[$k]
    if ($null -eq $v) { continue }
    $v = $v.Trim()
    if ($v -eq '') { continue }
    $models += $v
  }
  return @($models)
}

function Format-RetirementNotice {
  param($Results, [string]$OwnerMention)
  $lines = @()
  foreach ($r in (Convert-ToArray $Results)) {
    if ($null -eq $r) { continue }
    if ($r.Verdict -eq 'retired') {
      $lines += ('• {0}  HTTP {1}' -f $r.Model, $r.StatusCode)
    }
  }
  $head = ('<@{0}> ⚠️ **nim-model-canary** NIM 模型已永久下架（HTTP 410/404）。死模型不會自己好，請同步改 openab/docker-compose.yml 與 url-intake/bot.py。' -f $OwnerMention)
  if ($lines.Count -eq 0) { return $head }
  return $head + "`n" + ($lines -join "`n")
}

function Get-NimProbeBody {
  param([string]$Model)
  $escaped = ([string]$Model).Replace('\', '\\').Replace('"', '\"')
  return '{"model":"' + $escaped + '","messages":[{"role":"user","content":"Reply with the single word: ok"}],"max_tokens":16,"stream":false}'
}

# ── SelfTest（必須在任何 I/O 副作用之前可獨立跑；不讀 .local 內容）────────

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

  Write-Output '=== nim-model-canary SelfTest ==='

  Assert-Eq (Get-RetirementVerdict -StatusCode 410 -Body 'Gone') 'retired' 'HTTP 410 is retired'
  Assert-Eq (Get-RetirementVerdict -StatusCode 404 -Body 'Not Found') 'retired' 'HTTP 404 is retired'
  Assert-Eq (Get-RetirementVerdict -StatusCode 200 -Body '{"ok":true}') 'alive' 'HTTP 200 with body is alive'
  Assert-Eq (Get-RetirementVerdict -StatusCode 200 -Body '') 'undetermined' 'HTTP 200 empty body is undetermined'
  Assert-Eq (Get-RetirementVerdict -StatusCode 200 -Body '   ') 'undetermined' 'HTTP 200 whitespace body is undetermined'
  Assert-Eq (Get-RetirementVerdict -StatusCode 503 -Body 'busy') 'undetermined' 'HTTP 503 is undetermined (transient)'
  Assert-Eq (Get-RetirementVerdict -StatusCode 429 -Body 'rate') 'undetermined' 'HTTP 429 is undetermined (transient)'
  Assert-Eq (Get-RetirementVerdict -StatusCode $null) 'undetermined' 'null status is undetermined (timeout/connect)'
  Assert-Eq (Get-RetirementVerdict -StatusCode 0) 'undetermined' 'status 0 is undetermined'
  Assert-Eq (Get-RetirementVerdict -StatusCode '') 'undetermined' 'empty status is undetermined'
  Assert-Eq (Get-RetirementVerdict -StatusCode 500 -Body 'oops') 'undetermined' 'HTTP 500 is undetermined'
  Assert-Eq (Get-RetirementVerdict -StatusCode 401 -Body 'no') 'undetermined' 'HTTP 401 is not retired'
  Assert-True (Test-ShouldAlertRetirement 'retired') 'retired should alert'
  Assert-True (-not (Test-ShouldAlertRetirement 'alive')) 'alive should not alert'
  Assert-True (-not (Test-ShouldAlertRetirement 'undetermined')) 'undetermined should not alert'
  Assert-True (-not (Test-ShouldAlertRetirement 'undetermined')) 'third-state does not collide with retired'

  $yaml = @"
services:
  other-bot:
    environment:
      NVIDIA_MODEL: "wrong/first-hit"
      NVIDIA_FALLBACK_MODEL: "wrong/first-fallback"
      NVIDIA_FINAL_FALLBACK_MODEL: "wrong/first-final"
  openab-url-intake:
    image: assistant-url-intake:dev
    environment:
      CHANNEL_ID: "1"
      NVIDIA_MODEL: "openai/gpt-oss-20b"
      NVIDIA_FALLBACK_MODEL: "google/gemma-4-31b-it"
      NVIDIA_FINAL_FALLBACK_MODEL: "nvidia/nemotron-3-super-120b-a12b"
    volumes:
      - /vault
  later-bot:
    environment:
      NVIDIA_MODEL: "wrong/later-hit"
"@
  $scoped = Get-UrlIntakeNimModels $yaml
  Assert-Eq $scoped.Count 3 'url-intake yields three models'
  Assert-Eq $scoped[0] 'openai/gpt-oss-20b' 'parser takes url-intake primary not first file hit'
  Assert-Eq $scoped[1] 'google/gemma-4-31b-it' 'parser takes url-intake fallback'
  Assert-Eq $scoped[2] 'nvidia/nemotron-3-super-120b-a12b' 'parser takes url-intake final'

  $explicit = Resolve-AlertEnvPaths -AlertEnv 'C:\tmp\infra_alert.env' -TokenEnv 'C:\tmp\discord_token.env' -RepoRoot 'C:\nope' -KnownLocal 'C:\also-nope'
  Assert-Eq $explicit.AlertPath 'C:\tmp\infra_alert.env' 'explicit AlertEnv wins'
  Assert-Eq $explicit.TokenPath 'C:\tmp\discord_token.env' 'explicit TokenEnv wins'

  $fallback = Resolve-AlertEnvPaths -AlertEnv '' -TokenEnv '' -RepoRoot 'C:\repo' -KnownLocal 'D:\discord 個人助理\.local'
  Assert-True ($fallback.AlertCandidates[0] -eq 'C:\repo\.local\infra_alert.env') 'alert candidate 0 is worktree .local'
  Assert-True ($fallback.AlertCandidates[1] -eq 'D:\discord 個人助理\.local\infra_alert.env') 'alert candidate 1 is known checkout .local'

  $nv = Resolve-NvidiaEnvPath -NvidiaEnv '' -RepoRoot 'C:\repo' -KnownLocal 'D:\discord 個人助理\.local'
  Assert-True (
    ($nv -eq 'C:\repo\.local\nvidia.env') -or
    ($nv -eq 'D:\discord 個人助理\.local\nvidia.env')
  ) 'nvidia.env fallback is worktree then known checkout'

  $notice = Format-RetirementNotice @(
    [pscustomobject]@{ Model = 'dead/model'; StatusCode = 410; Verdict = 'retired' },
    [pscustomobject]@{ Model = 'ok/model'; StatusCode = 200; Verdict = 'alive' },
    [pscustomobject]@{ Model = 'slow/model'; StatusCode = 503; Verdict = 'undetermined' }
  ) '843428445802725388'
  Assert-True ($notice -match 'dead/model') 'notice names retired model'
  Assert-True ($notice -match 'HTTP 410') 'notice includes 410'
  Assert-True ($notice -notmatch 'ok/model') 'notice omits alive model'
  Assert-True ($notice -notmatch 'slow/model') 'notice omits undetermined model'
  Assert-True ($notice -match 'infra-alerts' -or $notice -match 'nim-model-canary') 'notice identifies canary'

  $probeBody = Get-NimProbeBody 'openai/gpt-oss-20b'
  Assert-True ($probeBody -match '"max_tokens":16') 'probe payload is tiny'
  Assert-True ($probeBody -match 'Reply with the single word: ok') 'probe prompt is canary-sized'
  Assert-True ($probeBody -notmatch 'system') 'probe has no system prompt'

  Assert-True (Test-HttpSuccess 200) 'HTTP 200 is success'
  Assert-True (-not (Test-HttpSuccess 410)) 'HTTP 410 is not Discord success'
  Assert-True (-not (Test-AlertChannelConfigured '')) 'empty channel is not configured'
  Assert-True (-not (Test-AlertChannelConfigured 'PASTE_CHANNEL_ID')) 'placeholder channel is not configured'
  Assert-True (Test-AlertChannelConfigured '1536220007657373806') 'numeric channel is configured'

  if (Test-Path -LiteralPath $ComposeFile) {
    $composeText = [System.IO.File]::ReadAllText($ComposeFile, (New-Object System.Text.UTF8Encoding $false))
    $liveModels = Get-UrlIntakeNimModels $composeText
    Assert-Eq $liveModels.Count 3 'real compose url-intake has three NIM models'
    Assert-Eq $liveModels[0] 'openai/gpt-oss-20b' 'real compose primary is gpt-oss-20b'
    Assert-Eq $liveModels[1] 'google/gemma-4-31b-it' 'real compose fallback is gemma-4-31b-it'
    Assert-Eq $liveModels[2] 'nvidia/nemotron-3-super-120b-a12b' 'real compose final is nemotron-3-super'
  } else {
    Write-Output '[FAIL] compose file missing for live-model lock'
    $script:FailCount++
  }

  if ($script:FailCount -gt 0) {
    Write-Output ("SelfTest FAILED: {0} assertion(s)" -f $script:FailCount)
  } else {
    Write-Output 'SelfTest PASSED'
  }
}

function Write-Log {
  param([string]$Message)
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
  Write-Host $line
  if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Get-AlertConfig {
  $alert = Read-DotEnv $EnvAlert
  $channel = $alert['INFRA_ALERT_CHANNEL_ID']
  $tokenVar = $alert['INFRA_ALERT_TOKEN_VAR']
  if ($null -eq $tokenVar -or $tokenVar -eq '') { $tokenVar = 'DISCORD_TOKEN_NVIDIA' }
  $tokens = Read-DotEnv $EnvTokens
  $token = $tokens[$tokenVar]
  return [pscustomobject]@{
    ChannelId  = $channel
    TokenVar   = $tokenVar
    Token      = $token
    Configured = (Test-AlertChannelConfigured $channel)
  }
}

function Send-DiscordAlert {
  param(
    [string]$Token,
    [string]$ChannelId,
    [string]$Text,
    [bool]$Mention = $true
  )
  # ⚠ User-Agent 必填：少了 DiscordBot (...) Cloudflare 回空 body 403。
  $ua = 'DiscordBot (https://github.com/openabdev/openab, 1.0) openab-nim-model-canary'
  $mentions = @{ parse = @() }
  if ($Mention) { $mentions = @{ users = @($OwnerId) } }
  $body = @{ content = $Text; allowed_mentions = $mentions } | ConvertTo-Json -Depth 5 -Compress
  $resp = Invoke-WebRequest -Method Post `
    -Uri "https://discord.com/api/v10/channels/$ChannelId/messages" `
    -Headers @{ Authorization = "Bot $Token"; 'User-Agent' = $ua } `
    -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) `
    -UseBasicParsing `
    -TimeoutSec 20
  return @{ Code = [int]$resp.StatusCode; Body = [string]$resp.Content }
}

function Invoke-NimCanaryProbe {
  param(
    [string]$BaseUrl,
    [string]$ApiKey,
    [string]$Model,
    [int]$TimeoutSec = 20
  )
  $uri = $BaseUrl.TrimEnd('/') + '/chat/completions'
  $json = Get-NimProbeBody $Model
  try {
    $resp = Invoke-WebRequest -Method Post `
      -Uri $uri `
      -Headers @{ Authorization = ("Bearer {0}" -f $ApiKey) } `
      -ContentType 'application/json; charset=utf-8' `
      -Body ([Text.Encoding]::UTF8.GetBytes($json)) `
      -UseBasicParsing `
      -TimeoutSec $TimeoutSec
    $body = $resp.Content
    if ($null -eq $body) { $body = '' }
    return [pscustomobject]@{
      Model = $Model
      StatusCode = [int]$resp.StatusCode
      Body = [string]$body
      Error = ''
    }
  } catch {
    $err = [string]$_.Exception.Message
    $webResp = $null
    if ($null -ne $_.Exception.Response) { $webResp = $_.Exception.Response }
    if ($null -eq $webResp -and $null -ne $_.Exception.InnerException) {
      if ($null -ne $_.Exception.InnerException.Response) {
        $webResp = $_.Exception.InnerException.Response
      }
    }
    if ($null -eq $webResp) {
      return [pscustomobject]@{
        Model = $Model
        StatusCode = $null
        Body = ''
        Error = $err
      }
    }
    $code = [int]$webResp.StatusCode
    $body = ''
    try {
      $stream = $webResp.GetResponseStream()
      if ($null -ne $stream) {
        $reader = New-Object System.IO.StreamReader($stream)
        $body = $reader.ReadToEnd()
        $reader.Close()
      }
    } catch {}
    if ($null -eq $body) { $body = '' }
    return [pscustomobject]@{
      Model = $Model
      StatusCode = $code
      Body = [string]$body
      Error = $err
    }
  }
}

# ── 主流程 ────────────────────────────────────────────────────────────────

if ($SelfTest) {
  Invoke-SelfTest
  if ($script:FailCount -gt 0) { exit 1 }
  exit 0
}

# TestAlert 與正式路徑共用：worktree .local → D:\discord 個人助理\.local
# （或 -AlertEnv / -TokenEnv / -NvidiaEnv）。沒有 TestAlert 專屬捷徑。
$resolvedEnv = Resolve-AlertEnvPaths -AlertEnv $AlertEnv -TokenEnv $TokenEnv -RepoRoot $Root -KnownLocal $KnownCheckoutLocal
$EnvAlert = $resolvedEnv.AlertPath
$EnvTokens = $resolvedEnv.TokenPath
$EnvNvidia = Resolve-NvidiaEnvPath -NvidiaEnv $NvidiaEnv -RepoRoot $Root -KnownLocal $KnownCheckoutLocal

if ($TestAlert) {
  $alertCfg = Get-AlertConfig
  Write-Host '=== nim-model-canary -TestAlert ==='
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
  $text = "ℹ️ **nim-model-canary TestAlert** — 這是測試訊息，可忽略。時間：$iso。不是真實模型下架。"
  try {
    $sent = Send-DiscordAlert -Token $alertCfg.Token -ChannelId $alertCfg.ChannelId -Text $text -Mention $false
    Write-Host ('HTTP ' + $sent.Code)
    $bodyPreview = $sent.Body
    if ($null -eq $bodyPreview) { $bodyPreview = '' }
    if ($bodyPreview.Length -gt 200) { $bodyPreview = $bodyPreview.Substring(0, 200) }
    Write-Host ('body: ' + $bodyPreview)
    Write-Host 'TestAlert done (no model probe; same env resolution as official path)'
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

if (-not (Test-Path -LiteralPath $ComposeFile)) {
  Write-Log ("[FAIL] compose not found: {0}" -f $ComposeFile)
  exit 1
}
$composeText = [System.IO.File]::ReadAllText($ComposeFile, (New-Object System.Text.UTF8Encoding $false))
$models = @(Get-UrlIntakeNimModels $composeText)
if ($models.Count -eq 0) {
  Write-Log '[FAIL] no NVIDIA_* models under openab-url-intake environment'
  exit 1
}

Write-Log '=== nim-model-canary run ==='
Write-Log ("[CFG] alert env={0}" -f $EnvAlert)
Write-Log ("[CFG] token env={0}" -f $EnvTokens)
Write-Log ("[CFG] nvidia env={0}" -f $EnvNvidia)
Write-Log ("[CFG] models={0}" -f ($models -join ', '))
if ($DryRun) { Write-Log '[DRYRUN] will not call NIM or Discord' }

$nvidiaMap = Read-DotEnv $EnvNvidia
$apiKey = $nvidiaMap['NVIDIA_API_KEY']
$baseUrl = $nvidiaMap['NVIDIA_BASE_URL']
if ($null -eq $baseUrl -or $baseUrl.Trim() -eq '') { $baseUrl = $DefaultNimBase }

$results = @()
foreach ($model in $models) {
  if ($DryRun) {
    $row = [pscustomobject]@{
      Model = $model
      StatusCode = $null
      Body = ''
      Error = 'dryrun'
      Verdict = 'undetermined'
    }
    $results += $row
    Write-Log ("[DRYRUN] would probe {0}" -f $model)
    continue
  }
  if ($null -eq $apiKey -or $apiKey.Trim() -eq '') {
    $row = [pscustomobject]@{
      Model = $model
      StatusCode = $null
      Body = ''
      Error = 'no-api-key'
      Verdict = 'undetermined'
    }
    $results += $row
    Write-Log ("[SKIP] {0} undetermined (NVIDIA_API_KEY not found)" -f $model)
    continue
  }
  $probe = Invoke-NimCanaryProbe -BaseUrl $baseUrl -ApiKey $apiKey -Model $model -TimeoutSec $ProbeTimeoutSec
  $verdict = Get-RetirementVerdict -StatusCode $probe.StatusCode -Body $probe.Body
  $row = [pscustomobject]@{
    Model = $model
    StatusCode = $probe.StatusCode
    Body = $probe.Body
    Error = $probe.Error
    Verdict = $verdict
  }
  $results += $row
  $codeText = $probe.StatusCode
  if ($null -eq $codeText) { $codeText = 'none' }
  Write-Log ("[PROBE] {0} HTTP {1} verdict={2}" -f $model, $codeText, $verdict)
}

$retired = @($results | Where-Object { $_.Verdict -eq 'retired' })
$alertCfg = Get-AlertConfig

if ($retired.Count -gt 0 -and -not $DryRun) {
  $notice = Format-RetirementNotice $retired $OwnerId
  if (-not $alertCfg.Configured) {
    Write-Log '[SKIP] no alert channel configured (not sending retirement alert)'
  } elseif ($null -eq $alertCfg.Token -or $alertCfg.Token -eq '') {
    Write-Log ('[SKIP] token var {0} not found in discord_token.env' -f $alertCfg.TokenVar)
  } else {
    try {
      $sent = Send-DiscordAlert -Token $alertCfg.Token -ChannelId $alertCfg.ChannelId -Text $notice -Mention $true
      if (Test-HttpSuccess ([int]$sent.Code)) {
        Write-Log ("[ALERT] Discord sent HTTP {0}" -f $sent.Code)
      } else {
        Write-Log ("[WARN] Discord send HTTP {0}" -f $sent.Code)
      }
    } catch {
      $resp = $_.Exception.Response
      $code = 0
      if ($null -ne $resp) { $code = [int]$resp.StatusCode }
      Write-Log ("[WARN] Discord send failed HTTP {0}: {1}" -f $code, $_.Exception.Message)
    }
  }
  exit 2
}

if ($DryRun) { exit 0 }
if ($null -eq $apiKey -or $apiKey.Trim() -eq '') {
  Write-Log '[FAIL] NVIDIA_API_KEY missing; probes were undetermined (not an EOL alert)'
  exit 1
}
exit 0
