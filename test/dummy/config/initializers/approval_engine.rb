# The dummy app opts into the admin so the engine's own tests can exercise it.
# Routes are drawn once at boot, so this can't be flipped per test — the
# request-time guard is what the "disabled" tests toggle.
ApprovalEngine.configure { |config| config.admin_enabled = true }
