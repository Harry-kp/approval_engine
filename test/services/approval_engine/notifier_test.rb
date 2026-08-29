require "test_helper"

module ApprovalEngine
  # A mailer a host might plug in via `config.mailer_class` to take one
  # notification over completely, leaving the other five alone.
  class HostNotificationMailer < ApprovalEngine::NotificationMailer
    def step_activated(step, to:)
      mail(to: to, from: "ops@example.test", subject: "Custom: #{step.name}") do |format|
        format.text { render plain: "our own words" }
      end
    end
  end

  # Dispatch: which outbox event becomes which email, who receives it, and — the
  # question this whole layer is shaped around — when nothing is sent at all.
  class NotifierTest < ApprovalEngine::TestCase
    include ActiveJob::TestHelper

    setup do
      ActionMailer::Base.deliveries.clear
      @invoice   = Invoice.create!(tenant_id: TENANT, amount: 6000)
      @manager   = create_user(role: :manager, email: "manager@example.test")
      @requester = create_user(role: :requester, email: "requester@example.test")
      @approval  = Approval.create!(tenant_id: TENANT, target: @invoice, status: "pending")
      @track     = @approval.tracks.create!(tenant_id: TENANT, name: "Finance")
      @step      = @track.steps.create!(tenant_id: TENANT, name: "Sign-off", layer: 1,
                                        status: "pending", assigned_actor: @manager)
    end

    def enable!
      ApprovalEngine.config.notifications_enabled = true
      ApprovalEngine.config.mailer_from = "approvals@example.test"
    end

    def emit(event_name, record: @approval, reason: nil)
      OutboxEvent.create!(tenant_id: TENANT, event_name: event_name, record: record, error_payload: reason)
    end

    # The step.activated event the engine wrote when the step above was built.
    def activation
      OutboxEvent.find_by!(event_name: "step.activated", record: @step)
    end

    def relay(event)
      perform_enqueued_jobs { ProcessOutboxJob.perform_now(event.id) }
    end

    # Multipart mail keeps its text in the parts, not in the container body.
    def body_of(mail)
      mail.multipart? ? mail.parts.map { |part| part.body.to_s }.join("\n") : mail.body.to_s
    end

    # The regression guard for the risk this whole design is shaped around: a
    # v1.0.0 install that upgrades the gem and runs its outbox must stay silent.
    test "notifications are off by default, so upgrading never starts sending mail" do
      perform_enqueued_jobs do
        @step.approve!(by: @manager)
        OutboxEvent.unprocessed.order(:created_at).each { |e| ProcessOutboxJob.perform_now(e.id) }
      end

      assert_equal "approved", @approval.reload.status, "the approval itself still ran"
      assert_empty ActionMailer::Base.deliveries, "nobody was mailed without opting in"
    end

    test "an activated step notifies its assignee" do
      enable!

      relay(activation)

      assert_equal 1, ActionMailer::Base.deliveries.size
      mail = ActionMailer::Base.deliveries.first
      assert_equal [ "manager@example.test" ], mail.to
      assert_equal "Approval needed: Invoice ##{@invoice.id}", mail.subject
    end

    test "removing an event from notification_events silences it" do
      enable!
      ApprovalEngine.config.notification_events -= [ :step_activated ]

      assert_no_enqueued_jobs only: ActionMailer::Base.delivery_job do
        ProcessOutboxJob.perform_now(activation.id)
      end
    end

    test "an actor with no address is skipped, not raised on" do
      enable!
      @manager.update!(email: nil)
      event = activation

      assert_no_enqueued_jobs only: ActionMailer::Base.delivery_job do
        ProcessOutboxJob.perform_now(event.id)
      end
      assert event.reload.processed, "a missing address is a config problem, not a failed event"
    end

    test "actor_email_method reads whatever the host calls its address" do
      enable!
      ApprovalEngine.config.actor_email_method = :work_email
      User.define_method(:work_email) { "manager@work.example.test" }

      relay(activation)

      assert_equal [ "manager@work.example.test" ], ActionMailer::Base.deliveries.first.to
    ensure
      User.remove_method(:work_email) if User.method_defined?(:work_email)
    end

    test "approval-level notifications stay silent until approval_recipients is configured" do
      enable!

      relay(emit("approval.approved"))
      assert_empty ActionMailer::Base.deliveries, "the engine knows who approves, not who asked"

      ApprovalEngine.config.approval_recipients = ->(_approval) { [ @requester ] }
      relay(emit("approval.approved"))

      assert_equal [ "requester@example.test" ], ActionMailer::Base.deliveries.first.to
    end

    test "approval.rejected carries the outbox reason into the mail" do
      enable!
      ApprovalEngine.config.approval_recipients = ->(_approval) { [ @requester ] }

      relay(emit("approval.rejected", reason: "over budget"))

      assert_match(/over budget/, body_of(ActionMailer::Base.deliveries.first))
    end

    test "step_reassigned goes to the new assignee, not the old one" do
      enable!
      backup = create_user(role: :backup, email: "backup@example.test")
      @step.reassign!(to: backup)

      relay(OutboxEvent.find_by!(event_name: "step.reassigned", record: @step))

      assert_equal [ "backup@example.test" ], ActionMailer::Base.deliveries.first.to
    end

    test "mailer_class lets a host replace a notification wholesale" do
      enable!
      ApprovalEngine.config.mailer_class = "ApprovalEngine::HostNotificationMailer"

      relay(activation)

      assert_equal "Custom: Sign-off", ActionMailer::Base.deliveries.first.subject
    end

    test "mailer_queue is honoured, and left to the host's default when unset" do
      enable!
      # What this mail would land on if the host enqueued it themselves — the
      # engine must not quietly move it off that queue.
      clear_enqueued_jobs
      NotificationMailer.step_activated(@step, to: "probe@example.test").deliver_later
      host_default = enqueued_jobs.last[:queue]

      clear_enqueued_jobs
      ProcessOutboxJob.perform_now(activation.id)
      assert_equal host_default, enqueued_jobs.last[:queue], "the engine picks no queue of its own"

      clear_enqueued_jobs
      ApprovalEngine.config.mailer_queue = :approvals_mail
      ProcessOutboxJob.perform_now(emit("step.reassigned", record: @step).id)

      assert_equal "approvals_mail", enqueued_jobs.last[:queue]
    end

    # The guard for the reason mail is enqueued rather than sent inside the
    # relay: a broken notification must not fail the event, because the retry
    # would re-run the host's callbacks — turning a mailer problem into a
    # double-disbursed invoice.
    test "a broken notification is logged and never fails the outbox event" do
      enable!
      ApprovalEngine.config.mailer_class = "ApprovalEngine::NoSuchMailer"
      event = activation
      clear_enqueued_jobs

      ProcessOutboxJob.perform_now(event.id)

      assert event.reload.processed, "the ledger event was delivered; only the courtesy mail failed"
      assert_no_enqueued_jobs only: ProcessOutboxJob # a mailer problem must not retry the event
      assert_no_enqueued_jobs only: ActionMailer::Base.delivery_job
    end
  end
end
