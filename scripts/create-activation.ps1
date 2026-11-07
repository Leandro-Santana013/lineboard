[CmdletBinding()]
param(
    [string]$SupabaseUrl = $(if ($env:SUPABASE_URL) { $env:SUPABASE_URL } else { 'https://isktnezzanqpcrkkqldw.supabase.co' }),
    [string]$PublishableKey = $(if ($env:SUPABASE_PUBLISHABLE_KEY) { $env:SUPABASE_PUBLISHABLE_KEY } else { '' }),
    [string]$OrganizationId = 'c084a7a2-6862-4562-8328-e7cc822c37dc'
)

$ErrorActionPreference = 'Stop'
$SupabaseUrl = $SupabaseUrl.TrimEnd('/')

if ([string]::IsNullOrWhiteSpace($PublishableKey)) {
    $PublishableKey = Read-Host 'Cole a chave pública (publishable key) do Supabase'
}
if ([string]::IsNullOrWhiteSpace($PublishableKey)) {
    throw 'A chave pública do Supabase é obrigatória.'
}

function Invoke-SupabasePost {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Body,
        [Parameter(Mandatory = $false)][string]$AccessToken
    )

    $headers = @{ apikey = $PublishableKey }
    if (-not [string]::IsNullOrWhiteSpace($AccessToken)) {
        $headers.Authorization = "Bearer $AccessToken"
    }

    Invoke-RestMethod `
        -Method Post `
        -Uri "$SupabaseUrl$Path" `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body ($Body | ConvertTo-Json -Depth 8 -Compress)
}

Write-Host ''
Write-Host '=== Lineboard - gerar código de ativação ===' -ForegroundColor Cyan
Write-Host 'O código será válido por 24 horas e poderá ser usado uma vez.' -ForegroundColor DarkGray
Write-Host ''

$email = Read-Host 'E-mail do administrador'
if ([string]::IsNullOrWhiteSpace($email)) {
    throw 'O e-mail do administrador é obrigatório.'
}

try {
    Invoke-SupabasePost -Path '/auth/v1/otp' -Body @{
        email = $email.Trim()
        create_user = $false
    } | Out-Null
} catch {
    throw "Não foi possível enviar o código por e-mail. Confira a URL e a chave pública do Supabase. Detalhes: $($_.Exception.Message)"
}

$emailCode = Read-Host 'Digite o código recebido no e-mail'
if ([string]::IsNullOrWhiteSpace($emailCode)) {
    throw 'O código recebido por e-mail é obrigatório.'
}

try {
    $session = Invoke-SupabasePost -Path '/auth/v1/verify' -Body @{
        email = $email.Trim()
        token = $emailCode.Trim()
        type = 'email'
    }
} catch {
    throw "Não foi possível validar o código do e-mail. Confira se ele ainda está válido. Detalhes: $($_.Exception.Message)"
}

$adminAccessToken = [string]$session.access_token
if ([string]::IsNullOrWhiteSpace($adminAccessToken)) {
    throw 'O login foi concluído, mas o Supabase não retornou um token administrativo.'
}

$deviceName = Read-Host 'Nome do computador [Computador do caixa]'
if ([string]::IsNullOrWhiteSpace($deviceName)) { $deviceName = 'Computador do caixa' }

$maxUsesText = Read-Host 'Quantidade de usos [1]'
$maxUses = if ([string]::IsNullOrWhiteSpace($maxUsesText)) { 1 } else { [int]$maxUsesText }
if ($maxUses -lt 1 -or $maxUses -gt 20) { throw 'A quantidade de usos deve estar entre 1 e 20.' }

$hoursText = Read-Host 'Validade em horas [24]'
$expiresInHours = if ([string]::IsNullOrWhiteSpace($hoursText)) { 24 } else { [double]$hoursText }
if ($expiresInHours -le 0 -or $expiresInHours -gt 720) { throw 'A validade deve estar entre 1 hora e 30 dias.' }

$randomBytes = New-Object byte[] 6
$randomNumberGenerator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $randomNumberGenerator.GetBytes($randomBytes)
} finally {
    $randomNumberGenerator.Dispose()
}

$hex = ([BitConverter]::ToString($randomBytes).Replace('-', '')).ToUpperInvariant()
$activationCode = 'LB-{0}-{1}-{2}' -f $hex.Substring(0, 4), $hex.Substring(4, 4), $hex.Substring(8, 4)

$sha256 = [System.Security.Cryptography.SHA256]::Create()
try {
    $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($activationCode))
} finally {
    $sha256.Dispose()
}
$codeHash = ([BitConverter]::ToString($hashBytes).Replace('-', '')).ToLowerInvariant()
$expiresAt = [DateTime]::UtcNow.AddHours($expiresInHours).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')

try {
    $activationId = Invoke-SupabasePost `
        -Path '/rest/v1/rpc/create_desktop_activation' `
        -AccessToken $adminAccessToken `
        -Body @{
            p_org = $OrganizationId
            p_name = $deviceName.Trim()
            p_code_hash = $codeHash
            p_max_uses = $maxUses
            p_expires_at = $expiresAt
        }
} catch {
    throw "Não foi possível criar o código. Confirme que este administrador pertence à loja e que o Organization ID está correto. Detalhes: $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'Código de ativação:' -ForegroundColor Green
Write-Host $activationCode -ForegroundColor Yellow
Write-Host ''
Write-Host "Computador: $deviceName" -ForegroundColor DarkGray
Write-Host "Expira em: $expiresAt" -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Anote o código agora: ele não é salvo e não será exibido novamente.' -ForegroundColor Cyan
