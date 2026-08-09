# agent-usage-cli / ruby

Local history collector + Sinatra burn-down dashboard for the `agent-usage-cli` JSON CLI (Claude, Codex, Grok). Never calls a provider CLI directly — only runs `agent-usage-cli` itself on a timer and stores what it prints.

## Commands

```bash
bin/collector             # one collection: run agent-usage-cli, store the snapshot
bin/server                # dashboard at http://127.0.0.1:4570 (binds 127.0.0.1 only)
bin/install-services      # render + (re)install both launchd agents for this machine
bin/uninstall-services    # stop + unload the launchd agents (keeps the database)
bundle exec rake test     # Minitest suite (fixtures + fake runners only)
```

## Web routes

```
GET  /health                health check, {"ok":true,"data":{"status":"ok",...}}
GET  /api/dashboard.json     computed view model + chart series
POST /api/collect            collect once; redirects to / or returns JSON per Accept header
GET  /                       the dashboard
```

## Data

- SQLite at `~/Library/Application Support/agent-usage-cli/usage.sqlite3`. Override with `AGENT_USAGE_DB`.
- `raw_snapshots` keeps every full `agent-usage-cli` JSON envelope. `window_observations` holds normalized per-window rows (used/remaining percent, period bounds) so a future normalizer version can reprocess history.
- Ranking uses each provider's primary window: Claude `seven_day`, Codex `rateLimits.rateLimits.primary`, Grok `currentPeriod`. Everything else (Claude `five_hour`/`seven_day_opus`/`seven_day_sonnet`, Codex `secondary`, and distinct per-model limits from `rateLimitsByLimitId`) shows as a secondary constraint. Each `rateLimitsByLimitId` entry wraps its own `primary`/`secondary` windows (plus `limitId`/`limitName`); entries that exactly match a main window are deduped, the rest keep a stable `<limitId>`/`<limitId>_secondary` window key and use `limitName` as their label.
- Claude `resetsAt` is rounded to the nearest minute before storage. The live API's reset timestamp can jitter by under a second across polls (e.g. `:39:59.595` vs. `:40:00.478`), and SQLite history grouping matches `period_start`/`period_end` by exact string, so unrounded jitter would split one window's history across two buckets.
- Ranking compares allowance **percentage**, never raw token counts — token counts aren't comparable across providers.

## launchd

```
co.gen.agent-usage-collector   StartInterval=900 (15m), RunAtLoad
co.gen.agent-usage-web         KeepAlive, RunAtLoad
```

Templates live in `../launchd/*.plist.erb` and are checked in with no machine-specific paths — `bin/install-services` fills in absolute Ruby/Bundler/Node/provider-CLI paths and writes the rendered plists to `~/Library/LaunchAgents/`. Logs go to `~/Library/Logs/agent-usage-cli/`. Both scripts are idempotent (bootout before bootstrap).

## Chrome new-tab

`../chrome-new-tab/` is an unpacked MV3 extension: new tab checks `/health` and redirects to the dashboard, or shows a fallback page with setup commands if the server isn't running. Load unpacked from `chrome://extensions`.

## Testing notes

Tests never invoke a real provider CLI, `agent-usage-cli`, or the macOS Keychain. `Collector.new(cli_runner:)` and `Web.cli_runner_override` accept a fake runner (a zero-arg callable returning the CLI's stdout string) built from `test/fixtures/*.json`. Every test uses a temporary SQLite file (`AgentUsageTest#setup` in `test/test_helper.rb`), never the real database path.

## Caveats

Anthropic's and xAI's usage APIs are undocumented and can change shape without notice. When that happens `agent-usage-cli` reports the affected provider under `errors` instead of `providers`; the dashboard shows a partial-data banner rather than crashing, and history for the other providers keeps accumulating normally.
