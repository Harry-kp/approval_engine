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
  # The engine ships six emails: an approver is told they have work waiting, is
  # nudged if they go quiet, and is told when an approval is handed to them; the
  # requesting side is told when changes are requested, and when the approval is
  # approved or rejected.
  #
  # This stays false on purpose. Your Step rows are assigned to real people, and
  # an upgrade that starts mailing them — a backlog's worth on the first outbox
  # drain — is not something you can take back. Turn it on deliberately.
  config.notifications_enabled = false

  # Enabling notifications ALSO needs a sender: either set config.mailer_from,
  # or point config.parent_mailer at a mailer that already has `default from:`.
  # Without one, Action Mailer has nothing to hand the SMTP server.
  #
  #   config.mailer_from   = "approvals@example.com"
  #   config.parent_mailer = "ApplicationMailer"   # adopts your layout + sender
  #
  # Which of the six are live. Drop one to silence it:
  #   config.notification_events -= [ :step_reassigned ]
  #
  # Where an approval is acted on. The engine can't know your routes, so until
  # you set this the mail carries no link:
  #   config.approval_url_builder = ->(approval) do
  #     Rails.application.routes.url_helpers.invoice_url(approval.target)
  #   end
  #
  # Who hears about an *approval-level* outcome (approved / rejected / changes
  # requested). The engine knows who approves; only you know who asked. While
  # this is nil, those three notifications are never sent:
  #   config.approval_recipients = ->(approval) { [ approval.target.submitter ] }
  #
  # How an actor's address and display name are read, and how the record under
  # approval names itself. The label defaults fall back to "Invoice #12":
  #   config.actor_email_method  = :email
  #   config.actor_label_method  = :full_name
  #   config.target_label_method = :reference
  #
  # The mailer itself. Subclass ApprovalEngine::NotificationMailer to take one
  # message over completely, or leave it and override the views in
  # app/views/approval_engine/notification_mailer/ (override both formats of an
  # action together, or the message loses a part):
  #   config.mailer_class = "MyApprovalMailer"
  #   config.mailer_queue = :mailers

  # How long a step may sit unanswered before ReminderSweepJob nudges its
  # assignee, in seconds. nil = reminders off, so scheduling the job before
  # setting this does nothing. Each step is nudged at most once.
  #   config.reminder_after = 2.days.to_i
  config.reminder_after = nil
end
