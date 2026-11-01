param(
    [switch]$WithWebView2
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$frontend = Join-Path $workspace 'desktop\frontend'
if (-not (Test-Path -LiteralPath (Join-Path $frontend 'package.json'))) { throw 'desktop/frontend/package.json not found.' }
Push-Location $frontend
try {
    npm test
    if ($LASTEXITCODE -ne 0) { throw 'React frontend tests failed.' }
} finally { Pop-Location }
if ($WithWebView2) {
    & (Join-Path $PSScriptRoot 'test-web.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Real WebView2 bridge verification failed.' }
}
# The previous WinForms checks remain available as test-legacy-ui.ps1.
