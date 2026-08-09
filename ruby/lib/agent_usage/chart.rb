require "time"

module AgentUsage
  # Renders one burn-down SVG per active window from the fraction/percent
  # coordinates Dashboard.build_chart already computed. Colors come from
  # CSS classes (see public/app.css) so light/dark mode and
  # reduced-motion apply without regenerating markup.
  module Chart
    WIDTH = 640
    HEIGHT = 260
    MARGIN_LEFT = 44
    MARGIN_RIGHT = 16
    MARGIN_TOP = 16
    MARGIN_BOTTOM = 34
    PLOT_WIDTH = WIDTH - MARGIN_LEFT - MARGIN_RIGHT
    PLOT_HEIGHT = HEIGHT - MARGIN_TOP - MARGIN_BOTTOM

    def self.render(window_view, dom_id:)
      chart = window_view[:chart]
      <<~SVG
        <svg class="usage-chart" viewBox="0 0 #{WIDTH} #{HEIGHT}" role="img" aria-labelledby="#{dom_id}-title" preserveAspectRatio="xMidYMid meet">
          <title id="#{dom_id}-title">#{escape(describe(window_view))}</title>
          #{grid}
          #{x_axis_labels(window_view)}
          #{ideal_line(chart[:ideal])}
          #{actual_line(chart[:actual])}
          #{actual_markers(chart[:actual])}
          #{projection_markup(chart[:projection])}
        </svg>
      SVG
    end

    def self.px_x(fraction)
      MARGIN_LEFT + (clamp01(fraction) * PLOT_WIDTH)
    end

    def self.px_y(percent)
      MARGIN_TOP + (((100.0 - clamp_percent(percent)) / 100.0) * PLOT_HEIGHT)
    end

    def self.clamp01(value)
      [[value, 1.0].min, 0.0].max
    end

    def self.clamp_percent(value)
      [[value, 100.0].min, 0.0].max
    end

    def self.grid
      [0, 25, 50, 75, 100].map do |percent|
        y = px_y(percent).round(1)
        %(<line class="chart-grid" x1="#{MARGIN_LEFT}" y1="#{y}" x2="#{WIDTH - MARGIN_RIGHT}" y2="#{y}" />) +
          %(<text class="chart-axis-label" x="#{MARGIN_LEFT - 8}" y="#{y + 4}" text-anchor="end">#{percent}%</text>)
      end.join("\n")
    end

    def self.x_axis_labels(window_view)
      start_label = format_time(window_view[:period_start])
      end_label = format_time(window_view[:period_end])
      %(<text class="chart-axis-label" x="#{MARGIN_LEFT}" y="#{HEIGHT - 8}" text-anchor="start">#{escape(start_label)}</text>) +
        %(<text class="chart-axis-label" x="#{WIDTH - MARGIN_RIGHT}" y="#{HEIGHT - 8}" text-anchor="end">#{escape(end_label)}</text>)
    end

    def self.ideal_line(ideal_points)
      from = ideal_points[0]
      to = ideal_points[1]
      %(<line class="chart-ideal" x1="#{px_x(from[:x]).round(1)}" y1="#{px_y(from[:y]).round(1)}" ) +
        %(x2="#{px_x(to[:x]).round(1)}" y2="#{px_y(to[:y]).round(1)}" />)
    end

    def self.actual_line(points)
      return "" if points.size < 2

      coords = points.map { |point| "#{px_x(point[:x]).round(1)},#{px_y(point[:y]).round(1)}" }.join(" ")
      %(<polyline class="chart-actual" points="#{coords}" fill="none" />)
    end

    def self.actual_markers(points)
      points.each_with_index.map do |point, index|
        current = index == points.size - 1
        css_class = if point[:inferred]
                      "chart-point chart-point-inferred"
                    elsif current
                      "chart-point chart-point-current"
                    else
                      "chart-point"
                    end
        radius = current ? 5 : (point[:inferred] ? 4 : 3)
        label = point[:inferred] ? "Inferred period start: 100% remaining (no observation yet)" : "#{format_time(point[:collected_at])}: #{point[:y].round(1)}% remaining"
        %(<circle class="#{css_class}" tabindex="0" data-tooltip="#{escape(label)}" ) +
          %(cx="#{px_x(point[:x]).round(1)}" cy="#{px_y(point[:y]).round(1)}" r="#{radius}"><title>#{escape(label)}</title></circle>)
      end.join("\n")
    end

    def self.projection_markup(projection)
      return "" unless projection

      line = %(<line class="chart-projection" x1="#{px_x(projection[:from][:x]).round(1)}" y1="#{px_y(projection[:from][:y]).round(1)}" ) +
        %(x2="#{px_x(projection[:to][:x]).round(1)}" y2="#{px_y(projection[:to][:y]).round(1)}" />)
      label = "Projected remaining at reset: #{projection[:to][:y].round(1)}%"
      marker = %(<circle class="chart-point chart-point-projection" tabindex="0" data-tooltip="#{escape(label)}" ) +
        %(cx="#{px_x(projection[:to][:x]).round(1)}" cy="#{px_y(projection[:to][:y]).round(1)}" r="4"><title>#{escape(label)}</title></circle>)
      line + marker
    end

    def self.describe(window_view)
      gap = window_view[:gap_points]
      gap_desc = gap >= 0 ? "#{gap.round(1)} points ahead of ideal pace" : "#{gap.abs.round(1)} points behind ideal pace"
      "#{window_view[:label]} window: #{window_view[:remaining_percent].round(1)}% allowance remaining, " \
        "#{gap_desc}. Resets #{format_time(window_view[:period_end])}."
    end

    def self.format_time(iso)
      Time.parse(iso).getlocal.strftime("%b %-d, %-I:%M %p")
    rescue ArgumentError, TypeError
      iso.to_s
    end

    def self.escape(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end
  end
end
