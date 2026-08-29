require "test_helper"

module ApprovalEngine
  # Reminders. The guiding rule: a nudge is not a verdict, and a nudge fires
  # once. A sweep that runs every ten minutes must never mail someone every ten
  # minutes — that is the whole reason `reminded_at` exists.
  class ReminderTest < ApprovalEngine::TestCase
    setup do
      @invoice  = Invoice.create!(tenant_id: TENANT, amount: 6000)
      @manager  = create_user(role: :manager)
      @approval = Approval.create!(tenant_id: TENANT, target: @invoice, status: "pending")
      @track    = @approval.tracks.create!(tenant_id: TENANT, name: "Main")
    end

    def pending_step(waiting_for: nil)
      step = @track.steps.create!(tenant_id: TENANT, layer: 1, status: "pending", assigned_actor: @manager)
      step.update_column(:activated_at, waiting_for.ago) if waiting_for
      step
    end

    test "remindable selects only pending, un-nudged steps past the threshold" do
      pending_step(waiting_for: 10.minutes)
      stale = pending_step(waiting_for: 3.days)
      already = pending_step(waiting_for: 3.days)
      already.update_column(:reminded_at, 1.hour.ago)

      assert_equal [ stale ], Step.remindable(after: 2.days).to_a
    end

    test "remind! nudges once and never decides the step" do
      step = pending_step(waiting_for: 3.days)

      assert_difference -> { OutboxEvent.where(event_name: "step.reminded").count }, 1 do
        step.remind!
      end

      assert step.reload.pending?, "a nudge does NOT decide the step"
      assert_not_nil step.reminded_at
      assert_nil step.decided_at, "a nudge is not a decision"

      assert_no_difference -> { OutboxEvent.count } do
        step.remind! # already nudged — idempotent
      end
      assert_empty Step.remindable(after: 2.days).to_a
    end

    test "a reminder is a system event with no human actor on the ledger" do
      step = pending_step(waiting_for: 3.days)

      step.remind!

      log = step.audit_logs.find_by(event: "reminded")
      assert_not_nil log, "the nudge is durable compliance evidence, not just a column"
      assert_nil log.actual_actor, "nobody acted, and the ledger says so"
      assert_not log.by_proxy?
    end

    test "the sweep is a no-op until reminder_after is configured" do
      pending_step(waiting_for: 30.days)

      assert_no_difference -> { OutboxEvent.count } do
        assert_equal 0, Step.sweep_reminders!
      end
    end

    test "sweep_reminders! nudges every stale step and returns the count" do
      first  = pending_step(waiting_for: 3.days)
      second = pending_step(waiting_for: 3.days)
      pending_step(waiting_for: 1.hour) # still inside the window
      ApprovalEngine.config.reminder_after = 2.days.to_i

      assert_equal 2, Step.sweep_reminders!

      assert_not_nil first.reload.reminded_at
      assert_not_nil second.reload.reminded_at
    end

    test "sweep_reminders! scopes to one tenant" do
      mine = pending_step(waiting_for: 3.days)
      theirs = other_tenant_step(waiting_for: 3.days)
      ApprovalEngine.config.reminder_after = 2.days.to_i

      assert_equal 1, Step.sweep_reminders!(tenant_id: TENANT)

      assert_not_nil mine.reload.reminded_at
      assert_nil theirs.reload.reminded_at, "another tenant's approvers are not ours to nudge"
    end

    test "ReminderSweepJob sweeps stale steps" do
      step = pending_step(waiting_for: 3.days)
      ApprovalEngine.config.reminder_after = 2.days.to_i

      ReminderSweepJob.perform_now

      assert_not_nil step.reload.reminded_at
    end

    test "the sweep fires through the host's on_step_reminder callback" do
      step = pending_step(waiting_for: 3.days)
      ApprovalEngine.config.reminder_after = 2.days.to_i
      seen = []
      Invoice.define_method(:on_step_reminder) { |s| seen << s }

      assert_equal 1, Step.sweep_reminders!
      ProcessOutboxJob.perform_now(OutboxEvent.find_by!(event_name: "step.reminded").id)

      assert_equal [ step ], seen
    ensure
      Invoice.remove_method(:on_step_reminder) if Invoice.method_defined?(:on_step_reminder)
    end

    test "a fresh iteration re-arms the reminder" do
      step = pending_step(waiting_for: 3.days)
      step.remind!

      step.request_changes!(by: @manager, comment: "Missing PO number")

      redone = @track.steps.for_iteration(2).sole
      assert redone.pending?
      assert_nil redone.reminded_at, "rework restarts the clock without special-casing"
      redone.update_column(:activated_at, 3.days.ago)
      assert_equal [ redone ], Step.remindable(after: 2.days).to_a
    end

    private

    # A whole second approval under another tenant — the sweep must not reach
    # across the boundary even though the steps look identical.
    def other_tenant_step(waiting_for:)
      invoice  = Invoice.create!(tenant_id: "tenant-2", amount: 100)
      approval = Approval.create!(tenant_id: "tenant-2", target: invoice, status: "pending")
      track    = approval.tracks.create!(tenant_id: "tenant-2", name: "Main")
      step = track.steps.create!(tenant_id: "tenant-2", layer: 1, status: "pending",
                                 assigned_actor: create_user(role: :cfo))
      step.update_column(:activated_at, waiting_for.ago)
      step
    end
  end
end
