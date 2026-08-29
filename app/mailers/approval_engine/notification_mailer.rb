module ApprovalEngine
  # The built-in notifications. Dispatched by Notifier from inside
  # ProcessOutboxJob, never a model callback, so a message is only built for
  # state that has already committed.
  #
  # Every action takes an explicit `to:` and assigns only Strings and Integers,
  # so no view calls a method on a host record — that is what makes these
  # templates work for any application.
  #
  # To restyle one, drop your own copy at
  # app/views/approval_engine/notification_mailer/<action>.html.erb. Override
  # *both* formats together: Action Mailer takes an action's templates from the
  # first view path holding any of them, so a lone .html.erb silences the
  # engine's .text.erb. To replace one wholesale, subclass and point
  # `config.mailer_class` at it.
  class NotificationMailer < ApprovalEngine.config.parent_mailer.constantize
    # Only impose our layout when not inheriting the host's mailer — their
    # layout and sender are the whole point of setting `parent_mailer`.
    layout "approval_engine/mailer" if superclass == ActionMailer::Base

    # Action Mailer resolves templates from `self.class.mailer_name`, so without
    # this a subclass looks under its own path and every action raises
    # MissingTemplate. Pinned here, a subclass inherits the engine's views; a
    # host's own still win, because its view path is searched first.
    default template_path: "approval_engine/notification_mailer"

    def step_activated(step, to:)
      assign_step(step)
      notification_mail(to: to)
    end

    def step_reminder(step, to:)
      assign_step(step)
      # Whole hours: "sitting for two days" is the point, not the arithmetic.
      @waiting_hours = (step.waiting_for / 3600.0).round if step.waiting_for
      notification_mail(to: to)
    end

    def step_reassigned(step, to:)
      assign_step(step)
      notification_mail(to: to)
    end

    def changes_requested(step, to:)
      assign_step(step)
      @comment = step.audit_logs.where(event: "changes_requested").order(:created_at).last&.comment
      notification_mail(to: to)
    end

    def approval_approved(approval, to:)
      assign_approval(approval)
      notification_mail(to: to)
    end

    def approval_rejected(approval, to:, reason: nil)
      assign_approval(approval)
      @reason = reason
      notification_mail(to: to)
    end

    private

    def assign_step(step)
      @step_name   = step.name
      @track_name  = step.track.name
      @actor_label = ApprovalEngine.config.actor_label(step.assigned_actor)
      assign_approval(step.track.approval)
    end

    def assign_approval(approval)
      @target_label = ApprovalEngine.config.target_label(approval.target)
      @event_name   = approval.event_name
      @url          = ApprovalEngine.config.approval_url(approval)
    end

    # One funnel for all six. `from` is set only when configured, so inheriting
    # the host's mailer keeps their sender; subjects live in the locale file.
    def notification_mail(to:)
      headers = { to: to, subject: default_i18n_subject(target: @target_label) }
      headers[:from] = ApprovalEngine.config.mailer_from if ApprovalEngine.config.mailer_from.present?
      mail(headers)
    end
  end
end
