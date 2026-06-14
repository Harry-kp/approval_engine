require "test_helper"

module ApprovalEngine
  # The approver-inbox query: Step.actionable_by(actor).
  class InboxTest < ApprovalEngine::TestCase
    setup do
      @invoice = Invoice.create!(tenant_id: TENANT, amount: 6000, department: "IT")
      @alice = create_user(role: :manager, name: "Alice")
      @bob   = create_user(role: :manager, name: "Bob")
      @approval = Approval.create!(tenant_id: TENANT, target: @invoice, status: "pending")
      @track = Track.create!(tenant_id: TENANT, approval: @approval, name: "Main")
    end

    def step_for(actor, status: "pending")
      @track.steps.create!(tenant_id: TENANT, name: "Sign-off", status: status, assigned_actor: actor)
    end

    test "returns pending steps assigned directly to the actor" do
      mine = step_for(@alice)
      step_for(@bob) # someone else's

      assert_equal [ mine ], Step.actionable_by(@alice).to_a
      assert_equal 1, Step.actionable_by(@alice).count
    end

    test "excludes resolved steps" do
      step_for(@alice, status: "approved")

      assert_empty Step.actionable_by(@alice)
    end

    test "includes steps covered by an active delegation" do
      alices_step = step_for(@alice)
      Delegation.create!(tenant_id: TENANT, delegator: @alice, delegatee: @bob,
                         starts_at: 1.day.ago, ends_at: 1.day.from_now)

      assert_includes Step.actionable_by(@bob), alices_step, "Bob covers Alice while she's away"
    end

    test "ignores an expired delegation" do
      step_for(@alice)
      Delegation.create!(tenant_id: TENANT, delegator: @alice, delegatee: @bob,
                         starts_at: 10.days.ago, ends_at: 5.days.ago)

      assert_empty Step.actionable_by(@bob)
    end

    test "target points back to the host record being approved" do
      assert_equal @invoice, step_for(@alice).target
    end

    test "the inbox is N+1-free: a full inbox stays under a fixed query budget" do
      # 6 pending items, each targeting its OWN invoice — a missing preload would
      # N+1 on `target`. The preloaded inbox must stay a fixed handful of queries.
      6.times do
        c = Approval.create!(tenant_id: TENANT, target: Invoice.create!(tenant_id: TENANT), status: "pending")
        w = Track.create!(tenant_id: TENANT, approval: c, name: "W")
        w.steps.create!(tenant_id: TENANT, status: "pending", assigned_actor: @alice)
      end

      queries = count_queries do
        ApprovalEngine::Step.actionable_by(@alice)
                            .includes(track: { approval: :target })
                            .each { |s| s.target }
      end

      assert_operator queries, :<=, 5, "6 inbox items resolved in #{queries} queries — that's an N+1"
    end
  end
end
