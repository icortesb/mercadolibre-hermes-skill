---
name: mercadolibre
description: "MercadoLibre integration for buyers (search, price tracking with drop alerts, price history) and sellers (active listings, unanswered questions, competitor comparison, expiration alerts) using the official REST API and OAuth2."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [MercadoLibre, E-commerce, OAuth2, Price-Tracking, Sellers, Buyers, API, LATAM]
    related_skills: []
---

# MercadoLibre Integration

This skill lets the agent work with MercadoLibre as both **buyer** and **seller** through the official REST API at `https://api.mercadolibre.com`. It handles OAuth2 authentication, automatic token refresh, product search, local price snapshotting with drop alerts, and seller-side monitoring (listings, questions, competitor prices, expiration windows).

API reference: https://developers.mercadolibre.com.ar

## When to use this skill

- **Buyer flows**: "find the cheapest X", "track this listing and alert me if it drops 15%", "show me the price history of this item I've been watching", "compare prices of Y across sellers"
- **Seller flows**: "summary of my active listings (visits, sold, asked)", "do I have any unanswered questions?", "how do my prices compare to similar listings?", "which of my listings expire in the next 7 days?"

## Region codes (sites)

MercadoLibre is country-specific. Pick the right `site_id`:

| Country | Code | Auth host |
|---------|------|-----------|
| Argentina | `MLA` | `https://auth.mercadolibre.com.ar` |
| Brazil | `MLB` | `https://auth.mercadolivre.com.br` |
| Mexico | `MLM` | `https://auth.mercadolibre.com.mx` |
| Chile | `MLC` | `https://auth.mercadolibre.cl` |
| Colombia | `MCO` | `https://auth.mercadolibre.com.co` |
| Uruguay | `MLU` | `https://auth.mercadolibre.com.uy` |

If the user shares a link, infer the site:
- `articulo.mercadolibre.com.ar` → `MLA`
- `produto.mercadolivre.com.br` → `MLB`
- `articulo.mercadolibre.com.mx` → `MLM`

Otherwise default to `ML_SITE` from `~/.hermes/.env`, or ask.

---

## Authentication (first-time setup)

MercadoLibre uses OAuth2 with **short-lived access tokens (6 hours)** and refresh tokens. Run the full flow once; after that, refresh tokens keep the agent authenticated transparently.

### Step 1 — Create an app at the MercadoLibre Developer portal

Tell the user to:

1. Go to https://developers.mercadolibre.com.ar/devcenter and sign in
2. Click **Create new application**
3. Fill in:
   - **Name**: `hermes-agent` (or anything)
   - **Short name**: `hermes`
   - **Redirect URI**: `https://localhost:8080/callback` (any valid HTTPS URL — no server is required; we read the `code` from the redirected URL bar)
   - **Scopes**: `read`, `write`, `offline_access`
4. Save and copy the **App ID** (`client_id`) and **Secret Key** (`client_secret`)

### Step 2 — Save app credentials to `~/.hermes/.env`

```bash
mkdir -p ~/.hermes
cat >> ~/.hermes/.env <<'EOF'
ML_CLIENT_ID=YOUR_APP_ID
ML_CLIENT_SECRET=YOUR_CLIENT_SECRET
ML_REDIRECT_URI=https://localhost:8080/callback
ML_SITE=MLA
EOF
chmod 600 ~/.hermes/.env
```

### Step 3 — Authorize the app (one-shot helper)

The easy path: run the interactive helper, which builds the authorization URL, asks the user to paste back the redirected URL, exchanges the `code`, and writes tokens to `~/.hermes/.env`.

```bash
bash skills/mercadolibre/scripts/ml-oauth.sh
```

### Manual flow (if the helper isn't available)

Build the authorization URL using the auth host for the user's site:

```bash
source ~/.hermes/.env
SITE="${ML_SITE:-MLA}"
case "$SITE" in
  MLA) AUTH_HOST=https://auth.mercadolibre.com.ar ;;
  MLB) AUTH_HOST=https://auth.mercadolivre.com.br ;;
  MLM) AUTH_HOST=https://auth.mercadolibre.com.mx ;;
  MLC) AUTH_HOST=https://auth.mercadolibre.cl ;;
  MCO) AUTH_HOST=https://auth.mercadolibre.com.co ;;
  MLU) AUTH_HOST=https://auth.mercadolibre.com.uy ;;
esac

REDIRECT_ENC=$(printf %s "$ML_REDIRECT_URI" | jq -sRr @uri)
echo "Open in browser:"
echo "$AUTH_HOST/authorization?response_type=code&client_id=${ML_CLIENT_ID}&redirect_uri=${REDIRECT_ENC}"
```

The user logs in, grants access, and is redirected to `<redirect_uri>?code=TG-XXXXXX...`. The browser will show a "can't reach this page" error — that's expected. **Copy the entire URL from the address bar** and extract the `code` query parameter.

Exchange the code for tokens:

```bash
CODE="<paste here>"
RESP=$(curl -fsS -X POST https://api.mercadolibre.com/oauth/token \
  -H "Accept: application/json" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code" \
  -d "client_id=${ML_CLIENT_ID}" \
  -d "client_secret=${ML_CLIENT_SECRET}" \
  -d "code=${CODE}" \
  -d "redirect_uri=${ML_REDIRECT_URI}")
echo "$RESP" | jq .
```

Expected response:
```json
{
  "access_token":   "APP_USR-1234...",
  "token_type":     "Bearer",
  "expires_in":     21600,
  "scope":          "offline_access read write",
  "user_id":        12345678,
  "refresh_token":  "TG-abcd..."
}
```

Persist the values to `~/.hermes/.env`:

```bash
ACCESS=$(echo "$RESP" | jq -r .access_token)
REFRESH=$(echo "$RESP" | jq -r .refresh_token)
USER_ID=$(echo "$RESP" | jq -r .user_id)
EXPIRES_AT=$(( $(date +%s) + $(echo "$RESP" | jq -r .expires_in) - 60 ))

# Strip any previous values, then append
sed -i.bak -E '/^ML_(ACCESS_TOKEN|REFRESH_TOKEN|USER_ID|EXPIRES_AT)=/d' ~/.hermes/.env
cat >> ~/.hermes/.env <<EOF
ML_ACCESS_TOKEN=${ACCESS}
ML_REFRESH_TOKEN=${REFRESH}
ML_USER_ID=${USER_ID}
ML_EXPIRES_AT=${EXPIRES_AT}
EOF
chmod 600 ~/.hermes/.env
```

> **Important:** Each refresh issues a **new** refresh_token and **invalidates the previous one**. Always persist the new value immediately or the next refresh will fail with `invalid_grant`.

---

## Loading credentials (every session)

Before any authenticated API call, source the env helper. It auto-refreshes when the access token has expired:

```bash
source skills/mercadolibre/scripts/ml-env.sh
ml_load_token
# Exports: ML_ACCESS_TOKEN, ML_REFRESH_TOKEN, ML_USER_ID,
#          ML_CLIENT_ID, ML_CLIENT_SECRET, ML_SITE, ML_API
```

The helper:
1. Reads `~/.hermes/.env`
2. If `ML_EXPIRES_AT` is in the past (with a 60s safety buffer), calls `ml_refresh_token`
3. Persists the rotated tokens back to `~/.hermes/.env`
4. Exports everything for the current shell

For unauthenticated buyer-side queries (search, public item details) the access token is **not required** — only set `ML_SITE` and `ML_API`.

---

## Buyer flows

### Search products

```bash
source skills/mercadolibre/scripts/ml-env.sh && ml_load_token
QUERY="iphone 15 pro 256"
SITE="${ML_SITE:-MLA}"
Q=$(printf %s "$QUERY" | jq -sRr @uri)

curl -s "$ML_API/sites/${SITE}/search?q=${Q}&limit=10" \
  | jq '.results[] | {title, price, currency_id, condition, sold_quantity, permalink, id, seller: .seller.nickname}'
```

Common filters (appended as query params):

- `&condition=new` or `condition=used`
- `&sort=price_asc` (cheapest first), `price_desc`, `relevance`
- `&shipping_cost=free`
- `&category=MLA1055`
- `&price=*-50000` (under 50000), `&price=10000-50000` (range)
- `&limit=50&offset=50` (pagination — max `limit` is 50)

### Get item details

```bash
ITEM_ID="MLA123456789"
curl -s "$ML_API/items/${ITEM_ID}" \
  | jq '{id, title, price, original_price, currency_id, available_quantity, sold_quantity, condition, permalink, seller_id, status, date_created, category_id}'
```

To resolve an item from a permalink, extract the ID from the URL (it's the `MLA-...` segment after the last `/`) and strip the dash:

```bash
# https://articulo.mercadolibre.com.ar/MLA-123456789-... → MLA123456789
URL="$1"
ITEM_ID=$(echo "$URL" | grep -oE '(MLA|MLB|MLM|MLC|MCO|MLU)-?[0-9]+' | tr -d '-')
```

### Track a price (local snapshots, drop alerts)

MercadoLibre's API does **not** expose historical prices. To support "alert me if X drops Y%", snapshot prices locally and compare on each check.

**Add an item to tracking:**

```bash
mkdir -p ~/.hermes/mercadolibre
TRACK_FILE=~/.hermes/mercadolibre/tracked.json
[ ! -f "$TRACK_FILE" ] && echo '{}' > "$TRACK_FILE"

ITEM_ID="MLA123456789"
THRESHOLD_PCT=10      # alert when price drops this much vs. baseline

INFO=$(curl -s "$ML_API/items/${ITEM_ID}")
PRICE=$(echo "$INFO" | jq -r .price)
TITLE=$(echo "$INFO" | jq -r .title)
NOW=$(date +%s)

jq --arg id "$ITEM_ID" \
   --arg title "$TITLE" \
   --argjson price "$PRICE" \
   --argjson pct "$THRESHOLD_PCT" \
   --argjson ts "$NOW" \
   '.[$id] = {title:$title, baseline:$price, last:$price, threshold_pct:$pct, history:[{ts:$ts, price:$price}]}' \
   "$TRACK_FILE" > "$TRACK_FILE.tmp" && mv "$TRACK_FILE.tmp" "$TRACK_FILE"

echo "Tracking $TITLE @ $PRICE (alert if drops ≥${THRESHOLD_PCT}%)"
```

**Check tracked items and emit alerts:**

```bash
TRACK_FILE=~/.hermes/mercadolibre/tracked.json
for ID in $(jq -r 'keys[]' "$TRACK_FILE"); do
  CURRENT=$(curl -s "$ML_API/items/${ID}" | jq -r .price)
  [ "$CURRENT" = null ] && continue       # item removed/unavailable

  BASELINE=$(jq -r --arg id "$ID" '.[$id].baseline'      "$TRACK_FILE")
  THRESHOLD=$(jq -r --arg id "$ID" '.[$id].threshold_pct' "$TRACK_FILE")
  TITLE=$(jq -r    --arg id "$ID" '.[$id].title'         "$TRACK_FILE")
  TS=$(date +%s)

  # Append snapshot to history
  jq --arg id "$ID" --argjson p "$CURRENT" --argjson t "$TS" \
    '.[$id].history += [{ts:$t, price:$p}] | .[$id].last = $p' \
    "$TRACK_FILE" > "$TRACK_FILE.tmp" && mv "$TRACK_FILE.tmp" "$TRACK_FILE"

  DROP=$(awk -v b="$BASELINE" -v c="$CURRENT" 'BEGIN{ printf "%.2f", (b-c)/b*100 }')
  if awk -v d="$DROP" -v t="$THRESHOLD" 'BEGIN{ exit !(d >= t) }'; then
    echo "ALERT: $TITLE dropped ${DROP}% (baseline=${BASELINE}, now=${CURRENT}) — https://mercadolibre.com/p/${ID}"
  fi
done
```

For automatic background alerts, schedule via cron (every 4 hours):

```cron
0 */4 * * * source $HOME/.hermes/skills/mercadolibre/scripts/ml-env.sh && ml_load_token && bash $HOME/.hermes/skills/mercadolibre/scripts/ml-check-tracked.sh >> $HOME/.hermes/mercadolibre/alerts.log 2>&1
```

### View price history of a tracked item

```bash
ITEM_ID="MLA123456789"
jq -r --arg id "$ITEM_ID" \
  '.[$id].history[] | "\(.ts | strftime("%Y-%m-%d %H:%M"))  \(.price)"' \
  ~/.hermes/mercadolibre/tracked.json
```

Or visualize as a quick ASCII sparkline using `gnuplot`/`spark` if installed.

### Untrack / list tracked items

```bash
# List
jq 'to_entries | map({id:.key, title:.value.title, baseline:.value.baseline, last:.value.last})' \
  ~/.hermes/mercadolibre/tracked.json

# Remove
ITEM_ID="MLA123456789"
TRACK_FILE=~/.hermes/mercadolibre/tracked.json
jq "del(.\"$ITEM_ID\")" "$TRACK_FILE" > "$TRACK_FILE.tmp" && mv "$TRACK_FILE.tmp" "$TRACK_FILE"
```

### MercadoLibre-native bookmarks (favorites)

These touch the user's actual MercadoLibre account, not our local tracking file:

```bash
ml_load_token
ITEM_ID="MLA123456789"
curl -s -X POST "$ML_API/users/${ML_USER_ID}/bookmarks" \
  -H "Authorization: Bearer ${ML_ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"item_id\":\"${ITEM_ID}\"}"
```

Prefer the local snapshot method for price tracking — it gives you historical data MercadoLibre doesn't expose.

---

## Seller flows

All seller flows require `ml_load_token` first.

### Active listings summary (visits, sold, asked)

```bash
ml_load_token
AUTH="Authorization: Bearer ${ML_ACCESS_TOKEN}"

# Item IDs of active listings
IDS=$(curl -s -H "$AUTH" "$ML_API/users/${ML_USER_ID}/items/search?status=active&limit=50" | jq -r '.results[]')

for ITEM_ID in $IDS; do
  INFO=$(curl -s -H "$AUTH" "$ML_API/items/${ITEM_ID}")
  VISITS=$(curl -s -H "$AUTH" "$ML_API/items/${ITEM_ID}/visits/time_window?last=30&unit=day" | jq -r '.total_visits // 0')
  QUESTIONS=$(curl -s -H "$AUTH" "$ML_API/questions/search?item=${ITEM_ID}&status=UNANSWERED" | jq -r '.total // 0')

  echo "$INFO" | jq --argjson visits "$VISITS" --argjson qs "$QUESTIONS" \
    '{id, title, price, available_quantity, sold_quantity, visits_30d:$visits, unanswered_questions:$qs, stop_time}'
done
```

For more than 50 listings, paginate via `&offset=`.

### Unanswered questions (alerts)

```bash
ml_load_token
curl -s -H "Authorization: Bearer ${ML_ACCESS_TOKEN}" \
  "$ML_API/my/received_questions/search?status=UNANSWERED&limit=50" \
  | jq '.questions[] | {id, date_created, item_id, from_user: .from.id, text}'
```

To answer a question:

```bash
QUESTION_ID="12345678"
ANSWER="Sí, está disponible. ¡Saludos!"
curl -s -X POST "$ML_API/answers" \
  -H "Authorization: Bearer ${ML_ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"question_id\":${QUESTION_ID},\"text\":\"${ANSWER}\"}"
```

Cron-based alert (every hour during business hours):

```cron
0 9-21 * * * source $HOME/.hermes/skills/mercadolibre/scripts/ml-env.sh && ml_load_token && \
  COUNT=$(curl -s -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/my/received_questions/search?status=UNANSWERED" | jq -r '.total // 0') && \
  [ "$COUNT" -gt 0 ] && notify-send "MercadoLibre" "$COUNT unanswered question(s)"
```

### Compare your prices with competitors

For one of your listings, search the same category/keywords and rank competitors by relative price:

```bash
ml_load_token
MY_ITEM="MLA123456789"
SITE="${ML_SITE:-MLA}"

INFO=$(curl -s "$ML_API/items/${MY_ITEM}")
MY_PRICE=$(echo "$INFO" | jq -r .price)
MY_TITLE=$(echo "$INFO" | jq -r .title)
CATEGORY=$(echo "$INFO" | jq -r .category_id)
Q=$(printf %s "$MY_TITLE" | jq -sRr @uri)

echo "Your listing: $MY_TITLE @ $MY_PRICE"
echo

curl -s "$ML_API/sites/${SITE}/search?q=${Q}&category=${CATEGORY}&limit=10" \
  | jq --argjson mine "$MY_PRICE" --arg myid "$MY_ITEM" \
      '.results[] | select(.id != $myid) |
       {title, price, diff_pct: (((.price - $mine) / $mine) * 100 | floor), permalink, seller: .seller.nickname}'
```

A negative `diff_pct` means the competitor is cheaper; positive means yours is cheaper.

### Listings expiring soon

```bash
ml_load_token
AUTH="Authorization: Bearer ${ML_ACCESS_TOKEN}"
DAYS=7
THRESHOLD=$(date -u -d "+${DAYS} days" +%s 2>/dev/null || date -u -v+${DAYS}d +%s)

IDS=$(curl -s -H "$AUTH" "$ML_API/users/${ML_USER_ID}/items/search?status=active&limit=50" | jq -r '.results[]')
for ITEM_ID in $IDS; do
  INFO=$(curl -s -H "$AUTH" "$ML_API/items/${ITEM_ID}")
  STOP=$(echo "$INFO" | jq -r .stop_time)
  STOP_TS=$(date -d "$STOP" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S.000Z" "$STOP" +%s 2>/dev/null)
  [ -z "$STOP_TS" ] && continue
  if [ "$STOP_TS" -lt "$THRESHOLD" ]; then
    echo "$INFO" | jq --arg s "$STOP" '{id, title, price, available_quantity, expires:$s}'
  fi
done
```

To relist an expired listing or extend its duration, use `PUT /items/${ITEM_ID}` with the relevant fields (see MercadoLibre docs — write scope required).

---

## Error handling

### Token expired (401 Unauthorized)

The `ml_load_token` helper handles this automatically. If you bypass the helper and hit a 401, force a refresh and retry:

```bash
source skills/mercadolibre/scripts/ml-env.sh
ml_refresh_token       # forces refresh regardless of ML_EXPIRES_AT
# retry the request
```

If `ml_refresh_token` itself returns `400 invalid_grant` → the refresh_token has been rotated/revoked. The user **must** re-run the full OAuth flow (Step 3 onwards). Common causes:

- The previous refresh response was never persisted (so we still have the old, now-invalid refresh_token)
- The user revoked the app at https://www.mercadolibre.com.ar/apps/applications
- Two parallel processes both refreshed at once

### Rate limiting (429 Too Many Requests)

MercadoLibre limits to ~1000 requests/hour per user. On `HTTP 429` (or `{"message":"too_many_requests"}`):

1. Read the `X-RateLimit-Reset` header if present (epoch seconds when quota resets)
2. Sleep until reset or use exponential backoff (1s, 2s, 4s, 8s, capped at 60s)
3. Retry up to 3 times before giving up

Reusable wrapper:

```bash
ml_curl() {
  # Usage: ml_curl <url> [curl-args...]
  local url="$1"; shift
  local attempt=0 max=3 resp code body
  while [ $attempt -lt $max ]; do
    resp=$(curl -sS -w "\n%{http_code}" -H "Authorization: Bearer ${ML_ACCESS_TOKEN}" "$@" "$url")
    code=$(echo "$resp" | tail -1)
    body=$(echo "$resp" | sed '$d')
    case "$code" in
      200|201|204) echo "$body"; return 0 ;;
      401)         ml_refresh_token || return 1 ;;
      429|5*)      sleep $(( 2 ** attempt )) ;;
      *)           echo "ml_curl: HTTP $code: $body" >&2; return 1 ;;
    esac
    attempt=$(( attempt + 1 ))
  done
  echo "ml_curl: gave up after $max attempts" >&2
  return 1
}
```

### Error response cheat sheet

| HTTP | Body hint | Cause | Action |
|------|-----------|-------|--------|
| 400  | `invalid_grant` | Refresh token rotated/revoked | Re-run OAuth flow |
| 400  | `invalid_client` | Wrong client_id/secret | Check `~/.hermes/.env` |
| 401  | `invalid_token` | Access token expired | `ml_refresh_token`, retry |
| 403  | `forbidden` | Missing scope (need `write` for POST/PUT) | Re-authorize with proper scopes |
| 404  | `not_found` | Item removed, or wrong site code | Verify `ITEM_ID` and `ML_SITE` |
| 429  | `too_many_requests` | Rate limited | Exponential backoff |
| 5xx  | — | MercadoLibre transient | Retry with backoff |

---

## Privacy and safety

- `~/.hermes/.env` contains long-lived refresh tokens — keep it `chmod 600`
- Never paste access/refresh tokens into chat history, logs, or shared scripts
- On shared workstations, prefer `git credential.helper cache` semantics over plaintext storage
- The `read` scope alone is enough for buyer search/price tracking; only request `write` if the user wants to answer questions, edit listings, or modify bookmarks
- The user can revoke the app at https://www.mercadolibre.com.ar/apps/applications at any time

## Quick reference

| Task | Command |
|------|---------|
| First-time auth | `bash skills/mercadolibre/scripts/ml-oauth.sh` |
| Load + refresh token | `source skills/mercadolibre/scripts/ml-env.sh && ml_load_token` |
| Force refresh | `ml_refresh_token` |
| Search | `curl "$ML_API/sites/$ML_SITE/search?q=..."` |
| Item details | `curl "$ML_API/items/$ITEM_ID"` |
| My active listings | `curl -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/users/$ML_USER_ID/items/search?status=active"` |
| Unanswered questions | `curl -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/my/received_questions/search?status=UNANSWERED"` |
| Answer a question | `POST $ML_API/answers` with `{question_id, text}` |
| Track item locally | append entry to `~/.hermes/mercadolibre/tracked.json` |
| Check tracked + alert | `bash skills/mercadolibre/scripts/ml-check-tracked.sh` |
