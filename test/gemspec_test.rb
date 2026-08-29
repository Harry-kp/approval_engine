require "test_helper"

# The packaging contract.
class GemspecTest < ActiveSupport::TestCase
  REPO_URL = "https://github.com/Harry-kp/approval_engine".freeze

  def spec
    @spec ||= Dir.chdir(ApprovalEngine::Engine.root) do
      Gem::Specification.load(ApprovalEngine::Engine.root.join("approval_engine.gemspec").to_s)
    end
  end

  test "declares the metadata rubygems.org renders" do
    %w[source_code_uri documentation_uri changelog_uri bug_tracker_uri
       rubygems_mfa_required].each do |key|
      assert spec.metadata[key].present?, "the gemspec declares no #{key}"
    end

    # The Homepage link comes from `spec.homepage`; a `homepage_uri` alongside it
    # is a duplicate rubygems.org ignores and `gem build` warns about.
    assert_equal REPO_URL, spec.homepage
    assert_nil spec.metadata["homepage_uri"]
  end

  # Derived from `homepage` it would follow the homepage anywhere — including to
  # a marketing page some day, which would silently stop "Source code" pointing
  # at source.
  test "source_code_uri is pinned to the repository, not derived from homepage" do
    assert_equal REPO_URL, spec.metadata["source_code_uri"]
  end

  test "documentation_uri points at a file that exists in this repository" do
    uri  = spec.metadata["documentation_uri"]
    path = uri[%r{/blob/main/(.+)\z}, 1]
    assert path, "documentation_uri (#{uri}) is not a /blob/main/ link into this repository"
    assert File.exist?(ApprovalEngine::Engine.root.join(path)),
           "documentation_uri points at #{path}, which does not exist — the link is already a 404"
  end

  test "the summary leads with what the gem does" do
    assert_match(/\Amulti-step approval workflows for rails/i, spec.summary)
    assert_operator spec.summary.length, :<=, 160,
                    "rubygems.org truncates a long summary in search results"
  end

  test "packages the two reference docs" do
    assert_includes spec.files, "docs/COOKBOOK.md"
    assert_includes spec.files, "docs/ARCHITECTURE.md"
  end

  # Named explicitly rather than globbed for exactly this reason: a `docs/**/*`
  # would ship whatever lands in docs/ next, and assets/ is megabytes of
  # screenshots the README already loads over HTTP.
  test "packages neither the screenshots nor anything else under docs" do
    assert_empty spec.files.grep(%r{\Aassets/}), "assets/ is being packaged into the gem"

    extra = spec.files.grep(%r{\Adocs/}) - %w[docs/ARCHITECTURE.md docs/COOKBOOK.md]
    assert_empty extra, "docs/ is being globbed rather than enumerated"
  end

  test "the packaged version matches the library" do
    assert_equal ApprovalEngine::VERSION, spec.version.to_s
  end

  # Host apps `require "approval_engine/test_helpers"`, so it has to be in the
  # package — it lives under lib/ but is not loaded by the engine itself.
  test "ships the test helpers host apps are told to require" do
    assert_includes spec.files, "lib/approval_engine/test_helpers.rb"
  end
end
