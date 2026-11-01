param(
    [string]$HostAddress,
    [int]$Port = 47831,
    [string]$Database,
    [switch]$Production,
    [switch]$ConfirmProduction,
    [switch]$Lab
)
$ErrorActionPreference = 'Stop'
if ($Lab -and $Production) { throw 'Choose either -Lab or -Production, not both.' }
$implicitProduction = -not $Lab -and -not $Production
if ($implicitProduction) { $Production = $true; $ConfirmProduction = $true }
$Database = if ($Database) { $Database } elseif ($Production) { 'SICNET' } else { 'LINEBOARD_LAB' }
if ($Production -and $Database -ne 'SICNET') { throw 'Production only accepts -Database SICNET.' }
if ($Lab -and $Database -ne 'LINEBOARD_LAB') { throw 'Lab only accepts -Database LINEBOARD_LAB.' }
$desktopRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$executable = if ($Production) { Join-Path $desktopRoot 'bin\Lineboard.production.exe' } else { Join-Path $desktopRoot 'bin\Lineboard.exe' }
$uiIndex = Join-Path $desktopRoot 'bin\ui\index.html'
if (-not (Test-Path -LiteralPath $uiIndex)) { & (Join-Path $PSScriptRoot 'build.ps1') }
if (-not (Test-Path -LiteralPath $executable)) {
    if ($Production) { throw 'Production executable is missing. Compile desktop/bin/Lineboard.production.exe first.' }
    & (Join-Path $PSScriptRoot 'build.ps1')
}
if (-not $HostAddress) {
    $candidate = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    $HostAddress = if ($candidate) { $candidate.IPv4Address.IPAddress | Select-Object -First 1 } else { 'localhost' }
}
$arguments = @('--database', $Database, '--host', $HostAddress, '--port', $Port)
if ($Production) {
    if (-not $ConfirmProduction) { throw 'Production requires -ConfirmProduction.' }
    $arguments += @('--production', '--confirm-production')
}
# Interactive desktop requested by the user; no background service or firewall changes.
Start-Process -FilePath $executable -ArgumentList $arguments -WorkingDirectory $desktopRoot -WindowStyle Normal
