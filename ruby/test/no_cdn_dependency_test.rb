require_relative "test_helper"

# The dashboard must render entirely from files this repo ships (server-
# rendered HTML/SVG + local /app.css, /app.js, /logos/*), never fetching a
# script, stylesheet, font, or image from a third-party CDN at request time.
class NoCdnDependencyTest < AgentUsageTest
  RUNTIME_ASSET_PATTERN = %r{(?:src|href)\s*=\s*["']https?://|url\(\s*["']?https?://|@import\s+["']?https?://}i.freeze

  def test_the_rendered_view_never_references_an_external_url
    view_source = File.read(File.join(__dir__, "..", "views", "index.erb"))
    refute_match RUNTIME_ASSET_PATTERN, view_source
  end

  def test_app_css_never_references_an_external_url
    css_source = File.read(File.join(__dir__, "..", "public", "app.css"))
    refute_match RUNTIME_ASSET_PATTERN, css_source
  end

  def test_app_js_never_references_an_external_url
    js_source = File.read(File.join(__dir__, "..", "public", "app.js"))
    refute_match RUNTIME_ASSET_PATTERN, js_source
  end

  def test_provider_logos_are_vendored_locally_not_fetched_from_a_cdn
    logos_dir = File.join(__dir__, "..", "public", "logos")
    %w[claude.svg codex.svg grok.png].each do |file|
      path = File.join(logos_dir, file)
      assert File.exist?(path), "expected #{file} to be vendored under ruby/public/logos"
    end
  end

  def test_vendored_svg_logos_are_sanitized
    logos_dir = File.join(__dir__, "..", "public", "logos")
    Dir.glob(File.join(logos_dir, "*.svg")).each do |path|
      svg = File.read(path)
      refute_match(/<script/i, svg, "#{path} must not contain <script>")
      refute_match(/<foreignObject/i, svg, "#{path} must not contain <foreignObject>")
      refute_match(/\son\w+\s*=/i, svg, "#{path} must not contain inline event handlers")
    end
  end
end
