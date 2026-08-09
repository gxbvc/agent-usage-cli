require_relative "test_helper"
require "agent_usage/database"
require "agent_usage/dashboard"

class DashboardTest < AgentUsageTest
  def setup
    super
    @db = AgentUsage::Database.connect(path: @db_path)
  end

  def teardown
    @db.close
    super
  end

  def test_empty_database_returns_empty_view
    view = AgentUsage::Dashboard.build(@db, now: Time.parse("2026-01-04T00:00:00Z"))
    assert_equal [], view[:providers]
    assert_nil view[:recommendation]
    assert view[:stale]
  end

  def test_gap_pace_and_reset_math_for_a_single_window
    insert_snapshot(collected_at: "2026-01-02T00:00:00Z", windows: [claude_window(remaining_percent: 90.0, collected_at: "2026-01-02T00:00:00Z")])
    insert_snapshot(collected_at: "2026-01-04T00:00:00Z", windows: [claude_window(remaining_percent: 70.0, collected_at: "2026-01-04T00:00:00Z")])

    view = AgentUsage::Dashboard.build(@db, now: Time.parse("2026-01-04T12:00:00Z"))
    window = view[:providers].first[:ranking_window]

    assert_in_delta 0.5, window[:elapsed_fraction], 0.0001
    assert_in_delta 50.0, window[:ideal_remaining_percent], 0.0001
    assert_in_delta 20.0, window[:gap_points], 0.0001
    assert_in_delta 3.5, window[:remaining_days], 0.0001
    assert_in_delta 20.0, window[:required_daily_burn], 0.0001
    assert_in_delta 302_400.0, window[:reset_countdown_seconds], 1.0
  end

  def test_projection_uses_the_slope_between_the_first_and_last_real_observation
    insert_snapshot(collected_at: "2026-01-02T00:00:00Z", windows: [claude_window(remaining_percent: 90.0, collected_at: "2026-01-02T00:00:00Z")])
    insert_snapshot(collected_at: "2026-01-04T00:00:00Z", windows: [claude_window(remaining_percent: 70.0, collected_at: "2026-01-04T00:00:00Z")])

    view = AgentUsage::Dashboard.build(@db, now: Time.parse("2026-01-04T12:00:00Z"))
    chart = view[:providers].first[:ranking_window][:chart]

    refute_nil chart[:projection]
    assert_in_delta 30.0, chart[:projection][:to][:y], 0.0001
    assert_in_delta 1.0, chart[:projection][:to][:x], 0.0001
  end

  def test_single_observation_gets_an_inferred_start_point_and_no_projection
    insert_snapshot(collected_at: "2026-01-04T00:00:00Z", windows: [claude_window(remaining_percent: 70.0, collected_at: "2026-01-04T00:00:00Z")])

    view = AgentUsage::Dashboard.build(@db, now: Time.parse("2026-01-04T12:00:00Z"))
    chart = view[:providers].first[:ranking_window][:chart]

    assert_equal 2, chart[:actual].size
    inferred = chart[:actual].first
    assert inferred[:inferred]
    assert_in_delta 0.0, inferred[:x]
    assert_in_delta 100.0, inferred[:y]
    assert_nil chart[:projection]
  end

  def test_recommendation_ranks_providers_by_primary_window_gap_descending
    insert_snapshot(
      collected_at: "2026-01-04T00:00:00Z",
      windows: [
        claude_window(remaining_percent: 80.0, collected_at: "2026-01-04T00:00:00Z"),
        codex_window(remaining_percent: 60.0, collected_at: "2026-01-04T00:00:00Z"),
        grok_window(remaining_percent: 40.0, collected_at: "2026-01-04T00:00:00Z"),
      ],
    )

    view = AgentUsage::Dashboard.build(@db, now: Time.parse("2026-01-04T00:00:00Z"))

    assert_equal %w[claude codex grok], view[:ranking]
    assert_equal "claude", view[:recommendation][:provider]
  end

  def test_depleted_provider_ranks_after_providers_with_allowance_remaining
    insert_snapshot(
      collected_at: "2026-01-04T00:00:00Z",
      windows: [
        claude_window(remaining_percent: 80.0, collected_at: "2026-01-04T00:00:00Z"),
        codex_window(remaining_percent: 20.0, collected_at: "2026-01-04T00:00:00Z"),
        grok_window(remaining_percent: 0.0, collected_at: "2026-01-04T00:00:00Z"),
      ],
    )

    view = AgentUsage::Dashboard.build(@db, now: Time.parse("2026-01-04T00:00:00Z"))

    assert_equal %w[claude codex grok], view[:ranking]
  end

  def test_ranking_uses_the_weekly_duration_window_not_the_json_literal_primary_flag
    insert_snapshot(
      collected_at: "2026-01-04T00:00:00Z",
      windows: [
        claude_window(remaining_percent: 60.0, collected_at: "2026-01-04T00:00:00Z"),
        # This fixture's Codex snapshot reports "primary" as 5 hours
        # (short-class) and "secondary" as weekly-class — one of the shapes
        # Codex has been observed to use. Ranking must use the weekly one
        # (50.0) by duration, not the literal-primary one (90.0).
        codex_five_hour_window(remaining_percent: 90.0, collected_at: "2026-01-04T00:00:00Z"),
        codex_weekly_window(remaining_percent: 50.0, collected_at: "2026-01-04T00:00:00Z"),
        grok_window(remaining_percent: 26.5, collected_at: "2026-01-04T00:00:00Z"),
      ],
    )

    view = AgentUsage::Dashboard.build(@db, now: Time.parse("2026-01-04T00:00:00Z"))

    assert_equal %w[claude codex grok], view[:ranking]
    codex_view = view[:providers].find { |p| p[:provider] == "codex" }
    assert_equal "secondary", codex_view[:ranking_window][:window_key]
    assert_in_delta 50.0, codex_view[:ranking_window][:remaining_percent], 0.0001
  end

  def test_comparison_groups_windows_by_duration_class_across_providers
    insert_snapshot(
      collected_at: "2026-01-04T00:00:00Z",
      windows: [
        claude_window(remaining_percent: 60.0, collected_at: "2026-01-04T00:00:00Z"),
        codex_five_hour_window(remaining_percent: 90.0, collected_at: "2026-01-04T00:00:00Z"),
        codex_weekly_window(remaining_percent: 50.0, collected_at: "2026-01-04T00:00:00Z"),
        grok_window(remaining_percent: 26.5, collected_at: "2026-01-04T00:00:00Z"),
      ],
    )

    view = AgentUsage::Dashboard.build(@db, now: Time.parse("2026-01-04T00:00:00Z"))

    assert_equal %w[claude codex grok], view[:comparison][:weekly].map { |e| e[:provider] }.sort
    assert_equal %w[codex], view[:comparison][:short].map { |e| e[:provider] }.sort

    codex_weekly = view[:comparison][:weekly].find { |e| e[:provider] == "codex" }
    assert_equal "secondary", codex_weekly[:window_key]
    codex_short = view[:comparison][:short].find { |e| e[:provider] == "codex" }
    assert_equal "primary", codex_short[:window_key]
  end

  def test_surfaces_errors_and_completeness_from_the_latest_snapshot
    insert_snapshot(
      collected_at: "2026-01-04T00:00:00Z",
      windows: [claude_window(remaining_percent: 70.0, collected_at: "2026-01-04T00:00:00Z")],
      complete: false,
      errors: [{ "provider" => "codex", "code" => "CLI_NOT_FOUND", "message" => "codex is not installed" }],
    )

    view = AgentUsage::Dashboard.build(@db, now: Time.parse("2026-01-04T00:00:00Z"))
    refute view[:complete]
    assert_equal 1, view[:errors].size
    assert_equal "codex", view[:errors].first["provider"]
  end

  def test_stale_flag_reflects_time_since_last_collection
    insert_snapshot(collected_at: "2026-01-04T00:00:00Z", windows: [claude_window(remaining_percent: 70.0, collected_at: "2026-01-04T00:00:00Z")])

    fresh = AgentUsage::Dashboard.build(@db, now: Time.parse("2026-01-04T00:10:00Z"))
    stale = AgentUsage::Dashboard.build(@db, now: Time.parse("2026-01-04T01:00:00Z"))

    refute fresh[:stale]
    assert stale[:stale]
  end

  private

  def claude_window(remaining_percent:, collected_at:)
    {
      provider: "claude",
      window_key: "seven_day",
      primary_window: true,
      period_start: "2026-01-01T00:00:00Z",
      period_end: "2026-01-08T00:00:00Z",
      used_percent: 100.0 - remaining_percent,
      remaining_percent: remaining_percent,
      collected_at: collected_at,
    }
  end

  def codex_window(remaining_percent:, collected_at:)
    claude_window(remaining_percent: remaining_percent, collected_at: collected_at).merge(provider: "codex", window_key: "primary")
  end

  def codex_five_hour_window(remaining_percent:, collected_at:)
    {
      provider: "codex",
      window_key: "primary",
      primary_window: true,
      period_start: "2026-01-03T19:00:00Z",
      period_end: "2026-01-04T00:00:00Z",
      used_percent: 100.0 - remaining_percent,
      remaining_percent: remaining_percent,
      collected_at: collected_at,
    }
  end

  def codex_weekly_window(remaining_percent:, collected_at:)
    {
      provider: "codex",
      window_key: "secondary",
      primary_window: false,
      period_start: "2026-01-01T00:00:00Z",
      period_end: "2026-01-08T00:00:00Z",
      used_percent: 100.0 - remaining_percent,
      remaining_percent: remaining_percent,
      collected_at: collected_at,
    }
  end

  def grok_window(remaining_percent:, collected_at:)
    claude_window(remaining_percent: remaining_percent, collected_at: collected_at).merge(provider: "grok", window_key: "currentPeriod")
  end

  def insert_snapshot(collected_at:, windows:, complete: true, errors: [])
    @db.execute(
      "INSERT INTO raw_snapshots (collected_at, observed_at, schema_version, complete, errors_json, raw_json) " \
      "VALUES (?, ?, 1, ?, ?, ?)",
      [collected_at, collected_at, complete ? 1 : 0, JSON.generate(errors), "{}"],
    )
    raw_snapshot_id = @db.last_insert_row_id

    windows.each do |window|
      @db.execute(
        "INSERT INTO window_observations " \
        "(raw_snapshot_id, collected_at, provider, window_key, primary_window, period_start, period_end, " \
        "used_percent, remaining_percent, normalizer_version, raw_window_json) " \
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, '{}')",
        [
          raw_snapshot_id,
          window[:collected_at],
          window[:provider],
          window[:window_key],
          window[:primary_window] ? 1 : 0,
          window[:period_start],
          window[:period_end],
          window[:used_percent],
          window[:remaining_percent],
        ],
      )
    end
    raw_snapshot_id
  end
end
