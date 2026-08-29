module ApprovalEngine
  # Turns one relayed outbox event into one piece of mail — the only place that
  # knows which event produces which notification, who gets it, and whether it
  # is on at all. Sends nothing until `config.notifications_enabled` is true.
  class Notifier
    # Step notifications go to the assignee the engine already knows; the
    # approval-level ones go wherever `config.approval_recipients` says,
    # because the engine knows who approves but not who asked.
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

    # Enqueued, not sent: a dead mail server must retry the *mail*, never the
    # outbox event, which would re-run the host's callbacks with it.
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

    # Without a sender the failure surfaces deep in the delivery job, far from
    # the missing setting. Name it here; still enqueue, because dropping what
    # the host asked for is worse than a job their queue reports on.
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

    # A delegate can act on the step (`Step.actionable_by` includes them), so a
    # notification that reaches only the assignee tells the wrong person. Both
    # are mailed: the assignee stays informed, the delegate can act.
    def recipients
      if ACTOR_ADDRESSED.include?(notification)
        [ record.assigned_actor, *active_delegates_for(record) ]
      else
        ApprovalEngine.config.approval_recipients_for(approval)
      end
    end

    def active_delegates_for(step)
      return [] if step.assigned_actor.nil?

      Delegation.active_for(step.assigned_actor, tenant_id: step.tenant_id).map(&:delegatee)
    end

    def approval
      record.is_a?(Approval) ? record : record.approval
    end
  end
end
