param(
    [string]$Server = '(localdb)\MSSQLLocalDB',
    [string[]]$AdditionalRoots = @(),
    [string]$Output
)
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$registryRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$installed = @()
foreach ($registryRoot in $registryRoots) {
    $installed += @(Get-ItemProperty $registryRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'SICNET|Sistema Integrado Comercial' } |
        Select-Object DisplayName, DisplayVersion, InstallLocation)
}
$searchRoots = @('C:\SICNET', 'C:\NFE', 'C:\NFCE') + $AdditionalRoots + @($installed.InstallLocation)
$programs = @()
foreach ($searchRoot in @($searchRoots | Where-Object { $_ } | Sort-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) { continue }
    $fullRoot = [IO.Path]::GetFullPath($searchRoot)
    if ($fullRoot.TrimEnd('\') -eq [IO.Path]::GetPathRoot($fullRoot).TrimEnd('\')) { continue }
    $programs += @(Get-ChildItem -LiteralPath $fullRoot -Filter '*.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^(unins|instal|setup|atualiz)' } |
        ForEach-Object {
            $model = if ($_.BaseName -match '^(sic[-_]?)?nfce[0-9]*$') { 65 }
                     elseif ($_.BaseName -match '^(sic[-_]?)?nfe[0-9]*$') { 55 }
                     else { $null }
            [pscustomobject]@{ path = $_.FullName; version = $_.VersionInfo.FileVersion; possible_model = $model }
        })
}
$programs = @($programs | Sort-Object path -Unique)
$printerStatus = 'available'; $printers = @()
try { $printers = @(Get-CimInstance Win32_Printer -ErrorAction Stop | Select-Object Name, DriverName, Default) }
catch { $printerStatus = 'query_unavailable' }

# Only aggregate metadata is read. Never inspect/export a private key, PFX,
# certificate password, company configuration, CSC, or customer invoice XML.
$certificates = @(Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
    Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) })
$database = [ordered]@{ name = 'SICNET'; connected = $false; nfce_table_present = $false; nfce_records = $null }
$connection = New-Object System.Data.SqlClient.SqlConnection "Data Source=$Server;Initial Catalog=SICNET;Integrated Security=SSPI;Connect Timeout=5;Application Name=Lineboard Readonly Fiscal Probe"
try {
    $connection.Open(); $database.connected = $true
    $command = $connection.CreateCommand(); $command.CommandTimeout = 5
    $command.CommandText = "SELECT CASE WHEN OBJECT_ID('dbo.TABNFCE') IS NULL THEN 0 ELSE 1 END"
    $database.nfce_table_present = [bool][int]$command.ExecuteScalar()
    if ($database.nfce_table_present) {
        $command.CommandText = 'SELECT COUNT(*) FROM dbo.TABNFCE'
        $database.nfce_records = [int]$command.ExecuteScalar()
    }
    $command.Dispose()
} catch { $database.inspection_error = 'READ_ONLY_PROBE_FAILED' }
finally { $connection.Dispose() }

$report = [ordered]@{
    checked_at_utc = [DateTime]::UtcNow.ToString('o')
    state = 'SP'
    requested_models = @(55, 65)
    installed_sic_programs = $installed
    program_candidates = $programs
    nfce_candidate_found = @($programs | Where-Object possible_model -eq 65).Count -gt 0
    nfe_candidate_found = @($programs | Where-Object possible_model -eq 55).Count -gt 0
    program_candidates_require_verification = $true
    printer_query = $printerStatus
    printers = $printers
    windows_unexpired_private_certificates = $certificates.Count
    certificate_suitability_verified = $false
    certificate_files_inspected = $false
    database = $database
    transmission_attempted = $false
    installation_or_configuration_changed = $false
    automatic_fiscal_integration_verified = $false
}
$json = $report | ConvertTo-Json -Depth 7
if ($Output) {
    $fullOutput = [IO.Path]::GetFullPath($Output)
    $parent = [IO.Path]::GetDirectoryName($fullOutput)
    $null = New-Item -ItemType Directory -Path $parent -Force
    [IO.File]::WriteAllText($fullOutput, $json, (New-Object Text.UTF8Encoding($false)))
}
$json
