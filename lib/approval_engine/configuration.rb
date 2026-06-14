module ApprovalEngine
  # Host-tunable configuration. Every knob here is a *seam*: the engine ships a
  # sensible default and lets the host application override behaviour without
  # the engine having to know anything about the host's domain.
  #
  #   ApprovalEngine.configure do |config|
  #     config.outbox_queue          = :high_priority
  #     config.actor_class           = "User"
  #     config.current_tenant_method = -> { Current.account }
  #   end
  class Configuration
    # A callable (lambda/proc) that returns the current tenant, e.g.
    # `-> { Current.account }`. The engine only ever reads `#id` off the result.
    attr_accessor :current_tenant_method

    # The ActiveJob queue the transactional outbox is processed on.
    attr_accessor :outbox_queue

    # Name of the host's actor class (the thing that approves). It must respond
    # to `resolve_approval_group(group_name, target)`. Kept as a String so the
    # engine never holds a reference to an un-reloadable constant in development.
    attr_accessor :actor_class

    # When a dynamic rule blows up (e.g. a typo'd payload key), the engine fails
    # *closed* by quarantining the approval rather than raising into your app.
    # Flip this to `true` in development/test to surface the error loudly instead.
    attr_accessor :raise_on_rule_errors

    def initialize
      @outbox_queue          = :default
      @current_tenant_method = nil
      @actor_class           = "User"
      @raise_on_rule_errors  = false
    end

    # The host's actor class, resolved lazily so reloading works in development.
    def actor_class_constant
      actor_class.to_s.constantize
    end

    # Resolves the current tenant via the configured callable. Returns nil when
    # the host has not configured tenancy (single-tenant apps are welcome too).
    def current_tenant
      current_tenant_method&.call
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield(config)
    end

    # Resets configuration to defaults. Primarily a test-suite affordance.
    def reset_configuration!
      @config = Configuration.new
    end

    # Convenience reader used across the engine to scope queries by tenant.
    def current_tenant
      config.current_tenant
    end
  end
end
