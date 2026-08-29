module ApprovalEngine
  # The engine's built-in notifications: the approver-facing half of the system
  # that a host otherwise has to write from scratch.
  #
  # Dispatched by Notifier from inside ProcessOutboxJob, never from a model
  # callback — so a message is only ever built for state that has already
  # committed, and a down SMTP server can't reach back into an approval.
  #
  # Every action takes an explicit `to:` (the notifier owns recipient resolution)
  # and assigns nothing but plain Strings and Integers, so no view ever calls a
  # method on a host record. That is what keeps these templates usable by any
  # application, whatever its models happen to be called.
  #
  # To restyle one message, drop your own copy at
  # app/views/approval_engine/notification_mailer/<action>.html.erb — your app's
  # view path is searched before the engine's. Override *both* formats of an
  # action together: Action Mailer takes an action's templates from the first
  # view path that has any of them, so a lone .html.erb in your app silences the
  # engine's .text.erb and leaves you with a single-part message. To replace one
  # wholesale instead, subclass this and point `config.mailer_class` at it.
  class NotificationMailer < ApprovalEngine.config.parent_mailer.constantize
    # Only impose our own layout when we aren't inheriting the host's mailer — if
    # they pointed `parent_mailer` at their ApplicationMailer, their layout and
    # their `default from:` are the whole point of doing so.
    layout "approval_engine/mailer" if superclass == ActionMailer::Base

    # Action Mailer resolves templates from `self.class.mailer_name`, which for a
    # subclass is the subclass's own path. Without this, the documented
    # `config.mailer_class` route — subclass this, override one action — raises
    # ActionView::MissingTemplate for that action *and* for the five inherited
    # ones, because they would all look under `app/views/<your_mailer>/`.
    # Pinning the path here means a subclass inherits the engine's views and
    # overrides only what it actually rewrites. A host that wants its own
    # templates still gets them: its view path is searched first.
    default template_path: "approval_engine/notification_mailer"

    def step_activated(step, to:)
      assign_step(step)
      notification_mail(to: to)
    end

    def step_reminder(step, to:)
      assign_step(step)
      # Rounded to whole hours because "it has been sitting for two days" is the
      # point of a nudge; the arithmetic is not.
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

    # One funnel for all six. `from` is only set when the host configured one, so
    # inheriting their mailer keeps whatever sender they already standardised on;
    # the subject lives in the locale file, where they can rewrite it without
    # touching the engine.
    def notification_mail(to:)
      headers = { to: to, subject: default_i18n_subject(target: @target_label) }
      headers[:from] = ApprovalEngine.config.mailer_from if ApprovalEngine.config.mailer_from.present?
      mail(headers)
    end
  end
end
