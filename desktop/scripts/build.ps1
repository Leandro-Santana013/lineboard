$ErrorActionPreference = 'Stop'
$desktopRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework 4.8 compiler not found.' }
$output = Join-Path $desktopRoot 'bin'
$null = New-Item -ItemType Directory -Path $output -Force
if (-not (Test-Path -LiteralPath (Join-Path $output 'ui\index.html'))) {
    throw 'Frontend assets are missing from desktop/bin/ui. Run npm run build in desktop/frontend before building the GUI.'
}
$packageRoot = & (Join-Path $PSScriptRoot 'ensure-webview2.ps1') -OutputDirectory $output | Select-Object -Last 1
$coreAssembly = Join-Path $packageRoot 'lib\net462\Microsoft.Web.WebView2.Core.dll'
$winFormsAssembly = Join-Path $packageRoot 'lib\net462\Microsoft.Web.WebView2.WinForms.dll'
if (-not (Test-Path -LiteralPath $coreAssembly) -or -not (Test-Path -LiteralPath $winFormsAssembly)) { throw 'WebView2 net462 assemblies were not prepared.' }
$sources = @(Get-ChildItem -LiteralPath (Join-Path $desktopRoot 'src') -Filter '*.cs' | ForEach-Object FullName)
$target = 'winexe'
$fileName = 'Lineboard.exe'
$arguments = @('/nologo','/utf8output','/optimize+','/platform:x64',"/target:$target",('/out:' + (Join-Path $output $fileName)),'/reference:System.Data.dll','/reference:System.Web.Extensions.dll','/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Security.dll',('/reference:' + $coreAssembly),('/reference:' + $winFormsAssembly)) + $sources
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'Compilation failed.' }
Copy-Item -LiteralPath (Join-Path $desktopRoot 'schema.sql') -Destination (Join-Path $output 'schema.sql') -Force
Write-Output (Join-Path $output $fileName)
