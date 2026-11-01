param(
    [Parameter(Mandatory = $true)][string]$Email,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z]{20}$')][string]$ProjectRef,
    [Parameter(Mandatory = $true)][Guid]$OrganizationId
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Email = $Email.Trim().ToLowerInvariant()
if ($Email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { throw 'Invalid administrator email.' }
$endpoint = 'https://' + $ProjectRef + '.supabase.co'

# CLI credentials stay in the CLI credential store. Server keys are retrieved
# only into process memory and are never written to files, logs or the app.
$keyOutput = & npx supabase projects api-keys --project-ref $ProjectRef --reveal --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not obtain project credentials through the authenticated CLI.' }
$keys = ($keyOutput -join [Environment]::NewLine) | ConvertFrom-Json
$serverKey = $keys | Where-Object { $_.name -eq 'service_role' -and $_.type -eq 'legacy' } | Select-Object -First 1
if (-not $serverKey -or [string]::IsNullOrWhiteSpace($serverKey.api_key)) { throw 'Server credential unavailable.' }
$headers = @{ apikey = $serverKey.api_key; Authorization = 'Bearer ' + $serverKey.api_key }

function Invoke-ProjectApi([string]$Method, [string]$Path, [object]$Payload = $null) {
    try {
        $arguments = @{ Method = $Method; Uri = $endpoint + $Path; Headers = $headers; TimeoutSec = 30 }
        if ($null -ne $Payload) {
            $arguments.ContentType = 'application/json'
            $arguments.Body = ConvertTo-Json -InputObject $Payload -Depth 8 -Compress
        }
        Invoke-RestMethod @arguments
    } catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'unreachable' }
        throw "Project API operation failed ($Method $Path, status $status). No credentials were logged."
    }
}

try {
    $organizations = @(Invoke-ProjectApi 'Get' ('/rest/v1/organizations?select=id&id=eq.' + $OrganizationId))
    if ($organizations.Count -ne 1) { throw 'Target organization does not exist in this project.' }
    $directory = Invoke-ProjectApi 'Get' '/auth/v1/admin/users?page=1&per_page=1000'
    if (@($directory.users).Count -ge 1000) { throw 'Use the admin panel to select the user in this large directory.' }
    $account = @($directory.users | Where-Object { $_.email -eq $Email })
    if ($account.Count -gt 1) { throw 'Administrator email is ambiguous.' }
    $created = $account.Count -eq 0
    if ($created) {
        # createUser does not send email. Ownership is verified when the user
        # requests and opens their own login link; do not mark email confirmed.
        $user = Invoke-ProjectApi 'Post' '/auth/v1/admin/users' @{ email = $Email; email_confirm = $false }
    } else { $user = $account[0] }
    $userId = [Guid]::Parse($user.id)
    $headers.Prefer = 'resolution=merge-duplicates,return=minimal'
    $null = Invoke-ProjectApi 'Post' '/rest/v1/memberships?on_conflict=organization_id,user_id' @{
        organization_id = $OrganizationId.ToString(); user_id = $userId.ToString(); role = 'admin'
    }
    [pscustomobject]@{ administrator_prepared = $true; created = $created; user_id = $userId; organization_id = $OrganizationId; email_sent = $false } | ConvertTo-Json -Compress
} finally {
    Remove-Variable keys,keyOutput,serverKey,headers -ErrorAction SilentlyContinue
}
