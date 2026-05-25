# mercadolibre — Hermes Agent skill

Integrate MercadoLibre into Hermes so the agent can act as a **buyer** (search, price tracking with drop alerts, price history) and as a **seller** (active-listings overview, unanswered questions, competitor price comparison, expiration alerts).

Covers MercadoLibre Argentina, Brazil, Mexico, Chile, Colombia, and Uruguay (any site that uses the public API at `https://api.mercadolibre.com`).

## Install

Copy the folder into your Hermes skills directory:

```bash
cp -r mercadolibre ~/.hermes/skills/
```

Or symlink it during development:

```bash
ln -s "$(pwd)/mercadolibre" ~/.hermes/skills/mercadolibre
```

Make the helper scripts executable:

```bash
chmod +x ~/.hermes/skills/mercadolibre/scripts/*.sh
```

## Configure

1. Create an app at https://developers.mercadolibre.com.ar/devcenter
   - Pick any name (e.g. `hermes-agent`)
   - Redirect URI: `https://localhost:8080/callback` (any valid HTTPS URL works — no server needed)
   - Scopes: `read`, `write`, `offline_access`
2. Copy the App ID and Secret Key into `~/.hermes/.env`:

   ```bash
   cp .env.example ~/.hermes/.env
   chmod 600 ~/.hermes/.env
   $EDITOR ~/.hermes/.env       # paste your App ID + Secret + pick ML_SITE
   ```

3. Run the one-shot OAuth helper to authorize the app and persist tokens:

   ```bash
   bash ~/.hermes/skills/mercadolibre/scripts/ml-oauth.sh
   ```

   The script prints an authorization URL, asks the user to open it in a browser, then paste back the redirected URL. It extracts the `code`, exchanges it for tokens, and writes everything to `~/.hermes/.env`.

## Use

Once configured, ask Hermes things like:

- "Find the cheapest iPhone 15 Pro 256GB on MercadoLibre Argentina"
- "Track this listing and alert me if it drops 15%: https://articulo.mercadolibre.com.ar/MLA-..."
- "Show me the price history of that AirPods listing I've been watching"
- "What unanswered questions do I have on my listings?"
- "Which of my listings expire in the next 7 days?"
- "How does my price for MLA123456789 compare to similar listings?"

Hermes will load `SKILL.md` automatically when these intents come up.

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Agent-facing instructions (Hermes loads this) |
| `README.md` | This file — install & configure for humans |
| `.env.example` | Config template, copy to `~/.hermes/.env` |
| `scripts/ml-env.sh` | Source-able token loader + auto-refresh |
| `scripts/ml-oauth.sh` | Interactive first-time OAuth flow |
| `scripts/ml-check-tracked.sh` | Cron-friendly tracked-items checker (alerts on price drops) |

Tracking state is stored at `~/.hermes/mercadolibre/tracked.json`.

## Dependencies

- `curl` — required
- `jq`   — required, parses every API response
- `bash` 4+ (for `ml-oauth.sh`'s associative array of auth hosts)
- GNU `date` on Linux or BSD `date` on macOS — both supported

## Automation (optional)

Add to crontab to get periodic alerts:

```cron
# Check tracked items for price drops every 4 hours
0 */4 * * * source $HOME/.hermes/skills/mercadolibre/scripts/ml-env.sh && ml_load_token && \
  bash $HOME/.hermes/skills/mercadolibre/scripts/ml-check-tracked.sh \
  >> $HOME/.hermes/mercadolibre/alerts.log 2>&1

# Notify when seller has unanswered questions (9am–9pm)
0 9-21 * * * source $HOME/.hermes/skills/mercadolibre/scripts/ml-env.sh && ml_load_token && \
  COUNT=$(curl -s -H "Authorization: Bearer $ML_ACCESS_TOKEN" \
    "$ML_API/my/received_questions/search?status=UNANSWERED" | jq -r '.total // 0') && \
  [ "$COUNT" -gt 0 ] && notify-send "MercadoLibre" "$COUNT unanswered question(s)"
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `400 invalid_grant` on refresh | refresh_token was rotated and not persisted | Re-run `ml-oauth.sh` |
| `400 invalid_client` | wrong client_id or secret | Check `~/.hermes/.env` |
| `401 invalid_token` after refresh | clock skew, or stale `ML_EXPIRES_AT` | `ml_refresh_token` once, retry |
| `403 forbidden` on POST/PUT | app missing `write` scope | Re-authorize with proper scopes |
| `429 too_many_requests` | rate limited (~1000 req/h) | Exponential backoff; see `ml_curl` in SKILL.md |
| `404 not_found` on item | wrong `ML_SITE`, or item removed | Verify ID and site code |

To revoke the app entirely: https://www.mercadolibre.com.ar/apps/applications

## License

MIT
