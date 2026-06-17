require_relative "lib/approval_engine/version"

Gem::Specification.new do |spec|
  spec.name        = "approval_engine"
  spec.version     = ApprovalEngine::VERSION
  spec.authors     = [ "Harry-kp" ]
  spec.email       = [ "chaudharyharshit9@gmail.com" ]
  spec.homepage    = "https://github.com/Harry-kp/approval_engine"
  spec.summary     = "Multi-tenant, immutable-ledger approval flows for Rails."
  spec.description = <<~DESC.strip
    A mountable Rails engine for human-in-the-loop approval flows: an
    append-only ledger, dynamic JSON-Logic routing, consensus (any/all/majority),
    delegation, and a transactional outbox — without forcing Redis or Sidekiq.
  DESC
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["source_code_uri"]       = spec.homepage
  spec.metadata["changelog_uri"]         = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]       = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Ship only runtime files (no Rakefile/test harness/dev tooling) and only
  # files, never directory entries — keep the published gem minimal.
  spec.files = Dir.chdir(__dir__) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "README.md", "CHANGELOG.md"].select { |f| File.file?(f) }
  end

  spec.add_dependency "rails", ">= 7.0.8", "< 9.0"
  spec.add_dependency "shiny_json_logic", "~> 0.3"
end
