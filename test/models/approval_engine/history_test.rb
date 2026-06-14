require "test_helper"

module ApprovalEngine
  class HistoryTest < ApprovalEngine::TestCase
    setup do
      @invoice = Invoice.create!(tenant_id: TENANT, amount: 6000, department: "IT")
      @manager = create_user(role: :manager)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })
      @invoice.run_approval!(event: "invoice.created", tenant_id: TENANT)
    end

    test "empty? is true for a record with no approvals" do
      assert Invoice.create!(tenant_id: TENANT, amount: 1).approval_history.empty?
    end

    test "approvals lists the record's approvals, newest first" do
      history = @invoice.approval_history

      assert_equal 1, history.approvals.size
      assert_equal @invoice.approvals.first, history.latest
    end

    test "events is N+1-free: a large history stays under a fixed query budget" do
      invoice = Invoice.create!(tenant_id: TENANT, amount: 6000)
      build_history(invoice, actions: 8)

      # Fully consume the timeline (touching preloaded actors + step) — 8 events
      # must NOT cost ~8 queries. The whole thing is a fixed handful of preloads.
      queries = count_queries do
        invoice.approval_history.events.each { |e| [ e.actual_actor&.name, e.step.name, e.comment ] }
      end

      assert_operator queries, :<=, 6, "8 events resolved in #{queries} queries — that's an N+1"
    end

    test "events is a chronological timeline of actions, with actors and comments" do
      Step.pending.first.request_changes!(by: @manager, comment: "Fix the totals")
      Step.where(iteration: 2).first.approve!(by: @manager, comment: "Looks good now")

      events = @invoice.approval_history.events

      assert_equal %w[changes_requested approved], events.map(&:event)
      assert_equal [ "Fix the totals", "Looks good now" ], events.map(&:comment)
      assert_equal [ @manager, @manager ], events.map(&:actual_actor)
      assert_equal events, events.sort_by(&:created_at), "ordered oldest first"
    end

    private

    # Build `actions` recorded events for an invoice without running the full flow.
    def build_history(invoice, actions:)
      approval = Approval.create!(tenant_id: TENANT, target: invoice, status: "pending")
      track = Track.create!(tenant_id: TENANT, approval: approval, name: "W")
      actions.times do |i|
        step = track.steps.create!(tenant_id: TENANT, layer: i + 1, status: "approved", assigned_actor: @manager)
        step.audit_logs.create!(tenant_id: TENANT, event: "approved",
                                intended_actor: @manager, actual_actor: @manager, comment: "ok #{i}")
      end
    end
  end
end
