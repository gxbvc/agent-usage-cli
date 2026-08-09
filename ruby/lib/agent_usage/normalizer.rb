require "json"
require "time"

module AgentUsage
  # Turns one provider result from the agent-usage-cli JSON envelope into
  # flat window observations ready for storage. Kept separate from the
  # collector so a future normalizer_version can reprocess raw_snapshots.
  module Normalizer
    VERSION = 2

    FIVE_HOURS_SECONDS = 5 * 3600
    SEVEN_DAYS_SECONDS = 7 * 24 * 3600

    CLAUDE_WINDOW_KEYS = %w[five_hour seven_day seven_day_opus seven_day_sonnet].freeze
    CLAUDE_PRIMARY_KEY = "seven_day"

    def self.windows_for(provider, provider_result)
      return [] unless provider_result.is_a?(Hash)

      case provider.to_s
      when "claude" then claude_windows(provider_result)
      when "codex" then codex_windows(provider_result)
      when "grok" then grok_windows(provider_result)
      else []
      end
    end

    def self.claude_windows(provider_result)
      windows = provider_result.dig("usage", "windows")
      return [] unless windows.is_a?(Hash)

      CLAUDE_WINDOW_KEYS.filter_map do |key|
        window = windows[key]
        next unless window.is_a?(Hash)

        utilization = window["utilization"]
        resets_at = parse_time(window["resetsAt"])
        next if utilization.nil? || resets_at.nil?

        resets_at = round_to_nearest_minute(resets_at)
        offset = key == "five_hour" ? FIVE_HOURS_SECONDS : SEVEN_DAYS_SECONDS
        build_observation(
          window_key: key,
          primary_window: key == CLAUDE_PRIMARY_KEY,
          period_start: resets_at - offset,
          period_end: resets_at,
          used_percent: utilization.to_f,
          raw_window: window,
        )
      end
    end

    # rateLimitsByLimitId wraps each named limit as { limitId, limitName,
    # primary: { usedPercent, windowDurationMins, resetsAt }, secondary: {...} }
    # rather than exposing the window fields directly. One entry (limitId
    # "codex") is normally a republish of the main rateLimits.primary /
    # .secondary windows; others (e.g. "codex_bengalfox") are genuinely
    # distinct per-model limits and must survive as their own secondary
    # windows.
    def self.codex_windows(provider_result)
      rate_limits = provider_result.dig("usage", "rateLimits", "rateLimits")
      return [] unless rate_limits.is_a?(Hash)

      by_limit_id = provider_result.dig("usage", "rateLimits", "rateLimitsByLimitId")
      by_limit_id = {} unless by_limit_id.is_a?(Hash)

      main = %w[primary secondary].filter_map do |key|
        window = rate_limits[key]
        next unless window.is_a?(Hash)

        observation = codex_observation(key, window, key == "primary")
        [key, window, observation] if observation
      end

      extras = by_limit_id.flat_map do |limit_id, entry|
        next [] unless entry.is_a?(Hash)

        label = entry["limitName"] if entry["limitName"].is_a?(String) && !entry["limitName"].empty?

        %w[primary secondary].filter_map do |sub_key|
          window = entry[sub_key]
          next unless window.is_a?(Hash)
          next if main.any? { |(_, main_window, _)| duplicate_codex_window?(main_window, window) }

          window_key = sub_key == "primary" ? limit_id.to_s : "#{limit_id}_#{sub_key}"
          raw_window = label ? window.merge("limitName" => label) : window
          codex_observation(window_key, raw_window, false)
        end
      end

      main.map { |(_, _, observation)| observation } + extras
    end

    def self.codex_observation(key, window, primary)
      used_percent = window["usedPercent"]
      duration_mins = window["windowDurationMins"]
      resets_at = parse_time(window["resetsAt"])
      return nil if used_percent.nil? || duration_mins.nil? || resets_at.nil?

      build_observation(
        window_key: key,
        primary_window: primary,
        period_start: resets_at - (duration_mins.to_f * 60),
        period_end: resets_at,
        used_percent: used_percent.to_f,
        raw_window: window,
      )
    end

    # Codex sometimes republishes the primary/secondary window under
    # rateLimitsByLimitId with a different key name. Treat it as a duplicate
    # (and skip it as a secondary window) only when percent, duration, and
    # reset all match a main window exactly.
    def self.duplicate_codex_window?(main_window, candidate)
      main_window["usedPercent"] == candidate["usedPercent"] &&
        main_window["windowDurationMins"] == candidate["windowDurationMins"] &&
        main_window["resetsAt"] == candidate["resetsAt"]
    end

    # Grok's config.creditUsagePercent is the truthful percent-used value
    # (100 = fully used). Prefer it over usage["usedPercent"] so raw
    # snapshots stored by a pre-fix build of agent-usage-cli — whose
    # usedPercent/remainingPercent were swapped but whose creditUsagePercent
    # passthrough was always correct — reprocess into correct history.
    def self.grok_windows(provider_result)
      usage = provider_result["usage"]
      return [] unless usage.is_a?(Hash)

      used_percent = usage["creditUsagePercent"] || usage["usedPercent"]
      current_period = usage["currentPeriod"]
      return [] unless used_percent && current_period.is_a?(Hash)

      period_start = parse_time(current_period["start"])
      period_end = parse_time(current_period["end"])
      return [] unless period_start && period_end

      [
        build_observation(
          window_key: "currentPeriod",
          primary_window: true,
          period_start: period_start,
          period_end: period_end,
          used_percent: used_percent.to_f,
          raw_window: current_period.merge("usedPercent" => used_percent),
        ),
      ]
    end

    # Shared insert used by both the live Collector and the Reprocessor so
    # they write identical SQL against window_observations. Callers that
    # replace an existing snapshot's rows (the Reprocessor) must DELETE
    # first: INSERT OR IGNORE silently no-ops on the unique
    # (raw_snapshot_id, provider, window_key) index otherwise.
    def self.store_window(db, raw_snapshot_id, collected_at, provider, observation)
      db.execute(
        "INSERT OR IGNORE INTO window_observations " \
        "(raw_snapshot_id, collected_at, provider, window_key, primary_window, " \
        "period_start, period_end, used_percent, remaining_percent, normalizer_version, raw_window_json) " \
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        [
          raw_snapshot_id,
          collected_at,
          provider.to_s,
          observation[:window_key],
          observation[:primary_window] ? 1 : 0,
          observation[:period_start],
          observation[:period_end],
          observation[:used_percent],
          observation[:remaining_percent],
          observation[:normalizer_version],
          observation[:raw_window_json],
        ],
      )
    end

    def self.build_observation(window_key:, primary_window:, period_start:, period_end:, used_percent:, raw_window:)
      {
        window_key: window_key,
        primary_window: primary_window,
        period_start: period_start.utc.iso8601,
        period_end: period_end.utc.iso8601,
        used_percent: used_percent,
        remaining_percent: 100.0 - used_percent,
        normalizer_version: VERSION,
        raw_window_json: JSON.generate(raw_window),
      }
    end

    def self.parse_time(value)
      return nil unless value.is_a?(String) && !value.empty?

      Time.parse(value)
    rescue ArgumentError, TypeError
      nil
    end

    # Claude's resetsAt can jitter by under a second across the same
    # underlying reset (observed live moving from :39:59.595 to :40:00.478
    # between polls). Rounding to the nearest minute keeps period_start and
    # period_end stable so SQLite history grouping (exact string match)
    # merges snapshots into one window instead of splitting on jitter.
    def self.round_to_nearest_minute(time)
      Time.at((time.to_r / 60).round * 60).utc
    end
  end
end
