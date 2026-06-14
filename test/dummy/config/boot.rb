# Set up gems listed in the Gemfile.
ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../../../Gemfile", __dir__)

require "bundler/setup" if File.exist?(ENV["BUNDLE_GEMFILE"])

# Start coverage before the engine is required (so lib/ is instrumented, not
# just app/). Gated on COVERAGE so ordinary test runs stay fast. Config: /.simplecov.
require "simplecov" if ENV["COVERAGE"]

$LOAD_PATH.unshift File.expand_path("../../../lib", __dir__)
