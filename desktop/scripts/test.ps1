param([string]$Server = '(localdb)\MSSQLLocalDB')
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'build.ps1')
$database = 'LINEBOARD_LAB_TEST' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
& (Join-Path $PSScriptRoot 'New-SicSandbox.ps1') -Server $Server -Database $database -Empty
$executable = Join-Path $PSScriptRoot '..\bin\Lineboard.exe'
$process = Start-Process -FilePath $executable -ArgumentList @('--server', $Server, '--database', $database, '--self-test') -Wait -PassThru -WindowStyle Hidden
if ($process.ExitCode -ne 0) { throw 'SIC connector tests failed.' }
# Keep the database and COPY_ONLY backup as evidence; this script never drops a database.
