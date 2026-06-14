require "test_helper"

module ApprovalEngine
  class RuleEvaluatorTest < ApprovalEngine::TestCase
    setup do
      @target = Invoice.create!(tenant_id: TENANT, amount: 6000, department: "IT")
      create_user(role: :manager)
      @template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
    end

    def evaluate(payload)
      RuleEvaluator.call(event_name: "invoice.created", tenant_id: TENANT, target: @target, payload: payload)
    end

    test "spawns the matching template's approval on a match" do
      create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 5000 ] })

      approval = nil
      assert_difference -> { Approval.count } => 1 do
        approval = evaluate("amount" => 6000)
      end
      assert_equal "pending", approval.status
    end

    test "returns nil and builds nothing when no rule matches" do
      create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 5000 ] })

      assert_no_difference -> { Approval.count } do
        assert_nil evaluate("amount" => 100)
      end
    end

    test "highest priority rule wins" do
      low = create_template(event: "invoice.created", name: "Low", steps: [ { group: "manager" } ])
      create_rule(template: low, condition: { ">" => [ { "var" => "amount" }, 0 ] }, priority: 1)
      create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 0 ] }, priority: 10)

      approval = evaluate("amount" => 6000)
      assert_equal "Flow", approval.tracks.first.name, "the priority-10 template was chosen"
    end

    test "fails closed: a broken rule quarantines instead of crashing" do
      create_rule(template: @template, condition: { "bogus_operator" => [ 1, 2 ] })

      assert_difference -> { Approval.quarantined.count } => 1 do
        approval = evaluate("amount" => 6000)
        assert_equal "quarantined", approval.status
      end
      assert_equal "approval.quarantined", OutboxEvent.last.event_name
    end

    test "UC6 tenant isolation: another tenant's rules never fire" do
      other = create_template(event: "invoice.created", tenant: "tenant-2", steps: [ { group: "manager" } ])
      create_rule(template: other, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      assert_no_difference -> { Approval.count } do
        assert_nil evaluate("amount" => 9999) # evaluated for TENANT, not tenant-2
      end
    end

    test "raises loudly when raise_on_rule_errors is enabled" do
      ApprovalEngine.config.raise_on_rule_errors = true
      create_rule(template: @template, condition: { "bogus_operator" => [ 1, 2 ] })

      assert_raises(RuleEvaluator::EvaluationError) { evaluate("amount" => 6000) }
    end

    def preview(payload)
      RuleEvaluator.preview(event_name: "invoice.created", tenant_id: TENANT, target: @target, payload: payload)
    end

    test "preview reports the matched plan and resolved actors, building nothing" do
      create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 5000 ] })

      plan = nil
      assert_no_difference -> { Approval.count } do
        plan = preview("amount" => 6000)
      end

      assert plan.triggered?
      assert_equal @template, plan.template
      assert_equal "manager", plan.steps.first.assigned_group
      assert_equal [ "Manager" ], plan.actors_for(plan.steps.first).map(&:name)
    end

    test "preview reports no approval required when nothing matches" do
      create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 5000 ] })

      plan = preview("amount" => 100)

      assert plan.no_approval_required?
      assert_empty plan.steps
    end

    test "preview surfaces a broken rule as an error and never quarantines or raises" do
      ApprovalEngine.config.raise_on_rule_errors = true # preview must still not raise
      create_rule(template: @template, condition: { "bogus_operator" => [ 1, 2 ] })

      plan = nil
      assert_no_difference -> { Approval.count } do
        plan = preview("amount" => 6000)
      end

      assert plan.error?
      assert_match(/evaluation failed/, plan.reason)
    end

    def candidates(payload)
      RuleEvaluator.candidates(event_name: "invoice.created", tenant_id: TENANT, target: @target, payload: payload)
    end

    test "candidates returns every matching template in priority order, not just the top" do
      high = create_template(event: "invoice.created", name: "High", steps: [ { group: "manager" } ])
      create_rule(template: high, condition: { ">" => [ { "var" => "amount" }, 0 ] }, priority: 10)
      low = create_template(event: "invoice.created", name: "Low", steps: [ { group: "manager" } ])
      create_rule(template: low, condition: { ">" => [ { "var" => "amount" }, 0 ] }, priority: 1)

      plans = candidates("amount" => 5000)

      assert_equal [ "High", "Low" ], plans.map { |p| p.template.name }
      assert(plans.all?(&:triggered?))
    end

    test "candidates skips rules that do not match or are malformed" do
      create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 9999 ] }) # won't match
      broken = create_template(event: "invoice.created", name: "Broken", steps: [ { group: "manager" } ])
      create_rule(template: broken, condition: { "bogus_operator" => [ 1, 2 ] }) # errors → skipped

      assert_empty candidates("amount" => 100)
    end
  end
end
