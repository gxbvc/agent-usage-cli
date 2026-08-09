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
end
