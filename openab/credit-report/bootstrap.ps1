[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{17,20}$')]
    [string]$ChannelId,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$localDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $PSScriptRoot '..\..\.local')
)
$environmentFile = Join-Path $localDirectory 'credit_report.env'

if ((Test-Path -LiteralPath $environmentFile) -and -not $Force) {
    throw "$environmentFile already exists. Use -Force only when intentionally rotating credentials."
}

$secureToken = Read-Host 'Discord bot token for #聯徵報告製作' -AsSecureString
$tokenPointer = [IntPtr]::Zero
$tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
try {
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    if ([string]::IsNullOrWhiteSpace($token) -or $token -match '\s') {
        throw 'The Discord token is empty or contains whitespace.'
    }

    [System.IO.Directory]::CreateDirectory($localDirectory) | Out-Null
    $content = @(
        "DISCORD_TOKEN_CREDIT_REPORT=$token"
        "CREDIT_REPORT_CHANNEL_ID=$ChannelId"
        ''
    ) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText(
        $environmentFile,
        $content,
        [System.Text.UTF8Encoding]::new($false)
    )
}
finally {
    if ($tokenPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
    }
    $token = $null
    $content = $null
}

Write-Host "Wrote $environmentFile. This path is gitignored; do not share or commit it."
