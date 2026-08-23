<#
  claude-oauth-check.ps1 — 監看走 Claude OAuth 的 bridge 容器（2026-08-23 建立）

  起因：travel-claudebridge 的 access token 在 2026-06-12 到期後兩個多月都沒被
  refresh，直到使用者在 Discord 問問題才以「⚠️ Internal Error (code: -32603)
  + API Error: 401」的形式浮現。TRAVEL_SETUP.md 原本寫「token 自動 refresh，
  登一次即可」是錯的。

  兩段式檢查（都跑在容器外，因為要偵測的就是容器本身壞掉）：
    無參數  → 便宜檢查：容器在跑嗎？.credentials.json 的 expiresAt 過期了嗎？
              零 token 成本、零風險，適合每小時跑。
    -Live   → 真實探測：docker exec <容器> claude -p "ok"，看得到 401 的地實情況。
              會消耗一點點 Claude 額度，一天跑一次即可。

  發現異常就用「該 bot 自己的 Discord token」發到「它自己的頻道」並 @ owner。
  用自己的 token 是因為壞的是 Claude OAuth，不是 Discord token；而且腳本在
  host 上持有 token，就算容器整個掛掉也發得出通知。

  重登方式見 TRAVEL_SETUP.md：docker exec -it <容器> claude → /login → 然後
  **一定要 docker restart**（ACP 子行程只在 spawn 時讀一次憑證）。
#>
param(
  [switch]$Live,
  # 同一個容器在這段時間內只通知一次，避免每小時洗頻。
  [int]$RealertHours = 12
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root      = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)  # D:\discord 個人助理
$EnvFile   = Join-Path $Root '.local\discord_token.env'
$StateDir  = Join-Path $PSScriptRoot '.state'
$OwnerId   = '843428445802725388'   # anxxxiii

# 監看名單 —— 兩隻都掛 Claude OAuth named volume，是同一種故障模式。
$Targets = @(
  @{ Container = 'openab-travel-claude'; TokenVar = 'DISCORD_TOKEN_TRAVEL_CLAUDE'; ChannelId = '1514819240631206072'; Label = '#travel-planner / travel-claudebridge' },
  @{ Container = 'openab-astruct';       TokenVar = 'DISCORD_TOKEN_ASTRUCT';       ChannelId = '1518874308716265643'; Label = '#a-struct / A_struct bot' }
)

if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir | Out-Null }

# ── 讀 token（只認 ASCII 大寫的 KEY=VALUE；檔案裡那行中文 key 會被略過）──────
$Tokens = @{}
foreach ($line in (Get-Content $EnvFile)) {
  if ($line -match '^([A-Z_][A-Z0-9_]*)=(.+)$') { $Tokens[$Matches[1]] = $Matches[2].Trim() }
}

# ── 執行外部指令並取回 exit code / stdout / stderr（附 timeout，避免卡死）────
function Invoke-Cmd {
  param([string]$Exe, [string[]]$CmdArgs, [int]$TimeoutSec = 90)
  # 不用 Start-Process -PassThru：PS 5.1 下不加 -Wait 時它回傳的 Process 物件
  # ExitCode 永遠是 $null（HasExited 卻是 True），但 -Wait 又沒有 timeout。
  # 直接用 System.Diagnostics.Process 才能同時拿到 exit code 與 timeout。
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
  # 先掛非同步讀取再 WaitForExit，否則 stdout/stderr 塞滿 pipe 會死鎖。
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
  param([string]$Token, [string]$ChannelId, [string]$Text)
  # ⚠ User-Agent 必填：Discord 前面的 Cloudflare 會把非 `DiscordBot (...)` 的
  # 請求擋掉，回一個**空 body 的 403**，看起來很像權限不足，其實不是。
  $ua = "DiscordBot (https://github.com/openabdev/openab, 1.0) openab-healthcheck"
  $body = @{ content = $Text; allowed_mentions = @{ users = @($OwnerId) } } | ConvertTo-Json -Depth 5 -Compress
  Invoke-RestMethod -Method Post `
    -Uri "https://discord.com/api/v10/channels/$ChannelId/messages" `
    -Headers @{ Authorization = "Bot $Token"; "User-Agent" = $ua } `
    -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
}

# expiresAt 讀取器 —— 丟進容器用 node 解析，避免 host 端還要處理 JSON 路徑。
$ReadExpiry = @'
try {
  const c = require("/home/node/.claude/.credentials.json").claudeAiOauth || {};
  console.log(JSON.stringify({ expiresAt: c.expiresAt || 0, sub: c.subscriptionType || "?" }));
} catch (err) { console.log(JSON.stringify({ error: String(err.message) })); }
'@

# 偵測「是否已切換到長效訂閱 token」——讀掛進容器的 config.toml，找未註解的
# 注入行，取出它引用的 ${VAR} 名字，再確認該變數有值且不是佔位字串。
$DetectEnvToken = @'
line=$(grep -E "^[[:space:]]*env[[:space:]]*=.*CLAUDE_CODE_OAUTH_TOKEN" /etc/openab/config.toml 2>/dev/null | head -1)
if [ -z "$line" ]; then echo NO; exit 0; fi
var=$(echo "$line" | sed -n 's/.*${\([A-Za-z_][A-Za-z0-9_]*\)}.*/\1/p')
if [ -z "$var" ]; then echo NO; exit 0; fi
val=$(eval echo "\$$var")
case "$val" in ""|PASTE_*) echo NO ;; *) echo YES ;; esac
'@

# env-token 模式的真實探測：乾淨 HOME（沒有 .credentials.json）＋ 手動 export，
# 複製 agent 子行程的條件，確保測到的是環境變數那條路。
$LiveProbeEnvToken = @'
line=$(grep -E "^[[:space:]]*env[[:space:]]*=.*CLAUDE_CODE_OAUTH_TOKEN" /etc/openab/config.toml | head -1)
var=$(echo "$line" | sed -n 's/.*${\([A-Za-z_][A-Za-z0-9_]*\)}.*/\1/p')
CLAUDE_CODE_OAUTH_TOKEN=$(eval echo "\$$var"); export CLAUDE_CODE_OAUTH_TOKEN
HOME=$(mktemp -d); export HOME
claude -p "say ok" 2>&1
rc=$?
rm -rf "$HOME"
exit $rc
'@

$problems = 0

foreach ($t in $Targets) {
  $name   = $t.Container
  $issues = @()

  # 1) 容器在跑嗎？
  $r = Invoke-Cmd 'docker' @('inspect', '-f', '{{.State.Running}}', $name) 30
  if ($r.Code -ne 0) {
    $issues += "容器不存在或 docker 無回應：$(($r.Err).Trim())"
  } elseif (($r.Out).Trim() -ne 'true') {
    $issues += '容器沒有在跑（State.Running = false）'
  } else {
    # 2a) 這隻是不是已經改吃長效訂閱 token？
    #     ⚠ 不能查容器的基礎 env —— `CLAUDE_CODE_OAUTH_TOKEN` 只存在於 openab
    #     spawn 出來的 agent 子行程裡（由 config.toml 的 [agent] env 注入），
    #     容器自己的 env 只有 env_file 裡那個帶後綴的名字。所以改成讀 config.toml
    #     有沒有未註解的注入行，再確認它引用的變數確實有值。
    $detect = Invoke-Cmd 'docker' @('exec', $name, 'sh', '-c', $DetectEnvToken) 30
    $usingEnvToken = (($detect.Out).Trim() -eq 'YES')

    if ($usingEnvToken) {
      Write-Output "[NOTE] $name 走長效訂閱 token（環境變數），略過憑證檔檢查"
    } else {
      # 2b) OAuth access token 過期了嗎？（只在還走 .credentials.json 時有意義）
      $r = Invoke-Cmd 'docker' @('exec', $name, 'node', '-e', $ReadExpiry) 60
      if ($r.Code -ne 0) {
        $issues += "讀不到 .credentials.json：$(($r.Err).Trim())"
      } else {
        $info = $null
        try { $info = ($r.Out).Trim() | ConvertFrom-Json } catch {}
        if ($null -eq $info) {
          $issues += "憑證輸出無法解析：$(($r.Out).Trim())"
        } elseif ($info.error) {
          $issues += "憑證檔讀取失敗：$($info.error)"
        } elseif ([int64]$info.expiresAt -le 0) {
          $issues += '憑證檔沒有 expiresAt（可能從未登入）'
        } else {
          $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$info.expiresAt)
          if ($exp -lt [DateTimeOffset]::UtcNow) {
            $age = [int]([DateTimeOffset]::UtcNow - $exp).TotalHours
            $issues += "access token 已於 $($exp.ToString('yyyy-MM-dd HH:mm')) UTC 過期（$age 小時前），refresh 沒有生效"
          }
        }
      }
    }

    # 3) 真實探測（僅 -Live）
    if ($Live -and $issues.Count -eq 0) {
      # ⚠ 直接 `docker exec claude -p` 讀的是 .credentials.json，不是注入的環境
      #    變數 —— 對已切換的容器測錯對象（舊憑證早就死了，會誤報）。所以
      #    env-token 模式改用乾淨 HOME ＋ 手動 export，複製 agent 子行程的條件。
      $probe = if ($usingEnvToken) { $LiveProbeEnvToken } else { 'claude -p "say ok"' }
      $r = Invoke-Cmd 'docker' @('exec', $name, 'sh', '-c', $probe) 120
      $combined = ("$($r.Out)$($r.Err)").Trim()
      if ($combined -match "hit your limit|usage limit|rate.?limit|resets") {
        # 訂閱額度用完 —— 會自己恢復，不是認證故障，只記錄不通知。
        Write-Output "[NOTE] $name 額度用完：$combined（非認證問題，略過）"
      } elseif ($r.Code -ne 0 -or $combined -match "401|authentication_error|Failed to authenticate") {
        $issues += "實測 ``claude -p`` 失敗（exit $($r.Code)）：$combined"
      }
    }
  }
  $stateFile = Join-Path $StateDir "$name.last-alert"

  if ($issues.Count -eq 0) {
    # 恢復正常就清掉節流狀態，下次再壞會立刻通知。
    Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
    Write-Output "[OK] $name"
    continue
  }

  $problems++
  Write-Output "[FAIL] $name -- $($issues -join ' / ')"

  # 節流：$RealertHours 小時內不重複發。
  if (Test-Path $stateFile) {
    $last = Get-Item $stateFile
    if (((Get-Date) - $last.LastWriteTime).TotalHours -lt $RealertHours) {
      Write-Output "       (已於 $($last.LastWriteTime) 通知過，節流中)"
      continue
    }
  }

  $token = $Tokens[$t.TokenVar]
  if (-not $token) {
    Write-Output "       (無法通知：$EnvFile 裡找不到 $($t.TokenVar))"
    continue
  }

  $lines = @(
    "<@$OwnerId> ⚠️ **$($t.Label)** 健康檢查失敗"
  )
  foreach ($i in $issues) { $lines += "• $i" }
  $lines += ''
  $lines += '修法（PowerShell）：'
  $lines += '```'
  $lines += "docker exec -it $name claude      # 進去打 /login"
  $lines += "docker restart $name              # 一定要重啟，子行程只在 spawn 時讀憑證"
  $lines += '```'

  try {
    Send-DiscordAlert -Token $token -ChannelId $t.ChannelId -Text ($lines -join "`n")
    Set-Content -Path $stateFile -Value (Get-Date -Format 'o') -Encoding utf8
    Write-Output '       (已發 Discord 通知)'
  } catch {
    Write-Output "       (Discord 通知失敗：$($_.Exception.Message))"
  }
}

exit $(if ($problems -gt 0) { 1 } else { 0 })
