param(
    [string]$SyncUrl = 'https://isktnezzanqpcrkkqldw.supabase.co/functions/v1/sic-sync',
    [switch]$SkipInitialSync
)

$ErrorActionPreference = 'Stop'

$uri = $null
if (-not [Uri]::TryCreate($SyncUrl, [UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -ne 'https' -or
    -not $uri.Host.EndsWith('.supabase.co', [StringComparison]::OrdinalIgnoreCase) -or
    $uri.AbsolutePath -ne '/functions/v1/sic-sync' -or
    $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
    throw 'SyncUrl deve ser uma URL HTTPS /functions/v1/sic-sync de um projeto Supabase.'
}

$secureToken = Read-Host 'Cole o token privado slb_live_... (nao sera exibido)' -AsSecureString
$token = $null
$pointer = [IntPtr]::Zero
try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
}
finally {
    if ($pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

if ($token -notmatch '^slb_live_[a-f0-9]{64}$') {
    throw 'Token invalido. Ele deve seguir o formato slb_live_ mais 64 caracteres hexadecimais.'
}

[Environment]::SetEnvironmentVariable('LINEBOARD_SYNC_URL', $SyncUrl, [EnvironmentVariableTarget]::User)
[Environment]::SetEnvironmentVariable('LINEBOARD_SYNC_TOKEN', $token, [EnvironmentVariableTarget]::User)
$token = $null
Write-Host 'Configuracao cloud salva no usuario atual do Windows.'

if ($SkipInitialSync) {
    Write-Host 'Bootstrap inicial ignorado por -SkipInitialSync.'
    exit 0
}

$desktopRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$executable = Join-Path $desktopRoot 'bin\Lineboard.exe'
if (-not (Test-Path -LiteralPath $executable)) {
    & (Join-Path $PSScriptRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel compilar o Lineboard.exe.' }
}

$resultPath = Join-Path ([IO.Path]::GetTempPath()) ('lineboard-bootstrap-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
    & $executable '--sync-now' '--result-file' $resultPath
    $exitCode = $LASTEXITCODE
    if (-not (Test-Path -LiteralPath $resultPath)) {
        throw 'O executavel nao produziu o resultado do bootstrap.'
    }
    $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
    if ($exitCode -ne 0 -or $result.ok -eq $false) {
        $message = if ($result.error) { [string]$result.error } else { 'CLOUD_BOOTSTRAP_FAILED' }
        throw $message
    }
    Write-Host ('Bootstrap concluido: estado={0}; importados={1}; enviados={2}.' -f $result.state, $result.imported, $result.sent)
}
finally {
    if (Test-Path -LiteralPath $resultPath) {
        Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    }
}
