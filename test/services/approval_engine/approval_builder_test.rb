require "test_helper"

module ApprovalEngine
  class ApprovalBuilderTest < ApprovalEngine::TestCase
    setup { @invoice = Invoice.create!(tenant_id: TENANT, amount: 6000) }

    test "expands each group into one step per actor and activates only layer 1" do
      2.times { |i| create_user(role: :manager, name: "M#{i}") }
      create_user(role: :cfo)
      template = create_template(steps: [
        { name: "Managers", layer: 1, group: "manager", approvals_required: :all },
        { name: "CFO", layer: 2, group: "cfo" }
      ])

      approval = ApprovalBuilder.build!(template: template, target: @invoice)
      steps = approval.steps

      assert_equal 3, steps.count
      assert_equal 2, steps.where(layer: 1, status: "pending").count
      assert_equal 1, steps.where(layer: 2, status: "waiting").count
      assert_equal "all", steps.where(layer: 1).first.approvals_required
    end

    test "carries the consensus spec onto the concrete steps" do
      3.times { |i| create_user(role: :board, name: "B#{i}") }
      template = create_template(steps: [ { group: "board", approvals_required: 2 } ])

      approval = ApprovalBuilder.build!(template: template, target: @invoice)

      assert_equal [ "2" ], approval.steps.pluck(:approvals_required).uniq
    end

    test "records the event passed in (the fired event), since templates are event-agnostic" do
      create_user(role: :manager)
      template = create_template(steps: [ { group: "manager" } ])

      approval = ApprovalBuilder.build!(template: template, target: @invoice, event_name: "invoice.updated")

      assert_equal "invoice.updated", approval.event_name
    end

    test "a manually built approval (no event) records no event" do
      create_user(role: :manager)
      template = create_template(steps: [ { group: "manager" } ])

      approval = ApprovalBuilder.build!(template: template, target: @invoice)

      assert_nil approval.event_name
    end

    test "build! records the matched rule as provenance when given one" do
      create_user(role: :manager)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      rule = create_rule(template: template, condition: { "==" => [ 1, 1 ] })

      approval = ApprovalBuilder.build!(template: template, target: @invoice, trigger_rule: rule)

      assert_equal rule, approval.trigger_rule
    end

    test "build_parallel! records no rule provenance (no single rule routes it)" do
      create_user(role: :legal)
      legal = create_template(event: "invoice.created", name: "Legal", steps: [ { group: "legal" } ])

      approval = ApprovalBuilder.build_parallel!(templates: [ legal ], target: @invoice)

      assert_nil approval.trigger_rule
    end

    test "build_parallel! creates one track per template under a single approval" do
      create_user(role: :legal)
      create_user(role: :it)
      legal = create_template(event: "invoice.created", name: "Legal", steps: [ { group: "legal" } ])
      it = create_template(event: "invoice.created", name: "IT", steps: [ { group: "it" } ])

      approval = ApprovalBuilder.build_parallel!(templates: [ legal, it ], target: @invoice)

      assert_equal %w[IT Legal], approval.tracks.pluck(:name).sort
      assert_equal 2, approval.steps.pending.count
    end

    test "build_parallel! rejects an empty template list" do
      assert_raises(ApprovalBuilder::BuilderError) do
        ApprovalBuilder.build_parallel!(templates: [], target: @invoice)
      end
    end

    test "raises when the required count exceeds the resolved group (would never resolve)" do
      2.times { |i| create_user(role: :board, name: "B#{i}") }
      template = create_template(event: "invoice.created",
                                 steps: [ { group: "board", approvals_required: 3 } ])

      error = assert_raises(ApprovalBuilder::BuilderError) { ApprovalBuilder.build!(template: template, target: @invoice) }
      assert_match(/never resolve/, error.message)
    end

    test "raises a clear, actionable error when actor_class is misconfigured" do
      ApprovalEngine.config.actor_class = "NoSuchActorClass"
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])

      error = assert_raises(ApprovalBuilder::BuilderError) { ApprovalBuilder.build!(template: template, target: @invoice) }
      assert_match(/actor_class is "NoSuchActorClass"/, error.message)
    end

    test "raises when a group resolves to no actors" do
      template = create_template(event: "invoice.created", steps: [ { group: "nobody" } ])

      assert_raises(ApprovalBuilder::BuilderError) { ApprovalBuilder.build!(template: template, target: @invoice) }
    end

    test "raises when the actor class does not implement the resolver" do
      ApprovalEngine.config.actor_class = "Invoice" # does not define resolve_approval_group
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])

      assert_raises(ApprovalBuilder::BuilderError) { ApprovalBuilder.build!(template: template, target: @invoice) }
    end

    test "quarantine approval records the failure reason on the outbox" do
      approval = ApprovalBuilder.build_quarantine_approval!(
        target: @invoice, tenant_id: TENANT, reason: "boom"
      )

      assert_equal "quarantined", approval.status
      assert_equal "boom", OutboxEvent.last.error_payload
    end
  end
end
