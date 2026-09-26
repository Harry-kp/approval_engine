source "https://rubygems.org"
git_source(:github) { |repo| "https://github.com/#{repo}.git" }

# Specify your gem's dependencies in approval_engine.gemspec.
gemspec

# CI pins a Rails version per matrix entry so the gemspec's supported range is
# actually exercised, not just asserted. Unset resolves to the newest Rails.
if (rails_version = ENV["RAILS_VERSION"]) && !rails_version.empty?
  gem "rails", "~> #{rails_version}.0"
  # Rails 7.x predates Minitest 6, whose runner signature it calls incorrectly.
  gem "minitest", "~> 5.25" if rails_version.start_with?("7.")
  # ActiveSupport's JSON encoder passes `quirks_mode:` to JSON.generate up to
  # Rails 8.0; json 3 removed the keyword, so every migration raises
  # `ArgumentError: unknown keyword: quirks_mode` before a test can run. Fixed
  # in 7.2 and 8.1+, which is why the unpinned matrix entry is unaffected. Drop
  # this once 7.1/8.0 leave the support range.
  gem "json", "< 3" if rails_version.start_with?("7.1", "8.0")
end

gem "puma"

gem "pg"

gem "sprockets-rails"

# Lint to the 37signals / DHH "omakase" Ruby style.
gem "rubocop-rails-omakase", require: false

# Measure line + branch coverage of the engine's own code during tests.
gem "simplecov", require: false

# Start debugger with binding.b [https://github.com/ruby/debug]
# gem "debug", ">= 1.0.0"
