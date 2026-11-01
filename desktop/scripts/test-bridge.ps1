param([string]$Server = '(localdb)\MSSQLLocalDB')
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$desktopRoot = Join-Path $workspace 'desktop'
$database = 'LINEBOARD_LAB_BRIDGE' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$output = Join-Path $workspace '.local\bridge-verification'
$null = New-Item -ItemType Directory -Path $output -Force
$packageRoot = & (Join-Path $PSScriptRoot 'ensure-webview2.ps1') | Select-Object -Last 1
$coreAssembly = Join-Path $packageRoot 'lib\net462\Microsoft.Web.WebView2.Core.dll'
$winFormsAssembly = Join-Path $packageRoot 'lib\net462\Microsoft.Web.WebView2.WinForms.dll'
$sources = @(Get-ChildItem -LiteralPath (Join-Path $desktopRoot 'src') -Filter '*.cs' | ForEach-Object FullName)
$testExecutable = Join-Path $output 'Lineboard.BridgeTests.exe'
& $compiler /nologo /utf8output /optimize+ /platform:x64 /target:exe /main:Lineboard.BridgeTests ("/out:$testExecutable") /reference:System.Data.dll /reference:System.Web.Extensions.dll /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Security.dll ("/reference:$coreAssembly") ("/reference:$winFormsAssembly") @sources (Join-Path $desktopRoot 'tests\BridgeTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Bridge test compilation failed.' }
Copy-Item -LiteralPath (Join-Path $desktopRoot 'schema.sql') -Destination (Join-Path $output 'schema.sql') -Force
& (Join-Path $PSScriptRoot 'New-SicSandbox.ps1') -Server $Server -Database $database -Empty
& $testExecutable $workspace $database
if ($LASTEXITCODE -ne 0) { throw 'Desktop bridge tests failed.' }
# Keep the dedicated sandbox and output as evidence. This script never drops a database.
