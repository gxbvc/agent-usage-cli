# Grok percent-used fix and comparison-chart redesign

## Why

`config.creditUsagePercent` from Grok Build's billing response is the percent of
the weekly allowance already **used** (100 = fully used, 0 remaining), matching
what `/usage` shows. The original implementation (`plans/01-usage-dashboard.md`)
treated it as percent **remaining**, inverting every Grok data point end to end:
the TypeScript adapter, its tests and fixtures, both Ruby-side envelope
fixtures, and the README. Every `raw_snapshots` row collected before this fix
carries an inverted `usage.usedPercent`/`remainingPercent`, though
`usage.creditUsagePercent` itself was always passed through correctly.

Separately, the dashboard's "primary window" ranking followed each provider's
JSON-literal `primary`/`secondary` field names. For Codex that's backwards:
the real weekly-class window is `secondary` (10080 min), not `primary` (300
min = 5 hours). The per-provider tiny embedded charts also didn't support
comparing providers against each other at a glance.

## Decisions

1. **Grok semantics.** `config.creditUsagePercent` is percent used. Fix
   `src/providers/grok.ts` to set `usage.usedPercent = creditUsagePercent` and
   `usage.remainingPercent = 100 - creditUsagePercent`. Bump the top-level
   `schemaVersion` 1 → 2 (a deliberate, flagged exception to "don't change the
   CLI contract" — this corrects a public field's meaning). Update tests,
   fixtures, and docs to match.

2. **Ruby normalizer robustness + reprocessing.** `Normalizer.grok_windows`
   prefers `usage["creditUsagePercent"]` over `usage["usedPercent"]` when
   present, so it derives the correct value regardless of which TS build
   produced the stored `raw_json` — this is what makes reprocessing old
   history safe. Bump `Normalizer::VERSION` 1 → 2. Add
   `AgentUsage::Reprocessor` (`ruby/lib/agent_usage/reprocessor.rb`): for each
   `raw_snapshots` row, delete its `window_observations` and rebuild them from
   `raw_json` with the current normalizer, in one transaction per snapshot.
   Idempotent; never modifies `raw_snapshots`. Exposed as `bin/reprocess` and
   `rake reprocess`.

3. **Comparison charts replace per-provider tiny charts.** Two full-width
   overlay SVGs: a **weekly subscription comparison** and a **short-window
   (~5h) comparison**. Both use a normalized 0→1 cycle-progress x-axis and a
   100→0 allowance-remaining y-axis, one shared dashed ideal diagonal, and one
   actual-history polyline + current marker per provider, plus an inferred
   start point when only one observation exists and a projection when at
   least two real observations exist.

4. **Duration-based classification, not JSON-literal names.**
   `Dashboard.classify_duration` buckets each window by
   `period_end - period_start` at read time (no schema/DB migration):
   weekly-class ≈ 6.5–7.5 days, short-class ≈ 1–8 hours. The weekly
   comparison uses each provider's weekly-class window — for Codex that's
   `secondary`, not `primary`. The short comparison uses each provider's
   short-class window (Claude `five_hour`, Codex `primary`) and generalizes to
   any future provider whose windows fall in these ranges, independent of
   field naming.

5. **Ranking follows the redesign.** The recommendation and provider ranking
   use each provider's weekly-class window (`ranking_window`), not the
   JSON-literal primary flag. This is a real behavior change for Codex
   (ranking now reflects its ~7-day allowance, not its 5-hour one) — flagged
   and applied deliberately, matching "keep recommendation ranking based on
   each provider's weekly comparison window."

6. **Provider cards slim down.** Cards keep a logo, rank badge, and the
   weekly-window metrics (remaining, gap, burn, reset), plus a compact
   "Other windows" detail listing every non-ranking window's metrics — no
   embedded per-window chart anywhere on a card.

7. **Local logos, no CDN.** `ruby/public/logos/{claude.svg,codex.svg,grok.png}`
   vendored from Simple Icons, Wikimedia Commons, and grok.com respectively
   (see `ruby/public/logos/SOURCES.md`). Both SVGs were checked for
   `<script>`/`<foreignObject>`/inline event handlers before committing.
   Providers are visually distinguished by more than color: each also gets
   its own line dash pattern and point marker shape (circle/square/triangle,
   diamond for any future provider) in the comparison charts.

## What changed

- `src/providers/grok.ts`, `src/types.ts`, `src/collector.ts` — percent-used
  fix, `schemaVersion` 2.
- `src/tests/normalization.test.ts`, `src/tests/collector.test.ts` — updated
  expectations.
- `README.md`, `AGENTS.md` (root) — corrected Grok semantics and schema
  version in docs.
- `ruby/lib/agent_usage/normalizer.rb` — `creditUsagePercent`-first Grok
  derivation, `VERSION = 2`, shared `Normalizer.store_window` used by both
  `Collector` and `Reprocessor`.
- `ruby/lib/agent_usage/reprocessor.rb` (new), `ruby/bin/reprocess` (new),
  `ruby/Rakefile` (`rake reprocess`).
- `ruby/lib/agent_usage/dashboard.rb` — duration classification,
  `ranking_window`, `Dashboard.build_comparison`.
- `ruby/lib/agent_usage/chart.rb` — `Chart.render_comparison` (new method,
  alongside the unchanged single-window `Chart.render`).
- `ruby/lib/agent_usage/web.rb` — `render_comparison_chart`, `provider_logo`
  helpers.
- `ruby/views/index.erb`, `ruby/public/app.css` — two comparison sections,
  slimmed provider cards, provider color/marker CSS.
- `ruby/public/logos/` (new) — vendored logos + `SOURCES.md`.
- Ruby fixtures (`ruby/test/fixtures/envelope_*.json`) — `schemaVersion` 2,
  corrected Grok percentages.
- New/updated tests: `ruby/test/reprocessor_test.rb` (new),
  `ruby/test/chart_test.rb` (new), `ruby/test/no_cdn_dependency_test.rb`
  (new), plus updates to `ruby/test/normalizer_test.rb`,
  `ruby/test/dashboard_test.rb`, `ruby/test/web_test.rb`.
- `README.md`, `ruby/AGENTS.md` — reprocessing, comparison charts, logos.

## Acceptance

1. `npm test` and `cd ruby && bundle exec rake test` both green.
2. A temp-DB reprocessor test seeds an old-style inverted Grok
   `raw_snapshots` row (correct `creditUsagePercent`, inverted
   `usedPercent`/`remainingPercent`), runs `Reprocessor.run`, and confirms
   `window_observations` is corrected while `raw_snapshots` is byte-identical
   before/after.
3. `GET /api/dashboard.json` includes `comparison.weekly` (claude, codex,
   grok) and `comparison.short` (claude `five_hour`, codex `primary`), each
   with 0..1 x fractions.
4. Manual dashboard check: two large full-width comparison charts, provider
   logos and distinguishable line/marker styles in both light and dark mode,
   tooltips and keyboard focus work, provider cards show metrics with no
   embedded tiny charts.
5. No file under `ruby/views/` or `ruby/public/` (excluding `logos/SOURCES.md`
   documentation) references an external `http(s)://` URL at runtime.
