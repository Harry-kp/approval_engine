# Auto-loaded when SimpleCov is required. It's required from the dummy app's
# boot (gated on COVERAGE=1) *before* the engine loads, so lib/ is instrumented
# too — not just the lazily-autoloaded app/. Generator templates are copied
# verbatim into host apps, never executed here, so they're filtered out.
SimpleCov.start do
  enable_coverage :branch
  command_name "minitest"
  track_files "{app,lib}/**/*.rb"
  add_filter %r{^/test/}
  add_filter %r{/lib/generators/.+/templates/}
end
