param(
    [string]$Server = '(localdb)\MSSQLLocalDB',
    [ValidatePattern('^LINEBOARD_LAB(_[A-Za-z0-9]+)?$')]
    [string]$SourceDatabase = 'LINEBOARD_LAB',
    [ValidateSet('SICNET')]
    [string]$TargetDatabase = 'SICNET',
    [switch]$IncludeSales,
    [switch]$ConfirmProduction
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmProduction) {
    throw 'This writes to the SICNET database. Re-run with -ConfirmProduction after checking the source and backup plan.'
}

$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$tables = @('TABEST1', 'TABEST2A', 'TABEST2B')
if ($IncludeSales) { $tables += @('TABEST3A', 'TABEST3B', 'TABEST3R') }

function New-DbConnection([string]$database) {
    $connectionString = "Data Source=$Server;Initial Catalog=$database;Integrated Security=SSPI;Connect Timeout=15;Application Name=Lineboard Controlled SIC Import"
    $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
    $connection.Open()
    return $connection
}

function Read-Table([System.Data.SqlClient.SqlConnection]$connection, [string]$sql) {
    $command = $connection.CreateCommand()
    $command.CommandTimeout = 60
    $command.CommandText = $sql
    $data = New-Object System.Data.DataTable
    $reader = $command.ExecuteReader()
    try { $data.Load($reader) } finally { $reader.Dispose(); $command.Dispose() }
    return ,$data
}

function Read-Scalar([System.Data.SqlClient.SqlConnection]$connection, [string]$sql) {
    $command = $connection.CreateCommand()
    $command.CommandTimeout = 60
    $command.CommandText = $sql
    try {
        $value = $command.ExecuteScalar()
        if ($value -is [System.DBNull]) { return $null }
        return $value
    } finally { $command.Dispose() }
}

function Insert-Rows([System.Data.SqlClient.SqlConnection]$connection, [System.Data.SqlClient.SqlTransaction]$transaction, [string]$destination, [System.Data.DataTable]$rows) {
    if ($rows.Rows.Count -eq 0) { return }
    $options = [System.Data.SqlClient.SqlBulkCopyOptions]::KeepIdentity -bor [System.Data.SqlClient.SqlBulkCopyOptions]::CheckConstraints
    $copy = New-Object System.Data.SqlClient.SqlBulkCopy($connection, $options, $transaction)
    $copy.DestinationTableName = $destination
    $copy.BatchSize = 500
    foreach ($column in $rows.Columns) { $null = $copy.ColumnMappings.Add($column.ColumnName, $column.ColumnName) }
    try { $copy.WriteToServer($rows) } finally { $copy.Close() }
}

$master = $null
$source = $null
$target = $null
$transaction = $null
$backupPath = $null
$localBackup = $null
try {
    $master = New-DbConnection 'master'
    $sourceState = Read-Scalar $master "SELECT state_desc FROM sys.databases WHERE name='$($SourceDatabase.Replace("'", "''"))'"
    $targetState = Read-Scalar $master "SELECT state_desc FROM sys.databases WHERE name='$($TargetDatabase.Replace("'", "''"))'"
    if ($sourceState -ne 'ONLINE' -or $targetState -ne 'ONLINE') { throw 'Both source and target databases must be ONLINE.' }

    $target = New-DbConnection $TargetDatabase
    $existingProducts = [int](Read-Scalar $target 'SELECT COUNT(*) FROM dbo.TABEST1')
    $existingReceipts = [int](Read-Scalar $target 'SELECT COUNT(*) FROM dbo.TABEST2A')
    $existingSales = [int](Read-Scalar $target 'SELECT COUNT(*) FROM dbo.TABEST3A')
    $lineboardSchema = Read-Scalar $target "SELECT SCHEMA_ID('lineboard')"
    if ($existingProducts -ne 0 -or $existingReceipts -ne 0 -or $existingSales -ne 0 -or $null -ne $lineboardSchema) {
        throw "Target is not empty or was already prepared (products=$existingProducts, receipts=$existingReceipts, sales=$existingSales, lineboard_schema=$lineboardSchema). Nothing was changed."
    }

    $source = New-DbConnection $SourceDatabase
    $sourceTables = @{}
    foreach ($table in $tables) { $sourceTables[$table] = Read-Table $source ('SELECT * FROM dbo.' + $table + ' ORDER BY controle') }
    if ($sourceTables['TABEST1'].Rows.Count -eq 0) { throw 'The source laboratory has no products. Nothing was changed.' }
    $sourceUnits = Read-Table $source 'SELECT * FROM lineboard.Units ORDER BY barcode'
    $sourceMovements = Read-Table $source "SELECT * FROM lineboard.Movements WHERE reason='initial' ORDER BY id"
    if ($sourceUnits.Rows.Count -ne $sourceTables['TABEST1'].Rows.Count) { throw 'Source product and Lineboard unit counts differ. Nothing was changed.' }

    $targetDataFile = [string](Read-Scalar $master "SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID('$($TargetDatabase.Replace("'", "''"))') AND type_desc='ROWS'")
    $targetFolder = Split-Path -Parent $targetDataFile
    $backupPath = Join-Path $targetFolder ('LINEBOARD_PREIMPORT_' + $stamp + '.bak')
    $backupCommand = $master.CreateCommand()
    $backupCommand.CommandTimeout = 180
    $backupCommand.CommandText = 'BACKUP DATABASE [' + $TargetDatabase + '] TO DISK=@path WITH COPY_ONLY, CHECKSUM, INIT'
    $null = $backupCommand.Parameters.AddWithValue('@path', $backupPath)
    $null = $backupCommand.ExecuteNonQuery()
    $backupCommand.Dispose()
    $localBackup = Join-Path $workspace ('.local\' + (Split-Path -Leaf $backupPath))
    Copy-Item -LiteralPath $backupPath -Destination $localBackup -Force

    $transaction = $target.BeginTransaction([System.Data.IsolationLevel]::Serializable)
    $schemaCommand = $target.CreateCommand()
    $schemaCommand.Transaction = $transaction
    $schemaCommand.CommandTimeout = 60
    $schemaCommand.CommandText = Get-Content -LiteralPath (Join-Path $workspace 'desktop\schema.sql') -Raw
    $null = $schemaCommand.ExecuteNonQuery()
    $schemaCommand.Dispose()
    foreach ($table in $tables) {
        Insert-Rows $target $transaction ('dbo.' + $table) $sourceTables[$table]
    }
    Insert-Rows $target $transaction 'lineboard.Units' $sourceUnits
    Insert-Rows $target $transaction 'lineboard.Movements' $sourceMovements
    $maxBarcode = 0L
    foreach ($unit in $sourceUnits.Rows) {
        $number = [Int64](([string]$unit['barcode']).Substring(4))
        if ($number -gt $maxBarcode) { $maxBarcode = $number }
    }
    $sequenceCommand = $target.CreateCommand()
    $sequenceCommand.Transaction = $transaction
    $sequenceCommand.CommandText = 'ALTER SEQUENCE lineboard.BarcodeNumber RESTART WITH ' + ($maxBarcode + 1)
    $null = $sequenceCommand.ExecuteNonQuery()
    $sequenceCommand.Dispose()
    $transaction.Commit()
    $transaction = $null

    $counts = [ordered]@{}
    foreach ($table in $tables) { $counts[$table] = [int](Read-Scalar $target ('SELECT COUNT(*) FROM dbo.' + $table)) }
    $counts['lineboard.Units'] = [int](Read-Scalar $target 'SELECT COUNT(*) FROM lineboard.Units')
    $counts['lineboard.Movements'] = [int](Read-Scalar $target 'SELECT COUNT(*) FROM lineboard.Movements')
    [pscustomobject]@{
        source = $SourceDatabase
        target = $TargetDatabase
        mode = 'controlled_product_import'
        products = $counts.TABEST1
        receipts = $counts.TABEST2A
        receipt_lines = $counts.TABEST2B
        lineboard_units = $counts['lineboard.Units']
        initial_movements = $counts['lineboard.Movements']
        sales = if ($IncludeSales) { $counts.TABEST3A } else { 0 }
        sales_imported = [bool]$IncludeSales
        backup = $localBackup
        backup_sha256 = (Get-FileHash -LiteralPath $localBackup -Algorithm SHA256).Hash
        source_unchanged = $true
        committed = $true
    } | ConvertTo-Json -Depth 4
} catch {
    if ($null -ne $transaction) { try { $transaction.Rollback() } catch {} }
    throw
} finally {
    if ($null -ne $transaction) { $transaction.Dispose() }
    if ($null -ne $target) { $target.Dispose() }
    if ($null -ne $source) { $source.Dispose() }
    if ($null -ne $master) { $master.Dispose() }
}
