ApprovalEngine.configure do |config|
  # ActiveJob queue used to relay the transactional outbox (host callbacks and
  # notifications). Defaults to :default; a dedicated queue is recommended.
  config.outbox_queue = :default

  # How the engine resolves the current tenant for strict data isolation.
  # Return anything that responds to #id, e.g. with acts_as_tenant:
  #   config.current_tenant_method = -> { Current.account }
  # IMPORTANT: while this is nil, auto-routing on create silently no-ops (the
  # engine can't scope the rules). Single-tenant apps can return a constant:
  #   config.current_tenant_method = -> { Struct.new(:id).new("default") }
  config.current_tenant_method = nil

  # Your application's actor class (who approves). It must define:
  #   def self.resolve_approval_group(group_name, target) -> [actors]
  config.actor_class = "User"

  # Fail closed by default: a malformed dynamic rule quarantines the approval
  # instead of crashing the approval. Set to true in development/test to raise.
  config.raise_on_rule_errors = false
end
