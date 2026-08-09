require_relative "test_helper"
require "rexml/document"
require "agent_usage/launchd"

class LaunchdTest < AgentUsageTest
  def test_checked_in_templates_never_hardcode_a_user_path
    %w[collector.plist.erb web.plist.erb].each do |name|
      source = File.read(File.join(AgentUsage::Launchd::TEMPLATES_DIR, name))
      refute_includes source, "/Users/", "#{name} must not hardcode an absolute user path"
      refute_includes source, ENV["HOME"], "#{name} must not hardcode this machine's HOME"
    end
  end

  def test_render_service_substitutes_arbitrary_machine_paths
    variables = {
      ruby_root: "/Users/testuser/tools/agent-usage-cli/ruby",
      combined_path: "/Users/testuser/.rbenv/shims:/usr/bin:/bin",
      home: "/Users/testuser",
      gemfile: "/Users/testuser/tools/agent-usage-cli/ruby/Gemfile",
      bundle_path: "/Users/testuser/.rbenv/shims/bundle",
      db_path: "/Users/testuser/Library/Application Support/agent-usage-cli/usage.sqlite3",
      port: 4570,
      log_dir: "/Users/testuser/Library/Logs/agent-usage-cli",
    }

    rendered = AgentUsage::Launchd.render_service(
      { label: "co.gen.agent-usage-collector", template: "collector.plist.erb" },
      variables,
    )

    assert_includes rendered, "/Users/testuser"
    assert_includes rendered, "<string>co.gen.agent-usage-collector</string>"
    assert_includes rendered, "<integer>900</integer>"
    doc = REXML::Document.new(rendered)
    refute_nil doc.root
  end

  def test_web_plist_includes_keep_alive_and_port
    variables = {
      ruby_root: "/Users/testuser/tools/agent-usage-cli/ruby",
      combined_path: "/usr/bin:/bin",
      home: "/Users/testuser",
      gemfile: "/Users/testuser/tools/agent-usage-cli/ruby/Gemfile",
      bundle_path: "/usr/bin/bundle",
      db_path: "/Users/testuser/Library/Application Support/agent-usage-cli/usage.sqlite3",
      port: 4570,
      log_dir: "/Users/testuser/Library/Logs/agent-usage-cli",
    }

    rendered = AgentUsage::Launchd.render_service(
      { label: "co.gen.agent-usage-web", template: "web.plist.erb" },
      variables,
    )

    assert_includes rendered, "<key>KeepAlive</key>"
    assert_includes rendered, "<string>4570</string>"
    doc = REXML::Document.new(rendered)
    refute_nil doc.root
  end

  def test_template_variables_produces_a_nonempty_combined_path
    variables = AgentUsage::Launchd.template_variables(db_path: @db_path)
    refute_empty variables[:combined_path]
    assert_includes variables[:combined_path], "/bin"
  end

  # -- launchctl orchestration (install/uninstall race + failure handling) --

  LABEL = "co.gen.agent-usage-web"

  def test_reinstall_service_boots_out_waits_enables_then_bootstraps_in_order
    runner = FakeLaunchctl.new(print: false) # already unloaded, no waiting needed
    sleeper = RecordingSleeper.new

    AgentUsage::Launchd.reinstall_service("/tmp/whatever.plist", LABEL, runner: runner, sleeper: sleeper)

    assert_equal(
      [
        ["bootout", "gui/#{Process.uid}/#{LABEL}"],
        ["print", "gui/#{Process.uid}/#{LABEL}"],
        ["enable", "gui/#{Process.uid}/#{LABEL}"],
        ["bootstrap", "gui/#{Process.uid}", "/tmp/whatever.plist"],
      ],
      runner.calls,
    )
    assert_empty sleeper.calls, "should not wait when the service is already absent"
    refute_includes runner.calls.map(&:first), "kickstart", "RunAtLoad should start it; no forced restart needed"
  end

  def test_reinstall_service_waits_out_a_delayed_unload_before_bootstrapping
    # Simulates the production race: `print` still reports the old instance
    # as loaded for a couple of polls before it actually unloads.
    runner = FakeLaunchctl.new(print_sequence: [true, true, false])
    sleeper = RecordingSleeper.new

    AgentUsage::Launchd.reinstall_service("/tmp/whatever.plist", LABEL, runner: runner, sleeper: sleeper)

    print_calls = runner.calls.count { |call| call.first == "print" }
    assert_equal 3, print_calls
    assert_equal [AgentUsage::Launchd::UNLOAD_POLL_INTERVAL_SECONDS] * 2, sleeper.calls
    assert_equal "bootstrap", runner.calls.last.first
  end

  def test_wait_until_absent_raises_after_bounded_timeout_if_never_absent
    runner = FakeLaunchctl.new(print: true) # never reports absent
    sleeper = RecordingSleeper.new

    error = assert_raises(AgentUsage::Launchd::LaunchctlError) do
      AgentUsage::Launchd.wait_until_absent(
        LABEL,
        runner: runner,
        sleeper: sleeper,
        timeout_seconds: 0.6,
        interval_seconds: 0.2,
      )
    end
    assert_match(/timed out/i, error.message)
    assert_match(/#{Regexp.escape(LABEL)}/, error.message)
    # Bounded: a handful of polls, not an infinite loop.
    assert_operator sleeper.calls.length, :<=, 4
  end

  def test_reinstall_service_raises_when_bootstrap_fails_instead_of_reporting_success
    runner = FakeLaunchctl.new(print: false, bootstrap: { success: false, stdout: "", stderr: "service already bootstrapped" })
    sleeper = RecordingSleeper.new

    error = assert_raises(AgentUsage::Launchd::LaunchctlError) do
      AgentUsage::Launchd.reinstall_service("/tmp/whatever.plist", LABEL, runner: runner, sleeper: sleeper)
    end
    assert_match(/bootstrap/i, error.message)
    assert_match(/service already bootstrapped/, error.message)
  end

  def test_reinstall_service_raises_when_enable_fails
    runner = FakeLaunchctl.new(print: false, enable: { success: false, stdout: "", stderr: "boom" })
    sleeper = RecordingSleeper.new

    error = assert_raises(AgentUsage::Launchd::LaunchctlError) do
      AgentUsage::Launchd.reinstall_service("/tmp/whatever.plist", LABEL, runner: runner, sleeper: sleeper)
    end
    assert_match(/enable/i, error.message)
    refute_includes runner.calls.map(&:first), "bootstrap", "must not claim success by bootstrapping after enable failed"
  end

  def test_install_bang_boots_out_waits_and_bootstraps_each_service_and_writes_plists
    runner = FakeLaunchctl.new(print: false)
    sleeper = RecordingSleeper.new

    AgentUsage::Launchd.install!(
      runner: runner,
      sleeper: sleeper,
      launch_agents_dir: @tmp_dir,
      log_dir: File.join(@tmp_dir, "logs"),
    )

    AgentUsage::Launchd::SERVICES.each do |service|
      plist_path = File.join(@tmp_dir, "#{service[:label]}.plist")
      assert_path_exists plist_path
    end
    assert_path_exists File.join(@tmp_dir, "logs")

    subcommands_by_label = AgentUsage::Launchd::SERVICES.map { |s| s[:label] }
    subcommands_by_label.each do |label|
      assert_includes runner.calls, ["bootout", "gui/#{Process.uid}/#{label}"]
      assert_includes runner.calls, ["enable", "gui/#{Process.uid}/#{label}"]
      assert_includes runner.calls, ["bootstrap", "gui/#{Process.uid}", File.join(@tmp_dir, "#{label}.plist")]
    end
  end

  def test_install_bang_stops_at_the_first_failing_service_and_raises
    web_label = "co.gen.agent-usage-web"
    runner = FakeLaunchctl.new(print: false, bootstrap: { success: false, stdout: "", stderr: "nope" })
    sleeper = RecordingSleeper.new

    assert_raises(AgentUsage::Launchd::LaunchctlError) do
      AgentUsage::Launchd.install!(
        runner: runner,
        sleeper: sleeper,
        launch_agents_dir: @tmp_dir,
        log_dir: File.join(@tmp_dir, "logs"),
      )
    end
    refute_empty runner.calls
  end

  def test_uninstall_bang_boots_out_and_confirms_absence_for_every_service
    runner = FakeLaunchctl.new(print: false)
    sleeper = RecordingSleeper.new

    AgentUsage::Launchd.uninstall!(runner: runner, sleeper: sleeper)

    AgentUsage::Launchd::SERVICES.each do |service|
      assert_includes runner.calls, ["bootout", "gui/#{Process.uid}/#{service[:label]}"]
      assert_includes runner.calls, ["print", "gui/#{Process.uid}/#{service[:label]}"]
    end
    refute_includes runner.calls.map(&:first), "enable", "uninstall must not re-enable or bootstrap anything"
    refute_includes runner.calls.map(&:first), "bootstrap"
  end

  def test_uninstall_bang_raises_if_a_service_never_actually_unloads
    runner = FakeLaunchctl.new(print: true) # always reports loaded, as if bootout silently failed
    sleeper = RecordingSleeper.new

    assert_raises(AgentUsage::Launchd::LaunchctlError) do
      AgentUsage::Launchd.uninstall!(runner: runner, sleeper: sleeper)
    end
  end

  # Fakes real launchctl without shelling out. `print` (service presence)
  # can be a fixed boolean or a per-call sequence to simulate a delayed
  # unload; other subcommands default to succeeding.
  class FakeLaunchctl
    attr_reader :calls

    def initialize(print: false, print_sequence: nil, bootout: { success: true, stdout: "", stderr: "" },
                    enable: { success: true, stdout: "", stderr: "" },
                    bootstrap: { success: true, stdout: "", stderr: "" })
      @print_sequence = print_sequence && print_sequence.dup
      @print_default = print
      @bootout = bootout
      @enable = enable
      @bootstrap = bootstrap
      @calls = []
    end

    def call(*args)
      @calls << args
      case args.first
      when "bootout" then @bootout
      when "enable" then @enable
      when "bootstrap" then @bootstrap
      when "print"
        loaded = @print_sequence && !@print_sequence.empty? ? @print_sequence.shift : @print_default
        { success: loaded, stdout: "", stderr: loaded ? "" : "Could not find service" }
      else
        { success: true, stdout: "", stderr: "" }
      end
    end
  end

  class RecordingSleeper
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(seconds)
      @calls << seconds
    end
  end
end
