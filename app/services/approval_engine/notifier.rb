module ApprovalEngine
  # Turns one relayed outbox event into one piece of mail. It is the only place
  # that knows which event produces which notification, who receives it, and
  # whether it is switched on at all.
  #
  # Nothing here sends anything until the host sets
  # `config.notifications_enabled = true` — an upgrade from a version without
  # notifications must never start mailing real people on its own.
  class Notifier
    # Outbox event name => notification. The three step notifications go to the
    # actor the engine already knows (the assignee); the three approval-level
    # ones go wherever `config.approval_recipients` says, because the engine
    # knows who approves but not who asked.
    EVENTS = {
      "step.activated"         => :step_activated,
      "step.reminded"          => :step_reminder,
      "step.reassigned"        => :step_reassigned,
      "step.changes_requested" => :changes_requested,
      "approval.approved"      => :approval_approved,
      "approval.rejected"      => :approval_rejected
    }.freeze

    ACTOR_ADDRESSED = %i[step_activated step_reminder step_reassigned].freeze

    def self.deliver(event)
      new(event).deliver
    end

    def initialize(event)
      @event        = event
      @notification = EVENTS[event.event_name]
    end

    def deliver
      return unless notification && ApprovalEngine.config.notification_enabled?(notification)
      return unless record

      addresses = recipient_addresses
      if addresses.empty?
        Rails.logger&.warn("[ApprovalEngine] no recipient address for #{@event.event_name} on #{record.class}##{record.id} — notification skipped")
        return
      end

      warn_without_sender
      addresses.each { |address| enqueue(address) }
    end

    private

    attr_reader :notification

    def record
      @event.record
    end

    # Mail is enqueued, not sent, from here: the SMTP round trip belongs in its
    # own job so a dead mail server retries the *mail*, never the outbox event
    # (which would re-run the host's callbacks alongside it).
    def enqueue(address)
      message(address).deliver_later(**delivery_options)
    end

    def message(address)
      mailer = ApprovalEngine.config.mailer

      if notification == :approval_rejected
        mailer.approval_rejected(record, to: address, reason: @event.error_payload)
      else
        mailer.public_send(notification, record, to: address)
      end
    end

    # Action Mailer has nothing to hand the SMTP server without a sender, and the
    # resulting failure surfaces deep inside the delivery job, far from the
    # missing setting that caused it. Name the fix here, where it is obvious. The
    # mail is still enqueued: silently dropping what the host asked for is worse
    # than a message their queue will report on.
    def warn_without_sender
      return if ApprovalEngine.config.mailer_from.present?
      return if ApprovalEngine.config.mailer.default_params[:from].present?

      Rails.logger&.warn("[ApprovalEngine] notifications are enabled but no From address is configured — set config.mailer_from, or point config.parent_mailer at a mailer with a `default from:`")
    end

    def delivery_options
      queue = ApprovalEngine.config.mailer_queue
      queue ? { queue: queue } : {}
    end

    def recipient_addresses
      Array(recipients).filter_map { |actor| ApprovalEngine.config.actor_email(actor) }.uniq
    end

    def recipients
      if ACTOR_ADDRESSED.include?(notification)
        [ record.assigned_actor ]
      else
        ApprovalEngine.config.approval_recipients_for(approval)
      end
    end

    def approval
      record.is_a?(Approval) ? record : record.approval
    end
  end
end
