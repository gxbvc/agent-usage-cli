require "time"

module AgentUsage
  # Renders the overlay comparison SVGs (one series per provider on a shared
  # ideal diagonal) from the fraction/percent coordinates
  # Dashboard.build_chart already computed. Colors come from CSS classes
  # (see public/app.css) so light/dark mode and reduced-motion apply
  # without regenerating markup.
  module Chart
    def self.clamp01(value)
      [[value, 1.0].min, 0.0].max
    end

    def self.clamp_percent(value)
      [[value, 100.0].min, 0.0].max
    end

    def self.format_time(iso)
      Time.parse(iso).getlocal.strftime("%b %-d, %-I:%M %p")
    rescue ArgumentError, TypeError
      iso.to_s
    end

    def self.escape(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end

    # --- Overlay comparison chart (multiple providers, one shared ideal line) ---
    #
    # Large full-width chart used by the two comparison sections on the
    # dashboard (weekly, short/~5h). Coordinates are normalized-cycle x
    # (0..1) / percent-remaining y (0..100) fractions, one series per
    # provider. Providers are distinguished by more than color: each also
    # gets its own line dash pattern, and the single current-position
    # marker is the provider's own vendored logo (see public/logos/) so the
    # chart reads correctly without relying on color alone. A provider with
    # no vendored logo (an unrecognized future provider) falls back to a
    # plain shape marker instead.
    COMPARISON_WIDTH = 1160
    COMPARISON_HEIGHT = 440
    COMPARISON_MARGIN_LEFT = 60
    COMPARISON_MARGIN_RIGHT = 28
    COMPARISON_MARGIN_TOP = 28
    COMPARISON_MARGIN_BOTTOM = 56
    COMPARISON_PLOT_WIDTH = COMPARISON_WIDTH - COMPARISON_MARGIN_LEFT - COMPARISON_MARGIN_RIGHT
    COMPARISON_PLOT_HEIGHT = COMPARISON_HEIGHT - COMPARISON_MARGIN_TOP - COMPARISON_MARGIN_BOTTOM

    PROVIDER_STYLES = {
      "claude" => { css_class: "provider-claude", dasharray: nil },
      "codex" => { css_class: "provider-codex", dasharray: "9 5" },
      "grok" => { css_class: "provider-grok", dasharray: "2 4" },
    }.freeze
    DEFAULT_PROVIDER_STYLE = { css_class: "provider-default", dasharray: "6 3 1 3", marker: :diamond }.freeze

    # Vendored under public/logos/ (see SOURCES.md). Kept here, next to the
    # marker rendering that consumes it, rather than duplicated in web.rb.
    PROVIDER_LOGOS = {
      "claude" => "claude.svg",
      "codex" => "codex.png",
      "grok" => "grok.png",
    }.freeze

    CURRENT_LOGO_SIZE = 64

    def self.provider_style(provider)
      PROVIDER_STYLES.fetch(provider.to_s, DEFAULT_PROVIDER_STYLE)
    end

    def self.provider_logo_file(provider)
      PROVIDER_LOGOS[provider.to_s]
    end

    def self.provider_logo_href(provider)
      file = provider_logo_file(provider)
      file && "/logos/#{file}"
    end

    def self.render_comparison(entries, dom_id:, section_label:, day_divisions: nil)
      <<~SVG
        <svg class="usage-chart comparison-chart" viewBox="0 0 #{COMPARISON_WIDTH} #{COMPARISON_HEIGHT}" role="img" aria-labelledby="#{dom_id}-title" preserveAspectRatio="xMidYMid meet">
          <title id="#{dom_id}-title">#{escape(describe_comparison(section_label, entries))}</title>
          #{comparison_grid}
          #{day_divisions ? comparison_day_lines(day_divisions) : ''}
          #{comparison_x_axis_labels}
          #{comparison_ideal_line}
          #{entries.map { |entry| comparison_series(entry) }.join("\n")}
        </svg>
      SVG
    end

    def self.comparison_px_x(fraction)
      COMPARISON_MARGIN_LEFT + (clamp01(fraction) * COMPARISON_PLOT_WIDTH)
    end

    def self.comparison_px_y(percent)
      COMPARISON_MARGIN_TOP + (((100.0 - clamp_percent(percent)) / 100.0) * COMPARISON_PLOT_HEIGHT)
    end

    def self.comparison_grid
      [0, 25, 50, 75, 100].map do |percent|
        y = comparison_px_y(percent).round(1)
        %(<line class="chart-grid" x1="#{COMPARISON_MARGIN_LEFT}" y1="#{y}" x2="#{COMPARISON_WIDTH - COMPARISON_MARGIN_RIGHT}" y2="#{y}" />) +
          %(<text class="chart-axis-label" x="#{COMPARISON_MARGIN_LEFT - 10}" y="#{y + 4}" text-anchor="end">#{percent}%</text>)
      end.join("\n")
    end

    def self.comparison_day_lines(divisions)
      top = COMPARISON_MARGIN_TOP
      bottom = COMPARISON_HEIGHT - COMPARISON_MARGIN_BOTTOM
      (1...divisions).map do |i|
        x = comparison_px_x(i / divisions.to_f).round(1)
        %(<line class="chart-grid" x1="#{x}" y1="#{top}" x2="#{x}" y2="#{bottom}" />)
      end.join("\n")
    end

    def self.comparison_x_axis_labels
      mid = ((COMPARISON_MARGIN_LEFT + COMPARISON_WIDTH - COMPARISON_MARGIN_RIGHT) / 2.0).round(1)
      %(<text class="chart-axis-label" x="#{COMPARISON_MARGIN_LEFT}" y="#{COMPARISON_HEIGHT - 14}" text-anchor="start">Period start</text>) +
        %(<text class="chart-axis-label" x="#{mid}" y="#{COMPARISON_HEIGHT - 14}" text-anchor="middle">Normalized cycle progress</text>) +
        %(<text class="chart-axis-label" x="#{COMPARISON_WIDTH - COMPARISON_MARGIN_RIGHT}" y="#{COMPARISON_HEIGHT - 14}" text-anchor="end">Reset</text>)
    end

    def self.comparison_ideal_line
      %(<line class="chart-ideal" x1="#{comparison_px_x(0.0).round(1)}" y1="#{comparison_px_y(100.0).round(1)}" ) +
        %(x2="#{comparison_px_x(1.0).round(1)}" y2="#{comparison_px_y(0.0).round(1)}"><title>Ideal pace: 100% remaining at period start, 0% at reset</title></line>)
    end

    # The polyline passes through every observation; the only marker is the
    # provider's logo at the current (latest) point, so "where are we right
    # now" is the single visual anchor per series.
    def self.comparison_series(entry)
      style = provider_style(entry[:provider])
      points = entry[:chart][:actual]

      line = comparison_line(points, style)
      marker = points.empty? ? "" : comparison_marker(entry, points.last, style)
      projection = comparison_projection(entry, style)
      "#{line}\n#{marker}\n#{projection}"
    end

    def self.comparison_line(points, style)
      return "" if points.size < 2

      coords = points.map { |point| "#{comparison_px_x(point[:x]).round(1)},#{comparison_px_y(point[:y]).round(1)}" }.join(" ")
      dash = style[:dasharray] ? %( stroke-dasharray="#{style[:dasharray]}") : ""
      %(<polyline class="chart-actual chart-actual-#{style[:css_class]}" points="#{coords}" fill="none"#{dash} />)
    end

    def self.comparison_marker(entry, point, style)
      label = comparison_point_label(entry, point)
      cx = comparison_px_x(point[:x])
      cy = comparison_px_y(point[:y])
      href = provider_logo_href(entry[:provider])

      unless href
        css = "chart-point chart-point-#{style[:css_class]} chart-point-current"
        return shape_markup(style[:marker], cx, cy, 10, css, label)
      end

      logo_marker(cx, cy, CURRENT_LOGO_SIZE, "chart-point chart-point-#{style[:css_class]} chart-point-current", label, href)
    end

    def self.comparison_projection(entry, style)
      projection = entry[:chart][:projection]
      return "" unless projection

      x1 = comparison_px_x(projection[:from][:x]).round(1)
      y1 = comparison_px_y(projection[:from][:y]).round(1)
      x2 = comparison_px_x(projection[:to][:x]).round(1)
      y2 = comparison_px_y(projection[:to][:y]).round(1)
      label = "#{entry[:label]} projected remaining at reset (current pace): #{projection[:to][:y].round(1)}%"
      %(<line class="chart-projection chart-projection-#{style[:css_class]}" x1="#{x1}" y1="#{y1}" x2="#{x2}" y2="#{y2}"><title>#{escape(label)}</title></line>)
    end

    # Renders one point as the provider's vendored logo. tabindex/data-tooltip/
    # <title> live on the <image> itself (not a wrapping <g>) so the existing
    # pointer/focus handling in app.js (`closest(".chart-point")`) keeps
    # working unchanged.
    def self.logo_marker(cx, cy, size, css_class, label, href)
      x = (cx - (size / 2.0)).round(1)
      y = (cy - (size / 2.0)).round(1)
      attrs = %(class="#{css_class}" tabindex="0" data-tooltip="#{escape(label)}")
      title = "<title>#{escape(label)}</title>"
      %(<image #{attrs} x="#{x}" y="#{y}" width="#{size}" height="#{size}" href="#{escape(href)}" preserveAspectRatio="xMidYMid meet">#{title}</image>)
    end

    def self.comparison_point_label(entry, point)
      return "#{entry[:label]} inferred period start: 100% remaining (no observation yet)." if point[:inferred]

      "#{entry[:label]} #{entry[:window_label]}: #{point[:y].round(1)}% remaining at #{format_time(point[:collected_at])}. " \
        "Resets #{format_time(entry[:period_end])}."
    end

    # Renders one marker as the shape style dictates. tabindex/data-tooltip/
    # <title> live on the shape element itself (not a wrapping <g>) so the
    # existing pointer/focus handling in app.js (`closest(".chart-point")`)
    # keeps working unchanged.
    def self.shape_markup(shape, cx, cy, radius, css_class, label)
      cx = cx.round(1)
      cy = cy.round(1)
      attrs = %(class="#{css_class}" tabindex="0" data-tooltip="#{escape(label)}")
      title = "<title>#{escape(label)}</title>"

      case shape
      when :square
        size = (radius * 1.7).round(1)
        x = (cx - (size / 2.0)).round(1)
        y = (cy - (size / 2.0)).round(1)
        %(<rect #{attrs} x="#{x}" y="#{y}" width="#{size}" height="#{size}">#{title}</rect>)
      when :triangle
        h = radius * 1.8
        points = "#{cx},#{(cy - (h * 0.6)).round(1)} #{(cx - (h * 0.6)).round(1)},#{(cy + (h * 0.5)).round(1)} " \
                 "#{(cx + (h * 0.6)).round(1)},#{(cy + (h * 0.5)).round(1)}"
        %(<polygon #{attrs} points="#{points}">#{title}</polygon>)
      when :diamond
        d = radius * 1.3
        points = "#{cx},#{(cy - d).round(1)} #{(cx + d).round(1)},#{cy} #{cx},#{(cy + d).round(1)} #{(cx - d).round(1)},#{cy}"
        %(<polygon #{attrs} points="#{points}">#{title}</polygon>)
      else
        %(<circle #{attrs} cx="#{cx}" cy="#{cy}" r="#{radius}">#{title}</circle>)
      end
    end

    def self.describe_comparison(section_label, entries)
      return "#{section_label}. No active window data yet." if entries.empty?

      parts = entries.map do |entry|
        gap = entry[:gap_points]
        gap_desc = gap >= 0 ? "#{gap.round(1)} points ahead of ideal pace" : "#{gap.abs.round(1)} points behind ideal pace"
        "#{entry[:label]} #{entry[:window_label]}: #{entry[:remaining_percent].round(1)}% remaining, #{gap_desc}, resets #{format_time(entry[:period_end])}"
      end
      "#{section_label}. #{parts.join('. ')}."
    end
  end
end
