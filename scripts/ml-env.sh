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
  [ ${#missing[@]} -eq 0 ] && return 0

  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  echo "ml-env: missing tools (${missing[*]}) — auto-installing..." >&2
  if [ -x "${here}/install-deps.sh" ]; then
    bash "${here}/install-deps.sh" >&2 || true
  fi

  # Re-check; bail with a clear message if still missing
  missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v jq   >/dev/null 2>&1 || missing+=(jq)
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ml-env: still missing: ${missing[*]} — install manually (no sudo, no apt?)" >&2
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
  \mv -f "$tmp" "$ML_ENV_FILE"
  chmod 600 "$ML_ENV_FILE"
}

# =====================================================================
# OAuth setup helpers (agent-driven; replace the interactive ml-oauth.sh)
# =====================================================================

# Auth host per MercadoLibre site code.
_ml_auth_host() {
  case "${1:-MLA}" in
    MLA) echo "https://auth.mercadolibre.com.ar" ;;
    MLB) echo "https://auth.mercadolivre.com.br" ;;
    MLM) echo "https://auth.mercadolibre.com.mx" ;;
    MLC) echo "https://auth.mercadolibre.cl"     ;;
    MCO) echo "https://auth.mercadolibre.com.co" ;;
    MLU) echo "https://auth.mercadolibre.com.uy" ;;
    *)   return 1 ;;
  esac
}

# Persist app credentials to the .env. Call before ml_oauth_url.
#   ml_oauth_set CLIENT_ID CLIENT_SECRET [REDIRECT_URI] [SITE]
ml_oauth_set() {
  local cid="$1" csec="$2" redir="${3:-https://www.google.com}" site="${4:-MLA}"
  [ -n "$cid" ] && [ -n "$csec" ] || { _ml_die "ml_oauth_set: pass client_id and client_secret"; return 1; }
  _ml_auth_host "$site" >/dev/null || { _ml_die "unknown site: $site (MLA/MLB/MLM/MLC/MCO/MLU)"; return 1; }
  mkdir -p "$(dirname "$ML_ENV_FILE")"
  touch "$ML_ENV_FILE"; chmod 600 "$ML_ENV_FILE"
  _ml_write_env_var ML_CLIENT_ID     "$cid"
  _ml_write_env_var ML_CLIENT_SECRET "$csec"
  _ml_write_env_var ML_REDIRECT_URI  "$redir"
  _ml_write_env_var ML_SITE          "$site"
  echo "Credentials saved. Next: call ml_oauth_url to get the authorization URL."
}

# Print the MercadoLibre authorization URL for the configured app.
# Send this to the user; after they authorize, they paste back the redirected URL.
ml_oauth_url() {
  _ml_check_deps || return 1
  _ml_read_env   || return 1
  [ -n "${ML_CLIENT_ID:-}" ]    || { _ml_die "ML_CLIENT_ID not set — call ml_oauth_set first"; return 1; }
  [ -n "${ML_REDIRECT_URI:-}" ] || { _ml_die "ML_REDIRECT_URI not set — call ml_oauth_set first"; return 1; }
  local host enc
  host=$(_ml_auth_host "${ML_SITE:-MLA}") || return 1
  enc=$(printf %s "$ML_REDIRECT_URI" | jq -sRr @uri)
  echo "${host}/authorization?response_type=code&client_id=${ML_CLIENT_ID}&redirect_uri=${enc}"
}

# Exchange an authorization code for access/refresh tokens and persist them.
# Accept either the raw code or the full redirected URL — we extract code= either way.
#   ml_oauth_exchange "TG-abc..."  OR  ml_oauth_exchange "https://...?code=TG-abc..."
ml_oauth_exchange() {
  local input="$1" code
  [ -n "$input" ] || { _ml_die "ml_oauth_exchange: pass the code or the full redirected URL"; return 1; }
  if printf %s "$input" | grep -q '://'; then
    code=$(printf %s "$input" | sed -n 's|.*[?&]code=\([^&]*\).*|\1|p')
  else
    code="$input"
  fi
  [ -n "$code" ] || { _ml_die "could not extract code from input"; return 1; }

  _ml_check_deps || return 1
  _ml_read_env   || return 1
  [ -n "${ML_CLIENT_ID:-}" ]     || { _ml_die "ML_CLIENT_ID not set";     return 1; }
  [ -n "${ML_CLIENT_SECRET:-}" ] || { _ml_die "ML_CLIENT_SECRET not set"; return 1; }
  [ -n "${ML_REDIRECT_URI:-}" ]  || { _ml_die "ML_REDIRECT_URI not set";  return 1; }

  local resp
  resp=$(curl -fsS -X POST "$ML_API/oauth/token" \
    -H "Accept: application/json" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code" \
    -d "client_id=${ML_CLIENT_ID}" \
    -d "client_secret=${ML_CLIENT_SECRET}" \
    -d "code=${code}" \
    -d "redirect_uri=${ML_REDIRECT_URI}") || { _ml_die "exchange failed — check the code/credentials"; return 1; }

  local access refresh expires_in user_id
  access=$(echo "$resp"     | jq -r '.access_token  // empty')
  refresh=$(echo "$resp"    | jq -r '.refresh_token // empty')
  expires_in=$(echo "$resp" | jq -r '.expires_in    // empty')
  user_id=$(echo "$resp"    | jq -r '.user_id       // empty')

  if [ -z "$access" ] || [ -z "$refresh" ]; then
    _ml_die "unexpected exchange response: $resp"
    return 1
  fi

  local expires_at=$(( $(date +%s) + expires_in - 60 ))
  _ml_write_env_var ML_ACCESS_TOKEN  "$access"
  _ml_write_env_var ML_REFRESH_TOKEN "$refresh"
  _ml_write_env_var ML_USER_ID       "$user_id"
  _ml_write_env_var ML_EXPIRES_AT    "$expires_at"
  export ML_ACCESS_TOKEN="$access" ML_REFRESH_TOKEN="$refresh" ML_USER_ID="$user_id" ML_EXPIRES_AT="$expires_at"

  echo "Authorized as user $user_id. Tokens written to $ML_ENV_FILE."
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

# Resolve the current price for a catalog product.
# Strategy: prefer .buy_box_winner.price; fall back to the minimum price across
# the product's active offers when the product has pickers/variants (buy_box null).
# Prints just the price number on success; empty string + non-zero on failure.
# Usage: ml_product_price MLA63094449
ml_product_price() {
  local product_id="$1" resp price
  [ -n "$product_id" ] || { echo "ml_product_price: missing product id" >&2; return 1; }
  [ -n "${ML_ACCESS_TOKEN:-}" ] || { echo "ml_product_price: ML_ACCESS_TOKEN not set (call ml_load_token)" >&2; return 1; }

  resp=$(curl -sS -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/${product_id}") || return 1
  price=$(echo "$resp" | jq -r '.buy_box_winner.price // empty')

  if [ -z "$price" ]; then
    # Fall back to min price across active offers
    price=$(curl -sS -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/${product_id}/items?limit=50" \
      | jq -r '[.results // [] | .[].price | select(. != null)] | if length == 0 then empty else min end')
  fi

  [ -n "$price" ] && printf '%s' "$price"
}

# =====================================================================
# Agent-mode helpers: high-level operations Hermes invokes from chat
# =====================================================================
#
# Each function returns 0 on success, non-zero on failure, and prints a
# single human-friendly line on stdout (or the requested data structure)
# so the agent can relay it verbatim to the user.

ML_TRACK_FILE="${ML_TRACK_FILE:-$HOME/.hermes/mercadolibre/tracked.json}"
ML_ALERTS_LOG="${ML_ALERTS_LOG:-$HOME/.hermes/mercadolibre/alerts.log}"
ML_CRON_TAG="# mercadolibre-skill"

_ml_ensure_track_file() {
  mkdir -p "$(dirname "$ML_TRACK_FILE")"
  [ -f "$ML_TRACK_FILE" ] || echo '{}' > "$ML_TRACK_FILE"
}

# Extract a MercadoLibre product ID (e.g. MLA63094449) from a website URL.
# Echoes the ID or returns 1 if not found.
ml_url_to_product_id() {
  local url="$1" id
  id=$(printf %s "$url" | grep -oE '/p/(MLA|MLB|MLM|MLC|MCO|MLU)[0-9]+' | head -1 | sed 's|/p/||')
  [ -n "$id" ] || return 1
  printf %s "$id"
}

# Install the periodic checker cron job. Idempotent — leaves the crontab alone
# if our tag is already present. Default interval: every 4 hours.
#
# Gracefully degrades when the host has no `crontab` binary (typical of minimal
# Docker containers like the Hermes image): prints a hint asking the agent
# (Hermes / similar) to schedule the checker via its own internal scheduler.
ml_install_cron() {
  local interval="${1:-0 */4 * * *}"
  if ! command -v crontab >/dev/null 2>&1; then
    echo "no system cron — schedule this with the agent's internal scheduler:" >&2
    echo "  every: $interval" >&2
    echo "  run:   bash \$HOME/.hermes/skills/mercadolibre/scripts/ml-check-tracked.sh" >&2
    return 0
  fi
  if crontab -l 2>/dev/null | grep -qF "$ML_CRON_TAG"; then
    echo "cron already installed"
    return 0
  fi
  local line="$interval source \$HOME/.hermes/skills/mercadolibre/scripts/ml-env.sh && ml_load_token && bash \$HOME/.hermes/skills/mercadolibre/scripts/ml-check-tracked.sh >> $ML_ALERTS_LOG 2>&1 $ML_CRON_TAG"
  ( crontab -l 2>/dev/null; echo "$line" ) | crontab -
  echo "cron installed ($interval)"
}

# Remove our cron line. Silent no-op if the host has no crontab (assumes the
# agent's internal scheduler is being used instead, which the agent unschedules
# on its own).
ml_remove_cron() {
  if ! command -v crontab >/dev/null 2>&1; then
    echo "no system cron — agent should unschedule the internal job itself" >&2
    return 0
  fi
  if ! crontab -l 2>/dev/null | grep -qF "$ML_CRON_TAG"; then
    echo "no cron to remove"
    return 0
  fi
  crontab -l 2>/dev/null | grep -vF "$ML_CRON_TAG" | crontab -
  echo "cron removed"
}

# Track a product by its MercadoLibre website URL or product_id.
#   ml_track_url <URL_or_PRODUCT_ID> [threshold_pct]
# threshold_pct defaults to 10. Installs the cron automatically if first item.
ml_track_url() {
  local input="$1" threshold="${2:-10}" pid title price now
  [ -n "$input" ] || { echo "ml_track_url: pass a URL or product_id" >&2; return 1; }

  if printf %s "$input" | grep -qE '^(MLA|MLB|MLM|MLC|MCO|MLU)[0-9]+$'; then
    pid="$input"
  else
    pid=$(ml_url_to_product_id "$input") || { echo "ml_track_url: no /p/MLA... in URL" >&2; return 1; }
  fi

  ml_load_token || return 1
  _ml_ensure_track_file

  title=$(curl -sS -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/$pid" | jq -r '.name // empty')
  [ -n "$title" ] || { echo "ml_track_url: product $pid not found" >&2; return 1; }

  price=$(ml_product_price "$pid")
  [ -n "$price" ] || { echo "ml_track_url: no active offers for $pid" >&2; return 1; }

  now=$(date +%s)
  jq --arg id "$pid" --arg t "$title" --argjson p "$price" --argjson pct "$threshold" --argjson ts "$now" \
    '.[$id] = {title:$t, baseline:$p, last:$p, threshold_pct:$pct, history:[{ts:$ts, price:$p}]}' \
    "$ML_TRACK_FILE" > "$ML_TRACK_FILE.tmp" && \mv -f "$ML_TRACK_FILE.tmp" "$ML_TRACK_FILE"

  ml_install_cron >/dev/null
  echo "Tracking '$title' ($pid) @ $price — alert if drops ≥${threshold}%"
}

# Untrack a product. Removes the cron if this was the last item.
#   ml_untrack <PRODUCT_ID>
ml_untrack() {
  local pid="$1"
  [ -n "$pid" ] || { echo "ml_untrack: pass a product_id" >&2; return 1; }
  [ -f "$ML_TRACK_FILE" ] || { echo "nothing tracked"; return 0; }

  local existed
  existed=$(jq -r --arg id "$pid" 'has($id) | tostring' "$ML_TRACK_FILE")
  [ "$existed" = "true" ] || { echo "$pid was not tracked"; return 0; }

  jq --arg id "$pid" 'del(.[$id])' "$ML_TRACK_FILE" > "$ML_TRACK_FILE.tmp" && \mv -f "$ML_TRACK_FILE.tmp" "$ML_TRACK_FILE"

  if [ "$(jq 'length' "$ML_TRACK_FILE")" = "0" ]; then
    ml_remove_cron >/dev/null
    echo "Untracked $pid (was the last one — cron removed)"
  else
    echo "Untracked $pid"
  fi
}

# List currently tracked products as compact JSON.
ml_list_tracked() {
  [ -f "$ML_TRACK_FILE" ] || { echo '[]'; return 0; }
  jq 'to_entries | map({id:.key, title:.value.title, baseline:.value.baseline, last:.value.last, threshold_pct:.value.threshold_pct, drop_pct: (if .value.baseline > 0 then ((.value.baseline - .value.last) / .value.baseline * 100 | floor) else 0 end)})' "$ML_TRACK_FILE"
}

# Build a catalog product URL from an ID and site code. Used as a fallback
# when the API does not return a permalink.
_ml_catalog_url() {
  local id="$1" site="${2:-${ML_SITE:-MLA}}" domain
  case "$site" in
    MLA) domain='mercadolibre.com.ar' ;;
    MLB) domain='mercadolivre.com.br' ;;
    MLM) domain='mercadolibre.com.mx' ;;
    MLC) domain='mercadolibre.cl'     ;;
    MCO) domain='mercadolibre.com.co' ;;
    MLU) domain='mercadolibre.com.uy' ;;
    *)   domain='mercadolibre.com'    ;;
  esac
  printf 'https://www.%s/p/%s' "$domain" "$id"
}

# Search the MercadoLibre catalog and return a compact JSON list of products
# with their current price (buy_box if available, else min(offers)), the
# canonical product URL, and shipping/installments signals. Products without
# an active offer come through with `price: null` and `available: false` —
# the agent should present them separately so the user knows the link will
# show "not available" if clicked.
# Results are in catalog relevance order (correlates with popularity).
#   ml_search "query"      → top 5 results
#   ml_search "query" 10   → top N results (max 50)
ml_search() {
  local query="$1" limit="${2:-5}" site="${ML_SITE:-MLA}"
  [ -n "$query" ] || { echo "ml_search: pass a query" >&2; return 1; }
  ml_load_token || return 1

  local q ids out='[]' info name buybox price permalink available
  local free_ship installments_qty installments_amt mercadopago
  q=$(printf %s "$query" | jq -sRr @uri)
  ids=$(curl -sS -H "Authorization: Bearer $ML_ACCESS_TOKEN" \
    "$ML_API/products/search?site_id=${site}&status=active&q=${q}&limit=${limit}" \
    | jq -r '.results[].id')

  [ -n "$ids" ] || { echo '[]'; return 0; }

  for id in $ids; do
    info=$(curl -sS -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/$id")
    name=$(echo "$info" | jq -r '.name // empty')
    permalink=$(echo "$info" | jq -r '.permalink // empty')
    buybox=$(echo "$info" | jq -r '.buy_box_winner.price // empty')
    if [ -n "$buybox" ]; then
      price="$buybox"
    else
      price=$(curl -sS -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/$id/items?limit=50" \
        | jq -r '[.results // [] | .[].price | select(. != null)] | if length == 0 then empty else min end')
    fi
    if [ -z "$price" ] || [ "$price" = "null" ]; then
      available=false
    else
      available=true
    fi
    free_ship=$(echo "$info"        | jq -r '.buy_box_winner.shipping.free_shipping // false')
    installments_qty=$(echo "$info" | jq -r '.buy_box_winner.installments.quantity // empty')
    installments_amt=$(echo "$info" | jq -r '.buy_box_winner.installments.amount   // empty')
    mercadopago=$(echo "$info"      | jq -r '.buy_box_winner.accepts_mercadopago // false')
    [ -z "$permalink" ] && permalink=$(_ml_catalog_url "$id" "$site")
    out=$(printf '%s' "$out" | jq \
      --arg id "$id" \
      --arg name "$name" \
      --arg url "$permalink" \
      --argjson price "${price:-null}" \
      --argjson available "$available" \
      --argjson free_shipping "$free_ship" \
      --argjson installments_qty "${installments_qty:-null}" \
      --argjson installments_amount "${installments_amt:-null}" \
      --argjson mercadopago "$mercadopago" \
      '. + [{id:$id, name:$name, price:$price, available:$available, url:$url, free_shipping:$free_shipping, installments_qty:$installments_qty, installments_amount:$installments_amount, mercadopago:$mercadopago}]')
  done
  printf '%s' "$out"
}

# Print recent ALERT lines from the log. Default window: 24 hours.
#   ml_pending_alerts [seconds]
ml_pending_alerts() {
  local since="${1:-86400}"
  [ -f "$ML_ALERTS_LOG" ] || { echo "no alerts yet"; return 0; }
  local cutoff
  cutoff=$(date -u -d "-${since} seconds" +%s 2>/dev/null || date -u -v -${since}S +%s 2>/dev/null) || cutoff=0

  awk -v cutoff="$cutoff" '
    /^ALERT / {
      cmd = "date -d \"" $2 "\" +%s 2>/dev/null"
      cmd | getline ts
      close(cmd)
      if (ts == "" || ts >= cutoff) print
    }
  ' "$ML_ALERTS_LOG"
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
