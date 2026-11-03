param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 2100000000)]
    [int]$BuildNumber,
    [ValidateSet('android-arm64', 'android-arm', 'android-x64')]
    [string]$TargetPlatform = 'android-arm64'
)

$ErrorActionPreference = 'Stop'
$mobileRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$configFile = Join-Path $mobileRoot 'config.json'
if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
    throw 'Preencha mobile/config.json conforme config.example.json antes de compilar.'
}
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($config.SUPABASE_URL) -or
    [string]::IsNullOrWhiteSpace($config.SUPABASE_PUBLISHABLE_KEY)) {
    throw 'Configure SUPABASE_URL e SUPABASE_PUBLISHABLE_KEY em mobile/config.json.'
}
if (@($config.PSObject.Properties.Name | Where-Object {
    $_ -notin @('SUPABASE_URL', 'SUPABASE_PUBLISHABLE_KEY')
}).Count -gt 0) {
    throw 'Use somente a URL e a chave publica do Supabase em mobile/config.json.'
}

$flutter = Join-Path $mobileRoot '../.local/flutter/bin/flutter.bat'
if (-not (Test-Path -LiteralPath $flutter -PathType Leaf)) {
    $flutter = (Get-Command flutter -ErrorAction Stop).Source
}
$abi = switch ($TargetPlatform) {
    'android-arm64' { 'arm64-v8a' }
    'android-arm' { 'armeabi-v7a' }
    'android-x64' { 'x86_64' }
}
$architecture = switch ($TargetPlatform) {
    'android-arm64' { 'arm64' }
    'android-arm' { 'arm32' }
    'android-x64' { 'x64' }
}
$outputDirectory = Join-Path $mobileRoot 'build/releases'
$destination = Join-Path $outputDirectory "Lineboard-$BuildNumber-$architecture.apk"
if (Test-Path -LiteralPath $destination) {
    throw "O APK de destino ja existe. Use outro BuildNumber: $destination"
}

$previousDebug = $env:DEBUG
Push-Location $mobileRoot
try {
    # Gradle's Windows wrapper echoes all arguments when DEBUG is set.
    $env:DEBUG = $null
    & $flutter build apk --release --split-per-abi "--target-platform=$TargetPlatform" `
        --android-project-arg=force-version-code-ignoring-abi=true `
        "--build-number=$BuildNumber" --dart-define=LINEBOARD_MODE=cloud `
        "--dart-define-from-file=$configFile"
    if ($LASTEXITCODE -ne 0) { throw "Falha no build Flutter: codigo $LASTEXITCODE." }

    $null = New-Item -ItemType Directory -Path $outputDirectory -Force
    Copy-Item -LiteralPath (Join-Path $mobileRoot "build/app/outputs/flutter-apk/app-$abi-release.apk") `
        -Destination $destination
    $apk = Get-Item -LiteralPath $destination
    Write-Output "APK: $destination"
    Write-Output ('Tamanho: {0:N1} MiB' -f ($apk.Length / 1MB))
    Write-Output "SHA256: $((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash)"
} finally {
    $env:DEBUG = $previousDebug
    Pop-Location
}
