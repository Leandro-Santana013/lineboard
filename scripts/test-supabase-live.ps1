param([Parameter(Mandatory = $true)][ValidatePattern('^[a-z]{20}$')][string]$ProjectRef)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$settings = Get-Content -LiteralPath (Join-Path $workspace 'mobile/config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$base = 'https://' + $ProjectRef + '.supabase.co'
if ($settings.SUPABASE_URL.TrimEnd('/') -ne $base) { throw 'The mobile configuration must match the selected project.' }
$keyOutput = & npx supabase projects api-keys --project-ref $ProjectRef --reveal --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not obtain credentials from the authenticated CLI.' }
$keys = ($keyOutput -join [Environment]::NewLine) | ConvertFrom-Json
$serverKey = ($keys | Where-Object { $_.name -eq 'service_role' -and $_.type -eq 'legacy' } | Select-Object -First 1).api_key
if (-not $serverKey) { throw 'Server credential unavailable.' }
$org = [Guid]::NewGuid().ToString(); $instance = [Guid]::NewGuid().ToString()
$bytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create(); $rng.GetBytes($bytes); $rng.Dispose()
$token = 'slb_live_' + [BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()
$sha = [Security.Cryptography.SHA256]::Create()
$hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($token))).Replace('-', '').ToLowerInvariant(); $sha.Dispose()
$checks = New-Object 'System.Collections.Generic.List[string]'

function Query([string]$Sql) {
    $scratch = Join-Path $workspace ('.local/live-query-' + [Guid]::NewGuid().ToString('N') + '.sql')
    [IO.File]::WriteAllText($scratch, $Sql, (New-Object Text.UTF8Encoding($false)))
    try {
        $result = & npx supabase db query --linked --project-ref $ProjectRef --file $scratch --output json
        if ($LASTEXITCODE -ne 0) { throw 'Remote verification SQL failed.' }
        return ($result -join [Environment]::NewLine) | ConvertFrom-Json
    } finally { Remove-Item -LiteralPath $scratch -Force }
}
function Check([bool]$Passed, [string]$Name) {
    if (-not $Passed) { throw "Remote check failed: $Name" }
    $checks.Add($Name)
}
function Send-Event([object]$Event, [string]$Credential = $token, [int]$ExpectedStatus = 200) {
    $status = 0; $text = ''
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Post -Uri ($base + '/functions/v1/sic-sync') -Headers @{ apikey = $settings.SUPABASE_PUBLISHABLE_KEY; Authorization = 'Bearer ' + $Credential } -ContentType 'application/json' -Body (ConvertTo-Json -InputObject $Event -Depth 12 -Compress) -TimeoutSec 30
        $status = [int]$response.StatusCode; $text = $response.Content
    } catch {
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            $reader = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $text = $reader.ReadToEnd(); $reader.Dispose()
        } else { throw 'Cloud endpoint unreachable.' }
    }
    if ($status -ne $ExpectedStatus) {
        $safeCode = 'unavailable'
        try { $parsed = $text | ConvertFrom-Json; if ($parsed.error -match '^[A-Z_]{1,64}$') { $safeCode = $parsed.error } } catch {}
        throw "Unexpected cloud response: HTTP $status (expected $ExpectedStatus), code $safeCode."
    }
    return $text | ConvertFrom-Json
}

$cleanup = @"
begin;
delete from public.sic_sync_events where organization_id='$org';
delete from public.sic_unit_links where organization_id='$org';
delete from public.stock_movements where organization_id='$org';
delete from public.sale_lines where organization_id='$org';
delete from public.sales where organization_id='$org';
delete from public.catalog_requests where organization_id='$org';
delete from public.stock_items where organization_id='$org';
delete from public.variants where organization_id='$org';
delete from public.products where organization_id='$org';
delete from public.integration_keys where organization_id='$org';
delete from public.sic_connections where organization_id='$org';
delete from public.memberships where organization_id='$org';
delete from public.organizations where id='$org' and name='Lineboard validation $org';
commit;
select count(*)::int as remaining from public.organizations where id='$org';
"@
try {
    # Every fixture belongs to a new, explicitly named organization. Existing
    # store data and the original SIC database are never used by this test.
    $null = Query @"
begin;
insert into public.organizations(id,name) values('$org','Lineboard validation $org');
insert into public.memberships(organization_id,user_id,role) select '$org',user_id,'admin' from public.memberships where role='admin' order by user_id limit 1;
insert into public.integration_keys(organization_id,name,token_hash) values('$org','Temporary live verification','$hash');
insert into public.sic_connections(organization_id,instance_id,allow_sandbox) values('$org','$instance',true);
commit;
select exists(select 1 from public.memberships where organization_id='$org') as admin_present;
"@
    $seedCheck = Query "select (select count(*) from public.integration_keys where organization_id='$org' and token_hash='$hash')::int as key_present, (select count(*) from public.memberships where organization_id='$org')::int as member_present;"
    Check ($seedCheck.rows[0].key_present -eq 1 -and $seedCheck.rows[0].member_present -eq 1) 'Isolated verification fixture was committed'
    $resolved = Invoke-RestMethod -Method Post -Uri ($base + '/rest/v1/rpc/integration_organization') -Headers @{ apikey=$serverKey; Authorization='Bearer '+$serverKey } -ContentType 'application/json' -Body (@{p_hash=$hash} | ConvertTo-Json -Compress) -TimeoutSec 20
    Check ($resolved -eq $org) 'Registered integration credential resolves only its temporary organization'
    $item = @{ stock_item_id=[Guid]::NewGuid().ToString(); product_id=[Guid]::NewGuid().ToString(); variant_id=[Guid]::NewGuid().ToString(); barcode=('SLB-8' + ([Math]::Abs([BitConverter]::ToInt64($bytes,0)) % 100000000000).ToString('D11')); name='Live verification'; brand='Test'; color='Azul'; size='M'; quantity=1; expected_quantity=1; revision=1; price=25; cost=10 }
    $event = @{ event_id=[Guid]::NewGuid().ToString(); instance_id=$instance; mode='sandbox'; kind='unit.upsert'; payload=$item }
    $result = Send-Event $event
    Check ($result.state -eq 'applied' -and $result.event_id -eq $event.event_id) 'Authenticated SIC event reaches deployed function and database'
    $replay = Send-Event $event
    Check ($replay.replayed -eq $true) 'Repeated event returns the previous result'
    $changed = $event.Clone(); $changed.payload = $item.Clone(); $changed.payload.price = 30
    $conflict = Send-Event $changed -ExpectedStatus 409
    Check ($conflict.error -eq 'IDEMPOTENCY_CONFLICT') 'Changed payload cannot reuse an event ID'
    $sale = @{ event_id=[Guid]::NewGuid().ToString(); instance_id=$instance; mode='sandbox'; kind='sale.confirmed'; payload=@{sale_id=[Guid]::NewGuid().ToString(); items=@($item); total=25; payment='pix'} }
    $sold = Send-Event $sale
    Check ($sold.state -eq 'applied' -and $sold.cloud_sale_id) 'SIC sale decreases cloud stock'
    $soldAgain = Send-Event $sale
    Check ($soldAgain.replayed -eq $true -and $soldAgain.cloud_sale_id -eq $sold.cloud_sale_id) 'Sale retry does not duplicate the sale'
    $quantity = Query "select quantity from public.stock_items where organization_id='$org' and id='$($item.stock_item_id)';"
    Check (@($quantity.rows).Count -eq 1 -and $quantity.rows[0].quantity -eq 0) 'Cloud quantity is zero after one confirmed sale'
    $rejected = Send-Event $event -Credential ('slb_live_' + ('0' * 64)) -ExpectedStatus 401
    Check ($rejected.error -eq 'UNAUTHORIZED') 'Unknown integration credential is refused'
} finally {
    $removed = Query $cleanup
    Remove-Variable keys,keyOutput,serverKey,token,bytes -ErrorAction SilentlyContinue
}
Check ($removed.rows[0].remaining -eq 0) 'Temporary verification organization was removed'
$evidence = [pscustomobject]@{ project_ref=$ProjectRef; passed=$checks.Count; checks=@($checks); fixture_removed=$true; email_sent=$false }
$evidence | ConvertTo-Json -Depth 5
