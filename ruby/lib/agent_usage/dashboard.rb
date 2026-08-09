require "json"
require "time"

module AgentUsage
  # Computes the burn-down view model shown by the web UI: per-window gap
  # vs. ideal pace, required daily burn, reset countdown, and (when at
  # least two real observations exist in the active period) a recent-pace
  # projection. Ranking always uses each provider's primary window.
  module Dashboard
    STALE_AFTER_SECONDS = 30 * 60

    PROVIDER_LABELS = { "claude" => "Claude", "codex" => "Codex", "grok" => "Grok" }.freeze

    WINDOW_LABELS = {
      "five_hour" => "5-hour",
      "seven_day" => "7-day",
      "seven_day_opus" => "7-day (Opus)",
      "seven_day_sonnet" => "7-day (Sonnet)",
      "primary" => "Primary",
      "secondary" => "Secondary",
      "currentPeriod" => "Current period",
    }.freeze

    def self.build(db, now: Time.now.utc)
      latest = db.get_first_row("SELECT * FROM raw_snapshots ORDER BY id DESC LIMIT 1")
      return empty_view(now) unless latest

      errors = JSON.parse(latest["errors_json"] || "[]")
      providers_present = db.execute(
        "SELECT DISTINCT provider FROM window_observations WHERE raw_snapshot_id = ? ORDER BY provider",
        [latest["id"]],
      ).map { |row| row["provider"] }

      provider_views = providers_present.filter_map { |provider| build_provider_view(db, provider, latest, now) }
      ranked = provider_views.select { |view| view[:primary_window] }
                              .sort_by { |view| [-view[:primary_window][:gap_points], -(view[:primary_window][:required_daily_burn] || 0)] }

      {
        generated_at: now.utc.iso8601,
        observed_at: latest["observed_at"],
        collected_at: latest["collected_at"],
        complete: latest["complete"] == 1,
        errors: errors,
        stale: (now - Time.parse(latest["collected_at"])) > STALE_AFTER_SECONDS,
        recommendation: recommendation_for(ranked),
        providers: provider_views,
        ranking: ranked.map { |view| view[:provider] },
      }
    end

    def self.empty_view(now)
      {
        generated_at: now.utc.iso8601,
        observed_at: nil,
        collected_at: nil,
        complete: false,
        errors: [],
        stale: true,
        recommendation: nil,
        providers: [],
        ranking: [],
      }
    end

    def self.recommendation_for(ranked)
      top = ranked.first
      return nil unless top

      {
        provider: top[:provider],
        label: top[:label],
        gap_points: top[:primary_window][:gap_points],
        reason: "#{top[:label]} has the most unused allowance relative to time remaining " \
                "(#{format('%+.1f', top[:primary_window][:gap_points])} points vs. ideal pace).",
      }
    end

    def self.build_provider_view(db, provider, latest, now)
      window_keys = db.execute(
        "SELECT DISTINCT window_key FROM window_observations WHERE raw_snapshot_id = ? AND provider = ?",
        [latest["id"], provider],
      ).map { |row| row["window_key"] }
      return nil if window_keys.empty?

      windows = window_keys.filter_map { |key| build_window_view(db, provider, key, latest, now) }
      return nil if windows.empty?

      primary = windows.find { |window| window[:primary_window] }
      secondary = windows.reject { |window| window[:primary_window] }.sort_by { |window| window[:window_key] }

      {
        provider: provider,
        label: PROVIDER_LABELS.fetch(provider, provider.to_s.capitalize),
        primary_window: primary,
        secondary_windows: secondary,
      }
    end

    def self.build_window_view(db, provider, window_key, latest, now)
      current = db.get_first_row(
        "SELECT * FROM window_observations WHERE raw_snapshot_id = ? AND provider = ? AND window_key = ?",
        [latest["id"], provider, window_key],
      )
      return nil unless current && current["period_start"] && current["period_end"]

      period_start = Time.parse(current["period_start"])
      period_end = Time.parse(current["period_end"])
      history = db.execute(
        "SELECT collected_at, remaining_percent FROM window_observations " \
        "WHERE provider = ? AND window_key = ? AND period_start = ? AND period_end = ? " \
        "ORDER BY collected_at ASC",
        [provider, window_key, current["period_start"], current["period_end"]],
      )

      calc = calculate(
        period_start: period_start,
        period_end: period_end,
        remaining_percent: current["remaining_percent"],
        now: now,
      )
      chart = build_chart(period_start: period_start, period_end: period_end, history: history)

      {
        window_key: window_key,
        label: window_label(window_key, current["raw_window_json"]),
        primary_window: current["primary_window"] == 1,
        used_percent: current["used_percent"],
        remaining_percent: current["remaining_percent"],
        period_start: current["period_start"],
        period_end: current["period_end"],
        reset_countdown_seconds: calc[:reset_countdown_seconds],
        elapsed_fraction: calc[:elapsed_fraction],
        ideal_remaining_percent: calc[:ideal_remaining_percent],
        gap_points: calc[:gap_points],
        remaining_days: calc[:remaining_days],
        required_daily_burn: calc[:required_daily_burn],
        chart: chart,
      }
    end

    def self.clamp(value, min = 0.0, max = 100.0)
      [[value, max].min, min].max
    end

    def self.calculate(period_start:, period_end:, remaining_percent:, now:)
      total_seconds = period_end - period_start
      elapsed_seconds = now - period_start
      elapsed_fraction = total_seconds.positive? ? clamp(elapsed_seconds / total_seconds, 0.0, 1.0) : 1.0
      ideal_remaining_percent = 100.0 - (elapsed_fraction * 100.0)
      gap_points = remaining_percent - ideal_remaining_percent

      reset_countdown_seconds = period_end - now
      remaining_days = reset_countdown_seconds / 86_400.0
      required_daily_burn = remaining_days.positive? ? remaining_percent / remaining_days : nil

      {
        elapsed_fraction: elapsed_fraction,
        ideal_remaining_percent: ideal_remaining_percent,
        gap_points: gap_points,
        reset_countdown_seconds: reset_countdown_seconds,
        remaining_days: remaining_days,
        required_daily_burn: required_daily_burn,
      }
    end

    # x/y are fractions of the period (0..1) and percent remaining (0..100)
    # so the ERB template can scale them into any SVG viewBox.
    def self.build_chart(period_start:, period_end:, history:)
      total_seconds = period_end - period_start

      actual = history.map do |row|
        t = Time.parse(row["collected_at"])
        x = total_seconds.positive? ? clamp((t - period_start) / total_seconds, 0.0, 1.0) : 0.0
        { x: x, y: clamp(row["remaining_percent"]), collected_at: row["collected_at"], inferred: false }
      end

      unless actual.any? { |point| point[:x] <= 0.0001 }
        actual.unshift({ x: 0.0, y: 100.0, collected_at: period_start.utc.iso8601, inferred: true })
      end
      actual.sort_by! { |point| point[:x] }

      real_points = actual.reject { |point| point[:inferred] }
      projection = build_projection(real_points, period_end)

      {
        ideal: [{ x: 0.0, y: 100.0 }, { x: 1.0, y: 0.0 }],
        actual: actual,
        current: actual.last,
        projection: projection,
      }
    end

    def self.build_projection(real_points, period_end)
      return nil if real_points.size < 2

      first = real_points.first
      last = real_points.last
      first_time = Time.parse(first[:collected_at])
      last_time = Time.parse(last[:collected_at])
      elapsed_days = (last_time - first_time) / 86_400.0
      return nil unless elapsed_days.positive?

      slope_per_day = (last[:y] - first[:y]) / elapsed_days
      days_to_reset = [(period_end - last_time) / 86_400.0, 0.0].max
      projected_remaining = clamp(last[:y] + (slope_per_day * days_to_reset))

      {
        from: { x: last[:x], y: last[:y] },
        to: { x: 1.0, y: projected_remaining },
      }
    end

    # Distinct Codex per-model limits (rateLimitsByLimitId) carry a
    # human-readable limitName in their preserved raw window; prefer that
    # over humanizing the stable-but-opaque limit_id-derived window_key.
    def self.window_label(window_key, raw_window_json)
      return WINDOW_LABELS[window_key] if WINDOW_LABELS.key?(window_key)

      raw_window = JSON.parse(raw_window_json || "{}")
      limit_name = raw_window["limitName"]
      return limit_name if limit_name.is_a?(String) && !limit_name.empty?

      humanize(window_key)
    rescue JSON::ParserError
      humanize(window_key)
    end

    def self.humanize(key)
      key.to_s.gsub(/[_-]/, " ").split(" ").map { |word| word[0].upcase + word[1..] }.join(" ")
    end
  end
end
