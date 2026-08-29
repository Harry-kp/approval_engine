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

  # ---------------------------------------------------------------------------
  # Notifications (opt-in, OFF by default)
  # ---------------------------------------------------------------------------
  # Six emails: work waiting, a nudge, a handover, changes requested, approved,
  # rejected. False on purpose — your Step rows are assigned to real people, and
  # an upgrade that starts mailing them is not something you can take back.
  config.notifications_enabled = false

  # Enabling ALSO needs a sender — Action Mailer has nothing to hand the SMTP
  # server without one:
  #
  #   config.mailer_from   = "approvals@example.com"
  #   config.parent_mailer = "ApplicationMailer"   # adopts your layout + sender
  #
  # Which of the six are live. Drop one to silence it:
  #   config.notification_events -= [ :step_reassigned ]
  #
  # Where an approval is acted on. Until set, the mail carries no link:
  #   config.approval_url_builder = ->(approval) do
  #     Rails.application.routes.url_helpers.invoice_url(approval.target)
  #   end
  #
  # Who hears an approval-level outcome. The engine knows who approves; only you
  # know who asked. While nil, those three are never sent:
  #   config.approval_recipients = ->(approval) { [ approval.target.submitter ] }
  #
  # How an actor's address and name are read, and how the record names itself.
  # Labels fall back to "Invoice #12":
  #   config.actor_email_method  = :email
  #   config.actor_label_method  = :full_name
  #   config.target_label_method = :reference
  #
  # Subclass NotificationMailer to take a message over, or override views in
  # app/views/approval_engine/notification_mailer/ (both formats together, or
  # the message loses a part):
  #   config.mailer_class = "MyApprovalMailer"
  #   config.mailer_queue = :mailers

  # Seconds a step may sit before ReminderSweepJob nudges its assignee. nil =
  # off, so scheduling the job alone does nothing. Nudged at most once.
  #   config.reminder_after = 2.days.to_i
  config.reminder_after = nil

  # Mounts the admin for templates, steps and rules — the write half of the
  # dashboard. Off by default so an upgrade can't turn a read-only mount into a
  # write surface.
  #
  # THIS IS NOT AUTHENTICATION. It decides whether the write routes exist, not
  # who may reach them, so wrap the mount yourself:
  #
  #   authenticate :admin_user, ->(u) { u.super_admin? } do
  #     mount ApprovalEngine::Engine => "/approval_engine"
  #   end
  #
  # Routes are drawn at boot, so restart after changing this.
  config.admin_enabled = false
end
