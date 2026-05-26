# mercadolibre — Hermes Agent skill

Turn Hermes into a MercadoLibre shopping assistant and seller-side monitor. Drive everything from chat (Telegram, CLI, web — wherever Hermes is exposed): search the catalog, snapshot product prices, get drop alerts, manage your listings.

Built on the official REST API at `https://api.mercadolibre.com`. Works on a freshly-created MercadoLibre app — buyer flows use the catalog/product endpoints (`/products/*`) which don't require app validation.

Supports MercadoLibre Argentina, Brazil, Mexico, Chile, Colombia, and Uruguay.

---

## Table of contents

- [What it does](#what-it-does)
- [How it works](#how-it-works)
- [Install](#install)
- [Configure](#configure)
- [Use from chat](#use-from-chat)
- [Use from the shell](#use-from-the-shell)
- [Telegram push (optional)](#telegram-push-optional)
- [Files & layout](#files--layout)
- [Dependencies](#dependencies)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## What it does

**Buyer-side (no app validation needed)**

- Search the catalog by free-text query, return top N products with current prices
- Look up any catalog product by ID (or by parsing a MercadoLibre URL)
- Snapshot product prices locally, build a price history
- Alert when a tracked product drops by a configurable percentage (default 10%)
- List all active offers for a catalog product (price comparison across sellers)

**Seller-side (uses your own listings)**

- Summary of your active listings (visits, sold quantity, unanswered questions, expiration)
- List unanswered customer questions; answer them
- Compare your listing's price against other sellers of the same catalog product
- Find listings that expire within N days

**Authentication**

- One-shot OAuth2 flow stored in `~/.hermes/.env`
- Automatic access-token refresh (tokens last 6 hours; refresh tokens rotate on every use and are persisted atomically)
- Pre-flight dependency check for `curl` and `jq` with an auto-installer

**Operational**

- Self-managed cron: the periodic price-checker is installed when you track your first item and removed when you untrack the last one
- Optional direct Telegram push of alerts (in addition to the local alert log)

---

## How it works

```
┌────────────────────┐          ┌────────────────────────┐
│   You (Telegram)   │  chat    │      Hermes Agent      │
│                    │ ───────▶ │  (reads SKILL.md, runs │
└────────────────────┘          │   ml_* helpers)        │
                                └─────────┬──────────────┘
                                          │  bash/curl
                                          ▼
                ┌───────────────────────────────────────────┐
                │  ~/.hermes/skills/mercadolibre/scripts/   │
                │   ├─ ml-env.sh        (sourced helpers)   │
                │   ├─ ml-oauth.sh      (one-shot setup)    │
                │   ├─ ml-check-tracked.sh  (cron target)   │
                │   └─ install-deps.sh                      │
                └─────────────────────┬─────────────────────┘
                                      │  HTTPS + OAuth2
                                      ▼
                          ┌─────────────────────────┐
                          │  api.mercadolibre.com   │
                          └─────────────────────────┘
                                      │
                  cron every 4h ──────┘
                  writes ALERTs to ~/.hermes/mercadolibre/alerts.log
                  (and pushes to Telegram if configured)
```

The agent never needs to call MercadoLibre directly — it only calls the helper functions in `ml-env.sh`, which take care of authentication, retries, token refresh, price-fallback for multi-variant products, and crontab management.

---

## Install

### Recommended (Hermes agent)

Ask your agent to install it for you. From Telegram (or any Hermes interface):

> Install the mercadolibre skill from https://github.com/icortesb/mercadolibre-hermes-skill

Hermes uses `skill_manage` to clone the repo into the right directory inside its container with correct ownership. After that, ask the agent to set up OAuth and it will walk you through it conversationally — no SSH or manual config required (see [Use from chat](#use-from-chat)).

### Manual (bare metal / no agent)

```bash
mkdir -p ~/.hermes/skills
cd ~/.hermes/skills
git clone https://github.com/icortesb/mercadolibre-hermes-skill mercadolibre
chmod +x mercadolibre/scripts/*.sh
```

Runtime dependencies (`curl`, `jq`) **install automatically on first use** — `ml-env.sh` detects missing tools and runs `install-deps.sh` itself. If your environment can't install packages automatically (no sudo, locked-down container), pre-install manually:

```bash
bash ~/.hermes/skills/mercadolibre/scripts/install-deps.sh
```

Supported package managers: `apt`, `dnf`, `yum`, `apk`, `pacman`, `zypper`, `brew`. As a fallback, install `curl` and `jq` by other means — e.g. a static `jq` binary from https://jqlang.github.io/jq/download/.

---

## Configure

### 1. Create a MercadoLibre app

1. Sign in at https://developers.mercadolibre.com.ar/devcenter
2. Click **Create new application**
3. Settings:
   - **Name**: anything (e.g. `hermes-agent`)
   - **Redirect URI**: any valid HTTPS URL — `https://www.google.com` works fine. MercadoLibre rejects `https://localhost:*` for security; the URL just needs to be syntactically valid. No server is required at that URL; the skill reads the `?code=` parameter from the redirected URL bar after authorization.
   - **Scopes**: `read`, `write`, `offline_access`
4. Save and copy the **App ID** and **Secret Key**

### 2. Drop credentials into `~/.hermes/.env`

```bash
cp ~/.hermes/skills/mercadolibre/.env.example ~/.hermes/.env
chmod 600 ~/.hermes/.env
$EDITOR ~/.hermes/.env       # paste App ID, Secret, set ML_SITE, set ML_REDIRECT_URI to match the app
```

If `$EDITOR` complains about your terminal (common when SSH'ing from kitty/wezterm), either run `TERM=xterm nano ...` or write the file from the shell:

```bash
echo "ML_CLIENT_ID=YOUR_APP_ID"             > ~/.hermes/.env
echo "ML_CLIENT_SECRET=YOUR_SECRET"        >> ~/.hermes/.env
echo "ML_REDIRECT_URI=https://www.google.com" >> ~/.hermes/.env
echo "ML_SITE=MLA"                         >> ~/.hermes/.env
chmod 600 ~/.hermes/.env
```

### 3. Run the OAuth flow

```bash
bash ~/.hermes/skills/mercadolibre/scripts/ml-oauth.sh
```

The script:
1. Prompts for App ID, Secret, Redirect URI, and Site (Enter to accept defaults from `.env`)
2. Prints a long authorization URL — open it in any browser, sign in, click **Authorize**
3. Your browser redirects to the redirect URI with `?code=...` in the address bar (the page itself will fail to load — that's expected)
4. Paste the entire redirected URL back into the prompt
5. The script exchanges the code for an access token + refresh token, writes them to `~/.hermes/.env`

You only do this once. After that, the helper auto-refreshes whenever the 6-hour access token expires.

---

## Use from chat

Hermes loads `SKILL.md` whenever the user mentions MercadoLibre, prices, listings, or anything matching the skill's description. From Telegram (or any Hermes interface) you can say things like:

| You say | What Hermes does |
|---------|------------------|
| "I'm thinking of buying a PS5" | `ml_search "PS5"`, presents top 5 with prices, asks which to track |
| "Track the cheapest" / "Track #2" / "Track MLA63094449" | `ml_track_url <id>` with the chosen ID |
| "Track this with a 5% alert: https://www.mercadolibre.com.ar/.../p/MLA63094449" | `ml_track_url "<url>" 5` |
| "What am I tracking?" | `ml_list_tracked` |
| "Any alerts in the last 12 hours?" | `ml_pending_alerts 43200` |
| "Stop tracking MLA63094449" | `ml_untrack MLA63094449` |
| "What's the current price of MLA63094449?" | `ml_product_price MLA63094449` |
| "Search the catalog for AirPods Pro" | `ml_search "AirPods Pro" 10` |
| "List sellers offering MLA63094449" | `curl /products/MLA63094449/items` |
| "What unanswered questions do I have?" | `curl /my/received_questions/search?status=UNANSWERED` |
| "Which of my listings expire this week?" | walk `/users/$ML_USER_ID/items/search?status=active` and filter by `stop_time` |

The first call to `ml_track_url` installs a cron job that checks tracked products every 4 hours. The cron is removed automatically when you untrack the last item.

---

## Use from the shell

Sometimes useful for testing or scripting outside Hermes:

```bash
source ~/.hermes/skills/mercadolibre/scripts/ml-env.sh
ml_load_token

# Search
ml_search "iphone 16 pro" 5

# Track (from URL or product ID)
ml_track_url "https://www.mercadolibre.com.ar/.../p/MLA63094449" 10
ml_track_url MLA63094449 10

# Inspect
ml_list_tracked
ml_product_price MLA63094449

# Manual price check (would normally run via cron)
bash ~/.hermes/skills/mercadolibre/scripts/ml-check-tracked.sh

# Untrack
ml_untrack MLA63094449

# Recent alerts
ml_pending_alerts                # last 24h
ml_pending_alerts 3600           # last hour
```

For arbitrary API calls, use the authenticated `ml_curl` wrapper (handles 401 refresh and 429 backoff automatically):

```bash
ml_curl "$ML_API/users/me" | jq
ml_curl "$ML_API/products/search?site_id=$ML_SITE&q=playstation%205&limit=3" | jq '.results[] | {id, name}'
```

---

## Telegram push (optional)

By default, alerts land in `~/.hermes/mercadolibre/alerts.log` and the agent surfaces them when you ask "any alerts?". To get push notifications instead, append two extra lines to `~/.hermes/.env`:

```bash
echo 'TELEGRAM_BOT_TOKEN=123456789:AAEabcdef...'  >> ~/.hermes/.env
echo 'TELEGRAM_CHAT_ID=-1001234567890'            >> ~/.hermes/.env
```

How to get those:

- **Bot token**: open `@BotFather` in Telegram → `/newbot` → follow the prompts → copy the token it gives you. If you already have a bot, `/mybots` → pick it → API token.
- **Chat ID**: send any message to the bot, then visit `https://api.telegram.org/bot<TOKEN>/getUpdates` in your browser. Look for `"chat":{"id": ...}`. For private chats it's a positive number; for groups, a negative one starting with `-100`.

Once both are set, every alert is pushed to the chat in addition to being logged. Nothing else changes — pull-mode commands (`ml_pending_alerts`) keep working.

---

## Files & layout

```
mercadolibre/
├── SKILL.md                       # Agent-facing instructions (Hermes loads this)
├── README.md                      # This file
├── .env.example                   # Config template
└── scripts/
    ├── ml-env.sh                  # Sourced — exposes ml_* helper functions
    ├── ml-oauth.sh                # One-shot interactive OAuth2 flow
    ├── ml-check-tracked.sh        # Periodic price checker (cron target)
    └── install-deps.sh            # Auto-detect package manager, install curl + jq
```

State files (created at runtime, never committed):

```
~/.hermes/
├── .env                           # OAuth credentials + tokens (chmod 600)
└── mercadolibre/
    ├── tracked.json               # Tracked products + price history
    └── alerts.log                 # Append-only ALERT lines
```

Crontab entries are tagged with `# mercadolibre-skill` and managed by `ml_install_cron` / `ml_remove_cron`.

---

## Dependencies

- `bash` 4+
- `curl`
- `jq`
- GNU `date` (Linux) or BSD `date` (macOS) — both supported

Everything else is plain POSIX shell tooling.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `400 invalid_grant` on refresh | Refresh token was rotated and not persisted (e.g., two refreshes raced) | Re-run `ml-oauth.sh` |
| `400 invalid_client` | Wrong client_id or secret in `.env` | Re-check; rotate secret if leaked |
| `401 invalid_token` after refresh | Clock skew, or stale `ML_EXPIRES_AT` | `ml_refresh_token` once, retry |
| `403 forbidden` on POST/PUT | App missing `write` scope | Re-authorize the app with all three scopes |
| `403 access_denied` on `/items/{id}` or `/sites/.../search` | App not validated for catalog-wide access | Use the `/products/*` endpoints (the skill already does), or request validation in the devcenter |
| `404 not_found` on an item | Wrong `ML_SITE`, or the item was removed | Verify ID and site code |
| `429 too_many_requests` | Rate limited (~1000 req/h per user) | `ml_curl` retries with exponential backoff — wait it out |
| `Failed to allocate directory watch: Too many open files` (apt install) | Tiny VPS hit the inotify limit | `sysctl -w fs.inotify.max_user_watches=524288`, or install jq via the static binary |
| `mv: overwrite '...'?` prompt on the helpers | Interactive shell has `mv` aliased to `mv -i` | Already mitigated — helpers use `\mv -f` to bypass aliases |
| `Lo sentimos, la aplicación no puede conectarse a tu cuenta` during OAuth | Redirect URI mismatch between the app config and `.env` | Make both identical; MercadoLibre is strict about trailing slashes |

To revoke the app entirely: https://www.mercadolibre.com.ar/apps/applications

---

## License

MIT
