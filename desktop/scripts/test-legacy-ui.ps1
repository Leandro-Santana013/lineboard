param([string]$Database = ('LINEBOARD_LAB_UITEST' + [Guid]::NewGuid().ToString('N').Substring(0, 10)))
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$desktopRoot = Join-Path $workspace 'desktop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$testOutput = Join-Path $workspace '.local\ui-verification'
$null = New-Item -ItemType Directory -Path $testOutput -Force
$packageRoot = & (Join-Path $PSScriptRoot 'ensure-webview2.ps1') | Select-Object -Last 1
$coreAssembly = Join-Path $packageRoot 'lib\net462\Microsoft.Web.WebView2.Core.dll'
$winFormsAssembly = Join-Path $packageRoot 'lib\net462\Microsoft.Web.WebView2.WinForms.dll'
$sources = @(Get-ChildItem -LiteralPath (Join-Path $desktopRoot 'src') -Filter '*.cs' | ForEach-Object FullName)
$testExecutable = Join-Path $testOutput 'Lineboard.UiTests.exe'
& $compiler /nologo /utf8output /platform:x64 /target:exe /main:Lineboard.DesktopUiTests "/out:$testExecutable" /reference:System.Data.dll /reference:System.Web.Extensions.dll /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Security.dll ("/reference:$coreAssembly") ("/reference:$winFormsAssembly") @sources (Join-Path $desktopRoot 'tests\DesktopUiTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Legacy WinForms test compilation failed.' }
Copy-Item -LiteralPath (Join-Path $desktopRoot 'schema.sql') -Destination (Join-Path $testOutput 'schema.sql') -Force
& (Join-Path $PSScriptRoot 'New-SicSandbox.ps1') -Database $Database -Empty
& $testExecutable $workspace $Database
if ($LASTEXITCODE -ne 0) { throw 'Legacy WinForms verification failed.' }
# Historical fallback UI evidence; the standard migration uses test-web.ps1.
