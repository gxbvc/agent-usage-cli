require "erb"
require "fileutils"
require "open3"
require "rbconfig"

require_relative "database"

module AgentUsage
  # Renders the checked-in launchd plist templates with absolute,
  # machine-specific paths and (un)installs them as per-user LaunchAgents.
  # Never hardcodes a user's home directory in the templates themselves.
  module Launchd
    RUBY_ROOT = File.expand_path("../..", __dir__)
    REPO_ROOT = File.expand_path("..", RUBY_ROOT)
    TEMPLATES_DIR = File.join(REPO_ROOT, "launchd")
    LAUNCH_AGENTS_DIR = File.expand_path("~/Library/LaunchAgents")
    LOG_DIR = File.expand_path("~/Library/Logs/agent-usage-cli")
    DEFAULT_PORT = 4570

    # How long to wait for `bootout` to actually finish unloading a service
    # before we try to `bootstrap` it again. `bootout` returns as soon as the
    # unload is requested, not once it's complete -- bootstrapping too early
    # races the still-unloading old instance and fails.
    UNLOAD_TIMEOUT_SECONDS = 5.0
    UNLOAD_POLL_INTERVAL_SECONDS = 0.2

    SERVICES = [
      { label: "co.gen.agent-usage-collector", template: "collector.plist.erb" },
      { label: "co.gen.agent-usage-web", template: "web.plist.erb" },
    ].freeze

    # Raised when a required `launchctl` invocation fails, or when a
    # boot-out never finishes within the timeout.
    class LaunchctlError < StandardError; end

    def self.which(command)
      (ENV["PATH"] || "").split(File::PATH_SEPARATOR).each do |dir|
        candidate = File.join(dir, command)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    def self.dir_for(command)
      found = which(command)
      found ? File.dirname(found) : nil
    end

    def self.combined_path
      dirs = [
        RbConfig::CONFIG["bindir"],
        dir_for("bundle"),
        dir_for("node"),
        dir_for("claude"),
        dir_for("codex"),
        dir_for("grok"),
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
      ]
      dirs.compact.uniq.join(File::PATH_SEPARATOR)
    end

    def self.template_variables(db_path: Database.path, port: DEFAULT_PORT)
      {
        ruby_root: RUBY_ROOT,
        combined_path: combined_path,
        home: ENV["HOME"] || Dir.home,
        gemfile: File.join(RUBY_ROOT, "Gemfile"),
        bundle_path: which("bundle") || "bundle",
        db_path: db_path,
        port: port,
        log_dir: LOG_DIR,
      }
    end

    def self.render(template_path, variables)
      ERB.new(File.read(template_path), trim_mode: "-").result_with_hash(variables)
    end

    def self.render_service(service, variables = template_variables)
      template_path = File.join(TEMPLATES_DIR, service[:template])
      render(template_path, variables.merge(label: service[:label]))
    end

    # Runs a real `launchctl` subcommand. Returns a result hash so callers
    # can check success and surface stderr on failure.
    def self.run_launchctl(*args)
      stdout, stderr, status = Open3.capture3("launchctl", *args)
      { success: status.success?, stdout: stdout, stderr: stderr }
    end

    def self.default_sleeper
      ->(seconds) { sleep(seconds) }
    end

    def self.install!(
      runner: method(:run_launchctl),
      sleeper: default_sleeper,
      launch_agents_dir: LAUNCH_AGENTS_DIR,
      log_dir: LOG_DIR
    )
      FileUtils.mkdir_p(launch_agents_dir)
      FileUtils.mkdir_p(log_dir)
      variables = template_variables
      SERVICES.each do |service|
        plist_path = File.join(launch_agents_dir, "#{service[:label]}.plist")
        File.write(plist_path, render_service(service, variables))
        reinstall_service(plist_path, service[:label], runner: runner, sleeper: sleeper)
      end
    end

    def self.uninstall!(runner: method(:run_launchctl), sleeper: default_sleeper)
      SERVICES.each do |service|
        boot_out(service[:label], runner: runner)
        wait_until_absent(service[:label], runner: runner, sleeper: sleeper)
      end
    end

    # Boots an existing instance of `label` out, waits for it to actually be
    # gone, then bootstraps the freshly rendered plist. This is the sequence
    # that used to race in production: bootstrapping immediately after
    # bootout could hit the old instance mid-unload and fail silently.
    def self.reinstall_service(plist_path, label, runner: method(:run_launchctl), sleeper: default_sleeper)
      boot_out(label, runner: runner)
      wait_until_absent(label, runner: runner, sleeper: sleeper)
      bootstrap(plist_path, label, runner: runner)
    end

    # `bootout` failing is the common, expected case (the service wasn't
    # loaded yet, e.g. on first install) so it isn't treated as fatal on its
    # own -- `wait_until_absent` is what actually confirms the end state.
    def self.boot_out(label, runner: method(:run_launchctl))
      runner.call("bootout", "gui/#{Process.uid}/#{label}")
    end

    def self.service_loaded?(label, runner: method(:run_launchctl))
      runner.call("print", "gui/#{Process.uid}/#{label}")[:success]
    end

    def self.wait_until_absent(
      label,
      runner: method(:run_launchctl),
      sleeper: default_sleeper,
      timeout_seconds: UNLOAD_TIMEOUT_SECONDS,
      interval_seconds: UNLOAD_POLL_INTERVAL_SECONDS
    )
      max_attempts = [(timeout_seconds / interval_seconds).ceil, 1].max
      attempts = 0
      loop do
        return true unless service_loaded?(label, runner: runner)

        attempts += 1
        if attempts > max_attempts
          raise LaunchctlError, "timed out after #{timeout_seconds}s waiting for #{label} to unload"
        end

        sleeper.call(interval_seconds)
      end
    end

    # Enabling before bootstrap (rather than kickstarting after) means a
    # single RunAtLoad start does the job -- no separate forced restart.
    def self.bootstrap(plist_path, label, runner: method(:run_launchctl))
      uid = Process.uid

      enable_result = runner.call("enable", "gui/#{uid}/#{label}")
      unless enable_result[:success]
        raise LaunchctlError, "launchctl enable failed for #{label}: #{enable_result[:stderr]&.strip}"
      end

      bootstrap_result = runner.call("bootstrap", "gui/#{uid}", plist_path)
      unless bootstrap_result[:success]
        raise LaunchctlError, "launchctl bootstrap failed for #{label}: #{bootstrap_result[:stderr]&.strip}"
      end
    end
  end
end
