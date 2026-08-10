require_relative "test_helper"
require "rack/test"
require "agent_usage/web"

class WebTest < AgentUsageTest
  include Rack::Test::Methods

  def app
    AgentUsage::Web
  end

  def setup
    super
    AgentUsage::Web.db_path_override = @db_path
    AgentUsage::Web.cli_runner_override = fake_runner("envelope_complete.json")
    header "Host", "127.0.0.1"
  end

  def teardown
    AgentUsage::Web.db_path_override = nil
    AgentUsage::Web.cli_runner_override = nil
    super
  end

  def test_health_returns_ok_json
    get "/health"
    assert last_response.ok?
    body = JSON.parse(last_response.body)
    assert body["ok"]
    assert_equal "ok", body["data"]["status"]
  end

  def test_dashboard_shows_empty_state_before_any_collection
    get "/"
    assert last_response.ok?
    assert_includes last_response.body, "No usage data yet"
  end

  def test_dashboard_json_is_empty_shaped_before_any_collection
    get "/api/dashboard.json"
    assert last_response.ok?
    body = JSON.parse(last_response.body)
    assert_equal [], body["data"]["providers"]
    assert_nil body["data"]["recommendation"]
  end

  def test_manual_collect_route_stores_data_and_redirects_by_default
    post "/api/collect"
    assert_equal 302, last_response.status
    assert_includes last_response.location, "/"

    db = AgentUsage::Database.connect(path: @db_path)
    assert_equal 1, db.get_first_value("SELECT COUNT(*) FROM raw_snapshots")
    db.close
  end

  def test_manual_collect_route_returns_json_when_requested
    post "/api/collect", {}, { "HTTP_ACCEPT" => "application/json" }
    assert last_response.ok?
    body = JSON.parse(last_response.body)
    assert body["ok"]
    assert_equal true, body["data"]["stored"]
  end

  def test_dashboard_renders_provider_cards_after_collection
    post "/api/collect"
    get "/"

    assert last_response.ok?
    # Fixture windows reset in the past relative to any real test run date, so
    # elapsed_fraction clamps to 1.0 for every provider and ranking reduces to
    # "highest remaining_percent wins" on each provider's weekly-class window:
    # Claude seven_day 60.0 > Codex secondary 50.0 > Grok currentPeriod 26.5.
    assert_includes last_response.body, "Claude"
    assert_includes last_response.body, "Codex"
    assert_includes last_response.body, "comparison-chart"
  end

  def test_dashboard_html_includes_both_full_width_comparison_sections
    post "/api/collect"
    get "/"

    assert_includes last_response.body, "Weekly subscription comparison"
    assert_includes last_response.body, "Short-window comparison"
    assert_includes last_response.body, 'id="weekly-comparison-heading"'
    assert_includes last_response.body, 'id="short-comparison-heading"'
    # Provider cards keep metrics but no longer embed a per-card chart.
    refute_includes last_response.body, "chart-figure"
  end

  def test_dashboard_json_reflects_stored_data
    post "/api/collect"
    get "/api/dashboard.json"

    body = JSON.parse(last_response.body)
    assert_equal %w[claude codex grok], body["data"]["providers"].map { |p| p["provider"] }.sort
    refute_nil body["data"]["recommendation"]
  end

  def test_dashboard_json_includes_the_weekly_and_short_comparison_groups
    post "/api/collect"
    get "/api/dashboard.json"

    body = JSON.parse(last_response.body)
    comparison = body["data"]["comparison"]
    refute_nil comparison
    assert_equal %w[claude codex grok], comparison["weekly"].map { |e| e["provider"] }.sort
    assert_equal %w[claude codex], comparison["short"].map { |e| e["provider"] }.sort
    assert_equal "secondary", comparison["weekly"].find { |e| e["provider"] == "codex" }["window_key"]
    assert_equal "primary", comparison["short"].find { |e| e["provider"] == "codex" }["window_key"]
    assert_equal "five_hour", comparison["short"].find { |e| e["provider"] == "claude" }["window_key"]
  end

  def test_dashboard_page_serves_all_three_vendored_provider_logos
    %w[claude.svg codex.png grok.png].each do |file|
      get "/logos/#{file}"
      assert last_response.ok?, "expected /logos/#{file} to be served locally"
    end
  end

  def test_dashboard_omits_the_recommendation_box_header_subtitle_and_collect_button
    post "/api/collect"
    get "/"

    refute_includes last_response.body, "Use Claude next"
    refute_includes last_response.body, "recommendation"
    refute_includes last_response.body, "Claude, Codex, and Grok subscription burn-down"
    refute_includes last_response.body, "Collect now"
    refute_includes last_response.body, 'id="collect-now"'
  end

  def test_dashboard_omits_the_comparison_blurb_paragraphs
    post "/api/collect"
    get "/"

    refute_includes last_response.body, "comparison-blurb"
    refute_includes last_response.body, "normalized to cycle progress so different reset schedules"
  end

  def test_dashboard_json_still_exposes_the_recommendation_even_though_the_ui_box_is_gone
    post "/api/collect"
    get "/api/dashboard.json"

    body = JSON.parse(last_response.body)
    refute_nil body["data"]["recommendation"]
    assert_equal "claude", body["data"]["recommendation"]["provider"]
  end

  def test_footer_names_the_burn_line_and_the_15_minute_collection_cadence
    post "/api/collect"
    get "/"

    assert_includes last_response.body, "pace needed to hit 0% at reset"
    assert_includes last_response.body, "every 15 minutes"
  end

  def test_comparison_legend_shows_each_series_projected_percentage_at_reset
    db = AgentUsage::Database.connect(path: @db_path)
    insert_claude_observation(db, collected_at: "2026-01-02T00:00:00Z", remaining_percent: 90.0)
    insert_claude_observation(db, collected_at: "2026-01-04T00:00:00Z", remaining_percent: 70.0)
    db.close

    get "/"

    assert_includes last_response.body, "projected"
    assert_includes last_response.body, "at reset (current pace)"
  end

  private

  def insert_claude_observation(db, collected_at:, remaining_percent:)
    db.execute(
      "INSERT INTO raw_snapshots (collected_at, observed_at, schema_version, complete, errors_json, raw_json) " \
      "VALUES (?, ?, 1, 1, '[]', '{}')",
      [collected_at, collected_at],
    )
    raw_snapshot_id = db.last_insert_row_id
    db.execute(
      "INSERT INTO window_observations " \
      "(raw_snapshot_id, collected_at, provider, window_key, primary_window, period_start, period_end, " \
      "used_percent, remaining_percent, normalizer_version, raw_window_json) " \
      "VALUES (?, ?, 'claude', 'seven_day', 1, '2026-01-01T00:00:00Z', '2026-01-08T00:00:00Z', ?, ?, 1, '{}')",
      [raw_snapshot_id, collected_at, 100.0 - remaining_percent, remaining_percent],
    )
  end
end
