param(
    [string]$Server,
    [string]$ConfigFile,
    [string]$WebView2Bootstrapper,
    [string]$InnoSetupPath,
    [string]$OutputDirectory,
    [string]$Version = '0.1.0',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$desktopRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspace = [IO.Path]::GetFullPath((Join-Path $desktopRoot '..'))
$bundle = Join-Path $desktopRoot 'bin'
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $workspace 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

if ($env:OS -ne 'Windows_NT') { throw 'O instalador Windows precisa ser gerado em Windows.' }

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'O build do desktop falhou.' }
}

$required = @(
    'Lineboard.exe',
    'schema.sql',
    'ui\index.html',
    'Microsoft.Web.WebView2.Core.dll',
    'Microsoft.Web.WebView2.WinForms.dll',
    'WebView2Loader.dll'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $bundle $relative))) {
        throw "Pacote incompleto: $relative não foi encontrado em desktop/bin."
    }
}

if (-not $WebView2Bootstrapper) {
    $WebView2Bootstrapper = Join-Path $workspace 'vendor\MicrosoftEdgeWebView2Setup.exe'
}
if (-not (Test-Path -LiteralPath $WebView2Bootstrapper)) {
    throw "WebView2 bootstrapper não encontrado: $WebView2Bootstrapper. Baixe o instalador oficial e informe -WebView2Bootstrapper."
}

$compilerCandidates = @()
if ($InnoSetupPath) { $compilerCandidates += $InnoSetupPath }
if ($env:ProgramFiles) { $compilerCandidates += (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe') }
if (${env:ProgramFiles(x86)}) { $compilerCandidates += (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe') }
$compiler = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compiler) { throw 'Inno Setup 6 não encontrado. Instale-o no computador de build ou informe -InnoSetupPath.' }

$stage = Join-Path ([IO.Path]::GetTempPath()) ('lineboard-installer-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stage -Force
try {
    Copy-Item -Path (Join-Path $bundle '*') -Destination $stage -Recurse -Force
    Copy-Item -LiteralPath $WebView2Bootstrapper -Destination (Join-Path $stage 'MicrosoftEdgeWebView2Setup.exe') -Force

    if ($ConfigFile) {
        if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "ConfigFile não encontrado: $ConfigFile" }
        $null = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
        Copy-Item -LiteralPath $ConfigFile -Destination (Join-Path $stage 'config.json') -Force
    } else {
        $configuredServer = if ($Server) { $Server.Trim() } else { '' }
        $config = [ordered]@{}
        if ($configuredServer) { $config['LINEBOARD_SIC_SERVER'] = $configuredServer }
        $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'config.json') -Encoding UTF8
    }

    $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    $iss = Join-Path $desktopRoot 'installer\Lineboard.iss'
    & $compiler "/DAppVersion=$Version" "/DStageRoot=$stage" "/DOutputDir=$OutputDirectory" $iss
    if ($LASTEXITCODE -ne 0) { throw 'O Inno Setup não conseguiu compilar o instalador.' }
    Write-Output (Join-Path $OutputDirectory 'Lineboard-Setup.exe')
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
