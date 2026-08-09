require "erb"
require "fileutils"
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

    SERVICES = [
      { label: "co.gen.agent-usage-collector", template: "collector.plist.erb" },
      { label: "co.gen.agent-usage-web", template: "web.plist.erb" },
    ].freeze

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

    def self.install!
      FileUtils.mkdir_p(LAUNCH_AGENTS_DIR)
      FileUtils.mkdir_p(LOG_DIR)
      variables = template_variables
      SERVICES.each do |service|
        plist_path = File.join(LAUNCH_AGENTS_DIR, "#{service[:label]}.plist")
        File.write(plist_path, render_service(service, variables))
        boot_out(service[:label])
        bootstrap(plist_path, service[:label])
      end
    end

    def self.uninstall!
      SERVICES.each { |service| boot_out(service[:label]) }
    end

    def self.boot_out(label)
      system("launchctl", "bootout", "gui/#{Process.uid}/#{label}", out: File::NULL, err: File::NULL)
    end

    def self.bootstrap(plist_path, label)
      uid = Process.uid
      system("launchctl", "bootstrap", "gui/#{uid}", plist_path, out: File::NULL, err: File::NULL)
      system("launchctl", "enable", "gui/#{uid}/#{label}", out: File::NULL, err: File::NULL)
      system("launchctl", "kickstart", "-k", "gui/#{uid}/#{label}", out: File::NULL, err: File::NULL)
    end
  end
end
