#!/usr/bin/env bash
# mercadolibre/scripts/ml-oauth.sh
#
# Interactive first-time OAuth flow for MercadoLibre.
# Prints an authorization URL, asks the user to paste back the redirected URL,
# exchanges the code for tokens, and persists everything to ~/.hermes/.env.
#
# Run:  bash scripts/ml-oauth.sh

set -euo pipefail

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required tool: $cmd" >&2
    echo "  Run: bash $(dirname "$0")/install-deps.sh" >&2
    exit 1
  }
done

ML_ENV_FILE="${ML_ENV_FILE:-$HOME/.hermes/.env}"
ML_API="${ML_API:-https://api.mercadolibre.com}"

declare -A AUTH_HOSTS=(
  [MLA]="https://auth.mercadolibre.com.ar"
  [MLB]="https://auth.mercadolivre.com.br"
  [MLM]="https://auth.mercadolibre.com.mx"
  [MLC]="https://auth.mercadolibre.cl"
  [MCO]="https://auth.mercadolibre.com.co"
  [MLU]="https://auth.mercadolibre.com.uy"
)

mkdir -p "$(dirname "$ML_ENV_FILE")"
touch "$ML_ENV_FILE"
chmod 600 "$ML_ENV_FILE"

# Load any existing values so prompts can default to them
# shellcheck disable=SC1090
set -a; . "$ML_ENV_FILE"; set +a

read -rp "App ID (client_id)${ML_CLIENT_ID:+ [$ML_CLIENT_ID]}: " IN
ML_CLIENT_ID="${IN:-${ML_CLIENT_ID:-}}"
[ -n "$ML_CLIENT_ID" ] || { echo "client_id required" >&2; exit 1; }

read -rp "Secret Key (client_secret)${ML_CLIENT_SECRET:+ [hidden, press enter to keep]}: " IN
ML_CLIENT_SECRET="${IN:-${ML_CLIENT_SECRET:-}}"
[ -n "$ML_CLIENT_SECRET" ] || { echo "client_secret required" >&2; exit 1; }

DEFAULT_REDIRECT="${ML_REDIRECT_URI:-https://localhost:8080/callback}"
read -rp "Redirect URI [${DEFAULT_REDIRECT}]: " IN
ML_REDIRECT_URI="${IN:-$DEFAULT_REDIRECT}"

DEFAULT_SITE="${ML_SITE:-MLA}"
read -rp "Site code (MLA/MLB/MLM/MLC/MCO/MLU) [${DEFAULT_SITE}]: " IN
ML_SITE="${IN:-$DEFAULT_SITE}"

AUTH_HOST="${AUTH_HOSTS[$ML_SITE]:-}"
[ -n "$AUTH_HOST" ] || { echo "Unknown site $ML_SITE — supported: ${!AUTH_HOSTS[*]}" >&2; exit 1; }

REDIRECT_ENC=$(printf %s "$ML_REDIRECT_URI" | jq -sRr @uri)
AUTH_URL="${AUTH_HOST}/authorization?response_type=code&client_id=${ML_CLIENT_ID}&redirect_uri=${REDIRECT_ENC}"

echo
echo "1. Open this URL in your browser and authorize the app:"
echo
echo "   $AUTH_URL"
echo
echo "2. After clicking 'Allow', the browser will redirect to your callback URL"
echo "   and probably show a 'can't reach this page' error. That's expected."
echo
echo "3. Copy the ENTIRE URL from the browser's address bar and paste it below."
echo
read -rp "Pasted URL: " RETURNED

CODE=$(printf '%s' "$RETURNED" | sed -n 's|.*[?&]code=\([^&]*\).*|\1|p')
[ -n "$CODE" ] || { echo "Could not extract ?code= from URL" >&2; exit 1; }

echo
echo "Exchanging authorization code for tokens..."

RESP=$(curl -fsS -X POST "$ML_API/oauth/token" \
  -H "Accept: application/json" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code" \
  -d "client_id=${ML_CLIENT_ID}" \
  -d "client_secret=${ML_CLIENT_SECRET}" \
  -d "code=${CODE}" \
  -d "redirect_uri=${ML_REDIRECT_URI}") \
  || { echo "Token exchange failed (curl error). Re-check client_id/secret and try again." >&2; exit 1; }

ACCESS=$(echo "$RESP"  | jq -r '.access_token  // empty')
REFRESH=$(echo "$RESP" | jq -r '.refresh_token // empty')
EXPIRES_IN=$(echo "$RESP" | jq -r '.expires_in // empty')
USER_ID=$(echo "$RESP" | jq -r '.user_id // empty')

if [ -z "$ACCESS" ] || [ -z "$REFRESH" ]; then
  echo "Token exchange failed:" >&2
  echo "$RESP" | jq . >&2 || echo "$RESP" >&2
  exit 1
fi

EXPIRES_AT=$(( $(date +%s) + EXPIRES_IN - 60 ))

# Rewrite the env file: strip our keys, then append fresh values
TMP="${ML_ENV_FILE}.tmp.$$"
{
  grep -vE '^(ML_CLIENT_ID|ML_CLIENT_SECRET|ML_REDIRECT_URI|ML_SITE|ML_ACCESS_TOKEN|ML_REFRESH_TOKEN|ML_USER_ID|ML_EXPIRES_AT)=' "$ML_ENV_FILE" 2>/dev/null || true
  echo "ML_CLIENT_ID=${ML_CLIENT_ID}"
  echo "ML_CLIENT_SECRET=${ML_CLIENT_SECRET}"
  echo "ML_REDIRECT_URI=${ML_REDIRECT_URI}"
  echo "ML_SITE=${ML_SITE}"
  echo "ML_ACCESS_TOKEN=${ACCESS}"
  echo "ML_REFRESH_TOKEN=${REFRESH}"
  echo "ML_USER_ID=${USER_ID}"
  echo "ML_EXPIRES_AT=${EXPIRES_AT}"
} > "$TMP"
mv "$TMP" "$ML_ENV_FILE"
chmod 600 "$ML_ENV_FILE"

echo
echo "Authorized. Tokens written to $ML_ENV_FILE"
echo "  user_id    = $USER_ID"
echo "  site       = $ML_SITE"
echo "  expires_at = $(date -d "@$EXPIRES_AT" 2>/dev/null || date -r "$EXPIRES_AT" 2>/dev/null || echo "$EXPIRES_AT")"
