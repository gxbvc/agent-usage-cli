require_relative "test_helper"
require "agent_usage/normalizer"

class NormalizerTest < AgentUsageTest
  def setup
    super
    @providers = fixture_json("envelope_complete.json")["data"]["providers"]
  end

  def test_claude_windows_derive_period_start_and_flag_primary
    windows = AgentUsage::Normalizer.windows_for("claude", @providers["claude"])
    by_key = windows.each_with_object({}) { |w, h| h[w[:window_key]] = w }

    assert_equal %w[five_hour seven_day seven_day_sonnet].sort, by_key.keys.sort
    assert_equal "2026-01-01T00:00:00Z", by_key["five_hour"][:period_start]
    assert_equal "2026-01-01T05:00:00Z", by_key["five_hour"][:period_end]
    assert_equal 20.0, by_key["five_hour"][:used_percent]
    assert_equal 80.0, by_key["five_hour"][:remaining_percent]
    refute by_key["five_hour"][:primary_window]

    assert_equal "2026-01-01T00:00:00Z", by_key["seven_day"][:period_start]
    assert_equal "2026-01-08T00:00:00Z", by_key["seven_day"][:period_end]
    assert by_key["seven_day"][:primary_window]

    refute by_key["seven_day_sonnet"][:primary_window]
  end

  def test_claude_rounds_resets_at_jitter_across_a_minute_boundary_to_the_same_period
    claude_result = lambda do |resets_at|
      { "usage" => { "windows" => { "seven_day" => { "utilization" => 40, "resetsAt" => resets_at } } } }
    end

    before_boundary = AgentUsage::Normalizer.windows_for("claude", claude_result.call("2026-01-08T00:39:59.595Z")).first
    after_boundary = AgentUsage::Normalizer.windows_for("claude", claude_result.call("2026-01-08T00:40:00.478Z")).first

    assert_equal "2026-01-08T00:40:00Z", before_boundary[:period_end]
    assert_equal before_boundary[:period_end], after_boundary[:period_end]
    assert_equal before_boundary[:period_start], after_boundary[:period_start]
  end

  def test_claude_skips_null_windows
    windows = AgentUsage::Normalizer.windows_for("claude", @providers["claude"])
    refute windows.any? { |w| w[:window_key] == "seven_day_opus" }
  end

  def test_codex_windows_derive_period_start_from_duration
    windows = AgentUsage::Normalizer.windows_for("codex", @providers["codex"])
    by_key = windows.each_with_object({}) { |w, h| h[w[:window_key]] = w }

    primary = by_key["primary"]
    assert primary[:primary_window]
    assert_equal "2026-01-01T00:00:00Z", primary[:period_start]
    assert_equal 30.0, primary[:used_percent]

    secondary = by_key["secondary"]
    refute secondary[:primary_window]
    assert_equal "2026-01-01T00:00:00Z", secondary[:period_start]
  end

  def test_codex_deduplicates_limits_by_limit_id_matching_a_main_window
    windows = AgentUsage::Normalizer.windows_for("codex", @providers["codex"])
    keys = windows.map { |w| w[:window_key] }

    refute_includes keys, "codex"
    refute_includes keys, "codex_secondary"
    assert_includes keys, "codex_bengalfox"
  end

  def test_codex_keeps_genuine_extra_limit_as_secondary_with_a_stable_key_and_label
    windows = AgentUsage::Normalizer.windows_for("codex", @providers["codex"])
    extra = windows.find { |w| w[:window_key] == "codex_bengalfox" }
    refute extra[:primary_window]
    assert_equal 55.0, extra[:used_percent]

    raw_window = JSON.parse(extra[:raw_window_json])
    assert_equal "GPT-5.3-Codex-Spark", raw_window["limitName"]
  end

  def test_codex_extra_limit_key_is_stable_across_repeated_normalization
    first = AgentUsage::Normalizer.windows_for("codex", @providers["codex"]).map { |w| w[:window_key] }
    second = AgentUsage::Normalizer.windows_for("codex", @providers["codex"]).map { |w| w[:window_key] }
    assert_equal first.sort, second.sort
  end

  def test_grok_uses_current_period_as_the_single_primary_window
    windows = AgentUsage::Normalizer.windows_for("grok", @providers["grok"])
    assert_equal 1, windows.size
    window = windows.first
    assert_equal "currentPeriod", window[:window_key]
    assert window[:primary_window]
    assert_equal 26.5, window[:used_percent]
    assert_equal 73.5, window[:remaining_percent]
    assert_equal "2026-01-01T00:00:00Z", window[:period_start]
    assert_equal "2026-01-08T00:00:00Z", window[:period_end]
  end

  def test_returns_empty_array_for_missing_or_malformed_usage
    assert_equal [], AgentUsage::Normalizer.windows_for("claude", {})
    assert_equal [], AgentUsage::Normalizer.windows_for("codex", { "usage" => {} })
    assert_equal [], AgentUsage::Normalizer.windows_for("grok", { "usage" => { "usedPercent" => 10 } })
    assert_equal [], AgentUsage::Normalizer.windows_for("claude", nil)
  end

  def test_every_observation_carries_the_normalizer_version
    windows = AgentUsage::Normalizer.windows_for("grok", @providers["grok"])
    assert_equal AgentUsage::Normalizer::VERSION, windows.first[:normalizer_version]
  end
end
