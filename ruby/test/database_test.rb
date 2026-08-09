require_relative "test_helper"
require "agent_usage/database"

class DatabaseTest < AgentUsageTest
  def test_creates_expected_tables
    db = AgentUsage::Database.connect(path: @db_path)
    tables = db.execute("SELECT name FROM sqlite_master WHERE type = 'table'").map { |row| row["name"] }
    assert_includes tables, "raw_snapshots"
    assert_includes tables, "window_observations"
    db.close
  end

  def test_setup_is_idempotent
    AgentUsage::Database.connect(path: @db_path).close
    AgentUsage::Database.connect(path: @db_path).close
    db = AgentUsage::Database.connect(path: @db_path)
    assert db.get_first_value("SELECT 1")
    db.close
  end

  def test_enables_wal_and_foreign_keys
    db = AgentUsage::Database.connect(path: @db_path)
    assert_equal "wal", db.get_first_value("PRAGMA journal_mode")
    assert_equal 1, db.get_first_value("PRAGMA foreign_keys")
    db.close
  end

  def test_unique_index_rejects_duplicate_window_within_snapshot
    db = AgentUsage::Database.connect(path: @db_path)
    db.execute(
      "INSERT INTO raw_snapshots (collected_at, observed_at, schema_version, complete, errors_json, raw_json) " \
      "VALUES (?, ?, ?, ?, ?, ?)",
      ["2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z", 1, 1, "[]", "{}"],
    )
    raw_id = db.last_insert_row_id

    db.execute(insert_window_sql, [raw_id, "claude", "seven_day", 10.0, 90.0])
    assert_raises(SQLite3::ConstraintException) do
      db.execute(insert_window_sql, [raw_id, "claude", "seven_day", 20.0, 80.0])
    end
    db.close
  end

  def test_default_path_honors_agent_usage_db_override
    previous = ENV["AGENT_USAGE_DB"]
    ENV["AGENT_USAGE_DB"] = "/tmp/custom-agent-usage.sqlite3"
    assert_equal "/tmp/custom-agent-usage.sqlite3", AgentUsage::Database.path
  ensure
    ENV["AGENT_USAGE_DB"] = previous
  end

  private

  def insert_window_sql
    "INSERT INTO window_observations " \
    "(raw_snapshot_id, collected_at, provider, window_key, primary_window, period_start, period_end, " \
    "used_percent, remaining_percent, normalizer_version, raw_window_json) " \
    "VALUES (?, '2026-01-01T00:00:00Z', ?, ?, 1, '2025-12-25T00:00:00Z', '2026-01-01T00:00:00Z', ?, ?, 1, '{}')"
  end
end
