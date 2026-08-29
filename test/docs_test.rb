require "test_helper"

# The documentation is API, and this is the test that treats it as one.
class DocsTest < ApprovalEngine::TestCase
  ROOT      = ApprovalEngine::Engine.root
  README    = ROOT.join("README.md")
  CHANGELOG = ROOT.join("CHANGELOG.md")
  INITIALIZER = ROOT.join("lib/generators/approval_engine/install/templates/approval_engine.rb")

  RAW_ASSET_PREFIX = "https://raw.githubusercontent.com/Harry-kp/approval_engine/main/".freeze

  # `config.key =` and `config.key -=` both name a key.
  CONFIG_ASSIGNMENT = /config\.([a-z_]+)\s*[-+]?=(?!=)/
  # A commented-out example naming a key we never shipped is the same lie in
  # slower motion, so comments are scanned too — which the regex above already
  # does, since it never anchors to the start of a line.
  ENGINE_METHOD     = /ApprovalEngine\.([a-z_]+)/
  GENERATOR_CALL    = /rails generate approval_engine:([a-z_]+)/
  MARKDOWN_IMAGE    = /!\[[^\]]*\]\(([^)\s]+)\)/
  VERSION_HEADING   = /^## \[(\d+\.\d+\.\d+)\]/

  # --- names the README promises ----------------------------------------------

  test "every config key the README documents exists on Configuration" do
    assert_config_keys_exist(README)
  end

  test "every config key the install template writes exists on Configuration" do
    assert_config_keys_exist(INITIALIZER)
  end

  test "every ApprovalEngine method the README calls responds" do
    each_match(README, ENGINE_METHOD) do |method, line|
      assert ApprovalEngine.respond_to?(method),
             "README:#{line} calls ApprovalEngine.#{method}, which the engine does not respond to"
    end
  end

  test "every generator the README tells people to run exists" do
    each_match(README, GENERATOR_CALL) do |name, line|
      generator = ROOT.join("lib/generators/approval_engine/#{name}/#{name}_generator.rb")
      assert File.exist?(generator),
             "README:#{line} documents `rails generate approval_engine:#{name}`, " \
             "but #{generator.relative_path_from(ROOT)} does not exist"
    end
  end

  # --- images -----------------------------------------------------------------

  # assets/ is deliberately not in spec.files, so a relative image path renders
  # nowhere except github.com — not on rubygems.org, not in a mirror, not in
  # `bundle open`.
  test "every README image is an absolute URL" do
    each_match(README, MARKDOWN_IMAGE) do |url, line|
      assert url.start_with?("https://"),
             "README:#{line} references the image #{url} relatively. assets/ is not packaged " \
             "in the gem, so it must be an absolute #{RAW_ASSET_PREFIX}... URL"
    end
  end

  test "every repository image the README references exists in this repo" do
    urls = matches(README, MARKDOWN_IMAGE).map(&:first).grep(/\Ahttps:\/\/raw\.githubusercontent\.com/)
    assert urls.any?, "the README references no repository images at all — the screenshots are gone"

    urls.each do |url|
      assert url.start_with?(RAW_ASSET_PREFIX),
             "#{url} is a raw.githubusercontent URL for some other repository or branch"

      path = url.delete_prefix(RAW_ASSET_PREFIX)
      assert File.exist?(ROOT.join(path)),
             "the README shows #{url}, but #{path} does not exist in this repository"
    end
  end

  # --- changelog --------------------------------------------------------------

  test "the CHANGELOG has a link reference for every version heading" do
    body     = CHANGELOG.read
    versions = body.scan(VERSION_HEADING).flatten
    assert_includes versions, ApprovalEngine::VERSION,
                    "CHANGELOG.md has no entry for the current version (#{ApprovalEngine::VERSION})"

    versions.each do |version|
      assert_match(/^\[#{Regexp.escape(version)}\]: \S+/, body,
                   "CHANGELOG.md has a `## [#{version}]` heading but no `[#{version}]:` link reference, " \
                   "so the heading renders as broken markdown")
    end
  end

  private

  def assert_config_keys_exist(path)
    keys = each_match(path, CONFIG_ASSIGNMENT) do |key, line|
      assert ApprovalEngine.config.respond_to?("#{key}="),
             "#{path.basename}:#{line} documents config.#{key}, but " \
             "ApprovalEngine::Configuration has no #{key}="
    end
    assert keys.any?, "#{path.basename} documents no config keys at all — the scan is broken, not the docs"
  end

  # Yields every capture with the 1-indexed line it was found on, so a failure
  # points at somewhere to go and fix rather than at a whole file.
  def each_match(path, pattern)
    found = matches(path, pattern)
    found.each { |capture, line| yield(capture, line) }
    found.map(&:first)
  end

  def matches(path, pattern)
    path.each_line.with_index(1).flat_map do |content, line|
      content.scan(pattern).map { |capture| [ Array(capture).first, line ] }
    end
  end
end
