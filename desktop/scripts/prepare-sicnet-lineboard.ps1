param(
    [string]$Server = '(localdb)\MSSQLLocalDB',
    [ValidatePattern('^LINEBOARD_LAB(_[A-Za-z0-9]+)?$')]
    [string]$SourceDatabase = 'LINEBOARD_LAB',
    [ValidateSet('SICNET')]
    [string]$TargetDatabase = 'SICNET',
    [switch]$ConfirmProduction
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmProduction) { throw 'This writes the Lineboard metadata schema to SICNET. Re-run with -ConfirmProduction.' }
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function New-DbConnection([string]$database) {
    $connection = New-Object System.Data.SqlClient.SqlConnection "Data Source=$Server;Initial Catalog=$database;Integrated Security=SSPI;Connect Timeout=15;Application Name=Lineboard SIC Metadata Provisioning"
    $connection.Open()
    return $connection
}
function Read-Scalar([System.Data.SqlClient.SqlConnection]$connection, [string]$sql) {
    $command = $connection.CreateCommand(); $command.CommandTimeout = 60; $command.CommandText = $sql
    try { $value = $command.ExecuteScalar(); if ($value -is [System.DBNull]) { return $null }; return $value } finally { $command.Dispose() }
}
function Read-Table([System.Data.SqlClient.SqlConnection]$connection, [string]$sql) {
    $command = $connection.CreateCommand(); $command.CommandTimeout = 60; $command.CommandText = $sql
    $data = New-Object System.Data.DataTable; $reader = $command.ExecuteReader()
    try { $data.Load($reader) } finally { $reader.Dispose(); $command.Dispose() }
    return ,$data
}
function Copy-Rows([System.Data.SqlClient.SqlConnection]$connection, [System.Data.SqlClient.SqlTransaction]$transaction, [string]$destination, [System.Data.DataTable]$rows) {
    if ($rows.Rows.Count -eq 0) { return }
    $options = [System.Data.SqlClient.SqlBulkCopyOptions]::KeepIdentity -bor [System.Data.SqlClient.SqlBulkCopyOptions]::CheckConstraints
    $copy = New-Object System.Data.SqlClient.SqlBulkCopy($connection, $options, $transaction)
    $copy.DestinationTableName = $destination; $copy.BatchSize = 500
    foreach ($column in $rows.Columns) { $null = $copy.ColumnMappings.Add($column.ColumnName, $column.ColumnName) }
    try { $copy.WriteToServer($rows) } finally { $copy.Close() }
}

$source = $null; $target = $null; $master = $null; $transaction = $null
try {
    $source = New-DbConnection $SourceDatabase
    $target = New-DbConnection $TargetDatabase
    $sourceUnits = Read-Table $source 'SELECT * FROM lineboard.Units ORDER BY barcode'
    $sourceInitial = Read-Table $source "SELECT * FROM lineboard.Movements WHERE reason='initial' ORDER BY id"
    $targetProducts = Read-Table $target 'SELECT controle,codigo FROM dbo.TABEST1 ORDER BY controle'
    $targetReceipts = [int](Read-Scalar $target 'SELECT COUNT(*) FROM dbo.TABEST2A')
    $sourceReceipts = [int](Read-Scalar $source 'SELECT COUNT(*) FROM dbo.TABEST2A')
    if ($sourceUnits.Rows.Count -eq 0) { throw 'The source laboratory has no units.' }
    if ($targetProducts.Rows.Count -ne $sourceUnits.Rows.Count) { throw "Target product count ($($targetProducts.Rows.Count)) differs from source units ($($sourceUnits.Rows.Count))." }
    if ($targetReceipts -ne $sourceReceipts) { throw "Target receipt count ($targetReceipts) differs from source ($sourceReceipts)." }
    if ($null -ne (Read-Scalar $target "SELECT SCHEMA_ID('lineboard')")) { throw 'The target already has the lineboard schema. Nothing was changed.' }
    for ($index = 0; $index -lt $sourceUnits.Rows.Count; $index++) {
        if ([string]$targetProducts.Rows[$index]['codigo'] -ne [string]$sourceUnits.Rows[$index]['barcode']) { throw "Barcode mismatch at row $index. Nothing was changed." }
    }

    $master = New-DbConnection 'master'
    $targetDataFile = [string](Read-Scalar $master "SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID('$($TargetDatabase.Replace("'", "''"))') AND type_desc='ROWS'")
    $backupPath = Join-Path (Split-Path -Parent $targetDataFile) ('LINEBOARD_PREPARE_' + $stamp + '.bak')
    $backup = $master.CreateCommand(); $backup.CommandTimeout = 180; $backup.CommandText = 'BACKUP DATABASE [' + $TargetDatabase + '] TO DISK=@path WITH COPY_ONLY, CHECKSUM, INIT'; $null = $backup.Parameters.AddWithValue('@path',$backupPath); $null = $backup.ExecuteNonQuery(); $backup.Dispose()
    $localBackup = Join-Path $workspace ('.local\' + (Split-Path -Leaf $backupPath)); Copy-Item -LiteralPath $backupPath -Destination $localBackup -Force

    $transaction = $target.BeginTransaction([System.Data.IsolationLevel]::Serializable)
    $schema = $target.CreateCommand(); $schema.Transaction = $transaction; $schema.CommandTimeout = 60; $schema.CommandText = Get-Content -LiteralPath (Join-Path $workspace 'desktop\schema.sql') -Raw; $null = $schema.ExecuteNonQuery(); $schema.Dispose()
    Copy-Rows $target $transaction 'lineboard.Units' $sourceUnits
    Copy-Rows $target $transaction 'lineboard.Movements' $sourceInitial
    $maxBarcode = 0L
    foreach ($unit in $sourceUnits.Rows) { $number = [Int64](([string]$unit['barcode']).Substring(4)); if ($number -gt $maxBarcode) { $maxBarcode = $number } }
    $sequence = $target.CreateCommand(); $sequence.Transaction = $transaction; $sequence.CommandText = 'ALTER SEQUENCE lineboard.BarcodeNumber RESTART WITH ' + ($maxBarcode + 1); $null = $sequence.ExecuteNonQuery(); $sequence.Dispose()
    $transaction.Commit(); $transaction = $null

    [pscustomobject]@{
        source = $SourceDatabase; target = $TargetDatabase; mode = 'controlled_metadata_provisioning'
        lineboard_units = [int](Read-Scalar $target 'SELECT COUNT(*) FROM lineboard.Units')
        initial_movements = [int](Read-Scalar $target 'SELECT COUNT(*) FROM lineboard.Movements')
        next_barcode = $maxBarcode + 1; backup = $localBackup
        backup_sha256 = (Get-FileHash -LiteralPath $localBackup -Algorithm SHA256).Hash
        committed = $true
    } | ConvertTo-Json -Depth 3
} catch {
    if ($null -ne $transaction) { try { $transaction.Rollback() } catch {} }
    throw
} finally {
    if ($null -ne $transaction) { $transaction.Dispose() }
    if ($null -ne $target) { $target.Dispose() }
    if ($null -ne $source) { $source.Dispose() }
    if ($null -ne $master) { $master.Dispose() }
}
