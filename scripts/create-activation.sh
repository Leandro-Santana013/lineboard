#!/usr/bin/env bash
set -euo pipefail

SUPABASE_URL="${SUPABASE_URL:-https://isktnezzanqpcrkkqldw.supabase.co}"
SUPABASE_URL="${SUPABASE_URL%/}"
SUPABASE_PUBLISHABLE_KEY="${SUPABASE_PUBLISHABLE_KEY:-}"
ORGANIZATION_ID="${ORGANIZATION_ID:-c084a7a2-6862-4562-8328-e7cc822c37dc}"

die() {
  echo "Erro: $1" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die "curl não encontrado. Instale o pacote curl."
command -v openssl >/dev/null 2>&1 || die "openssl não encontrado. Instale o pacote openssl."
if command -v sha256sum >/dev/null 2>&1; then
  HASH_COMMAND="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  HASH_COMMAND="shasum -a 256"
else
  die "sha256sum/shasum não encontrado."
fi

if [[ -z "$SUPABASE_PUBLISHABLE_KEY" ]]; then
  read -r -p "Cole a chave pública (publishable key) do Supabase: " SUPABASE_PUBLISHABLE_KEY
fi
[[ -n "$SUPABASE_PUBLISHABLE_KEY" ]] || die "A chave pública do Supabase é obrigatória."

json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\t'/\\t}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\n'/\\n}"
  printf '%s' "$value"
}

post_json() {
  local path="$1"
  local body="$2"
  local access_token="${3:-}"
  local response status response_body
  local -a headers=("-H" "apikey: $SUPABASE_PUBLISHABLE_KEY" "-H" "Content-Type: application/json")
  if [[ -n "$access_token" ]]; then
    headers+=("-H" "Authorization: Bearer $access_token")
  fi

  response="$(curl -sS -X POST "${SUPABASE_URL}${path}" "${headers[@]}" --data "$body" -w $'\n%{http_code}')" || die "Falha de rede ao acessar o Supabase."
  status="${response##*$'\n'}"
  response_body="${response%$'\n'*}"
  if [[ "$status" != 2* ]]; then
    echo "$response_body" >&2
    die "O Supabase respondeu HTTP $status."
  fi
  printf '%s' "$response_body"
}

echo
echo '=== Lineboard - gerar código de ativação ==='
echo 'O código será válido por 24 horas e poderá ser usado uma vez.'
echo

read -r -p 'E-mail do administrador: ' ADMIN_EMAIL
[[ -n "$ADMIN_EMAIL" ]] || die 'O e-mail do administrador é obrigatório.'

OTP_BODY="{\"email\":\"$(json_escape "$ADMIN_EMAIL")\",\"create_user\":false}"
post_json '/auth/v1/otp' "$OTP_BODY" >/dev/null

read -r -p 'Digite o código recebido no e-mail: ' EMAIL_CODE
[[ -n "$EMAIL_CODE" ]] || die 'O código recebido por e-mail é obrigatório.'

VERIFY_BODY="{\"email\":\"$(json_escape "$ADMIN_EMAIL")\",\"token\":\"$(json_escape "$EMAIL_CODE")\",\"type\":\"email\"}"
SESSION="$(post_json '/auth/v1/verify' "$VERIFY_BODY")"
ADMIN_ACCESS_TOKEN="$(printf '%s' "$SESSION" | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^\"]*\)".*/\1/p')"
[[ -n "$ADMIN_ACCESS_TOKEN" ]] || die 'O Supabase não retornou um token administrativo.'

read -r -p 'Nome do computador [Computador do caixa]: ' DEVICE_NAME
DEVICE_NAME="${DEVICE_NAME:-Computador do caixa}"

read -r -p 'Quantidade de usos [1]: ' MAX_USES
MAX_USES="${MAX_USES:-1}"
[[ "$MAX_USES" =~ ^[0-9]+$ ]] || die 'A quantidade de usos deve ser um número.'
(( MAX_USES >= 1 && MAX_USES <= 20 )) || die 'A quantidade de usos deve estar entre 1 e 20.'

read -r -p 'Validade em horas [24]: ' EXPIRES_IN_HOURS
EXPIRES_IN_HOURS="${EXPIRES_IN_HOURS:-24}"
[[ "$EXPIRES_IN_HOURS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die 'A validade deve ser um número de horas.'
(( $(awk "BEGIN { print ($EXPIRES_IN_HOURS > 0 && $EXPIRES_IN_HOURS <= 720) ? 1 : 0 }") == 1 )) || die 'A validade deve estar entre 1 hora e 30 dias.'

EXPIRES_AT="$(date -u -d "+${EXPIRES_IN_HOURS} hours" '+%Y-%m-%dT%H:%M:%S.000Z')" || die 'Não foi possível calcular a validade.'

HEX="$(openssl rand -hex 6 | tr '[:lower:]' '[:upper:]')"
ACTIVATION_CODE="LB-${HEX:0:4}-${HEX:4:4}-${HEX:8:4}"
CODE_HASH="$(printf '%s' "$ACTIVATION_CODE" | $HASH_COMMAND | awk '{print $1}')"

CREATE_BODY="{\"p_org\":\"$(json_escape "$ORGANIZATION_ID")\",\"p_name\":\"$(json_escape "$DEVICE_NAME")\",\"p_code_hash\":\"$CODE_HASH\",\"p_max_uses\":$MAX_USES,\"p_expires_at\":\"$EXPIRES_AT\"}"
post_json '/rest/v1/rpc/create_desktop_activation' "$CREATE_BODY" "$ADMIN_ACCESS_TOKEN" >/dev/null

echo
echo 'Código de ativação:'
echo "$ACTIVATION_CODE"
echo
echo "Computador: $DEVICE_NAME"
echo "Expira em: $EXPIRES_AT"
echo
echo 'Anote o código agora: ele não é salvo e não será exibido novamente.'
