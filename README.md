# agent-usage-cli

Read subscription usage and basic account details from locally logged-in Claude Code, Codex, and Grok Build CLIs. The command is read-only and returns one JSON envelope.

## Prerequisites

- Node.js 20 or newer
- Any provider CLI you want to query on `PATH`
- A local login for each selected provider
- macOS Keychain access for Claude usage

The command does not need an `.env` file or separate API credentials. It does not call a model.

## Setup

```bash
npm install
npm run build
npm link
```

## Usage

```bash
agent-usage-cli
agent-usage-cli --provider claude
agent-usage-cli --provider claude,codex
agent-usage-cli --provider codex --provider grok
agent-usage-cli --include-history
agent-usage-cli --pretty
agent-usage-cli --strict
```

Options:

- `--provider <claude|codex|grok>` selects providers. Repeat the option or use commas. The default selects all three.
- `--include-history` includes Codex `dailyUsageBuckets`. The Codex summary is always included.
- `--pretty` indents the JSON. The default output is compact, single-line JSON.
- `--strict` exits with status 1 if any selected provider fails. Without it, partial failures exit successfully.

## Output

Successful queries and partial results use this envelope:

```json
{"ok":true,"data":{"schemaVersion":2,"observedAt":"2026-08-09T04:00:00.000Z","complete":false,"providers":{"claude":{"cli":{"command":"claude","version":"1.2.3"},"account":{},"usage":{}}},"errors":[{"provider":"codex","code":"CLI_NOT_FOUND","message":"codex is not installed or is not on PATH"}]}}
```

`schemaVersion` identifies the output contract. `observedAt` records when collection finished. `complete` is false when a selected provider fails. Successful provider data remains available in `providers`. Each provider keeps separate usage windows rather than combining them into one total. Missing values are omitted instead of reported as zero.

## How it works

- Claude account metadata comes from `claude auth status --json`. The OAuth token is read from the macOS Keychain with `security` and used only in memory for the Anthropic usage request.
- Codex uses the newline JSON protocol from `codex app-server` to read the account, rate limits, and usage summary.
- Grok uses newline JSON-RPC from `grok agent stdio` to read subscription and billing data. Grok reports `config.creditUsagePercent` as the percent of the weekly allowance already **used** (100 = fully used, 0 remaining), matching what `/usage` shows. The output preserves that value as `creditUsagePercent`, copies it to `usedPercent`, and derives `remainingPercent` as `100 - usedPercent`. It also includes the plan tier, period dates, unified billing status, and credit amounts in cents and dollars when reported.
- Each provider CLI version is read with `--version`. These commands do not start model inference.
- Providers run concurrently. Subprocesses and network calls have a 20-second timeout. Timed-out children receive a short graceful shutdown and then a forced kill if needed.

The tool does not print or persist tokens, authorization headers, raw authentication payloads, or provider stderr.

## Development

```bash
npm test
npm run build
node dist/cli.js --help
```

Tests use fixtures, fake adapters, and temporary local Node child processes. They do not access real credentials or run provider CLIs.

## Usage dashboard (Ruby)

`ruby/` adds a local history collector and a burn-down dashboard on top of the CLI above. It does not change the CLI's contract or output; it only runs `agent-usage-cli` on a timer, stores the JSON it prints, and renders it. Nothing here calls a model or a provider CLI directly — the Ruby side only ever shells out to the existing `agent-usage-cli`.

The dashboard answers one question: which subscription (Claude, Codex, or Grok) has the most unused plan allowance relative to time remaining in its current billing window. It compares **allowance percentage**, not raw token counts, because token counts are not comparable across providers.

Two full-width overlay charts drive this: a **weekly subscription comparison** (each provider's ~7-day window) and a **short-window comparison** (~1–8 hour windows, e.g. Claude's 5-hour limit). Windows are grouped into these two charts by their actual duration, not by a provider's JSON field names — Codex's weekly window has been seen reported as both `secondary` (alongside a 5-hour `primary`) and `primary` depending on the account, so a future provider that reports a 5-hour-and-weekly pair either way is still classified correctly automatically. Ranking and the "Use X next" recommendation always use each provider's weekly-class window. Model-specific limits (Claude Opus/Sonnet, Codex per-model `rateLimitsByLimitId` entries) show as compact secondary metrics on each provider's card, not as their own charts.

### Setup

```bash
cd ruby
rbenv install --skip-existing   # uses the version in .ruby-version
bundle install
```

### Run it by hand

```bash
cd ruby
bin/collector          # one collection: runs agent-usage-cli, stores the snapshot
bin/server              # starts the dashboard at http://127.0.0.1:4570
```

Open `http://127.0.0.1:4570/` in a browser. `GET /health` and `GET /api/dashboard.json` are also available; `POST /api/collect` triggers a manual collection from the page's "Collect now" button.

### Run it automatically (launchd)

```bash
cd ruby
bin/install-services    # renders and (re)installs both launchd agents for this machine
bin/uninstall-services  # stops and unloads them; the database is left in place
```

This installs two per-user LaunchAgents:

- `co.gen.agent-usage-collector` — runs `bin/collector` every 15 minutes.
- `co.gen.agent-usage-web` — keeps `bin/server` running and restarts it if it dies.

Logs land in `~/Library/Logs/agent-usage-cli/`. The plist templates in `launchd/` are checked in without any machine-specific paths; `bin/install-services` fills in absolute paths (Ruby, Bundler, Node, and each provider CLI's directory) at install time.

### Data location

History is stored in a local SQLite database at `~/Library/Application Support/agent-usage-cli/usage.sqlite3` by default. Set `AGENT_USAGE_DB` to use a different path (tests always use a temporary one). The database keeps every raw `agent-usage-cli` response alongside normalized per-window rows, so it can be reprocessed if the normalization logic changes later.

If you collected data before the Grok percent-used fix (schema/normalizer version bump), repair existing history once with:

```bash
cd ruby
bin/reprocess            # or: bundle exec rake reprocess
```

This deletes and rebuilds `window_observations` from the immutable `raw_snapshots` using the current normalizer. It never modifies `raw_snapshots`, and it's safe to run any number of times.

### Logos

`ruby/public/logos/` vendors each provider's mark locally (`claude.svg`, `codex.svg`, `grok.png`) — no CDN is loaded at request time. See `ruby/public/logos/SOURCES.md` for where each file came from.

### Chrome new-tab extension

`chrome-new-tab/` is an unpacked Manifest V3 extension that checks `http://127.0.0.1:4570/health` and opens the dashboard as your new tab. If the local server isn't running, it shows a fallback page with the commands above instead of failing silently.

To install it: open `chrome://extensions`, enable Developer Mode, choose "Load unpacked," and select the `chrome-new-tab/` directory.

### Notes

- The server binds to `127.0.0.1:4570` only — it is never reachable from the network.
- Anthropic's and xAI's (Grok) usage APIs are undocumented and can change without notice; if a provider's response shape changes, `agent-usage-cli` itself will start returning that provider's data under `errors` instead of `providers`, and the dashboard will show a partial-data banner rather than failing.
- Ruby tests (`ruby/test/`) use fixtures and injected fake collector runners. They never invoke a real provider CLI, Keychain, or network request.
