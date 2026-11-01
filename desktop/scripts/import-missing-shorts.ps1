param(
    [string]$Server = '(localdb)\MSSQLLocalDB',
    [ValidatePattern('^LINEBOARD_LAB(_[A-Za-z0-9]+)?$')]
    [string]$SourceDatabase = 'LINEBOARD_LAB',
    [ValidateSet('SICNET')]
    [string]$TargetDatabase = 'SICNET',
    [switch]$ConfirmProduction
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmProduction) { throw 'This writes missing shorts to SICNET. Re-run with -ConfirmProduction.' }
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function New-DbConnection([string]$database) {
    $connection = New-Object System.Data.SqlClient.SqlConnection "Data Source=$Server;Initial Catalog=$database;Integrated Security=SSPI;Connect Timeout=15;Application Name=Lineboard Short Import"
    $connection.Open()
    return $connection
}
function Read-Table([System.Data.SqlClient.SqlConnection]$connection,[string]$sql) {
    $command=$connection.CreateCommand();$command.CommandTimeout=60;$command.CommandText=$sql
    $table=New-Object System.Data.DataTable;$reader=$command.ExecuteReader()
    try{$table.Load($reader)}finally{$reader.Dispose();$command.Dispose()}
    return ,$table
}
function Read-Scalar([System.Data.SqlClient.SqlConnection]$connection,[string]$sql) {
    $command=$connection.CreateCommand();$command.CommandTimeout=60;$command.CommandText=$sql
    try{$value=$command.ExecuteScalar();if($value -is [System.DBNull]){return $null};return $value}finally{$command.Dispose()}
}
function Insert-Rows([System.Data.SqlClient.SqlConnection]$connection,[System.Data.SqlClient.SqlTransaction]$transaction,[string]$destination,[System.Data.DataTable]$rows) {
    if($rows.Rows.Count -eq 0){return}
    $options=[System.Data.SqlClient.SqlBulkCopyOptions]::KeepIdentity -bor [System.Data.SqlClient.SqlBulkCopyOptions]::CheckConstraints
    $copy=New-Object System.Data.SqlClient.SqlBulkCopy($connection,$options,$transaction);$copy.DestinationTableName=$destination;$copy.BatchSize=500
    foreach($column in $rows.Columns){$null=$copy.ColumnMappings.Add($column.ColumnName,$column.ColumnName)}
    try{$copy.WriteToServer($rows)}finally{$copy.Close()}
}
function Select-Rows([System.Data.DataTable]$source,[scriptblock]$predicate) {
    $result=$source.Clone();foreach($row in $source.Rows){if(& $predicate $row){$result.ImportRow($row)}};return ,$result
}

$master=$null;$source=$null;$target=$null;$transaction=$null;$localBackup=$null
try {
    $master=New-DbConnection 'master'
    $sourceState=Read-Scalar $master "SELECT state_desc FROM sys.databases WHERE name='$($SourceDatabase.Replace("'","''"))'"
    $targetState=Read-Scalar $master "SELECT state_desc FROM sys.databases WHERE name='$($TargetDatabase.Replace("'","''"))'"
    if($sourceState -ne 'ONLINE' -or $targetState -ne 'ONLINE'){throw 'Source and target databases must be ONLINE.'}
    $source=New-DbConnection $SourceDatabase;$target=New-DbConnection $TargetDatabase
    $sourceProducts=Read-Table $source "SELECT * FROM dbo.TABEST1 WHERE produto LIKE '%short%' OR fabricante LIKE '%short%' ORDER BY controle"
    $targetBarcodes=@{};foreach($row in (Read-Table $target 'SELECT controle,codigo FROM dbo.TABEST1').Rows){$targetBarcodes[[string]$row['codigo']]=[int]$row['controle']}
    $products=Select-Rows $sourceProducts {param($row) -not $targetBarcodes.ContainsKey([string]$row['codigo'])}
    if($products.Rows.Count -eq 0){Write-Output (ConvertTo-Json ([ordered]@{imported=0;message='All short barcodes are already in SICNET';source_unchanged=$true}));return}
    $productIds=[System.Collections.Generic.HashSet[int]]::new();foreach($row in $products.Rows){$null=$productIds.Add([int]$row['controle'])}
    $sourceReceipts=Read-Table $source 'SELECT * FROM dbo.TABEST2A ORDER BY controle';$sourceReceiptLines=Read-Table $source 'SELECT * FROM dbo.TABEST2B ORDER BY controle'
    $receiptIds=[System.Collections.Generic.HashSet[int]]::new();foreach($row in $sourceReceiptLines.Rows){if($productIds.Contains([int]$row['lkproduto'])){$null=$receiptIds.Add([int]$row['lkest2a'])}}
    $receipts=Select-Rows $sourceReceipts {param($row) $receiptIds.Contains([int]$row['controle'])}
    $receiptLines=Select-Rows $sourceReceiptLines {param($row) $productIds.Contains([int]$row['lkproduto']) -or $receiptIds.Contains([int]$row['lkest2a'])}
    $sourceUnits=Read-Table $source 'SELECT * FROM lineboard.Units ORDER BY barcode';$units=Select-Rows $sourceUnits {param($row) $productIds.Contains([int]$row['sic_id'])}
    $unitIds=[System.Collections.Generic.HashSet[string]]::new();foreach($row in $units.Rows){$null=$unitIds.Add(([Guid]$row['id']).ToString())}
    $sourceMovements=Read-Table $source "SELECT * FROM lineboard.Movements WHERE reason='initial' ORDER BY id";$movements=Select-Rows $sourceMovements {param($row) $unitIds.Contains(([Guid]$row['unit_id']).ToString())}
    $sourceOperations=Read-Table $source 'SELECT * FROM lineboard.Operations ORDER BY created_at';$operations=Select-Rows $sourceOperations {param($row) $text=[string]$row['response'];$found=$false;foreach($product in $products.Rows){if($text.Contains([string]$product['codigo'])){$found=$true;break}};$found}
    $targetProductCount=[int](Read-Scalar $target 'SELECT COUNT(*) FROM dbo.TABEST1');$targetReceiptCount=[int](Read-Scalar $target 'SELECT COUNT(*) FROM dbo.TABEST2A')
    foreach($row in $products.Rows){if([int]$row['controle'] -le $targetProductCount -and (Read-Scalar $target ('SELECT COUNT(*) FROM dbo.TABEST1 WHERE controle='+[int]$row['controle'])) -gt 0){throw 'A product control already exists in SICNET.'}}
    foreach($row in $receipts.Rows){if([int]$row['controle'] -le $targetReceiptCount -and (Read-Scalar $target ('SELECT COUNT(*) FROM dbo.TABEST2A WHERE controle='+[int]$row['controle'])) -gt 0){throw 'A receipt control already exists in SICNET.'}}
    $targetDataFile=[string](Read-Scalar $master "SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID('$TargetDatabase') AND type_desc='ROWS'")
    $backupPath=Join-Path (Split-Path -Parent $targetDataFile) ('LINEBOARD_SHORTS_'+$stamp+'.bak')
    $backup=$master.CreateCommand();$backup.CommandTimeout=180;$backup.CommandText='BACKUP DATABASE [SICNET] TO DISK=@path WITH COPY_ONLY, CHECKSUM, INIT';$null=$backup.Parameters.AddWithValue('@path',$backupPath);$null=$backup.ExecuteNonQuery();$backup.Dispose()
    $localBackup=Join-Path $workspace ('.local\'+(Split-Path -Leaf $backupPath));Copy-Item -LiteralPath $backupPath -Destination $localBackup -Force
    $maxBarcode=0L;foreach($row in (Read-Table $target 'SELECT barcode FROM lineboard.Units').Rows){$number=[Int64](([string]$row['barcode']).Substring(4));if($number -gt $maxBarcode){$maxBarcode=$number}}
    foreach($row in $units.Rows){$number=[Int64](([string]$row['barcode']).Substring(4));if($number -gt $maxBarcode){$maxBarcode=$number}}
    $transaction=$target.BeginTransaction([System.Data.IsolationLevel]::Serializable)
    Insert-Rows $target $transaction 'dbo.TABEST1' $products
    Insert-Rows $target $transaction 'dbo.TABEST2A' $receipts
    Insert-Rows $target $transaction 'dbo.TABEST2B' $receiptLines
    Insert-Rows $target $transaction 'lineboard.Units' $units
    Insert-Rows $target $transaction 'lineboard.Movements' $movements
    Insert-Rows $target $transaction 'lineboard.Operations' $operations
    $command=$target.CreateCommand();$command.Transaction=$transaction;$command.CommandText='ALTER SEQUENCE lineboard.BarcodeNumber RESTART WITH '+($maxBarcode+1);$null=$command.ExecuteNonQuery();$command.Dispose()
    foreach($table in @('dbo.TABEST1','dbo.TABEST2A','dbo.TABEST2B','lineboard.Movements')){
        $command=$target.CreateCommand();$command.Transaction=$transaction;$command.CommandText='DBCC CHECKIDENT ('''+$table+''', RESEED) WITH NO_INFOMSGS';$null=$command.ExecuteNonQuery();$command.Dispose()
    }
    $transaction.Commit();$transaction=$null
    [pscustomobject]@{source=$SourceDatabase;target=$TargetDatabase;short_products=$products.Rows.Count;receipts=$receipts.Rows.Count;receipt_lines=$receiptLines.Rows.Count;units=$units.Rows.Count;initial_movements=$movements.Rows.Count;operations=$operations.Rows.Count;backup=$localBackup;backup_sha256=(Get-FileHash -LiteralPath $localBackup -Algorithm SHA256).Hash;source_unchanged=$true;committed=$true}|ConvertTo-Json -Depth 4
} catch {if($null -ne $transaction){try{$transaction.Rollback()}catch{}};throw} finally {if($null -ne $transaction){$transaction.Dispose()};if($null -ne $target){$target.Dispose()};if($null -ne $source){$source.Dispose()};if($null -ne $master){$master.Dispose()}}
