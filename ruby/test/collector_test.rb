require_relative "test_helper"
require "agent_usage/collector"
require "agent_usage/database"

class CollectorTest < AgentUsageTest
  def test_run_stores_one_raw_snapshot_and_its_normalized_windows
    collector = AgentUsage::Collector.new(db_path: @db_path, cli_runner: fake_runner("envelope_complete.json"))
    result = collector.run

    refute result[:locked]
    assert result[:stored]

    db = AgentUsage::Database.connect(path: @db_path)
    assert_equal 1, db.get_first_value("SELECT COUNT(*) FROM raw_snapshots")

    providers = db.execute("SELECT DISTINCT provider FROM window_observations").map { |row| row["provider"] }.sort
    assert_equal %w[claude codex grok], providers

    claude_windows = db.execute("SELECT window_key FROM window_observations WHERE provider = 'claude'")
                        .map { |row| row["window_key"] }.sort
    assert_equal %w[five_hour seven_day seven_day_sonnet], claude_windows
    db.close
  end

  def test_second_run_adds_history_without_duplicating_rows_within_a_snapshot
    collector = AgentUsage::Collector.new(db_path: @db_path, cli_runner: fake_runner("envelope_complete.json"))
    collector.run
    collector.run

    db = AgentUsage::Database.connect(path: @db_path)
    assert_equal 2, db.get_first_value("SELECT COUNT(*) FROM raw_snapshots")

    per_snapshot_claude_seven_day = db.execute(
      "SELECT raw_snapshot_id, COUNT(*) AS count FROM window_observations " \
      "WHERE provider = 'claude' AND window_key = 'seven_day' GROUP BY raw_snapshot_id",
    )
    assert_equal 2, per_snapshot_claude_seven_day.size
    per_snapshot_claude_seven_day.each { |row| assert_equal 1, row["count"] }
    db.close
  end

  def test_partial_envelope_stores_errors_and_only_successful_providers
    collector = AgentUsage::Collector.new(db_path: @db_path, cli_runner: fake_runner("envelope_partial.json"))
    collector.run

    db = AgentUsage::Database.connect(path: @db_path)
    snapshot = db.get_first_row("SELECT * FROM raw_snapshots")
    assert_equal 0, snapshot["complete"]
    errors = JSON.parse(snapshot["errors_json"])
    assert_equal %w[codex grok], errors.map { |e| e["provider"] }.sort

    providers = db.execute("SELECT DISTINCT provider FROM window_observations").map { |row| row["provider"] }
    assert_equal ["claude"], providers
    db.close
  end

  def test_overlapping_run_is_skipped_via_nonblocking_lock
    lock_path = "#{@db_path}.lock"
    FileUtils.mkdir_p(File.dirname(lock_path))
    held_lock = File.open(lock_path, File::RDWR | File::CREAT, 0o644)
    held_lock.flock(File::LOCK_EX)

    begin
      collector = AgentUsage::Collector.new(
        db_path: @db_path,
        lock_path: lock_path,
        cli_runner: fake_runner("envelope_complete.json"),
      )
      result = collector.run
      assert result[:locked]
      refute File.exist?(@db_path), "collector must not touch the database when it could not acquire the lock"
    ensure
      held_lock.flock(File::LOCK_UN)
      held_lock.close
    end
  end

  def test_raw_json_preserves_the_full_envelope_for_future_reprocessing
    collector = AgentUsage::Collector.new(db_path: @db_path, cli_runner: fake_runner("envelope_complete.json"))
    collector.run

    db = AgentUsage::Database.connect(path: @db_path)
    raw = JSON.parse(db.get_first_value("SELECT raw_json FROM raw_snapshots"))
    assert_equal "2026-01-01T00:00:00.000Z", raw["observedAt"]
    assert raw["providers"]["codex"]["usage"]["rateLimits"]["rateLimitsByLimitId"].key?("codex_bengalfox")
    db.close
  end
end
