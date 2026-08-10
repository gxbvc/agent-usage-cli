# Dashboard marker and header polish

## Why

The comparison charts distinguished providers by generic shapes
(circle/square/triangle) plus color and dash pattern. Shapes don't say
"Claude" the way a logo does, and Codex's vendored mark was actually the old
green ChatGPT/OpenAI logo, not Codex's own. Separately, the header subtitle,
the "Use X next" recommendation box, the per-section blurb paragraphs, and
the "Collect now" button added UI surface that didn't earn its place: the
blurbs restated what the chart axes already show, the recommendation
duplicated the top provider card's rank badge, and manual collection already
happens automatically every 15 minutes with no button needed. The
projection line's meaning (a current-pace forecast, not a guarantee) also
wasn't stated anywhere in the UI.

## Decisions

1. **Logo point markers.** `Chart.logo_marker` renders every real, inferred,
   and projected point in the comparison SVGs as an `<image>` referencing
   the provider's vendored logo (`/logos/*`, same local files the legend and
   provider cards already use) instead of a circle/square/triangle/diamond.
   A provider with no vendored logo (an unrecognized future provider) still
   falls back to the old shape-marker code path via
   `Chart.provider_logo_href` returning `nil` - `PROVIDER_STYLES` keeps a
   `marker: :diamond` default style for that case only.

2. **Sizing carries "which point is this."** Since a fixed-color logo can't
   be shape-differentiated, state is now conveyed by size plus a decorative
   circle drawn behind the logo (`Chart.marker_decoration`, never itself
   focusable - the `<image>` keeps `tabindex`/`data-tooltip`/`<title>`, so
   `app.js`'s `closest(".chart-point")` handling is unchanged):
   - History points: 10px logo, no decoration, restrained so a dense
     15-minute-interval week of history doesn't turn into a wall of icons.
   - Current point: 22px logo (clearly larger, per the request) plus a
     translucent provider-colored halo behind it.
   - Inferred start point: 10px logo, dimmed via CSS opacity, plus a dashed
     ring in the "ideal" color (same visual language the old hollow-circle
     inferred marker used).
   - Projected endpoint: 13px logo, dimmed, plus a dashed ring in the
     projection color, echoing the projection line's own dash pattern.

3. **Codex logo.** Re-vendored from
   [LobeHub Icons](https://github.com/lobehub/lobe-icons) (MIT), retrieved
   2026-08-09, as `ruby/public/logos/codex.png` (transparent PNG). Replaces
   `codex.svg`, which was the old ChatGPT/OpenAI mark. `Chart::PROVIDER_LOGOS`
   is now the single source of truth for provider → logo filename;
   `Web#provider_logo` delegates to it instead of keeping its own copy.
   `SOURCES.md` documents the new source, retrieval date, and license.

4. **Projection semantics made explicit, math unchanged.** The footer
   legend key was renamed "projection" → "projected at current pace" to
   name what the dashed line actually is: a straight-line extrapolation
   from the two most recent real observations to the reset time, which can
   legitimately land anywhere from 0% (a provider on track to fully deplete
   its allowance) to well above the ideal-pace line. Each comparison
   legend row now also states that series' own projected-remaining-at-reset
   percentage inline (e.g. "projected 45.0% at reset (current pace)") when
   a projection exists for it, sourced from the same `chart[:projection]`
   data the SVG already draws. `Dashboard.build_projection`'s calculation is
   untouched.

5. **Honest about window availability.** The footer now states plainly
   that automatic snapshots run every 15 minutes, without claiming every
   provider has a short-duration window - Codex's short-class window
   depends on the account (its documented weekly-only shape has no
   short-class window at all in some cases), and Grok only reports
   `currentPeriod` (weekly-class) today. The short-comparison chart already
   tolerated a single provider entry before this change (`filter_map` over
   whichever providers have a short-class window); no behavior change was
   needed there, only removing UI copy that implied more providers would
   always be present.

6. **Removed UI surface.** Header subtitle, "Collect now" button/form, the
   whole recommendation box, and both comparison-section blurb paragraphs
   are gone from `views/index.erb`. `GET /api/dashboard.json`'s
   `data.recommendation` field is untouched - nothing reads the UI copy to
   produce it, so removing the box doesn't affect the API. `POST
   /api/collect` also still works as a route; it just has no button
   pointing at it anymore (README updated to say so). Dead CSS
   (`.recommendation*`, `.comparison-blurb`, `.legend-marker*`, `button*`,
   `.page-header-title p`) and dead JS (`setupCollectButton`) were removed
   alongside their markup. The redundant shape-swatch (`legend-marker`) in
   each comparison legend row was also dropped - the provider logo `<img>`
   already sitting next to it is the identifier now.

## What changed

- `ruby/lib/agent_usage/chart.rb` - logo markers (`logo_marker`,
  `marker_decoration`, `provider_logo_href`/`provider_logo_file`,
  `PROVIDER_LOGOS`, `HISTORY_LOGO_SIZE`/`CURRENT_LOGO_SIZE`/
  `INFERRED_LOGO_SIZE`/`PROJECTION_LOGO_SIZE`); shape-marker fallback kept
  only for providers with no vendored logo; projection `<title>` text now
  says "(current pace)".
- `ruby/lib/agent_usage/web.rb` - `provider_logo` delegates to
  `Chart.provider_logo_file`; `PROVIDER_LOGOS` constant removed (no longer
  duplicated).
- `ruby/public/logos/codex.png` (new, replaces `codex.svg`),
  `ruby/public/logos/SOURCES.md` - corrected Codex source/date/attribution.
- `ruby/views/index.erb` - header, recommendation box, blurbs, and
  Collect-now form removed; comparison legend rows drop the shape swatch and
  add the per-series projected-at-reset percentage; footer legend and
  15-minute copy updated.
- `ruby/public/app.css` - dead rules removed (`.recommendation*`,
  `.comparison-blurb`, `.legend-marker*`, `button*`, `.page-header-title p`);
  new marker-decoration rules (`.chart-point-history`, `.chart-marker-ring*`,
  `.chart-marker-halo`) added; `.chart-point-inferred`/`-current`/
  `-projection` extended with opacity/filter so state still reads on a
  fixed-color logo image (old fill/stroke rules kept for the shape-marker
  fallback path).
- `ruby/public/app.js` - `setupCollectButton` and its call removed.
- `README.md`, `ruby/AGENTS.md` - corrected `codex.svg` → `codex.png`
  references, described logo point markers, updated the Collect-now
  description to reflect there's no button, pointed the recommendation
  reference at the JSON API.
- Tests: `ruby/test/chart_test.rb` (logo markers, marker sizing, projection
  logo+ring), `ruby/test/web_test.rb` (`codex.png`, removed-UI assertions,
  projection copy, 15-minute copy, per-series projected percentage via a
  seeded two-observation history), `ruby/test/no_cdn_dependency_test.rb`
  (`codex.png`, added a `chart.rb` source scan since it now emits `<image
  href>` attributes).

## Acceptance

1. `npm test` and `cd ruby && bundle exec rake test` both green (81
   runs / 358 assertions).
2. `ruby -c` on every changed `.rb` file, `git diff --check`: clean.
3. In-process Rack::Test smoke against a `Dir.mktmpdir` SQLite database and
   a fake `cli_runner` (no real provider/model calls): `/health`,
   `POST /api/collect`, `GET /`, `GET /api/dashboard.json`, and all three
   `/logos/*` routes all return the expected status; the rendered page
   contains no recommendation box, no "Collect now", no header subtitle, no
   `comparison-blurb`, references `/logos/codex.png` and never
   `/logos/codex.svg`, includes "every 15 minutes" and "projected at
   current pace"; both comparison-chart SVGs parse as well-formed XML via
   REXML; `data.recommendation` is still present in the JSON API.
4. Manual/visual check still recommended before shipping: open the
   dashboard in a browser and confirm the logo markers read clearly at
   actual chart density (light and dark mode), and that keyboard
   Tab-through still reaches every point with a visible focus ring and
   tooltip.
