---
name: mercadolibre
description: "MercadoLibre integration for buyers (catalog search, product price tracking with drop alerts, price history) and sellers (active listings, unanswered questions, competitor comparison via catalog offers, expiration alerts) using the official REST API and OAuth2. Works on non-validated apps via the catalog/product endpoints."
version: 1.1.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [MercadoLibre, E-commerce, OAuth2, Price-Tracking, Sellers, Buyers, API, LATAM]
    related_skills: []
---

# MercadoLibre Integration

This skill lets the agent work with MercadoLibre as both **buyer** and **seller** through the official REST API at `https://api.mercadolibre.com`. It handles OAuth2 authentication, automatic token refresh, catalog product search, local price snapshotting with drop alerts, and seller-side monitoring (listings, questions, competitor prices, expiration windows).

Buyer flows use the **catalog/product API** (`/products/*`), which works on any authenticated app — no MercadoLibre validation step needed for typical price-tracking and shopping use cases.

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

All endpoints require `Authorization: Bearer ${ML_ACCESS_TOKEN}`. Even reads that used to be public (search, item details) are now gated since the 2024 MercadoLibre API hardening.

> ### Heads-up: non-validated apps have catalog restrictions
>
> A freshly-created MercadoLibre app can hit `/users/me`, `/users/$ID/items/...` (your own data), and the **catalog/product API** (`/products/*`) — but **`/items/{id}` and `/sites/$SITE/search` return `403 access_denied` until the app is validated** by MercadoLibre. For most buyer flows the catalog API is actually a better choice (it aggregates all sellers for a product, exposes a `buy_box_winner.price`, and keeps the same ID even when individual listings come and go). The recipes below default to `/products/*`. If your app is validated and you want item-level data, see "App validation" near the end.

---

## Buyer flows (catalog-based, work on any app)

### Search the catalog

```bash
source skills/mercadolibre/scripts/ml-env.sh && ml_load_token
QUERY="playstation 5"
SITE="${ML_SITE:-MLA}"
Q=$(printf %s "$QUERY" | jq -sRr @uri)

curl -s -H "Authorization: Bearer $ML_ACCESS_TOKEN" \
  "$ML_API/products/search?site_id=${SITE}&status=active&q=${Q}&limit=10" \
  | jq '.results[] | {id, name, domain_id}'
```

The catalog `id` (a.k.a. `catalog_product_id`) is what `/p/MLA...` URLs use on the website.

Common filters:

- `&domain_id=MLA-CELLPHONES` — narrows to a domain (categories aren't used here; domain IDs are)
- `&status=active` — only currently-sellable products (recommended default)
- `&limit=50&offset=50` — pagination (max `limit` is 50)
- `&attribute_id=BRAND&attribute_value=Apple` — filter by attribute

### Get a product (with the current best price)

```bash
PRODUCT_ID="MLA63094449"     # from the website URL: /p/MLA63094449
curl -s -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/${PRODUCT_ID}" \
  | jq '{
      id,
      name,
      status,
      buy_box_price:    .buy_box_winner.price,
      buy_box_currency: .buy_box_winner.currency_id,
      buy_box_seller:   .buy_box_winner.seller_id,
      buy_box_item:     .buy_box_winner.item_id,
      offers:           .offers_count,
      min_price:        .min_price,
      max_price:        .max_price
    }'
```

`buy_box_winner.price` is the headline price shown on the product page — that's what we track for simple products.

> **Heads up for multi-variant products**: products with `pickers` (size/colour/capacity selectors — e.g. a PS5 with capacity & colour pickers) have **no buy-box winner** at the parent level (`.buy_box_winner == null`, `.min_price == null`). For those, query the offers directly and take the cheapest:
>
> ```bash
> curl -s -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/$PRODUCT_ID/items?limit=50" \
>   | jq -r '[.results[].price | select(. != null)] | min'
> ```
>
> The bundled `ml_product_price` helper does this fallback automatically — see below.

### Resolve a product's current price (helper)

The `ml_product_price` function in `ml-env.sh` returns the current price for a product, falling back from `buy_box_winner.price` to `min(offers)` when the product has variants:

```bash
source skills/mercadolibre/scripts/ml-env.sh && ml_load_token
PRICE=$(ml_product_price MLA63094449)
echo "$PRICE"
# → 1159999  (the cheapest active offer)
```

Use this anywhere you'd otherwise hand-roll the buy-box lookup; it makes the tracking and alerting recipes work uniformly across simple and multi-variant products.

### Resolve a product ID from a MercadoLibre URL

```bash
# Accepts: https://www.mercadolibre.com.ar/.../p/MLA63094449#... → MLA63094449
url_to_product_id() {
  printf %s "$1" | grep -oE '/p/(MLA|MLB|MLM|MLC|MCO|MLU)[0-9]+' | head -1 | sed 's|/p/||'
}

# Example:
url_to_product_id "https://www.mercadolibre.com.ar/sony-playstation-5/p/MLA63094449#x=1"
# → MLA63094449
```

If the user shares an `articulo.mercadolibre.com.ar/MLA-XXXX-...` URL instead (which points to a specific seller's listing, not the catalog), they may need to open the listing and follow "Ver publicación del catálogo" to get the `/p/MLA...` URL.

### Track a product's price (local snapshots, drop alerts)

MercadoLibre's API does **not** expose historical prices. We snapshot the `buy_box_winner.price` locally and compare on each check.

**Add a product to tracking:** (uses `ml_product_price`, which handles multi-variant products automatically)

```bash
source skills/mercadolibre/scripts/ml-env.sh && ml_load_token

mkdir -p ~/.hermes/mercadolibre
TRACK_FILE=~/.hermes/mercadolibre/tracked.json
[ ! -f "$TRACK_FILE" ] && echo '{}' > "$TRACK_FILE"

PRODUCT_ID="MLA63094449"
THRESHOLD_PCT=10        # alert when price drops at least this much vs. baseline

TITLE=$(curl -s -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/${PRODUCT_ID}" | jq -r .name)
PRICE=$(ml_product_price "$PRODUCT_ID")

if [ -z "$PRICE" ]; then
  echo "No active offers for ${PRODUCT_ID}; cannot establish baseline" >&2
  exit 1
fi

NOW=$(date +%s)
jq --arg id "$PRODUCT_ID" \
   --arg title "$TITLE" \
   --argjson price "$PRICE" \
   --argjson pct "$THRESHOLD_PCT" \
   --argjson ts "$NOW" \
   '.[$id] = {title:$title, baseline:$price, last:$price, threshold_pct:$pct, history:[{ts:$ts, price:$price}]}' \
   "$TRACK_FILE" > "$TRACK_FILE.tmp" && mv "$TRACK_FILE.tmp" "$TRACK_FILE"

echo "Tracking $TITLE @ $PRICE (alert if drops ≥${THRESHOLD_PCT}%)"
```

**Check tracked products and emit alerts:** use the bundled `scripts/ml-check-tracked.sh` (it loops, snapshots, and prints `ALERT ...` lines). Cron-friendly.

For automatic background alerts (every 4 hours):

```cron
0 */4 * * * source $HOME/.hermes/skills/mercadolibre/scripts/ml-env.sh && ml_load_token && bash $HOME/.hermes/skills/mercadolibre/scripts/ml-check-tracked.sh >> $HOME/.hermes/mercadolibre/alerts.log 2>&1
```

### View price history of a tracked product

```bash
PRODUCT_ID="MLA63094449"
jq -r --arg id "$PRODUCT_ID" \
  '.[$id].history[] | "\(.ts | strftime("%Y-%m-%d %H:%M"))  \(.price)"' \
  ~/.hermes/mercadolibre/tracked.json
```

### Untrack / list tracked products

```bash
# List
jq 'to_entries | map({id:.key, title:.value.title, baseline:.value.baseline, last:.value.last})' \
  ~/.hermes/mercadolibre/tracked.json

# Remove
PRODUCT_ID="MLA63094449"
TRACK_FILE=~/.hermes/mercadolibre/tracked.json
jq "del(.\"$PRODUCT_ID\")" "$TRACK_FILE" > "$TRACK_FILE.tmp" && mv "$TRACK_FILE.tmp" "$TRACK_FILE"
```

### List offers for a product (compare sellers)

```bash
PRODUCT_ID="MLA63094449"
curl -s -H "Authorization: Bearer $ML_ACCESS_TOKEN" \
  "$ML_API/products/${PRODUCT_ID}/items?limit=10" \
  | jq '.results[] | {item_id, price, seller_id, condition, listing_type_id}'
```

Useful when the user wants to see who else is selling the same product and at what price (the seller_id resolves to a nickname via `/users/${seller_id}`).

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

If your listing belongs to a catalog product (most new-condition listings do), the cleanest comparison is via the product's offers list — every other seller on the same catalog product, ranked by price:

```bash
ml_load_token
MY_ITEM="MLA123456789"

INFO=$(curl -s -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/items/${MY_ITEM}")
MY_PRICE=$(echo "$INFO"   | jq -r .price)
MY_TITLE=$(echo "$INFO"   | jq -r .title)
PRODUCT_ID=$(echo "$INFO" | jq -r '.catalog_product_id // empty')

if [ -z "$PRODUCT_ID" ]; then
  echo "Listing $MY_ITEM isn't bound to a catalog product — comparison falls back to keyword search (requires validated app)." >&2
  exit 1
fi

echo "Your listing: $MY_TITLE @ $MY_PRICE  (catalog: $PRODUCT_ID)"
echo

curl -s -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/${PRODUCT_ID}/items?limit=20" \
  | jq --argjson mine "$MY_PRICE" --arg myid "$MY_ITEM" \
      '.results[]
        | select(.item_id != $myid)
        | {item_id, price, seller_id, diff_pct: (((.price - $mine) / $mine) * 100 | floor)}'
```

Negative `diff_pct` = competitor is cheaper, positive = yours is cheaper.

For non-catalog listings (used items, unique handmade pieces) you need keyword-based search, which requires app validation.

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
| 403  | `forbidden` (on POST/PUT) | App missing `write` scope | Re-authorize with proper scopes |
| 403  | `access_denied` (on `/items/{id}` or `/sites/.../search`) | App not validated for catalog access | Use `/products/*` instead, or request app validation (see below) |
| 404  | `not_found` | Item removed, or wrong site code | Verify ID and `ML_SITE` |
| 429  | `too_many_requests` | Rate limited | Exponential backoff |
| 5xx  | — | MercadoLibre transient | Retry with backoff |

---

## App validation (optional — only needed for `/items/*` and keyword search)

A freshly-created MercadoLibre app can use:

- All authentication endpoints (token exchange, refresh)
- All data scoped to the app owner (`/users/me`, `/users/$ID/items/search`, `/my/received_questions/...`, `/orders/search?seller=$ID`)
- The full **catalog/product API** (`/products/search`, `/products/{id}`, `/products/{id}/items`)

But these endpoints are restricted until the app is **validated** by MercadoLibre:

- `/items/{item_id}` for items not owned by the app owner
- `/sites/$SITE/search?q=...` (keyword search across listings)
- Various detailed catalog browsing endpoints

For most "agent-as-personal-shopper" use cases, the catalog API is enough — it covers price tracking, product lookup, and seller comparison.

If you do need item-level access (e.g. tracking used items that aren't in the catalog), request validation:

1. Go to https://developers.mercadolibre.com.ar/devcenter/applications
2. Open your app → look for "Solicitar validación" or "Publicar app"
3. Submit a use-case description ("personal AI agent for own buyer/seller workflow" is legitimate)
4. Approval typically takes 1–3 business days

While the request is pending, the catalog-based recipes in this skill continue to work as-is.

---

## Privacy and safety

- `~/.hermes/.env` contains long-lived refresh tokens — keep it `chmod 600`
- Never paste access/refresh tokens into chat history, logs, or shared scripts
- On shared workstations, prefer `git credential.helper cache` semantics over plaintext storage
- The `read` scope alone is enough for buyer search/price tracking; only request `write` if the user wants to answer questions, edit listings, or modify bookmarks
- The user can revoke the app at https://www.mercadolibre.com.ar/apps/applications at any time

## Operating as an agent (Hermes / Telegram-driven)

When invoked from a chat interface, the agent should always source the env first and then dispatch to one of the high-level helpers exposed by `ml-env.sh`. These functions are idempotent, return a single human-readable line on stdout, and take care of cron management, file locking, and price-fallback logic so the agent can stay declarative.

```bash
source ~/.hermes/skills/mercadolibre/scripts/ml-env.sh && ml_load_token
```

### Intent → command mapping

| User intent (Telegram message) | Helper to call |
|--------------------------------|----------------|
| "track this URL" (or paste a `https://...mercadolibre.com.ar/.../p/MLA...` link) | `ml_track_url "<url>" [threshold_pct]` |
| "track this with X% alert" | `ml_track_url "<url>" X` |
| "stop tracking MLAxxxxx" / "untrack MLAxxxxx" | `ml_untrack MLAxxxxx` |
| "what am I tracking?" / "list tracked" | `ml_list_tracked` (returns JSON) |
| "any alerts?" / "check alerts" | `ml_pending_alerts [seconds]` |
| "check now" (force a price check) | `bash ~/.hermes/skills/mercadolibre/scripts/ml-check-tracked.sh` |
| "current price of MLAxxxxx" | `ml_product_price MLAxxxxx` |
| "search the catalog for X" | `curl -s -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/search?site_id=$ML_SITE&status=active&q=$(printf %s 'X' \| jq -sRr @uri)&limit=10" \| jq '.results[]\|{id,name,domain_id}'` |

After mutating helpers (`ml_track_url`, `ml_untrack`), relay the helper's stdout to the user verbatim — it's already phrased for human consumption.

### Cron lifecycle

- **First call to `ml_track_url`** installs the cron line (default: every 4 hours) tagged with `# mercadolibre-skill`.
- **Last call to `ml_untrack`** (when zero items remain) removes that cron line.
- Manual control: `ml_install_cron "0 */4 * * *"` and `ml_remove_cron`.

The cron job sources `ml-env.sh`, calls `ml_load_token` (auto-refreshing the access token), then runs the checker.

### Delivering alerts to Telegram

**Pull mode (default)** — alerts are appended to `~/.hermes/mercadolibre/alerts.log`. When the user asks "any alerts?" via Telegram, the agent calls `ml_pending_alerts` and replies with the output.

**Push mode (opt-in)** — when the agent has access to the user's Telegram bot credentials, append them to `~/.hermes/.env` so `ml-env.sh` exports them; the checker will then push every new alert directly to the chat via the Telegram Bot API:

```bash
cat >> ~/.hermes/.env <<'EOF'
TELEGRAM_BOT_TOKEN=123456789:AAEabcdef...
TELEGRAM_CHAT_ID=-1001234567890
EOF
chmod 600 ~/.hermes/.env
```

The bot token comes from `@BotFather`; the chat_id can be looked up by sending a message to the bot and reading `https://api.telegram.org/bot<TOKEN>/getUpdates`. Both stay on the user's machine — the skill never transmits them anywhere except Telegram itself.

If the agent doesn't know the bot credentials, leave push mode disabled and stay on pull — it's just as functional, only less proactive.

---

## Quick reference

| Task | Command |
|------|---------|
| First-time auth | `bash skills/mercadolibre/scripts/ml-oauth.sh` |
| Install deps | `bash skills/mercadolibre/scripts/install-deps.sh` |
| Load + refresh token | `source skills/mercadolibre/scripts/ml-env.sh && ml_load_token` |
| Force refresh | `ml_refresh_token` |
| Track from URL or ID | `ml_track_url <url\|id> [pct]` |
| Untrack | `ml_untrack <id>` |
| List tracked | `ml_list_tracked` |
| Pending alerts (last 24h) | `ml_pending_alerts [seconds]` |
| Current price (with fallback) | `ml_product_price <id>` |
| Install / remove cron | `ml_install_cron` / `ml_remove_cron` |
| Catalog search | `curl -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/search?site_id=$ML_SITE&status=active&q=..."` |
| Product details | `curl -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/$PRODUCT_ID"` |
| Sellers offering a product | `curl -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/$PRODUCT_ID/items"` |
| My profile | `curl -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/users/me"` |
| My active listings | `curl -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/users/$ML_USER_ID/items/search?status=active"` |
| Unanswered questions | `curl -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/my/received_questions/search?status=UNANSWERED"` |
| Answer a question | `POST $ML_API/answers` with `{question_id, text}` |
| Check tracked + alert | `bash skills/mercadolibre/scripts/ml-check-tracked.sh` |
