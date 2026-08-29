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

    # Optional allowlist of group names `define_flow` may route to, e.g.
    # `%w[manager cfo legal]`. nil (the default) checks nothing. Set it and a
    # `step group:` typo stops the seed instead of resolving zero actors later.
    attr_accessor :approval_groups

    # Master switch. Off by default: upgrading the gem must never start mailing
    # real users. Nothing below has any effect until this is true.
    attr_accessor :notifications_enabled

    # Drop one to silence it: config.notification_events -= [ :step_reassigned ]
    attr_accessor :notification_events

    # Point at a NotificationMailer subclass to override actions wholesale.
    attr_accessor :mailer_class

    # What NotificationMailer inherits from — point at your ApplicationMailer for
    # its layout and sender. Read once at class load, so set it in an initializer.
    attr_accessor :parent_mailer

    # From address. Leave nil only when `parent_mailer` already supplies one.
    attr_accessor :mailer_from

    # ActiveJob queue for the mail. nil uses your app's own mailer queue.
    attr_accessor :mailer_queue

    # How to read an address off an actor. A blank result is skipped, never
    # raised on — a missing email is not a reason to fail an approval.
    attr_accessor :actor_email_method

    # How an actor and the record name themselves in mail. nil falls back to
    # something readable rather than "#<Invoice:0x00007f...>".
    attr_accessor :actor_label_method
    attr_accessor :target_label_method

    # Callable returning where this approval is acted on. While nil the mail
    # carries no link, which is why you want to set it:
    # `->(a) { Rails.application.routes.url_helpers.invoice_url(a.target) }`
    attr_accessor :approval_url_builder

    # Who the approval-level mails (approved / rejected / changes requested) go
    # to, e.g. `->(a) { [ a.target.submitter ] }`. The engine knows who approves;
    # only you know who asked. While nil, those three are never sent.
    attr_accessor :approval_recipients

    # Seconds a step may sit unanswered before the sweep nudges its assignee.
    # nil = reminders off, so scheduling ReminderSweepJob alone does nothing.
    attr_accessor :reminder_after

    # Mounts the template/rule admin — the write half of the dashboard. Default
    # false: 1.0 shipped a read-only dashboard, and an upgrade must not turn it
    # into a write surface. Turning it on is not authentication — wrap the mount.
    attr_accessor :admin_enabled

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

      @admin_enabled         = false
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

    # Both gates matter: the switch keeps an upgrade silent, the list mutes one
    # message without turning the layer off.
    def notification_enabled?(name)
      notifications_enabled && notification_events.include?(name)
    end

    # The mailer, resolved lazily so reloading works in development.
    def mailer
      mailer_class.to_s.constantize
    end

    # `try`, so an actor that doesn't respond is skipped rather than raised on.
    def actor_email(actor)
      actor.try(actor_email_method).presence
    end

    # Read by a human in an inbox, unlike the dashboard's `User#3 (Manager)`.
    def actor_label(actor)
      return "" if actor.nil?

      (actor_label_method && actor.try(actor_label_method)).presence ||
        actor.try(:name).presence ||
        "#{actor.class.name} ##{actor.id}"
    end

    # ActiveRecord has no human `to_s`, so fall back to class-and-id rather than
    # leaking an object inspection into someone's inbox.
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
