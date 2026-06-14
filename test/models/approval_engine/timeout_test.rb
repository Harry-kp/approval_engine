require "test_helper"

module ApprovalEngine
  # Per-step timeouts. The guiding rule: a timeout can deny, escalate, or nudge —
  # it can NEVER manufacture an approval. Silence is not consent.
  class TimeoutTest < ApprovalEngine::TestCase
    setup do
      @invoice  = Invoice.create!(tenant_id: TENANT, amount: 6000)
      @manager  = create_user(role: :manager)
      @approval = Approval.create!(tenant_id: TENANT, target: @invoice, status: "pending")
      @track    = @approval.tracks.create!(tenant_id: TENANT, name: "Main")
    end

    def pending_step(timeout_after: 3600)
      @track.steps.create!(tenant_id: TENANT, layer: 1, status: "pending",
                           timeout_after: timeout_after, assigned_actor: @manager)
    end

    test "a pending step's deadline is its activation plus the SLA window" do
      step = pending_step(timeout_after: 3600)

      assert_not_nil step.activated_at
      assert_in_delta step.activated_at + 3600, step.timeout_at, 1
    end

    test "no timeout_after means no deadline and never overdue" do
      pending_step(timeout_after: nil)

      assert_nil Step.last.timeout_at
      assert_not Step.overdue.exists?
    end

    test "a waiting step's clock starts only when its layer opens" do
      waiting = @track.steps.create!(tenant_id: TENANT, layer: 2, status: "waiting",
                                     timeout_after: 3600, assigned_actor: create_user(role: :cfo))
      assert_nil waiting.timeout_at, "the clock doesn't run while waiting"

      waiting.update!(status: "pending")

      assert_not_nil waiting.reload.timeout_at, "activation starts the SLA clock"
    end

    test "overdue is only pending, past-deadline, not-yet-fired steps" do
      pending_step(timeout_after: 3600) # deadline in the future
      due = pending_step(timeout_after: 3600)
      due.update_column(:timeout_at, 1.minute.ago)

      assert_equal [ due ], Step.overdue.to_a
    end

    test "time_out! signals once and never decides the step (silence is not consent)" do
      step = pending_step
      step.update_column(:timeout_at, 1.minute.ago)

      assert_difference -> { OutboxEvent.where(event_name: "step.timed_out").count }, 1 do
        step.time_out!
      end

      assert step.reload.pending?, "the step is NOT auto-decided"
      assert_not_nil step.timed_out_at
      log = step.audit_logs.find_by(event: "timed_out")
      assert_nil log.actual_actor, "no human acted, and the ledger says so"
      assert_not log.by_proxy?

      assert_no_difference -> { OutboxEvent.count } do
        step.time_out! # already fired — idempotent
      end
      assert_not Step.overdue.exists?
    end

    test "expire! is an honest terminal denial with no human actor" do
      step = pending_step

      step.expire!

      assert step.reload.expired?
      assert step.terminal?
      assert_nil step.decided_at, "an expiry is not a human decision"
      assert_nil step.audit_logs.find_by(event: "expired").actual_actor
    end

    test "expiring the sole step fails the approval consensus-aware" do
      step = pending_step

      step.expire!

      assert_equal "rejected", @approval.reload.status, "no approval was ever granted"
    end

    test "expire! is a no-op once a human has already decided" do
      step = pending_step
      step.approve!(by: @manager)

      assert_nothing_raised { step.expire! }
      assert step.reload.approved?, "the human decision stands; expiry can't override it"
    end

    test "the engine never auto-approves on timeout" do
      step = pending_step
      step.update_column(:timeout_at, 1.minute.ago)

      Step.sweep_timeouts!

      assert_not step.reload.approved?
      assert_equal "pending", step.status, "a timeout signals; it never grants approval"
    end

    test "TimeoutSweepJob sweeps overdue steps" do
      step = pending_step
      step.update_column(:timeout_at, 1.minute.ago)

      TimeoutSweepJob.perform_now

      assert_not_nil step.reload.timed_out_at
    end

    test "the sweep fires overdue steps through the host's on_step_timeout callback" do
      step = pending_step
      step.update_column(:timeout_at, 1.minute.ago)
      seen = []
      Invoice.define_method(:on_step_timeout) { |s| seen << s }

      assert_equal 1, Step.sweep_timeouts!
      ProcessOutboxJob.perform_now(OutboxEvent.find_by!(event_name: "step.timed_out").id)

      assert_equal [ step ], seen
    ensure
      Invoice.remove_method(:on_step_timeout) if Invoice.method_defined?(:on_step_timeout)
    end

    test "host can deny on timeout: on_step_timeout -> expire! -> approval fails" do
      step = pending_step
      step.update_column(:timeout_at, 1.minute.ago)
      Invoice.define_method(:on_step_timeout) { |s| s.expire! }

      Step.sweep_timeouts!
      ProcessOutboxJob.perform_now(OutboxEvent.find_by!(event_name: "step.timed_out").id)

      assert step.reload.expired?
      assert_equal "rejected", @approval.reload.status
    ensure
      Invoice.remove_method(:on_step_timeout) if Invoice.method_defined?(:on_step_timeout)
    end
  end
end
