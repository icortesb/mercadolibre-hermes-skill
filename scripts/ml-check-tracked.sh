#!/usr/bin/env bash
# mercadolibre/scripts/ml-check-tracked.sh
#
# Walks ~/.hermes/mercadolibre/tracked.json, fetches the current price for each
# tracked item, appends the snapshot to history, and prints an alert line when
# the price has dropped by at least the per-item threshold percentage.
#
# Cron-friendly: writes alerts to stdout, errors to stderr.
#
# Pre-requisites: ml_load_token must have been called (or ML_ACCESS_TOKEN is
# not required for public item lookups). This script uses unauthenticated GET
# /items/:id which is sufficient for price tracking.

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

if [ ! -f "$TRACK_FILE" ]; then
  echo "No tracked items at $TRACK_FILE" >&2
  exit 0
fi

# Empty object → nothing to do
COUNT=$(jq 'length' "$TRACK_FILE")
[ "$COUNT" -eq 0 ] && exit 0

NOW=$(date +%s)
TMP="${TRACK_FILE}.tmp.$$"
cp "$TRACK_FILE" "$TMP"

for ID in $(jq -r 'keys[]' "$TMP"); do
  RESP=$(curl -sS "$ML_API/items/${ID}") || continue
  CURRENT=$(echo "$RESP" | jq -r '.price // empty')

  # Item removed / paused / unavailable
  if [ -z "$CURRENT" ] || [ "$CURRENT" = "null" ]; then
    STATUS=$(echo "$RESP" | jq -r '.status // "unknown"')
    TITLE=$(jq -r --arg id "$ID" '.[$id].title' "$TMP")
    echo "INFO: $TITLE ($ID) unavailable (status=$STATUS)"
    continue
  fi

  BASELINE=$(jq -r --arg id "$ID" '.[$id].baseline'      "$TMP")
  THRESHOLD=$(jq -r --arg id "$ID" '.[$id].threshold_pct' "$TMP")
  TITLE=$(jq -r    --arg id "$ID" '.[$id].title'         "$TMP")

  jq --arg id "$ID" --argjson p "$CURRENT" --argjson t "$NOW" \
    '.[$id].history += [{ts:$t, price:$p}] | .[$id].last = $p' \
    "$TMP" > "${TMP}.new" && mv "${TMP}.new" "$TMP"

  DROP=$(awk -v b="$BASELINE" -v c="$CURRENT" 'BEGIN{ if (b<=0) print 0; else printf "%.2f", (b-c)/b*100 }')
  if awk -v d="$DROP" -v t="$THRESHOLD" 'BEGIN{ exit !(d >= t) }'; then
    echo "ALERT $(date -Iseconds)  $TITLE  dropped ${DROP}%  baseline=${BASELINE} now=${CURRENT}  https://mercadolibre.com/p/${ID}"
  fi
done

mv "$TMP" "$TRACK_FILE"
