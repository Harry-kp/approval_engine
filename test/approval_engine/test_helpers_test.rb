require "test_helper"
require "approval_engine/test_helpers"

module ApprovalEngine
  # The helpers a host app includes. They are the gem's answer to "how do I test
  # my approval flow?", so they are exercised the way a host would use them.
  class TestHelpersTest < ApprovalEngine::TestCase
    include ApprovalEngine::TestHelpers

    setup do
      @manager = create_user(role: :manager)
      @cfo     = create_user(role: :cfo)
      @template = create_template(
        event: "invoice.created",
        steps: [ { name: "Manager", layer: 1, group: "manager" },
                 { name: "CFO",     layer: 2, group: "cfo" } ]
      )
      create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 1_000 ] })
      @invoice = Invoice.create!(tenant_id: TENANT, amount: 20_000, department: "IT")
      @invoice.run_approval!(event: "invoice.created", tenant_id: TENANT)
    end

    test "approval_for finds the run, and returns nil for an unapproved record" do
      assert_equal @invoice.approvals.sole, approval_for(@invoice)
      assert_nil approval_for(Invoice.create!(tenant_id: TENANT, amount: 1, department: "IT"))
    end

    test "pending_approval_steps is the inbox for one record" do
      assert_equal [ "Manager" ], pending_approval_steps(@invoice).map(&:name)
      assert_empty pending_approval_steps(Invoice.new(tenant_id: TENANT, amount: 1))
    end

    test "approve_approval! walks every layer to a decision" do
      approval = approve_approval!(@invoice)

      assert_equal "approved", approval.status
      assert_empty pending_approval_steps(@invoice)
    end

    test "approve_approval! gives up rather than looping on a flow that never resolves" do
      assert_nothing_raised { approve_approval!(@invoice, limit: 1) }
    end

    test "reject_approval! stops at the step that is waiting" do
      approval = reject_approval!(@invoice, comment: "No PO.")

      assert_equal "rejected", approval.status
    end

    test "draining the outbox is what makes the host's callback run" do
      approve_approval!(@invoice)
      assert_not_equal "paid", @invoice.reload.state

      drain_approval_outbox!

      assert_equal "paid", @invoice.reload.state
    end

    test "approve_approval_and_settle! does both" do
      approve_approval_and_settle!(@invoice)

      assert_equal "paid", @invoice.reload.state
    end

    test "raises a useful error when there is nothing to act on" do
      other = Invoice.create!(tenant_id: TENANT, amount: 1, department: "IT")

      assert_raises(ArgumentError) { approve_approval!(other) }
      assert_raises(ArgumentError) { reject_approval!(other) }
    end
  end
end
