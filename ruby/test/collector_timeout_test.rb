require_relative "test_helper"
require "agent_usage/collector"
require "rbconfig"

# Exercises AgentUsage::Collector.default_runner's real subprocess handling
# directly (never the provider CLIs) so the timeout/kill/drain path is
# actually covered, not just the fixture-backed collector flow.
class CollectorTimeoutTest < AgentUsageTest
  RUBY_BIN = RbConfig.ruby

  def test_run_command_returns_stdout_when_the_child_finishes_in_time
    runner = AgentUsage::Collector.default_runner(
      timeout_seconds: 5,
      command: RUBY_BIN,
      args: ["-e", "STDOUT.write('ok')"],
    )

    assert_equal "ok", runner.call
  end

  def test_drains_stderr_concurrently_so_a_verbose_child_cannot_deadlock
    # A pipe's OS buffer is far smaller than this; if stderr weren't drained
    # on its own thread the child would block writing to it and the whole
    # call would hang until the timeout instead of returning quickly.
    script = "STDERR.write('e' * 400_000); STDOUT.write('ok')"
    runner = AgentUsage::Collector.default_runner(
      timeout_seconds: 5,
      command: RUBY_BIN,
      args: ["-e", script],
    )

    assert_equal "ok", runner.call
  end

  def test_timeout_force_kills_a_child_that_ignores_sigterm_and_leaves_no_orphan
    pid_file = File.join(@tmp_dir, "stubborn.pid")
    script = <<~RUBY
      File.write(#{pid_file.inspect}, Process.pid.to_s)
      Signal.trap("TERM") {}
      sleep 5
    RUBY

    runner = AgentUsage::Collector.default_runner(
      timeout_seconds: 0.2,
      command: RUBY_BIN,
      args: ["-e", script],
    )

    assert_raises(Timeout::Error) { runner.call }

    pid = wait_for_pid_file(pid_file)
    refute process_alive?(pid), "a child that ignores SIGTERM must still be force-killed, not orphaned"
  end

  def test_timeout_on_a_well_behaved_child_still_raises_promptly
    runner = AgentUsage::Collector.default_runner(
      timeout_seconds: 0.1,
      command: RUBY_BIN,
      args: ["-e", "sleep 5"],
    )

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(Timeout::Error) { runner.call }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert elapsed < 3, "timeout handling should not itself block for multiple seconds (took #{elapsed}s)"
  end

  private

  def wait_for_pid_file(path, timeout: 2)
    deadline = Time.now + timeout
    pid = nil
    until pid || Time.now > deadline
      pid = File.read(path).to_i if File.exist?(path) && !File.zero?(path)
      sleep 0.02 unless pid
    end
    refute_nil pid, "stubborn child never wrote its pid file"
    pid
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
