require "json"

require_relative "database"
require_relative "normalizer"

module AgentUsage
  # Rebuilds window_observations from the immutable raw_snapshots history.
  # Safe to run at any time and any number of times: each snapshot's
  # existing rows are deleted and rebuilt from its raw_json inside one
  # transaction, so a normalizer fix (e.g. the Grok percent-used
  # correction) repairs already-stored history without re-collecting.
  # raw_snapshots itself is never modified.
  module Reprocessor
    def self.run(db_path: Database.path)
      db = Database.connect(path: db_path)
      snapshot_count = 0
      observation_count = 0

      db.execute("SELECT id, collected_at, raw_json FROM raw_snapshots ORDER BY id ASC").each do |row|
        data = JSON.parse(row["raw_json"])
        db.transaction do
          db.execute("DELETE FROM window_observations WHERE raw_snapshot_id = ?", [row["id"]])

          (data["providers"] || {}).each do |provider, provider_result|
            Normalizer.windows_for(provider, provider_result).each do |observation|
              Normalizer.store_window(db, row["id"], row["collected_at"], provider, observation)
              observation_count += 1
            end
          end
        end
        snapshot_count += 1
      end

      { snapshots: snapshot_count, observations: observation_count }
    ensure
      db&.close
    end
  end
end
