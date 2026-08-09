require "sinatra/base"
require "json"
require "time"
require "rack/utils"

require_relative "database"
require_relative "collector"
require_relative "dashboard"
require_relative "chart"

module AgentUsage
  class Web < Sinatra::Base
    set :bind, "127.0.0.1"
    set :port, 4570
    set :server, %w[webrick]
    set :views, File.expand_path("../../views", __dir__)
    set :public_folder, File.expand_path("../../public", __dir__)
    set :show_exceptions, false
    set :raise_errors, false
    # The server only ever binds 127.0.0.1, but Sinatra's default
    # development host allowlist still rejects requests whose Host header
    # isn't exactly "localhost" (e.g. "127.0.0.1:4570" from a browser).
    set :host_authorization, { permitted_hosts: ["127.0.0.1", "localhost"] }

    # Tests override these to point at a temporary database and a fixture
    # cli_runner instead of the real ~/Library database and a real
    # `agent-usage-cli` subprocess.
    class << self
      attr_accessor :db_path_override, :cli_runner_override
    end

    get "/health" do
      content_type :json
      JSON.generate(ok: true, data: { status: "ok", time: Time.now.utc.iso8601 })
    end

    get "/api/dashboard.json" do
      content_type :json
      JSON.generate(ok: true, data: dashboard_view)
    end

    post "/api/collect" do
      result = run_collector
      if wants_json?
        content_type :json
        JSON.generate(ok: true, data: { locked: result[:locked], stored: result[:stored] == true })
      else
        redirect "/"
      end
    end

    get "/" do
      @view = dashboard_view
      erb :index
    end

    def current_db_path
      self.class.db_path_override || Database.path
    end

    def dashboard_view
      db = Database.connect(path: current_db_path)
      Dashboard.build(db)
    ensure
      db&.close
    end

    def run_collector
      cli_runner = self.class.cli_runner_override || Collector.default_runner
      Collector.new(db_path: current_db_path, cli_runner: cli_runner).run
    end

    def wants_json?
      (request.env["HTTP_ACCEPT"] || "").include?("application/json")
    end

    def render_chart(window_view, dom_id)
      Chart.render(window_view, dom_id: dom_id)
    end

    # Provider window keys and error messages ultimately originate from
    # third-party CLI/API responses (e.g. a Codex rateLimitsByLimitId key),
    # so they are escaped before landing in the ERB template.
    def h(text)
      Rack::Utils.escape_html(text.to_s)
    end

    def format_duration(seconds)
      return "—" if seconds.nil?
      return "resetting…" if seconds <= 0

      total = seconds.to_i
      days = total / 86_400
      hours = (total % 86_400) / 3_600
      minutes = (total % 3_600) / 60
      return "#{days}d #{hours}h" if days.positive?
      return "#{hours}h #{minutes}m" if hours.positive?

      "#{minutes}m"
    end

    def format_percent(value)
      return "—" if value.nil?

      format("%.1f%%", value)
    end

    def format_signed_points(value)
      return "—" if value.nil?

      format("%+.1f pts", value)
    end

    def format_burn(value)
      return "n/a" if value.nil?

      format("%.1f pts/day", value)
    end

    def format_time(iso)
      return "—" unless iso

      Time.parse(iso).getlocal.strftime("%b %-d, %-I:%M %p")
    rescue ArgumentError, TypeError
      iso.to_s
    end
  end
end
