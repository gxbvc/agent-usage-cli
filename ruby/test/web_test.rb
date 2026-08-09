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

  def test_dashboard_renders_recommendation_and_provider_cards_after_collection
    post "/api/collect"
    get "/"

    assert last_response.ok?
    # Fixture windows reset in the past relative to any real test run date, so
    # elapsed_fraction clamps to 1.0 for every provider and ranking reduces to
    # "highest remaining_percent wins" (Grok 73.5 > Codex 70 > Claude 60).
    assert_includes last_response.body, "Use Grok next"
    assert_includes last_response.body, "Claude"
    assert_includes last_response.body, "Codex"
    assert_includes last_response.body, "usage-chart"
  end

  def test_dashboard_json_reflects_stored_data
    post "/api/collect"
    get "/api/dashboard.json"

    body = JSON.parse(last_response.body)
    assert_equal %w[claude codex grok], body["data"]["providers"].map { |p| p["provider"] }.sort
    refute_nil body["data"]["recommendation"]
  end
end
