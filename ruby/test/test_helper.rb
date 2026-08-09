$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"

class AgentUsageTest < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir("agent-usage-test")
    @db_path = File.join(@tmp_dir, "usage.sqlite3")
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir) if @tmp_dir && File.exist?(@tmp_dir)
  end

  def fixture_path(name)
    File.join(__dir__, "fixtures", name)
  end

  def fixture(name)
    File.read(fixture_path(name))
  end

  def fixture_json(name)
    JSON.parse(fixture(name))
  end

  # Returns a cli_runner proc suitable for Collector.new(cli_runner:) that
  # never touches a real subprocess or provider CLI.
  def fake_runner(fixture_name)
    stdout = fixture(fixture_name)
    -> { stdout }
  end
end
