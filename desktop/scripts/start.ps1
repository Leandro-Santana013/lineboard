param(
    [string]$HostAddress,
    [int]$Port = 47831,
    [string]$Server,
    [string]$Database,
    [switch]$Lab
)
$ErrorActionPreference = 'Stop'
$Database = if ($Database) { $Database } elseif ($Lab) { 'LINEBOARD_LAB' } else { 'SICNET' }
$Server = if ($Server) { $Server } elseif ([Environment]::GetEnvironmentVariable('LINEBOARD_SIC_SERVER')) { [Environment]::GetEnvironmentVariable('LINEBOARD_SIC_SERVER') } else { '(localdb)\MSSQLLocalDB' }
if ($Lab -and $Database -ne 'LINEBOARD_LAB') { throw 'Lab only accepts -Database LINEBOARD_LAB.' }
$production = -not $Lab
$desktopRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$executable = Join-Path $desktopRoot 'bin\Lineboard.exe'
$uiIndex = Join-Path $desktopRoot 'bin\ui\index.html'
if (-not (Test-Path -LiteralPath $uiIndex)) { & (Join-Path $PSScriptRoot 'build.ps1') }
if (-not (Test-Path -LiteralPath $executable)) {
    & (Join-Path $PSScriptRoot 'build.ps1')
}
if (-not $HostAddress) {
    $candidate = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    $HostAddress = if ($candidate) { $candidate.IPv4Address.IPAddress | Select-Object -First 1 } else { 'localhost' }
}
$arguments = @('--server', $Server, '--database', $Database, '--host', $HostAddress, '--port', $Port)
if ($production) {
    $arguments += @('--production', '--confirm-production')
}
# Interactive desktop requested by the user; no background service or firewall changes.
Start-Process -FilePath $executable -ArgumentList $arguments -WorkingDirectory $desktopRoot -WindowStyle Normal
