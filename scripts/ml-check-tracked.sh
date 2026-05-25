#!/usr/bin/env bash
# mercadolibre/scripts/ml-check-tracked.sh
#
# Walks ~/.hermes/mercadolibre/tracked.json, fetches the current buy-box price
# for each tracked catalog product, appends the snapshot to history, and prints
# an ALERT line when the price has dropped by at least the per-product threshold.
#
# Cron-friendly: alerts on stdout, errors on stderr.
#
# Prerequisite: a valid ML_ACCESS_TOKEN in the environment. The /products/ API
# requires authentication even for reads. Run via:
#
#   source ~/.hermes/skills/mercadolibre/scripts/ml-env.sh && ml_load_token && \
#     bash ~/.hermes/skills/mercadolibre/scripts/ml-check-tracked.sh

set -euo pipefail

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required tool: $cmd" >&2
    echo "  Run: bash $(dirname "$0")/install-deps.sh" >&2
    exit 1
  }
done

ML_API="${ML_API:-https://api.mercadolibre.com}"
TRACK_DIR="${TRACK_DIR:-$HOME/.hermes/mercadolibre}"
TRACK_FILE="${TRACK_FILE:-$TRACK_DIR/tracked.json}"

if [ -z "${ML_ACCESS_TOKEN:-}" ]; then
  echo "ML_ACCESS_TOKEN not set — source scripts/ml-env.sh and call ml_load_token first" >&2
  exit 1
fi

if [ ! -f "$TRACK_FILE" ]; then
  echo "No tracked items at $TRACK_FILE" >&2
  exit 0
fi

COUNT=$(jq 'length' "$TRACK_FILE")
[ "$COUNT" -eq 0 ] && exit 0

NOW=$(date +%s)
TMP="${TRACK_FILE}.tmp.$$"
cp "$TRACK_FILE" "$TMP"

for ID in $(jq -r 'keys[]' "$TMP"); do
  RESP=$(curl -sS -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/${ID}") || continue
  CURRENT=$(echo "$RESP" | jq -r '.buy_box_winner.price // empty')

  # Fall back to min offer price if the product has pickers/variants (buy_box null)
  if [ -z "$CURRENT" ] || [ "$CURRENT" = "null" ]; then
    CURRENT=$(curl -sS -H "Authorization: Bearer $ML_ACCESS_TOKEN" "$ML_API/products/${ID}/items?limit=50" \
      | jq -r '[.results[].price | select(. != null)] | if length == 0 then empty else min end')
  fi

  if [ -z "$CURRENT" ] || [ "$CURRENT" = "null" ]; then
    STATUS=$(echo "$RESP" | jq -r '.status // "unknown"')
    TITLE=$(jq -r --arg id "$ID" '.[$id].title' "$TMP")
    echo "INFO: $TITLE ($ID) no offers available (status=$STATUS)"
    continue
  fi

  BASELINE=$(jq -r --arg id "$ID"  '.[$id].baseline'      "$TMP")
  THRESHOLD=$(jq -r --arg id "$ID" '.[$id].threshold_pct' "$TMP")
  TITLE=$(jq -r    --arg id "$ID"  '.[$id].title'         "$TMP")

  jq --arg id "$ID" --argjson p "$CURRENT" --argjson t "$NOW" \
    '.[$id].history += [{ts:$t, price:$p}] | .[$id].last = $p' \
    "$TMP" > "${TMP}.new" && mv "${TMP}.new" "$TMP"

  DROP=$(awk -v b="$BASELINE" -v c="$CURRENT" 'BEGIN{ if (b<=0) print 0; else printf "%.2f", (b-c)/b*100 }')
  if awk -v d="$DROP" -v t="$THRESHOLD" 'BEGIN{ exit !(d >= t) }'; then
    echo "ALERT $(date -Iseconds)  $TITLE  dropped ${DROP}%  baseline=${BASELINE} now=${CURRENT}  https://www.mercadolibre.com.ar/p/${ID}"
  fi
done

mv "$TMP" "$TRACK_FILE"
