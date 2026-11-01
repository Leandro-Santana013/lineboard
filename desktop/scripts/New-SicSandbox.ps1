param(
    [string]$Server = '(localdb)\MSSQLLocalDB',
    [string]$SourceDatabase = 'SICNET',
    [ValidatePattern('^LINEBOARD_LAB(_[A-Za-z0-9]+)?$')]
    [string]$Database = 'LINEBOARD_LAB',
    [switch]$Empty
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$labRoot = Join-Path $workspace '.local\sic-lab'
$null = New-Item -ItemType Directory -Path $labRoot -Force
$databaseFolder = Join-Path $labRoot $Database
$null = New-Item -ItemType Directory -Path $databaseFolder -Force
$resolvedFolder = [IO.Path]::GetFullPath($databaseFolder)
if (-not $resolvedFolder.StartsWith($labRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid sandbox directory.' }
$connection = New-Object System.Data.SqlClient.SqlConnection "Data Source=$Server;Initial Catalog=master;Integrated Security=SSPI;Connect Timeout=10;Application Name=Lineboard Sandbox"
function Read-Query([string]$Sql, [hashtable]$Parameters = @{}) {
    $command = $connection.CreateCommand()
    $command.CommandTimeout = 60
    $command.CommandText = $Sql
    foreach ($key in $Parameters.Keys) { $null = $command.Parameters.AddWithValue($key, $Parameters[$key]) }
    $data = New-Object System.Data.DataTable
    $reader = $command.ExecuteReader()
    try { $data.Load($reader) } finally { $reader.Dispose(); $command.Dispose() }
    return ,$data
}
try {
    $connection.Open()
    $existing = Read-Query 'SELECT name FROM sys.databases WHERE name=@name' @{ '@name' = $Database }
    if ($existing.Rows.Count) { throw "Database $Database already exists. Nothing was overwritten. Use another lab name or open the existing lab." }
    $source = Read-Query 'SELECT name FROM sys.databases WHERE name=@name AND state=0' @{ '@name' = $SourceDatabase }
    if (-not $source.Rows.Count) { throw 'Source database is not online.' }
    $backupPath = Join-Path $resolvedFolder 'source-copy-only.bak'
    if (Test-Path -LiteralPath $backupPath) { throw 'Backup already exists. Nothing was overwritten.' }
    $sourceIdentifier = '[' + $SourceDatabase.Replace(']', ']]') + ']'
    $targetIdentifier = '[' + $Database.Replace(']', ']]') + ']'
    $null = Read-Query "BACKUP DATABASE $sourceIdentifier TO DISK=@path WITH COPY_ONLY, CHECKSUM" @{ '@path' = $backupPath }
    $files = Read-Query 'RESTORE FILELISTONLY FROM DISK=@path' @{ '@path' = $backupPath }
    if ($files.Rows.Count -ne 2) { throw 'This prototype expects one data file and one log file. Backup retained.' }
    $dataFile = @($files.Rows | Where-Object Type -eq 'D')[0]
    $logFile = @($files.Rows | Where-Object Type -eq 'L')[0]
    $mdfPath = Join-Path $resolvedFolder 'Lineboard.mdf'
    $ldfPath = Join-Path $resolvedFolder 'Lineboard_log.ldf'
    $null = Read-Query "RESTORE DATABASE $targetIdentifier FROM DISK=@backup WITH MOVE @dataName TO @dataPath, MOVE @logName TO @logPath, RECOVERY, CHECKSUM" @{
        '@backup'=$backupPath; '@dataName'=$dataFile.LogicalName; '@dataPath'=$mdfPath; '@logName'=$logFile.LogicalName; '@logPath'=$ldfPath
    }
    $connection.ChangeDatabase($Database)
    $null = Read-Query "CREATE TABLE dbo.LineboardSandboxMarker (id int PRIMARY KEY CHECK(id=1), source_database nvarchar(128) NOT NULL, instance_id uniqueidentifier NOT NULL, created_at datetime2 NOT NULL DEFAULT SYSUTCDATETIME()); INSERT dbo.LineboardSandboxMarker(id,source_database,instance_id) VALUES (1,@source,NEWID())" @{ '@source'=$SourceDatabase }
    if ($Empty) {
        foreach ($statement in @(
            'DELETE FROM lineboard.Cart',
            'DELETE FROM lineboard.Sales',
            'DELETE FROM lineboard.UnitEdits',
            'DELETE FROM lineboard.Movements',
            'DELETE FROM lineboard.Outbox',
            'DELETE FROM lineboard.Operations',
            'DELETE FROM lineboard.Units',
            'DELETE FROM dbo.TABEST3R',
            'DELETE FROM dbo.TABEST3B',
            'DELETE FROM dbo.TABEST3A',
            'DELETE FROM dbo.TABEST2B',
            'DELETE FROM dbo.TABEST2A',
            'DELETE FROM dbo.TABINV',
            'DELETE FROM dbo.TABEST1',
            'DBCC CHECKIDENT (''dbo.TABEST1'', RESEED, 0) WITH NO_INFOMSGS',
            'DBCC CHECKIDENT (''dbo.TABEST2A'', RESEED, 0) WITH NO_INFOMSGS',
            'DBCC CHECKIDENT (''dbo.TABEST2B'', RESEED, 0) WITH NO_INFOMSGS',
            'DBCC CHECKIDENT (''dbo.TABEST3A'', RESEED, 0) WITH NO_INFOMSGS',
            'DBCC CHECKIDENT (''dbo.TABEST3B'', RESEED, 0) WITH NO_INFOMSGS',
            'DBCC CHECKIDENT (''dbo.TABEST3R'', RESEED, 0) WITH NO_INFOMSGS',
            'ALTER SEQUENCE lineboard.BarcodeNumber RESTART WITH 900000000001'
        )) { $null = Read-Query $statement }
    }
    [pscustomobject]@{ database=$Database; server=$Server; data_file=$mdfPath; source_unchanged=$true; mode='sandbox'; empty=[bool]$Empty; backup=$backupPath } | ConvertTo-Json
} finally { $connection.Dispose() }
