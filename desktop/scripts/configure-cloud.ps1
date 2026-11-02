param(
    [string]$SyncUrl = 'https://isktnezzanqpcrkkqldw.supabase.co/functions/v1/sic-sync',
    [string]$Server,
    [switch]$SkipInitialSync
)

$ErrorActionPreference = 'Stop'
$configuredServer = if ($Server) { $Server.Trim() } else { [Environment]::GetEnvironmentVariable('LINEBOARD_SIC_SERVER', [EnvironmentVariableTarget]::User) }
if (-not $configuredServer) { $configuredServer = '(localdb)\MSSQLLocalDB' }

$uri = $null
if (-not [Uri]::TryCreate($SyncUrl, [UriKind]::Absolute, [ref]$uri) -or
    $uri.Scheme -ne 'https' -or
    -not $uri.Host.EndsWith('.supabase.co', [StringComparison]::OrdinalIgnoreCase) -or
    $uri.AbsolutePath -ne '/functions/v1/sic-sync' -or
    $uri.Query -or $uri.Fragment -or $uri.UserInfo) {
    throw 'SyncUrl deve ser uma URL HTTPS /functions/v1/sic-sync de um projeto Supabase.'
}

$token = [Environment]::GetEnvironmentVariable('LINEBOARD_SYNC_TOKEN', [EnvironmentVariableTarget]::User)
$token = if ($token) { $token.Trim() } else { $null }
if ($token) {
    if (($token.StartsWith("'") -and $token.EndsWith("'")) -or
        ($token.StartsWith('"') -and $token.EndsWith('"'))) {
        $token = $token.Substring(1, $token.Length - 2).Trim()
    }
}

if (-not $token -or $token -cnotmatch '^slb_live_[a-f0-9]{64}$') {
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
    $token = $token.Trim()
    if (($token.StartsWith("'") -and $token.EndsWith("'")) -or
        ($token.StartsWith('"') -and $token.EndsWith('"'))) {
        $token = $token.Substring(1, $token.Length - 2).Trim()
    }
} else {
    Write-Host 'Usando o token cloud ja salvo no usuario atual do Windows.'
}

if ($token -cnotmatch '^slb_live_[a-f0-9]{64}$') {
    throw 'Token invalido. Ele deve seguir o formato slb_live_ mais 64 caracteres hexadecimais.'
}

[Environment]::SetEnvironmentVariable('LINEBOARD_SYNC_URL', $SyncUrl, [EnvironmentVariableTarget]::User)
[Environment]::SetEnvironmentVariable('LINEBOARD_SYNC_TOKEN', $token, [EnvironmentVariableTarget]::User)
[Environment]::SetEnvironmentVariable('LINEBOARD_SIC_SERVER', $configuredServer, [EnvironmentVariableTarget]::User)
$token = $null
Write-Host ('Configuracao cloud salva no usuario atual do Windows. SIC server: {0}' -f $configuredServer)

if ($SkipInitialSync) {
    Write-Host 'Bootstrap inicial ignorado por -SkipInitialSync.'
    exit 0
}

$desktopRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$executable = Join-Path $desktopRoot 'bin\Lineboard.exe'
Write-Host 'Compilando o Lineboard.exe atual antes do bootstrap...'
& (Join-Path $PSScriptRoot 'build.ps1')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $executable)) {
    throw 'Nao foi possivel compilar o Lineboard.exe.'
}

$resultPath = Join-Path ([IO.Path]::GetTempPath()) ('lineboard-bootstrap-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
    $argumentLine = '--server "' + $configuredServer + '" --sync-now --result-file "' + $resultPath + '"'
    $process = Start-Process -FilePath $executable -ArgumentList $argumentLine -WorkingDirectory $desktopRoot -WindowStyle Hidden -Wait -PassThru
    $exitCode = $process.ExitCode
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
