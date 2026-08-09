require "json"
require "time"
require "open3"
require "timeout"
require "fileutils"

require_relative "database"
require_relative "normalizer"

module AgentUsage
  # Runs the existing `agent-usage-cli` command, stores the raw envelope,
  # and normalizes each provider's windows into window_observations.
  #
  # A nonblocking flock guards against overlapping launchd runs: a second
  # collector that finds the lock held exits successfully without touching
  # the database.
  class Collector
    DEFAULT_TIMEOUT_SECONDS = 25
    TERMINATE_GRACE_SECONDS = 0.5
    KILL_WAIT_SECONDS = 1.0

    def self.default_runner(timeout_seconds: DEFAULT_TIMEOUT_SECONDS, command: "agent-usage-cli", args: [].freeze)
      lambda { run_command(command, *args, timeout_seconds: timeout_seconds) }
    end

    # Runs command/args to completion or raises Timeout::Error. Both stdout
    # and stderr are drained on background threads for the life of the
    # child: a verbose child can otherwise fill the unread pipe's OS buffer
    # and block forever, hanging this method past its own timeout. On
    # timeout the child's whole process group is killed (SIGTERM, then
    # SIGKILL if it is still alive after a short grace period) so nothing
    # is left running after this method returns.
    def self.run_command(command, *args, timeout_seconds:)
      stdout = +""
      Open3.popen3(command, *args, pgroup: true) do |stdin, stdout_io, stderr_io, wait_thread|
        stdin.close
        stdout_reader = Thread.new { stdout_io.read.to_s }
        stderr_reader = Thread.new { stderr_io.read.to_s }

        unless wait_thread.join(timeout_seconds)
          kill_process_group(wait_thread.pid)
          wait_thread.join(KILL_WAIT_SECONDS)
          stdout_reader.join(TERMINATE_GRACE_SECONDS + KILL_WAIT_SECONDS)
          stderr_reader.join(TERMINATE_GRACE_SECONDS + KILL_WAIT_SECONDS)
          raise Timeout::Error, "#{command} timed out after #{timeout_seconds}s"
        end

        stdout = stdout_reader.value
        stderr_reader.value
      end
      stdout
    end

    def self.kill_process_group(pid)
      signal_process_group(pid, "TERM")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TERMINATE_GRACE_SECONDS
      sleep(0.02) while process_group_alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      return unless process_group_alive?(pid)

      signal_process_group(pid, "KILL")
    end

    def self.signal_process_group(pid, signal)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH
      nil
    end

    def self.process_group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    end
    private_class_method :kill_process_group, :signal_process_group, :process_group_alive?

    def initialize(db_path: Database.path, lock_path: nil, cli_runner: self.class.default_runner)
      @db_path = db_path
      @lock_path = lock_path || "#{db_path}.lock"
      @cli_runner = cli_runner
    end

    # Returns { locked: true } when another collection is in progress, or
    # { locked: false, stored: true, data: <UsageData> } after a successful run.
    def run
      FileUtils.mkdir_p(File.dirname(@lock_path))
      lock_file = File.open(@lock_path, File::RDWR | File::CREAT, 0o644)
      unless lock_file.flock(File::LOCK_EX | File::LOCK_NB)
        lock_file.close
        return { locked: true }
      end

      begin
        stdout = @cli_runner.call
        data = parse_envelope(stdout)
        store(data)
        { locked: false, stored: true, data: data }
      ensure
        lock_file.flock(File::LOCK_UN)
        lock_file.close
      end
    end

    private

    def parse_envelope(stdout)
      envelope = JSON.parse(stdout)
      raise "agent-usage-cli returned a failed envelope" unless envelope["ok"]

      envelope.fetch("data")
    end

    def store(data)
      db = Database.connect(path: @db_path)
      collected_at = Time.now.utc.iso8601
      db.transaction do
        db.execute(
          "INSERT INTO raw_snapshots " \
          "(collected_at, observed_at, schema_version, complete, errors_json, raw_json) " \
          "VALUES (?, ?, ?, ?, ?, ?)",
          [
            collected_at,
            data["observedAt"],
            data["schemaVersion"],
            data["complete"] ? 1 : 0,
            JSON.generate(data["errors"] || []),
            JSON.generate(data),
          ],
        )
        raw_snapshot_id = db.last_insert_row_id

        (data["providers"] || {}).each do |provider, provider_result|
          Normalizer.windows_for(provider, provider_result).each do |observation|
            Normalizer.store_window(db, raw_snapshot_id, collected_at, provider, observation)
          end
        end
      end
      db.close
    end
  end
end
