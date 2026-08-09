# Agent usage history and dashboard

## Goal

Add a Ruby snapshot collector, SQLite history, and a thin Sinatra dashboard to this repository. The dashboard must answer which Claude, Codex, or Grok subscription has the most unused plan allowance relative to time remaining.

Do not change the existing TypeScript CLI contract. Do not call any model endpoint. The Ruby collector only runs the existing local `agent-usage-cli` command.

## Product decisions

- Poll all providers every 15 minutes.
- Compare allowance percentage, not token counts. Provider token counts are not comparable.
- Rank subscriptions by their primary plan window:
  - Claude: `seven_day`
  - Codex: the main `rateLimits.rateLimits.primary` window
  - Grok: `currentPeriod`
- Show Claude's five-hour and model-specific windows and any additional Codex windows as secondary constraints. Do not let a short window hide major weekly underuse in the primary recommendation.
- Use a burn-down chart. The Y-axis is allowance remaining from 100% to 0%. The X-axis is period start through reset.
- Draw a dashed ideal line from 100% remaining at period start to 0% at reset.
- Draw the actual snapshot history. Include an inferred 100% start point so the first dashboard view is useful before a second snapshot exists. Label inferred starts in accessible text.
- Show the current gap from ideal, the required percentage-point burn per day, reset countdown, and a recent-pace projection when at least two real observations exist.
- Bind the web server to `127.0.0.1:4570` only.
- Use server-rendered HTML and SVG with small vanilla JavaScript for refresh and tooltips. Do not use an external CDN or frontend build step.
- Include a Manifest V3 Chrome new-tab extension that checks the local server and redirects to the dashboard. Show a useful fallback page if the server is down.

## Repository layout

Add:

```text
ruby/
  .ruby-version
  Gemfile
  Gemfile.lock
  Rakefile
  config.ru
  bin/collector
  bin/server
  bin/install-services
  bin/uninstall-services
  lib/agent_usage/database.rb
  lib/agent_usage/normalizer.rb
  lib/agent_usage/collector.rb
  lib/agent_usage/dashboard.rb
  lib/agent_usage/web.rb
  views/index.erb
  public/app.css
  public/app.js
  test/*_test.rb
  test/fixtures/*.json
launchd/
  collector.plist.erb
  web.plist.erb
chrome-new-tab/
  manifest.json
  newtab.html
  newtab.js
  newtab.css
```

Use module and model names, not service-object names.

## Storage

Use `~/Library/Application Support/agent-usage-cli/usage.sqlite3` by default. Allow `AGENT_USAGE_DB` to override it for tests and development.

Use SQLite WAL mode, foreign keys, a busy timeout, and an idempotent schema setup.

### `raw_snapshots`

- `id` integer primary key
- `collected_at` ISO 8601 UTC
- `observed_at` ISO 8601 UTC from the CLI envelope
- `schema_version`
- `complete` boolean integer
- `errors_json`
- `raw_json`

### `window_observations`

- `id` integer primary key
- `raw_snapshot_id` foreign key
- `collected_at`
- `provider`
- `window_key`
- `primary_window` boolean integer
- `period_start`
- `period_end`
- `used_percent`
- `remaining_percent`
- `normalizer_version`
- `raw_window_json`
- unique index on raw snapshot, provider, and window key
- lookup index on provider, window key, and collected time

Keep each raw envelope so future normalizer versions can reprocess old data.

## Normalization

- Claude windows live under `usage.windows`. Use `utilization` as used percent. Derive period start from reset minus 5 hours for `five_hour` and minus 7 days for all `seven_day*` keys.
- Codex main data lives under `usage.rateLimits.rateLimits`. Use `primary` and `secondary`. Derive period start from `resetsAt` minus `windowDurationMins`. Add additional named limits from `rateLimitsByLimitId` only when they are not duplicates of the main limit. The main `primary` window is the ranking window.
- Grok uses `usage.usedPercent`, `currentPeriod.start`, and `currentPeriod.end`. It is the ranking window.
- Skip null windows. Clamp derived percentages to 0 through 100 only for display calculations. Preserve original values in raw JSON.
- A partial CLI result is still a valid snapshot. Store its errors and all successful providers.

## Collection safety

- Use a nonblocking `flock` so overlapping launchd runs exit successfully without duplicate collection.
- Run the existing CLI with `Open3.capture3` and an explicit timeout.
- Do not log stdout from the CLI outside SQLite. It contains account metadata.
- Treat valid JSON as usable even when `--strict` would return nonzero. The collector should call the CLI without `--strict`.
- Insert the raw snapshot and normalized observations in one transaction.

## Dashboard calculations

For each current window:

```text
elapsed_fraction = (now - period_start) / (period_end - period_start)
ideal_used_percent = elapsed_fraction * 100
ideal_remaining_percent = 100 - ideal_used_percent
gap_points = remaining_percent - ideal_remaining_percent
required_daily_burn = remaining_percent / remaining_days
```

Positive gap means unused allowance is available. Rank providers by the gap on their primary window, descending. Use required daily burn as the urgency tie-breaker.

When at least two real observations exist in the active period, estimate a recent burn slope and projected remaining allowance at reset. Never include dollar balances in ranking math.

## Web routes

- `GET /health` returns compact JSON.
- `GET /api/dashboard.json` returns the computed view model and chart series.
- `POST /api/collect` collects once and redirects or returns JSON based on `Accept`.
- `GET /` renders the dashboard.

The page must include:

- A prominent recommendation such as `Use Claude next`.
- Three ranked provider cards.
- One responsive SVG chart per active window.
- Dashed ideal line, solid actual line, inferred start marker, current marker, and optional projection.
- Status text that does not depend only on color.
- Light and dark modes, reduced-motion support, responsive layout, keyboard-visible controls, and useful SVG `aria-label` text.
- Empty, partial-error, and stale-data states.

## launchd

Use `ruby/bin/install-services` to render both plist templates into `~/Library/LaunchAgents/` with current absolute paths. Do not hardcode `/Users/cgenco` in the checked-in templates.

At install time, resolve and include directories for `ruby`, `bundle`, `node`, `claude`, `codex`, and `grok` in `PATH`. Set `HOME`, `BUNDLE_GEMFILE`, `AGENT_USAGE_DB`, and port 4570 explicitly.

- Collector label: `co.gen.agent-usage-collector`, `StartInterval=900`, `RunAtLoad=true`.
- Web label: `co.gen.agent-usage-web`, `KeepAlive=true`, `RunAtLoad=true`, and a short throttle interval.
- Write logs under `~/Library/Logs/agent-usage-cli/`.
- Installation must be idempotent. Boot out an existing service before bootstrap.
- Provide an idempotent uninstall script that boots out services but does not delete the SQLite database.

## Tests

Use Minitest and Rack::Test. Tests must use temporary databases and fixture command runners. They must never invoke real provider CLIs or Keychain.

Cover:

- Schema setup and idempotency.
- Normalization for all provider windows and reset derivation.
- Partial provider errors.
- Duplicate Codex limit removal.
- Atomic insert and collector locking.
- Pace calculations, reset boundaries, projections, and recommendation order.
- Sinatra health, JSON API, empty state, dashboard HTML, and manual collection route.
- Plist rendering without hardcoded user paths.

Run both suites:

```bash
npm test
cd ruby && bundle exec rake test
```

## Documentation

Update root README and AGENTS with Ruby commands, local URL, service installation, data location, and Chrome setup. Add a short `ruby/AGENTS.md`. External text must avoid secrets and explain that Anthropic and Grok interfaces can change.

## Acceptance

1. Both test suites pass.
2. A manual collector run adds one raw snapshot and normalized rows.
3. A second collector run adds history without duplicates inside either snapshot.
4. The local API ranks the primary windows correctly.
5. launchd collector and web services are loaded and healthy.
6. `curl http://127.0.0.1:4570/health` succeeds.
7. The dashboard has populated charts and a clear recommendation.
8. Open `http://127.0.0.1:4570/` in Chrome when the graph is ready.
9. Commit and push only green work on `main`.
