param(
    [string]$Server = '(localdb)\MSSQLLocalDB',
    [ValidateSet('SICNET')]
    [string]$TargetDatabase = 'SICNET',
    [switch]$ConfirmProduction
)

$ErrorActionPreference = 'Stop'
if (-not $ConfirmProduction) { throw 'This removes camisa exg records and their linked sale from SICNET. Re-run with -ConfirmProduction.' }
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function New-DbConnection([string]$database) {
    $connection = New-Object System.Data.SqlClient.SqlConnection "Data Source=$Server;Initial Catalog=$database;Integrated Security=SSPI;Connect Timeout=15;Application Name=Lineboard EXG Removal"
    $connection.Open()
    return $connection
}
function Read-Scalar([System.Data.SqlClient.SqlConnection]$connection,[System.Data.SqlClient.SqlTransaction]$transaction,[string]$sql) {
    $command = $connection.CreateCommand(); $command.Transaction = $transaction; $command.CommandTimeout = 60; $command.CommandText = $sql
    try { $value = $command.ExecuteScalar(); if ($value -is [System.DBNull]) { return $null }; return $value } finally { $command.Dispose() }
}
function Invoke-Db([System.Data.SqlClient.SqlConnection]$connection,[System.Data.SqlClient.SqlTransaction]$transaction,[string]$sql) {
    $command = $connection.CreateCommand(); $command.Transaction = $transaction; $command.CommandTimeout = 120; $command.CommandText = $sql
    try { return $command.ExecuteNonQuery() } finally { $command.Dispose() }
}

$master = $null; $target = $null; $transaction = $null; $localBackup = $null
try {
    $master = New-DbConnection 'master'
    $state = [string](Read-Scalar $master $null "SELECT state_desc FROM sys.databases WHERE name='$($TargetDatabase.Replace("'","''"))'")
    if ($state -ne 'ONLINE') { throw 'SICNET must be ONLINE.' }
    $target = New-DbConnection $TargetDatabase

    $dataFile = [string](Read-Scalar $master $null "SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID('$TargetDatabase') AND type_desc='ROWS'")
    $backupPath = Join-Path (Split-Path -Parent $dataFile) ('LINEBOARD_REMOVE_EXG_' + $stamp + '.bak')
    $backup = $master.CreateCommand(); $backup.CommandTimeout = 180; $backup.CommandText = 'BACKUP DATABASE [SICNET] TO DISK=@path WITH COPY_ONLY, CHECKSUM, INIT'; $null = $backup.Parameters.AddWithValue('@path', $backupPath); $null = $backup.ExecuteNonQuery(); $backup.Dispose()
    $localBackup = Join-Path $workspace ('.local\' + (Split-Path -Leaf $backupPath)); Copy-Item -LiteralPath $backupPath -Destination $localBackup -Force

    $transaction = $target.BeginTransaction([System.Data.IsolationLevel]::Serializable)
    Invoke-Db $target $transaction @'
CREATE TABLE #ExgProducts (controle int NOT NULL PRIMARY KEY);
INSERT INTO #ExgProducts (controle)
SELECT controle
FROM dbo.TABEST1
WHERE LOWER(LTRIM(RTRIM(produto))) = 'camisa exg'
   OR LOWER(LTRIM(RTRIM(codinterno))) = 'camisa exg';
IF NOT EXISTS (SELECT 1 FROM #ExgProducts)
    THROW 50001, 'No camisa exg products found in SICNET.', 1;
CREATE TABLE #ExgUnits (id uniqueidentifier NOT NULL PRIMARY KEY);
INSERT INTO #ExgUnits (id)
SELECT u.id FROM lineboard.Units u JOIN #ExgProducts p ON p.controle = u.sic_id;
CREATE TABLE #ExgSales (controle int NOT NULL PRIMARY KEY);
INSERT INTO #ExgSales (controle)
SELECT DISTINCT b.lkest3a FROM dbo.TABEST3B b JOIN #ExgProducts p ON p.controle = b.lkproduto;
CREATE TABLE #ExgReceipts (controle int NOT NULL PRIMARY KEY);
INSERT INTO #ExgReceipts (controle)
SELECT DISTINCT b.lkest2a FROM dbo.TABEST2B b JOIN #ExgProducts p ON p.controle = b.lkproduto;
'@

    $productCount = [int](Read-Scalar $target $transaction 'SELECT COUNT(*) FROM #ExgProducts')
    $unitCount = [int](Read-Scalar $target $transaction 'SELECT COUNT(*) FROM #ExgUnits')
    $saleCount = [int](Read-Scalar $target $transaction 'SELECT COUNT(*) FROM #ExgSales')
    $receiptCount = [int](Read-Scalar $target $transaction 'SELECT COUNT(*) FROM #ExgReceipts')

    Invoke-Db $target $transaction 'DELETE c FROM lineboard.Cart c JOIN #ExgUnits u ON u.id=c.unit_id; DELETE e FROM lineboard.UnitEdits e JOIN #ExgUnits u ON u.id=e.unit_id; DELETE m FROM lineboard.Movements m JOIN #ExgUnits u ON u.id=m.unit_id; DELETE s FROM lineboard.Sales s JOIN #ExgProducts p ON p.controle=s.sic_id; DELETE o FROM lineboard.Outbox o WHERE o.payload LIKE ''%camisa exg%''; DELETE o FROM lineboard.Operations o WHERE o.response LIKE ''%"name":"camisa exg"%'';'
    Invoke-Db $target $transaction 'DELETE r FROM dbo.TABEST3R r JOIN #ExgSales s ON s.controle=r.lkest3a; DELETE b FROM dbo.TABEST3B b JOIN #ExgProducts p ON p.controle=b.lkproduto; DELETE h FROM dbo.TABEST3A h JOIN #ExgSales s ON s.controle=h.controle WHERE NOT EXISTS (SELECT 1 FROM dbo.TABEST3B b WHERE b.lkest3a=h.controle);'
    Invoke-Db $target $transaction 'DELETE b FROM dbo.TABEST2B b JOIN #ExgProducts p ON p.controle=b.lkproduto; DELETE h FROM dbo.TABEST2A h JOIN #ExgReceipts r ON r.controle=h.controle WHERE NOT EXISTS (SELECT 1 FROM dbo.TABEST2B b WHERE b.lkest2a=h.controle);'
    Invoke-Db $target $transaction 'DELETE u FROM lineboard.Units u JOIN #ExgProducts p ON p.controle=u.sic_id; DELETE p FROM dbo.TABEST1 p JOIN #ExgProducts x ON x.controle=p.controle;'

    $remaining = [int](Read-Scalar $target $transaction "SELECT COUNT(*) FROM dbo.TABEST1 WHERE LOWER(LTRIM(RTRIM(produto)))='camisa exg' OR LOWER(LTRIM(RTRIM(codinterno)))='camisa exg'")
    if ($remaining -ne 0) { throw 'Camisa exg records remain after deletion.' }
    $transaction.Commit(); $transaction = $null
    [pscustomobject]@{
        target = $TargetDatabase
        products_removed = $productCount
        units_removed = $unitCount
        sale_headers_considered = $saleCount
        receipt_headers_considered = $receiptCount
        backup = $localBackup
        backup_sha256 = (Get-FileHash -LiteralPath $localBackup -Algorithm SHA256).Hash
        committed = $true
    } | ConvertTo-Json -Depth 4
} catch {
    if ($null -ne $transaction) { try { $transaction.Rollback() } catch {} }
    throw
} finally {
    if ($null -ne $transaction) { $transaction.Dispose() }
    if ($null -ne $target) { $target.Dispose() }
    if ($null -ne $master) { $master.Dispose() }
}
