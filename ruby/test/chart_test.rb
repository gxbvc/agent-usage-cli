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

  def test_uses_distinct_marker_shapes_so_providers_do_not_rely_on_color_alone
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")

    assert_includes svg, "<circle"
    assert_includes svg, "<rect"
    assert_includes svg, "<polygon"
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

  def test_marks_inferred_start_points_distinctly
    svg = AgentUsage::Chart.render_comparison(@entries, dom_id: "weekly-chart", section_label: "Weekly subscription comparison")
    assert_includes svg, "chart-point-inferred"
    assert_includes svg, "inferred period start"
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
end
