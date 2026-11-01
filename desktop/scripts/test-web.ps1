param([string]$Server = '(localdb)\MSSQLLocalDB')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$desktopRoot = Join-Path $workspace 'desktop'
if (-not (Test-Path -LiteralPath (Join-Path $desktopRoot 'bin\ui\index.html'))) {
    throw 'Frontend assets are missing from desktop/bin/ui. Run npm run build in desktop/frontend first.'
}
& (Join-Path $PSScriptRoot 'build.ps1') -Console
$database = 'LINEBOARD_LAB_WEB' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
& (Join-Path $PSScriptRoot 'New-SicSandbox.ps1') -Server $Server -Database $database -Empty
$output = Join-Path $workspace '.local\desktop-web-self-test.png'
$evidenceJson = Join-Path $workspace '.local\desktop-web-self-test.json'
$executable = Join-Path $desktopRoot 'bin\Lineboard.Cli.exe'
$result = & $executable --workspace $workspace --server $Server --database $database --web-self-test --output $output
$exitCode = $LASTEXITCODE
$result | Set-Content -LiteralPath $evidenceJson -Encoding UTF8
$result
if ($exitCode -ne 0) { throw 'Real WebView2 bridge self-test failed.' }
# Keep the dedicated sandbox, JSON result, and CapturePreviewAsync PNG as evidence.
