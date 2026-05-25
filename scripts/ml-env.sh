#!/usr/bin/env bash
# mercadolibre/scripts/ml-env.sh
#
# Source this file, then call ml_load_token before any API request:
#
#   source skills/mercadolibre/scripts/ml-env.sh
#   ml_load_token
#
# Exports (after a successful load):
#   ML_API, ML_SITE, ML_CLIENT_ID, ML_CLIENT_SECRET, ML_REDIRECT_URI,
#   ML_ACCESS_TOKEN, ML_REFRESH_TOKEN, ML_USER_ID, ML_EXPIRES_AT
#
# Auto-refreshes when the access token is within 60s of expiry.

ML_ENV_FILE="${ML_ENV_FILE:-$HOME/.hermes/.env}"
export ML_API="${ML_API:-https://api.mercadolibre.com}"

_ml_die() { echo "ml-env: $*" >&2; return 1; }

_ml_check_deps() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq   >/dev/null 2>&1 || missing+=(jq)
  if [ ${#missing[@]} -gt 0 ]; then
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    echo "ml-env: missing required tools: ${missing[*]}" >&2
    echo "  Run: bash ${here:-scripts}/install-deps.sh" >&2
    return 1
  fi
}

_ml_read_env() {
  [ -f "$ML_ENV_FILE" ] || { _ml_die "missing $ML_ENV_FILE — run ml-oauth.sh first"; return 1; }
  # shellcheck disable=SC1090
  set -a; . "$ML_ENV_FILE"; set +a
}

# Atomically replace or append KEY=VALUE in $ML_ENV_FILE.
_ml_write_env_var() {
  local key="$1" val="$2"
  local tmp="${ML_ENV_FILE}.tmp.$$"
  if [ -f "$ML_ENV_FILE" ]; then
    grep -v "^${key}=" "$ML_ENV_FILE" > "$tmp" || true
  else
    : > "$tmp"
  fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$ML_ENV_FILE"
  chmod 600 "$ML_ENV_FILE"
}

ml_refresh_token() {
  _ml_check_deps || return 1
  _ml_read_env   || return 1
  [ -n "${ML_CLIENT_ID:-}" ]     || { _ml_die "ML_CLIENT_ID not set";     return 1; }
  [ -n "${ML_CLIENT_SECRET:-}" ] || { _ml_die "ML_CLIENT_SECRET not set"; return 1; }
  [ -n "${ML_REFRESH_TOKEN:-}" ] || { _ml_die "ML_REFRESH_TOKEN not set — re-run ml-oauth.sh"; return 1; }

  local resp
  resp=$(curl -fsS -X POST "$ML_API/oauth/token" \
    -H "Accept: application/json" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=refresh_token" \
    -d "client_id=${ML_CLIENT_ID}" \
    -d "client_secret=${ML_CLIENT_SECRET}" \
    -d "refresh_token=${ML_REFRESH_TOKEN}") \
    || { _ml_die "refresh failed — token may be revoked, re-run ml-oauth.sh"; return 1; }

  local access refresh expires_in user_id
  access=$(echo     "$resp" | jq -r '.access_token  // empty')
  refresh=$(echo    "$resp" | jq -r '.refresh_token // empty')
  expires_in=$(echo "$resp" | jq -r '.expires_in    // empty')
  user_id=$(echo    "$resp" | jq -r '.user_id       // empty')

  if [ -z "$access" ] || [ -z "$refresh" ]; then
    _ml_die "unexpected refresh response: $resp"
    return 1
  fi

  local now expires_at
  now=$(date +%s)
  expires_at=$(( now + expires_in - 60 ))    # 60s safety buffer

  _ml_write_env_var ML_ACCESS_TOKEN  "$access"
  _ml_write_env_var ML_REFRESH_TOKEN "$refresh"
  [ -n "$user_id" ] && _ml_write_env_var ML_USER_ID "$user_id"
  _ml_write_env_var ML_EXPIRES_AT    "$expires_at"

  export ML_ACCESS_TOKEN="$access"
  export ML_REFRESH_TOKEN="$refresh"
  [ -n "$user_id" ] && export ML_USER_ID="$user_id"
  export ML_EXPIRES_AT="$expires_at"
}

ml_load_token() {
  _ml_check_deps || return 1
  _ml_read_env   || return 1

  local now expiry
  now=$(date +%s)
  expiry="${ML_EXPIRES_AT:-0}"

  if [ -z "${ML_ACCESS_TOKEN:-}" ] || [ "$now" -ge "$expiry" ]; then
    ml_refresh_token || return 1
  fi

  export ML_API ML_SITE ML_CLIENT_ID ML_CLIENT_SECRET ML_REDIRECT_URI \
         ML_ACCESS_TOKEN ML_REFRESH_TOKEN ML_USER_ID ML_EXPIRES_AT
}

# Authenticated curl with retry on 401 (auto-refresh) and 429/5xx (exponential backoff).
# Usage: ml_curl <url> [extra curl args]
ml_curl() {
  local url="$1"; shift
  local attempt=0 max=3 resp code body
  while [ $attempt -lt $max ]; do
    resp=$(curl -sS -w $'\n%{http_code}' \
      -H "Authorization: Bearer ${ML_ACCESS_TOKEN}" \
      "$@" "$url")
    code=$(printf '%s' "$resp" | tail -1)
    body=$(printf '%s' "$resp" | sed '$d')
    case "$code" in
      200|201|204) printf '%s' "$body"; return 0 ;;
      401)         ml_refresh_token || return 1 ;;
      429|5*)      sleep $(( 2 ** attempt )) ;;
      *)           echo "ml_curl: HTTP $code: $body" >&2; return 1 ;;
    esac
    attempt=$(( attempt + 1 ))
  done
  echo "ml_curl: gave up after $max attempts" >&2
  return 1
}
