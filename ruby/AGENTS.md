# agent-usage-cli / ruby

Local history collector + Sinatra burn-down dashboard for the `agent-usage-cli` JSON CLI (Claude, Codex, Grok). Never calls a provider CLI directly — only runs `agent-usage-cli` itself on a timer and stores what it prints.

## Commands

```bash
bin/collector             # one collection: run agent-usage-cli, store the snapshot
bin/server                # dashboard at http://127.0.0.1:4570 (binds 127.0.0.1 only)
bin/install-services      # render + (re)install both launchd agents for this machine
bin/uninstall-services    # stop + unload the launchd agents (keeps the database)
bin/reprocess             # rebuild window_observations from raw_snapshots (or: rake reprocess)
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
- `raw_snapshots` keeps every full `agent-usage-cli` JSON envelope, immutable once written. `window_observations` holds normalized per-window rows (used/remaining percent, period bounds) so a normalizer version bump can reprocess history — see "Reprocessing" below.
- Windows are grouped for comparison/ranking by **actual duration** (`period_end - period_start`), computed at dashboard read time — not by a provider's JSON field names: weekly-class is ~6.5–7.5 days, short-class is ~1–8 hours. Codex's weekly-class window (10080 min) has been observed under both `primary` and `secondary` depending on the account, so it is never assumed to be one or the other — duration classification handles either shape. Claude's weekly-class window is `seven_day`; its short-class window is `five_hour`. Grok's `currentPeriod` is weekly-class. This means a future provider whose response shape changes is still classified correctly as long as its window durations fall in these ranges. Ranking and the recommendation always use each provider's weekly-class window.
- Model-specific limits (Claude `seven_day_opus`/`seven_day_sonnet`, Codex distinct per-model limits from `rateLimitsByLimitId`) show as compact secondary metrics on each provider's card — not their own chart. Each `rateLimitsByLimitId` entry wraps its own `primary`/`secondary` windows (plus `limitId`/`limitName`); entries that exactly match a main window are deduped, the rest keep a stable `<limitId>`/`<limitId>_secondary` window key and use `limitName` as their label.
- Claude `resetsAt` is rounded to the nearest minute before storage. The live API's reset timestamp can jitter by under a second across polls (e.g. `:39:59.595` vs. `:40:00.478`), and SQLite history grouping matches `period_start`/`period_end` by exact string, so unrounded jitter would split one window's history across two buckets.
- Ranking compares allowance **percentage**, never raw token counts — token counts aren't comparable across providers.
- Grok's `config.creditUsagePercent` is the percent of the weekly allowance already **used** (100 = fully used, 0 remaining) — the normalizer (`Normalizer::VERSION`, currently 2) always prefers it over `usage["usedPercent"]` so a raw snapshot stored by a pre-fix build (whose `usedPercent`/`remainingPercent` were inverted, but whose `creditUsagePercent` passthrough was always correct) reprocesses into correct history.

## Reprocessing

`bin/reprocess` (or `bundle exec rake reprocess`) rebuilds every `window_observations` row from `raw_snapshots` using the current normalizer. It deletes and re-inserts each snapshot's rows inside one transaction, so it's idempotent — safe to run any number of times — and never touches `raw_snapshots`. Run it once after a normalizer fix (e.g. the Grok percent-used correction) to repair history collected before the fix, without re-collecting.

## launchd

```
co.gen.agent-usage-collector   StartInterval=900 (15m), RunAtLoad
co.gen.agent-usage-web         KeepAlive, RunAtLoad
```

Templates live in `../launchd/*.plist.erb` and are checked in with no machine-specific paths — `bin/install-services` fills in absolute Ruby/Bundler/Node/provider-CLI paths and writes the rendered plists to `~/Library/LaunchAgents/`. Logs go to `~/Library/Logs/agent-usage-cli/`. Both scripts are idempotent (bootout before bootstrap).

## Logos

`public/logos/` vendors each provider's mark locally (`claude.svg`, `codex.svg`, `grok.png`) so the dashboard has zero CDN/runtime dependency. Sources are documented in `public/logos/SOURCES.md`. Both SVGs are checked for `<script>`/`<foreignObject>`/inline event handlers before being committed.

## Chrome new-tab

`../chrome-new-tab/` is an unpacked MV3 extension: new tab checks `/health` and redirects to the dashboard, or shows a fallback page with setup commands if the server isn't running. Load unpacked from `chrome://extensions`.

## Testing notes

Tests never invoke a real provider CLI, `agent-usage-cli`, or the macOS Keychain. `Collector.new(cli_runner:)` and `Web.cli_runner_override` accept a fake runner (a zero-arg callable returning the CLI's stdout string) built from `test/fixtures/*.json`. Every test uses a temporary SQLite file (`AgentUsageTest#setup` in `test/test_helper.rb`), never the real database path.

## Caveats

Anthropic's and xAI's usage APIs are undocumented and can change shape without notice. When that happens `agent-usage-cli` reports the affected provider under `errors` instead of `providers`; the dashboard shows a partial-data banner rather than crashing, and history for the other providers keeps accumulating normally.
