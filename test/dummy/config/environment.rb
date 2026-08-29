# Load the Rails application.
require_relative "application"

# Initialize the Rails application.
Rails.application.initialize!

# The engine's routes read `config.admin_enabled` at the moment they are drawn.
# With `eager_load = false` (this environment's default) Rails does not draw
# them at boot at all — it defers to whichever test first touches a route
# helper, by which time ApprovalEngine::TestCase may have called
# `reset_configuration!` and put the flag back to its default of false. That
# made the admin routes come and go with the Minitest seed. Drawing them here,
# while the dummy's initializer opt-in is still in effect, reproduces what an
# eager-loading production host gets at boot.
Rails.application.reload_routes_unless_loaded
