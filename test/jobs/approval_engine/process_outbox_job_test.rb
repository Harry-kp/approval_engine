require "test_helper"

module ApprovalEngine
  class ProcessOutboxJobTest < ApprovalEngine::TestCase
    include ActiveJob::TestHelper

    setup do
      @invoice = Invoice.create!(tenant_id: TENANT, amount: 6000)
      @approval = Approval.create!(tenant_id: TENANT, target: @invoice, status: "approved")
    end

    def emit(event_name, record: @approval, reason: nil)
      OutboxEvent.create!(tenant_id: TENANT, event_name: event_name, record: record, error_payload: reason)
    end

    test "approval.approved invokes the host callback and marks the event processed" do
      event = emit("approval.approved")

      ProcessOutboxJob.perform_now(event.id)

      assert event.reload.processed
      assert_not_nil event.processed_at
      assert_equal "paid", @invoice.reload.state
    end

    test "is idempotent: an already-processed event is skipped" do
      event = emit("approval.approved")
      event.mark_processed!

      assert_no_changes -> { @invoice.reload.state } do
        ProcessOutboxJob.perform_now(event.id)
      end
    end

    test "instruments an ActiveSupport notification" do
      event = emit("approval.approved")
      received = []
      callback = ->(*args) { received << ActiveSupport::Notifications::Event.new(*args) }

      ActiveSupport::Notifications.subscribed(callback, "approval_engine.approval.approved") do
        ProcessOutboxJob.perform_now(event.id)
      end

      assert_equal 1, received.size
      assert_equal @invoice, received.first.payload[:target]
    end

    test "records the error and reschedules a retry instead of losing the work" do
      event = emit("approval.approved")

      with_failing_callback do
        # retry_on reschedules rather than raising to the caller; the work is kept.
        assert_enqueued_with(job: ProcessOutboxJob) { ProcessOutboxJob.perform_now(event.id) }
      end

      assert_not event.reload.processed, "event stays unprocessed for the retry"
      assert_match(/Stripe is down/, event.delivery_error, "the failure is recorded for ops")
      assert_nil event.failed_at, "still retrying, not yet dead-lettered"
    end

    test "a failed delivery never clobbers the semantic reason the callback reads" do
      event = emit("approval.rejected", reason: "over budget")
      Invoice.define_method(:after_rejected) { |_reason| raise "mailer down" }

      ProcessOutboxJob.perform_now(event.id) # retry_on reschedules; doesn't raise out

      event.reload
      assert_equal "over budget", event.error_payload, "the host-facing reason survives"
      assert_match(/mailer down/, event.delivery_error, "the trace goes to its own column")
    ensure
      Invoice.remove_method(:after_rejected) if Invoice.method_defined?(:after_rejected)
    end

    test "drain! does not resurrect a dead-lettered event" do
      event = emit("approval.approved")
      event.update_columns(failed_at: Time.current, created_at: 5.minutes.ago)

      assert_no_enqueued_jobs { OutboxEvent.drain! }
      assert_includes OutboxEvent.failed, event
    end

    test "retires an event whose record was purged, rather than looping forever" do
      approval = Approval.create!(tenant_id: TENANT, target: @invoice, status: "approved")
      event = emit("approval.approved", record: approval)
      approval.delete # target gone — would be a poison message if not handled

      ProcessOutboxJob.perform_now(event.id)

      assert event.reload.processed, "a purged-record event is retired, not retried endlessly"
    end

    test "relays on the configured queue, not a hardcoded one (UC15 queue agnosticism)" do
      ApprovalEngine.config.outbox_queue = :approvals_low

      assert_equal "approvals_low", ProcessOutboxJob.new.queue_name
    end

    test "step events invoke the matching step-level host callbacks" do
      track   = @approval.tracks.create!(tenant_id: TENANT, name: "Main")
      manager = User.create!(name: "M", role: "manager")
      step    = track.steps.create!(tenant_id: TENANT, layer: 1, status: "approved", assigned_actor: manager)
      seen    = []
      Invoice.define_method(:after_step_approved)          { |s| seen << [ :approved, s ] }
      Invoice.define_method(:after_step_changes_requested) { |s| seen << [ :changes, s ] }

      ProcessOutboxJob.perform_now(emit("step.approved", record: step).id)
      ProcessOutboxJob.perform_now(emit("step.changes_requested", record: step).id)

      assert_equal [ [ :approved, step ], [ :changes, step ] ], seen
    ensure
      %i[after_step_approved after_step_changes_requested].each do |m|
        Invoice.remove_method(m) if Invoice.method_defined?(m)
      end
    end

    test "drain! re-enqueues stale unprocessed events, skipping fresh and processed ones" do
      stale = emit("approval.approved")
      stale.update_column(:created_at, 2.minutes.ago)
      emit("approval.approved") # fresh: relay likely still in-flight — must be skipped
      done = emit("approval.approved")
      done.update_columns(created_at: 2.minutes.ago, processed: true)

      clear_enqueued_jobs
      OutboxEvent.drain!

      assert_enqueued_jobs 1
      assert_enqueued_with(job: ProcessOutboxJob, args: [ stale.id ])
    end

    test "drain! honors the limit so a backlog can't enqueue everything at once" do
      3.times { emit("approval.approved").update_column(:created_at, 2.minutes.ago) }

      clear_enqueued_jobs
      OutboxEvent.drain!(limit: 2)

      assert_enqueued_jobs 2
    end

    # (approval.rejected → after_rejected dispatch is covered end-to-end by the
    # integration "hard reject ... fires the rejection callback" test, which drains
    # the outbox into the dummy Invoice's real after_rejected. We don't re-test it
    # here, because overriding Invoice#after_rejected would clobber that callback.)

    test "approval.quarantined invokes the host's on_quarantined callback with the reason" do
      event = emit("approval.quarantined", reason: "malformed rule")
      seen  = []
      Invoice.define_method(:on_quarantined) { |reason| seen << reason }

      ProcessOutboxJob.perform_now(event.id)

      assert_equal [ "malformed rule" ], seen
    ensure
      Invoice.remove_method(:on_quarantined) if Invoice.method_defined?(:on_quarantined)
    end

    private

    # Temporarily make the host callback blow up, then restore it — exercises the
    # real job's failure path without any mocking library.
    def with_failing_callback
      Invoice.define_method(:after_approved) { raise "Stripe is down" }
      yield
    ensure
      Invoice.remove_method(:after_approved)
      Invoice.define_method(:after_approved) { update!(state: "paid") }
    end
  end
end
