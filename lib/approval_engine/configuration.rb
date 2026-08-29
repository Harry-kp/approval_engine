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

    # An optional allowlist of the group names `define_flow` may route to, e.g.
    # `%w[manager cfo legal]`. nil — the default — means "no vocabulary
    # declared", so nothing is checked and behaviour is unchanged. Set it and a
    # `step group:` typo stops the seed instead of resolving zero actors at
    # build time. All-or-nothing on purpose: a host whose
    # `resolve_approval_group` invents names dynamically should leave it nil.
    attr_accessor :approval_groups

    # Master switch for the built-in notifications. OFF by default and
    # deliberately so: upgrading the gem must never start mailing an adopter's
    # real users. Nothing below it has any effect until this is true.
    attr_accessor :notifications_enabled

    # Which notifications are live, as symbols. Drop one to silence it without
    # writing a mailer:  config.notification_events -= [ :step_reassigned ]
    attr_accessor :notification_events

    # The mailer the notifier sends through. Point it at a subclass of
    # ApprovalEngine::NotificationMailer to override individual actions wholesale.
    attr_accessor :mailer_class

    # What NotificationMailer inherits from. Point it at your ApplicationMailer to
    # pick up your layout, your `default from:`, and your styling. Read *once*,
    # when the mailer class is first loaded, so it belongs in an initializer.
    attr_accessor :parent_mailer

    # The From address. Leave nil when `parent_mailer` already supplies one;
    # otherwise set it, or Action Mailer has no sender to hand the SMTP server.
    attr_accessor :mailer_from

    # ActiveJob queue for the mail itself. nil means your app's own mailer queue —
    # the engine doesn't force a queue name on you.
    attr_accessor :mailer_queue

    # How the engine reads an address off an actor. Whatever this returns blank
    # for is skipped, never raised on: an actor without an email is a
    # configuration problem, not a reason to fail an approval.
    attr_accessor :actor_email_method

    # How an actor, and the record under approval, name themselves in an email.
    # nil falls back to something safe and generic, so a host that configures
    # nothing still gets readable mail instead of "#<Invoice:0x00007f...>".
    attr_accessor :actor_label_method
    attr_accessor :target_label_method

    # A callable returning the URL where this approval is acted on, e.g.
    # `->(approval) { Rails.application.routes.url_helpers.invoice_url(approval.target) }`.
    # The engine can't know your routes, so while this is nil the mail carries no
    # link — which is exactly why you want to set it.
    attr_accessor :approval_url_builder

    # A callable returning the actors an *approval-level* notification goes to
    # (approved / rejected / changes requested), e.g.
    # `->(approval) { [ approval.target.submitter ] }`. The engine knows who
    # approves; only you know who asked. While this is nil, those three are never
    # sent.
    attr_accessor :approval_recipients

    # Seconds a step may sit unanswered before the reminder sweep nudges its
    # assignee. nil = reminders off, which is why scheduling ReminderSweepJob
    # before configuring this does nothing.
    attr_accessor :reminder_after

    def initialize
      @outbox_queue          = :default
      @current_tenant_method = nil
      @actor_class           = "User"
      @raise_on_rule_errors  = false
      @approval_groups       = nil
      @notifications_enabled = false
      @notification_events   = %i[step_activated step_reminder step_reassigned changes_requested approval_approved approval_rejected]
      @mailer_class          = "ApprovalEngine::NotificationMailer"
      @parent_mailer         = "ActionMailer::Base"
      @mailer_from           = nil
      @mailer_queue          = nil
      @actor_email_method    = :email
      @actor_label_method    = nil
      @target_label_method   = nil
      @approval_url_builder  = nil
      @approval_recipients   = nil
      @reminder_after        = nil
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

    # True when this notification should actually be sent. Both gates matter: the
    # master switch keeps an upgrade silent, and the event list lets a host keep
    # the layer on while muting one message.
    def notification_enabled?(name)
      notifications_enabled && notification_events.include?(name)
    end

    # The mailer, resolved lazily so reloading works in development.
    def mailer
      mailer_class.to_s.constantize
    end

    # The address to mail an actor at, or nil when there isn't one. `try` means an
    # actor that doesn't respond to the method at all is skipped, not raised on.
    def actor_email(actor)
      actor.try(actor_email_method).presence
    end

    # How an actor is addressed in an email. Unlike the dashboard's deliberately
    # technical `User#3 (Manager)`, this is read by a human in their inbox.
    def actor_label(actor)
      return "" if actor.nil?

      (actor_label_method && actor.try(actor_label_method)).presence ||
        actor.try(:name).presence ||
        "#{actor.class.name} ##{actor.id}"
    end

    # ActiveRecord doesn't define a human `to_s`, so the fallback is a class-and-id
    # shape rather than an object inspection leaking into someone's inbox.
    def target_label(target)
      return "" if target.nil?

      (target_label_method && target.try(target_label_method)).presence ||
        "#{target.class.name} ##{target.id}"
    end

    def approval_url(approval)
      approval_url_builder&.call(approval).presence
    end

    def approval_recipients_for(approval)
      Array(approval_recipients&.call(approval)).compact
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
