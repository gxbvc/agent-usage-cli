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

  def test_renders_exactly_one_large_current_marker_per_provider_with_no_halo
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    assert_equal 3, svg.scan("<image").size
    assert_includes svg, %(width="#{AgentUsage::Chart::CURRENT_LOGO_SIZE}" height="#{AgentUsage::Chart::CURRENT_LOGO_SIZE}")
    assert_includes svg, "chart-point-current"
    refute_includes svg, "chart-marker-halo"
    refute_includes svg, "chart-marker-ring"
  end

  def test_day_divisions_draw_vertical_grid_lines
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison", day_divisions: 7)
    vertical_lines = svg.scan(/<line class="chart-grid" x1="([\d.]+)" y1="28" x2="\1"/)
    assert_equal 6, vertical_lines.size
  end

  def test_no_day_divisions_by_default
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")
    vertical_lines = svg.scan(/<line class="chart-grid" x1="([\d.]+)" y1="28" x2="\1"/)
    assert_equal 0, vertical_lines.size
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

  def test_burn_line_runs_from_current_point_straight_to_zero_at_reset
    entries = [entry(provider: "claude", label: "Claude", window_label: "7-day", remaining_percent: 60.0, gap_points: 10.0)]
    entries.first[:chart][:actual] = [
      { x: 0.0, y: 100.0, collected_at: "2026-01-01T00:00:00Z", inferred: true },
      { x: 0.5, y: 60.0, collected_at: "2026-01-04T12:00:00Z", inferred: false },
    ]

    svg = AgentUsage::Chart.render_comparison(entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    right_edge = (AgentUsage::Chart::COMPARISON_WIDTH - AgentUsage::Chart::COMPARISON_MARGIN_RIGHT).to_f
    bottom = (AgentUsage::Chart::COMPARISON_HEIGHT - AgentUsage::Chart::COMPARISON_MARGIN_BOTTOM).to_f
    assert_includes svg, %(class="chart-burn chart-burn-provider-claude")
    assert_includes svg, %(x2="#{right_edge}" y2="#{bottom}")
    assert_includes svg, "pace needed to use the remaining 60.0% by reset"
    assert_equal 1, svg.scan("<image").size, "only the current-point logo, no endpoint logo"
    refute_includes svg, "chart-projection"
  end

  def test_dense_history_still_gets_exactly_one_marker
    points = dense_history_points(672) { |fraction| (1.0 - fraction) * 100.0 }
    current = points.last

    entries = [dense_entry(points, current)]
    svg = AgentUsage::Chart.render_comparison(entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    coords = svg[/<polyline[^>]*chart-actual-provider-grok[^>]*points="([^"]+)"/, 1]
    assert_equal points.size, coords.split(" ").size, "polyline must still pass through every observation"

    assert_equal 1, svg.scan('href="/logos/grok.png"').size, "only the current point gets a marker"
    assert_includes svg, "chart-point-current"
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
