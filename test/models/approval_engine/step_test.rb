require "test_helper"

module ApprovalEngine
  class StepTest < ApprovalEngine::TestCase
    setup do
      @manager = create_user(role: :manager)
      @approval = Approval.create!(tenant_id: TENANT, target: Invoice.create!(tenant_id: TENANT), status: "pending")
      @track = Track.create!(tenant_id: TENANT, approval: @approval, name: "Main")
      @step = @track.steps.create!(tenant_id: TENANT, layer: 1, status: "pending", assigned_actor: @manager)
      # A waiting second layer keeps a single approval from completing the whole
      # approval, so these tests stay focused on one step's behaviour.
      @track.steps.create!(tenant_id: TENANT, layer: 2, status: "waiting", assigned_actor: create_user(role: :cfo))
    end

    test "approval writes an audit row and an outbox event" do
      assert_difference -> { AuditLog.count } => 1, -> { OutboxEvent.count } => 1 do
        @step.approve!(by: @manager, comment: "Looks good")
      end

      assert_equal "approved", @step.reload.status
      log = AuditLog.last
      assert_equal "approved", log.event
      assert_equal "Looks good", log.comment
      assert_equal @manager, log.actual_actor
      assert_equal @manager, log.intended_actor
    end

    test "audit captures intended vs actual actor when a delegate acts" do
      delegate = create_user(role: :delegate)
      @step.approve!(by: delegate)

      log = AuditLog.last
      assert_equal @manager, log.intended_actor
      assert_equal delegate, log.actual_actor
      assert log.by_proxy?
    end

    test "a resolved step cannot be acted on again" do
      @step.approve!(by: @manager)

      assert_raises(ActiveRecord::RecordInvalid) { @step.reload.reject!(by: @manager) }
    end

    test "the ledger forbids illegal transitions" do
      @step.approve!(by: @manager)

      @step.reload.status = "pending"
      assert_not @step.save, "approved -> pending is rejected"
      assert_includes @step.errors[:status], "cannot transition from approved to pending"
    end

    test "audit logs are append-only" do
      @step.approve!(by: @manager)

      assert_raises(ActiveRecord::ReadOnlyRecord) { AuditLog.last.update!(comment: "tampered") }
    end

    test "the database rejects an invalid status even when Ruby validation is bypassed" do
      # update_column skips model validations — the CHECK constraint must still hold.
      assert_raises(ActiveRecord::StatementInvalid) { @step.update_column(:status, "definitely_not_a_status") }
    end

    test "the database rejects a malformed approvals_required even when Ruby validation is bypassed" do
      assert_raises(ActiveRecord::StatementInvalid) do
        @step.update_column(:approvals_required, "two-thirds")
      end
    end

    test "actionable_by? recognises the assignee and active delegates" do
      delegate = create_user(role: :delegate)
      assert @step.actionable_by?(@manager)
      assert_not @step.actionable_by?(delegate)

      Delegation.create!(tenant_id: TENANT, delegator: @manager, delegatee: delegate,
                         starts_at: 1.day.ago, ends_at: 1.day.from_now)
      assert @step.actionable_by?(delegate)
    end

    test "stamps activated_at when actionable and decided_at on a human decision" do
      assert_not_nil @step.activated_at, "a pending step is actionable now"
      assert_nil @step.decided_at
      assert_nil @step.time_to_decision, "not decided yet"
      assert_operator @step.waiting_for, :>=, 0

      @step.approve!(by: @manager)

      assert_not_nil @step.reload.decided_at
      assert_operator @step.time_to_decision, :>=, 0
    end

    test "a cancelled step records no decision time" do
      @step.update!(status: "cancelled")

      assert_nil @step.reload.decided_at, "a cancellation is not a decision"
    end

    test "a waiting step has no activation time until its layer opens" do
      late = @track.steps.create!(tenant_id: TENANT, layer: 3, status: "waiting", assigned_actor: create_user(role: :late))
      assert_nil late.activated_at

      late.update!(status: "pending")

      assert_not_nil late.reload.activated_at, "activation stamps the clock"
    end
  end

  # Pessimistic-locking proof needs real concurrent transactions, so this case
  # opts out of transactional fixtures and cleans up by hand.
  class StepConcurrencyTest < ActiveSupport::TestCase
    include ApprovalEngine::ApprovalFixtures
    self.use_transactional_tests = false

    setup do
      ApprovalEngine.reset_configuration!
      @manager = create_user(role: :manager)
      @approval = Approval.create!(tenant_id: TENANT, target: Invoice.create!(tenant_id: TENANT), status: "pending")
      @track = Track.create!(tenant_id: TENANT, approval: @approval, name: "Main")
      @step = @track.steps.create!(tenant_id: TENANT, status: "pending", assigned_actor: @manager)
    end

    teardown do
      [ AuditLog, OutboxEvent, Step, Track, Approval, Invoice, User ].each(&:delete_all)
    end

    test "concurrent approvals can never double-resolve a step" do
      threads = 2.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Step.find(@step.id).approve!(by: @manager)
          rescue ActiveRecord::RecordInvalid
            # losing the race is the expected outcome for one thread
          end
        end
      end
      threads.each(&:join)

      assert_equal "approved", @step.reload.status
      assert_equal 1, AuditLog.where(approval_engine_step_id: @step.id).count
    end
  end
end
