require "sqlite3"
require "fileutils"

module AgentUsage
  module Database
    DEFAULT_PATH = File.expand_path("~/Library/Application Support/agent-usage-cli/usage.sqlite3")

    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS raw_snapshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        collected_at TEXT NOT NULL,
        observed_at TEXT NOT NULL,
        schema_version INTEGER NOT NULL,
        complete INTEGER NOT NULL,
        errors_json TEXT NOT NULL,
        raw_json TEXT NOT NULL
      );

      CREATE TABLE IF NOT EXISTS window_observations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        raw_snapshot_id INTEGER NOT NULL REFERENCES raw_snapshots(id),
        collected_at TEXT NOT NULL,
        provider TEXT NOT NULL,
        window_key TEXT NOT NULL,
        primary_window INTEGER NOT NULL,
        period_start TEXT,
        period_end TEXT,
        used_percent REAL,
        remaining_percent REAL,
        normalizer_version INTEGER NOT NULL,
        raw_window_json TEXT NOT NULL
      );

      CREATE UNIQUE INDEX IF NOT EXISTS idx_window_observations_unique
        ON window_observations (raw_snapshot_id, provider, window_key);

      CREATE INDEX IF NOT EXISTS idx_window_observations_lookup
        ON window_observations (provider, window_key, collected_at);
    SQL

    # AGENT_USAGE_DB overrides the default location. Tests point it at a
    # temporary file so real usage history is never touched.
    def self.path
      override = ENV["AGENT_USAGE_DB"]
      override && !override.empty? ? override : DEFAULT_PATH
    end

    def self.connect(path: self.path)
      FileUtils.mkdir_p(File.dirname(path)) unless path == ":memory:"
      db = SQLite3::Database.new(path)
      db.results_as_hash = true
      db.busy_timeout = 5_000
      db.execute("PRAGMA journal_mode = WAL")
      db.execute("PRAGMA foreign_keys = ON")
      setup_schema(db)
      db
    end

    def self.setup_schema(db)
      db.execute_batch(SCHEMA)
    end
  end
end
