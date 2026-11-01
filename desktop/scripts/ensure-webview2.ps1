param(
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$desktopRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspace = [IO.Path]::GetFullPath((Join-Path $desktopRoot '..'))
$version = '1.0.4314.35'
$sha256 = '90778DEB1B77E36292828B4B5833C9255C27533F40E0DDD55891AE718944EDC4'
$cache = Join-Path $workspace '.local\webview2'
$nupkg = Join-Path $cache ("Microsoft.Web.WebView2.{0}.nupkg" -f $version)
$packageRoot = Join-Path $cache ("package-{0}" -f $version)
$null = New-Item -ItemType Directory -Path $cache -Force
if (-not (Test-Path -LiteralPath $nupkg)) {
    Invoke-WebRequest -UseBasicParsing -Uri ("https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/{0}/microsoft.web.webview2.{0}.nupkg" -f $version) -OutFile $nupkg
}
$actual = (Get-FileHash -LiteralPath $nupkg -Algorithm SHA256).Hash.ToUpperInvariant()
if ($actual -ne $sha256) { throw "WebView2 NuGet checksum mismatch. Expected $sha256, got $actual." }
$core = Join-Path $packageRoot 'lib\net462\Microsoft.Web.WebView2.Core.dll'
$winforms = Join-Path $packageRoot 'lib\net462\Microsoft.Web.WebView2.WinForms.dll'
$loader = Join-Path $packageRoot 'runtimes\win-x64\native\WebView2Loader.dll'
if (-not (Test-Path -LiteralPath $core) -or -not (Test-Path -LiteralPath $winforms) -or -not (Test-Path -LiteralPath $loader)) {
    if (Test-Path -LiteralPath $packageRoot) {
        $cacheFull = [IO.Path]::GetFullPath($cache)
        $cachePrefix = $cacheFull.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $packageFull = [IO.Path]::GetFullPath($packageRoot)
        $packageResolved = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $packageFull).Path)
        if ($packageFull.Equals($cacheFull, [StringComparison]::OrdinalIgnoreCase) -or -not $packageFull.StartsWith($cachePrefix, [StringComparison]::OrdinalIgnoreCase) -or $packageResolved.Equals($cacheFull, [StringComparison]::OrdinalIgnoreCase) -or -not $packageResolved.StartsWith($cachePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove a WebView2 path outside .local/webview2.' }
        Remove-Item -LiteralPath $packageFull -Recurse -Force
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $packageRoot)
}
if (-not (Test-Path -LiteralPath $core) -or -not (Test-Path -LiteralPath $winforms) -or -not (Test-Path -LiteralPath $loader)) { throw 'The pinned WebView2 package is missing net462 or x64 assets.' }
if ($OutputDirectory) {
    $out = [IO.Path]::GetFullPath($OutputDirectory)
    $null = New-Item -ItemType Directory -Path $out -Force
    Copy-Item -LiteralPath $core -Destination (Join-Path $out 'Microsoft.Web.WebView2.Core.dll') -Force
    Copy-Item -LiteralPath $winforms -Destination (Join-Path $out 'Microsoft.Web.WebView2.WinForms.dll') -Force
    Copy-Item -LiteralPath $loader -Destination (Join-Path $out 'WebView2Loader.dll') -Force
}
Write-Output $packageRoot
