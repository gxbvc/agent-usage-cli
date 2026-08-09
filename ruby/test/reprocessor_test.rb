require_relative "test_helper"
require "agent_usage/database"
require "agent_usage/reprocessor"

class ReprocessorTest < AgentUsageTest
  def setup
    super
    @db = AgentUsage::Database.connect(path: @db_path)
  end

  def teardown
    @db.close
    super
  end

  def test_repairs_old_style_grok_snapshots_by_trusting_credit_usage_percent
    # An old-shaped raw_json produced by a pre-fix agent-usage-cli build:
    # usedPercent/remainingPercent are inverted, creditUsagePercent is the
    # only reliable field, and the stored window_observations row still
    # carries the wrong (inverted) percentages and normalizer_version 1.
    raw_json = JSON.generate(
      "providers" => {
        "grok" => {
          "usage" => {
            "creditUsagePercent" => 73.5,
            "usedPercent" => 26.5,
            "remainingPercent" => 73.5,
            "currentPeriod" => { "start" => "2026-01-01T00:00:00Z", "end" => "2026-01-08T00:00:00Z" },
          },
        },
        "claude" => {
          "usage" => {
            "windows" => {
              "seven_day" => { "utilization" => 40, "resetsAt" => "2026-01-08T00:00:00Z" },
            },
          },
        },
      },
    )
    raw_snapshot_id = insert_raw_snapshot(raw_json)
    insert_stale_window_observation(
      raw_snapshot_id: raw_snapshot_id,
      provider: "grok",
      window_key: "currentPeriod",
      used_percent: 26.5,
      remaining_percent: 73.5,
    )
    insert_stale_window_observation(
      raw_snapshot_id: raw_snapshot_id,
      provider: "claude",
      window_key: "seven_day",
      used_percent: 40.0,
      remaining_percent: 60.0,
    )

    before_raw = @db.get_first_row("SELECT * FROM raw_snapshots WHERE id = ?", [raw_snapshot_id])

    result = AgentUsage::Reprocessor.run(db_path: @db_path)
    assert_equal 1, result[:snapshots]
    assert_equal 2, result[:observations]

    after_raw = @db.get_first_row("SELECT * FROM raw_snapshots WHERE id = ?", [raw_snapshot_id])
    assert_equal before_raw, after_raw, "raw_snapshots rows must be untouched by reprocessing"

    grok_row = @db.get_first_row(
      "SELECT * FROM window_observations WHERE raw_snapshot_id = ? AND provider = 'grok'",
      [raw_snapshot_id],
    )
    assert_in_delta 73.5, grok_row["used_percent"], 0.0001
    assert_in_delta 26.5, grok_row["remaining_percent"], 0.0001
    assert_equal AgentUsage::Normalizer::VERSION, grok_row["normalizer_version"]

    claude_row = @db.get_first_row(
      "SELECT * FROM window_observations WHERE raw_snapshot_id = ? AND provider = 'claude'",
      [raw_snapshot_id],
    )
    assert_in_delta 40.0, claude_row["used_percent"], 0.0001
    assert_in_delta 60.0, claude_row["remaining_percent"], 0.0001

    assert_equal 1, @db.get_first_value("SELECT COUNT(*) FROM window_observations WHERE raw_snapshot_id = ? AND provider = 'grok'", [raw_snapshot_id])
  end

  def test_is_idempotent_across_repeated_runs
    raw_json = JSON.generate(
      "providers" => {
        "grok" => {
          "usage" => {
            "creditUsagePercent" => 73.5,
            "currentPeriod" => { "start" => "2026-01-01T00:00:00Z", "end" => "2026-01-08T00:00:00Z" },
          },
        },
      },
    )
    raw_snapshot_id = insert_raw_snapshot(raw_json)

    first = AgentUsage::Reprocessor.run(db_path: @db_path)
    second = AgentUsage::Reprocessor.run(db_path: @db_path)

    assert_equal first, second
    assert_equal 1, @db.get_first_value(
      "SELECT COUNT(*) FROM window_observations WHERE raw_snapshot_id = ?",
      [raw_snapshot_id],
    )
  end

  private

  def insert_raw_snapshot(raw_json)
    @db.execute(
      "INSERT INTO raw_snapshots (collected_at, observed_at, schema_version, complete, errors_json, raw_json) " \
      "VALUES (?, ?, 2, 1, '[]', ?)",
      ["2026-01-04T00:00:00Z", "2026-01-04T00:00:00Z", raw_json],
    )
    @db.last_insert_row_id
  end

  def insert_stale_window_observation(raw_snapshot_id:, provider:, window_key:, used_percent:, remaining_percent:)
    @db.execute(
      "INSERT INTO window_observations " \
      "(raw_snapshot_id, collected_at, provider, window_key, primary_window, period_start, period_end, " \
      "used_percent, remaining_percent, normalizer_version, raw_window_json) " \
      "VALUES (?, ?, ?, ?, 1, ?, ?, ?, ?, 1, '{}')",
      [
        raw_snapshot_id,
        "2026-01-04T00:00:00Z",
        provider,
        window_key,
        "2026-01-01T00:00:00Z",
        "2026-01-08T00:00:00Z",
        used_percent,
        remaining_percent,
      ],
    )
  end
end
