param(
    [switch]$PrepareOnly,
    [string]$NodePath
)
$ErrorActionPreference = 'Stop'
$desktopRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspace = [IO.Path]::GetFullPath((Join-Path $desktopRoot '..'))
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw '.NET Framework 4.8 compiler not found.' }
$output = Join-Path $desktopRoot 'bin'

function Assert-WorkspacePath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $workspace.TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Build path must stay inside the workspace.' }
    $parent = $full
    while ($parent -and $parent.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        if (Test-Path -LiteralPath $parent) {
            $entry = Get-Item -LiteralPath $parent -Force
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Build paths must not follow junctions or symbolic links.' }
        }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
    return $full
}
function Assert-DesktopClosed {
    $installedPrefix = $output.TrimEnd('\') + '\'
    foreach ($process in @(Get-Process -Name Lineboard -ErrorAction SilentlyContinue)) {
        if (-not $process.Path -or $process.Path.StartsWith($installedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'O Lineboard esta aberto. Salve suas alteracoes e feche-o antes de instalar o build. Use -PrepareOnly para apenas preparar uma copia completa.'
        }
    }
}
if (-not $PrepareOnly) { Assert-DesktopClosed }
$null = Assert-WorkspacePath $output
$buildRoot = Assert-WorkspacePath (Join-Path $workspace ('.local\desktop-build\' + [Guid]::NewGuid().ToString('N')))
$bundle = Assert-WorkspacePath (Join-Path $buildRoot 'bundle')
$null = New-Item -ItemType Directory -Path $bundle -Force
$frontend = Join-Path $desktopRoot 'frontend'
$vite = Join-Path $frontend 'node_modules\vite\bin\vite.js'
if (-not (Test-Path -LiteralPath $vite)) { throw 'Frontend dependencies are missing. Run npm ci in desktop/frontend first.' }
if (-not $NodePath) { $NodePath = (Get-Command node.exe -ErrorAction Stop).Source }

Push-Location $frontend
try {
    & $NodePath $vite build --outDir (Join-Path $bundle 'ui')
    if ($LASTEXITCODE -ne 0) { throw 'Frontend compilation failed. The installed bundle was not changed.' }
} finally { Pop-Location }
$packageRoot = & (Join-Path $PSScriptRoot 'ensure-webview2.ps1') -OutputDirectory $bundle | Select-Object -Last 1
$coreAssembly = Join-Path $packageRoot 'lib\net462\Microsoft.Web.WebView2.Core.dll'
$winFormsAssembly = Join-Path $packageRoot 'lib\net462\Microsoft.Web.WebView2.WinForms.dll'
$sources = @(Get-ChildItem -LiteralPath (Join-Path $desktopRoot 'src') -Filter '*.cs' | ForEach-Object FullName)
$executable = Join-Path $bundle 'Lineboard.exe'
$arguments = @('/nologo','/utf8output','/optimize+','/platform:x64','/target:winexe',('/out:' + $executable),'/reference:System.Data.dll','/reference:System.Web.Extensions.dll','/reference:System.Windows.Forms.dll','/reference:System.Drawing.dll','/reference:System.Security.dll',('/reference:' + $coreAssembly),('/reference:' + $winFormsAssembly)) + $sources
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw 'Native compilation failed. The installed bundle was not changed.' }
Copy-Item -LiteralPath (Join-Path $desktopRoot 'schema.sql') -Destination (Join-Path $bundle 'schema.sql') -Force

# A separate process releases assembly file handles before installation.
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test-photo-upload.ps1') -AssemblyPath $executable
if ($LASTEXITCODE -ne 0) { throw 'Product photo bridge verification failed. The installed bundle was not changed.' }
if ($PrepareOnly) { Write-Output $executable; return }

# Publish both layers together; preserve the entire previous installation for rollback.
Assert-DesktopClosed
$previous = Assert-WorkspacePath (Join-Path $buildRoot 'previous')
$null = Assert-WorkspacePath $output
$null = Assert-WorkspacePath $bundle
$hadPrevious = Test-Path -LiteralPath $output
if ($hadPrevious) { Move-Item -LiteralPath $output -Destination $previous }
try { Move-Item -LiteralPath $bundle -Destination $output }
catch {
    if ($hadPrevious -and -not (Test-Path -LiteralPath $output)) { Move-Item -LiteralPath $previous -Destination $output }
    throw
}
if ($hadPrevious) { Write-Host ('Previous bundle preserved at ' + $previous) }
Write-Output (Join-Path $output 'Lineboard.exe')
