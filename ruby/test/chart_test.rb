require_relative "test_helper"
require "agent_usage/chart"

class ChartTest < AgentUsageTest
  def setup
    super
    @entries = [
      entry(provider: "claude", label: "Claude", window_label: "7-day", remaining_percent: 60.0, gap_points: 10.0),
      entry(provider: "codex", label: "Codex", window_label: "Secondary", remaining_percent: 50.0, gap_points: -5.0),
      entry(provider: "grok", label: "Grok", window_label: "Current period", remaining_percent: 26.5, gap_points: -20.0),
    ]
  end

  def test_renders_one_polyline_per_provider_with_distinct_dash_and_color_classes
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    assert_includes svg, "chart-actual-provider-claude"
    assert_includes svg, "chart-actual-provider-codex"
    assert_includes svg, "chart-actual-provider-grok"
    assert_includes svg, 'stroke-dasharray="9 5"'
    assert_includes svg, 'stroke-dasharray="2 4"'
    refute_includes svg, "chart-actual-provider-default"
  end

  def test_uses_each_providers_local_logo_as_its_point_marker
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    assert_includes svg, '<image class="chart-point chart-point-provider-claude'
    assert_includes svg, 'href="/logos/claude.svg"'
    assert_includes svg, '<image class="chart-point chart-point-provider-codex'
    assert_includes svg, 'href="/logos/codex.png"'
    assert_includes svg, '<image class="chart-point chart-point-provider-grok'
    assert_includes svg, 'href="/logos/grok.png"'
    refute_includes svg, "<circle class=\"chart-point"
    refute_includes svg, "<rect class=\"chart-point"
    refute_includes svg, "<polygon class=\"chart-point"
  end

  def test_current_point_logo_is_clearly_larger_than_history_points
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    assert_includes svg, 'width="10" height="10"'
    assert_includes svg, 'width="22" height="22"'
    assert_includes svg, "chart-point-current"
    assert_includes svg, "chart-marker-halo"
  end

  def test_falls_back_to_a_default_style_for_an_unknown_future_provider
    entries = [entry(provider: "future_provider", label: "Future", window_label: "Weekly", remaining_percent: 40.0, gap_points: 0.0)]
    svg = AgentUsage::Chart.render_comparison(entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    assert_includes svg, "chart-actual-provider-default"
    assert_includes svg, "<polygon"
  end

  def test_draws_exactly_one_shared_ideal_diagonal_regardless_of_provider_count
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")
    assert_equal 1, svg.scan('class="chart-ideal"').size
  end

  def test_svg_has_an_accessible_title_summarizing_every_provider
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    assert_includes svg, 'aria-labelledby="weekly-chart-title"'
    assert_includes svg, '<title id="weekly-chart-title">'
    assert_includes svg, "Claude 7-day: 60.0% remaining"
    assert_includes svg, "Codex Secondary: 50.0% remaining"
    assert_includes svg, "Grok Current period: 26.5% remaining"
  end

  def test_points_carry_hover_and_keyboard_accessible_tooltips
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    assert_includes svg, 'tabindex="0"'
    assert_includes svg, "data-tooltip="
    assert_includes svg, "Resets"
  end

  def test_projected_endpoint_also_uses_the_providers_logo_with_a_dashed_ring
    entries = [entry(provider: "claude", label: "Claude", window_label: "7-day", remaining_percent: 60.0, gap_points: 10.0)]
    entries.first[:chart][:projection] = { from: { x: 1.0, y: 60.0 }, to: { x: 1.0, y: 45.0 } }

    svg = AgentUsage::Chart.render_comparison(entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    assert_includes svg, "chart-point-projection"
    assert_includes svg, "chart-marker-ring-projection"
    assert_includes svg, "projected remaining at reset (current pace): 45.0%"
    assert_includes svg, 'href="/logos/claude.svg"'
  end

  def test_marks_inferred_start_points_distinctly
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")
    assert_includes svg, "chart-point-inferred"
    assert_includes svg, "inferred period start"
  end

  def test_repeated_unchanged_observations_widely_spaced_in_pixels_all_stay_markers
    inferred = { x: 0.0, y: 100.0, collected_at: "2026-01-01T00:00:00Z", inferred: true }
    flat_observations = (1..8).map do |i|
      { x: i / 10.0, y: 0.0, collected_at: "2026-01-01T0#{i}:00:00Z", inferred: false }
    end
    current = { x: 0.9, y: 0.0, collected_at: "2026-01-01T09:00:00Z", inferred: false }
    points = [inferred, *flat_observations, current]

    entries = [dense_entry(points, current)]
    svg = AgentUsage::Chart.render_comparison(entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    coords = svg[/<polyline[^>]*chart-actual-provider-grok[^>]*points="([^"]+)"/, 1]
    assert_equal points.size, coords.split(" ").size

    # Each observation here is ~107 SVG px apart on the x axis (0.1 fraction
    # of the plot width), well past the one-logo-width thinning threshold,
    # so an identical value doesn't get merged away: every point earns its
    # own marker because none of them actually overlap on screen.
    logo_markers = svg.scan('href="/logos/grok.png"').size
    assert_equal points.size, logo_markers
  end

  def test_dense_flat_weekly_history_thins_overlapping_markers_by_pixel_distance
    points = dense_history_points(672) { |_fraction| 0.0 }
    current = points.last

    entries = [dense_entry(points, current)]
    svg = AgentUsage::Chart.render_comparison(entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    coords = svg[/<polyline[^>]*chart-actual-provider-grok[^>]*points="([^"]+)"/, 1]
    assert_equal points.size, coords.split(" ").size, "polyline must still pass through every observation"

    # Consecutive 15-minute observations are only ~1.6 SVG px apart on the x
    # axis, so with an identical (flat) y this used to render a logo on
    # every single one of them: a 672-icon caterpillar. Distance-based
    # thinning should collapse that to roughly one marker per logo width
    # while still sampling meaningfully across the full week.
    logo_markers = svg.scan('href="/logos/grok.png"').size
    assert_operator logo_markers, :<, points.size / 4, "must be far fewer markers than raw observations"
    assert_operator logo_markers, :>, 10, "must still sample spaced points across the window, not just the guaranteed ones"

    assert_includes svg, "chart-point-current"
    assert_includes svg, "chart-marker-halo"
  end

  def test_dense_gradually_changing_weekly_history_thins_markers_but_keeps_current
    points = dense_history_points(672) { |fraction| (1.0 - fraction) * 100.0 }
    current = points.last

    entries = [dense_entry(points, current)]
    svg = AgentUsage::Chart.render_comparison(entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    coords = svg[/<polyline[^>]*chart-actual-provider-grok[^>]*points="([^"]+)"/, 1]
    assert_equal points.size, coords.split(" ").size, "polyline must still pass through every observation"

    # A gradually-changing series (a realistic slow-burn usage curve) still
    # moves only a fraction of a pixel per 15-minute step, so it must not
    # regress to a marker-per-point wall of icons just because every y
    # value differs slightly from its neighbor.
    logo_markers = svg.scan('href="/logos/grok.png"').size
    assert_operator logo_markers, :<, points.size / 4, "must be far fewer markers than raw observations"
    assert_operator logo_markers, :>, 10, "must still sample spaced points across the window"

    assert_includes svg, "chart-point-current"
    assert_includes svg, "chart-marker-halo"
  end

  def test_a_meaningful_jump_still_gets_its_own_marker_despite_tight_x_spacing
    step = 2.0 / AgentUsage::Chart::COMPARISON_PLOT_WIDTH # ~2 SVG px per step in x
    inferred = { x: 0.0, y: 100.0, collected_at: "2026-01-01T00:00:00Z", inferred: true }
    first_real = { x: 0.01, y: 90.0, collected_at: "2026-01-01T00:15:00Z", inferred: false }
    # Same y as first_real, ~2px away in x: should be swallowed by thinning.
    near_duplicate = { x: 0.01 + step, y: 90.0, collected_at: "2026-01-01T00:30:00Z", inferred: false }
    # Big y drop, still only ~2px further right in x: must still get a marker.
    jump = { x: 0.01 + (2 * step), y: 40.0, collected_at: "2026-01-01T00:45:00Z", inferred: false }
    # Same y as the jump, ~2px away in x: should be swallowed by thinning.
    after_jump = { x: 0.01 + (3 * step), y: 40.0, collected_at: "2026-01-01T01:00:00Z", inferred: false }
    current = { x: 1.0, y: 40.0, collected_at: "2026-01-08T00:00:00Z", inferred: false }
    points = [inferred, first_real, near_duplicate, jump, after_jump, current]

    entries = [dense_entry(points, current)]
    svg = AgentUsage::Chart.render_comparison(entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    coords = svg[/<polyline[^>]*chart-actual-provider-grok[^>]*points="([^"]+)"/, 1]
    assert_equal points.size, coords.split(" ").size

    # Guaranteed: inferred, first real, current. Plus the jump, which is
    # kept despite tiny x spacing because its y move is visually meaningful.
    # near_duplicate and after_jump are each ~2px from their neighbor with
    # no y movement, so they're thinned away.
    logo_markers = svg.scan('href="/logos/grok.png"').size
    assert_equal 4, logo_markers
  end

  def test_empty_entries_still_render_a_valid_chart_with_a_description
    svg = AgentUsage::Chart.render_comparison([], dom_id: "weekly-chart", section_label: "Weekly subscription comparison")
    assert_includes svg, "No active window data yet"
    assert_includes svg, 'class="chart-ideal"'
  end

  private

  def entry(provider:, label:, window_label:, remaining_percent:, gap_points:)
    inferred = { x: 0.0, y: 100.0, collected_at: "2026-01-01T00:00:00Z", inferred: true }
    real = { x: 1.0, y: remaining_percent, collected_at: "2026-01-08T00:00:00Z", inferred: false }
    {
      provider: provider,
      label: label,
      window_key: "primary",
      window_label: window_label,
      remaining_percent: remaining_percent,
      gap_points: gap_points,
      reset_countdown_seconds: 86_400,
      period_start: "2026-01-01T00:00:00Z",
      period_end: "2026-01-08T00:00:00Z",
      chart: {
        ideal: [{ x: 0.0, y: 100.0 }, { x: 1.0, y: 0.0 }],
        actual: [inferred, real],
        current: real,
        projection: nil,
      },
    }
  end

  def dense_entry(points, current)
    {
      provider: "grok",
      label: "Grok",
      window_key: "primary",
      window_label: "Current period",
      remaining_percent: current[:y],
      gap_points: -20.0,
      reset_countdown_seconds: 86_400,
      period_start: "2026-01-01T00:00:00Z",
      period_end: "2026-01-08T00:00:00Z",
      chart: { ideal: [{ x: 0.0, y: 100.0 }, { x: 1.0, y: 0.0 }], actual: points, current: current, projection: nil },
    }
  end

  # A realistic dense 15-minute-interval weekly history: `count` real
  # observations evenly spaced across the window, plus the inferred start.
  def dense_history_points(count)
    inferred = { x: 0.0, y: 100.0, collected_at: "2026-01-01T00:00:00Z", inferred: true }
    reals = (1..count).map do |i|
      fraction = i / count.to_f
      {
        x: fraction,
        y: yield(fraction),
        collected_at: (Time.parse("2026-01-01T00:00:00Z") + (i * 15 * 60)).iso8601,
        inferred: false,
      }
    end
    [inferred, *reals]
  end
end
