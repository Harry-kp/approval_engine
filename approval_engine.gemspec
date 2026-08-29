require_relative "lib/approval_engine/version"

Gem::Specification.new do |spec|
  spec.name        = "approval_engine"
  spec.version     = ApprovalEngine::VERSION
  spec.authors     = [ "Harry-kp" ]
  spec.email       = [ "chaudharyharshit9@gmail.com" ]
  spec.homepage    = "https://github.com/Harry-kp/approval_engine"
  # `summary` is the snippet on rubygems.org search and in `gem search -d`, so it
  # leads with the job rather than with implementation properties nobody types
  # into a search box. `description` is indexed too, and is where the long-tail
  # phrasing belongs.
  spec.summary     = "Multi-step approval workflows for Rails: an append-only ledger, runtime routing rules, and a full audit trail."
  spec.description = <<~DESC.strip
    ApprovalEngine is a mountable Rails engine for human-in-the-loop approval
    processes — a manager then the CFO, Legal and IT in parallel, "any two of
    five reviewers". It gives you an append-only approval ledger, tenant-scoped
    routing rules stored as JSON Logic so admins can change them without a
    deploy, a declarative define_flow DSL for the flows that live in your
    codebase, consensus per layer (any/all/majority/percentage/count),
    time-bound delegation with intended-vs-actual actor auditing, per-step
    timeouts that never auto-approve, optional built-in notifications, and a
    transactional outbox so a failing external API can never roll back an
    approval. PostgreSQL and ActiveJob; no Redis or Sidekiq required.
  DESC
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.1.0"

  # `source_code_uri` is pinned to the repository rather than derived from
  # `homepage`: moving the homepage some day must not silently repoint the
  # "Source code" link on rubygems.org at a marketing page. There is no
  # `homepage_uri` here on purpose — it would duplicate `spec.homepage`, which
  # rubygems.org already renders, and `gem build` warns about the duplicate.
  spec.metadata["source_code_uri"]       = "https://github.com/Harry-kp/approval_engine"
  spec.metadata["documentation_uri"]     = "https://github.com/Harry-kp/approval_engine/blob/main/docs/COOKBOOK.md"
  spec.metadata["changelog_uri"]         = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]       = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Ship only runtime files (no Rakefile/test harness/dev tooling) and only
  # files, never directory entries — keep the published gem minimal. The two
  # docs ride along because `bundle open approval_engine` should answer a
  # question rather than send you back to a browser; they are named one by one
  # so a future docs/ subdirectory can never be packaged by accident.
  spec.files = Dir.chdir(__dir__) do
    Dir[
      "{app,config,db,lib}/**/*", "MIT-LICENSE", "README.md", "CHANGELOG.md",
      "docs/ARCHITECTURE.md", "docs/COOKBOOK.md"
    ].select { |f| File.file?(f) }
  end

  spec.add_dependency "rails", ">= 7.0.8", "< 9.0"
  spec.add_dependency "shiny_json_logic", "~> 0.3"
end
