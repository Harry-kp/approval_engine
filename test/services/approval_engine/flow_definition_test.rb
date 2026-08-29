require "test_helper"

module ApprovalEngine
  class FlowDefinitionTest < ApprovalEngine::TestCase
    FLOW = "High-value invoice".freeze

    setup do
      @invoice = Invoice.create!(tenant_id: TENANT, amount: 20_000, department: "IT")
      create_user(role: :manager)
      create_user(role: :cfo)
    end

    def define_two_step_flow(name: FLOW)
      ApprovalEngine.define_flow(name, tenant: TENANT, model: Invoice) do
        on :create, when: { amount: { gt: 10_000 } }
        step "Manager", group: "manager"
        step "CFO",     group: "cfo"
      end
    end

    def route!(target = @invoice)
      target.run_approval!(event: "invoice.created", tenant_id: TENANT)
    end

    def row_counts
      [ -> { TrackTemplate.count }, -> { TemplateStep.count }, -> { TriggerRule.count } ]
    end

    # --- shape -----------------------------------------------------------

    test "builds the template, its steps and its rule in one block" do
      template = define_two_step_flow

      assert_equal 1, TrackTemplate.count
      assert_equal "active", template.status
      assert_equal [ [ "Manager", 1 ], [ "CFO", 2 ] ], template.template_steps.pluck(:name, :layer)
      assert_equal "invoice.created", template.trigger_rules.sole.event_name
    end

    test "sequential steps get incrementing layers" do
      create_user(role: :ceo)

      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
        step "Manager", group: "manager"
        step "CFO",     group: "cfo"
        step "CEO",     group: "ceo"
      end

      assert_equal [ 1, 2, 3 ], template.template_steps.pluck(:layer)
    end

    test "a parallel block puts its steps on one layer" do
      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
        parallel do
          step "Legal", group: "legal"
          step "IT",    group: "it"
        end
        step "CEO", group: "ceo"
      end

      assert_equal [ 1, 1, 2 ], template.template_steps.pluck(:layer)
      assert_equal 2, template.template_steps.where(layer: 1).count
    end

    test "a parallel block's consensus is stamped on every step in the layer" do
      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
        parallel(approvals_required: :all) do
          step "Legal", group: "legal"
          step "IT",    group: "it"
        end
      end

      # The engine reads one spec per layer, so both rows have to carry it —
      # whichever one Track#tally_for happens to read must say the same thing.
      assert_equal %w[all all], template.template_steps.where(layer: 1).pluck(:approvals_required)
    end

    test "a parallel block defaults to needing every reviewer in the layer" do
      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
        parallel do
          step "Legal", group: "legal"
          step "IT",    group: "it"
        end
      end

      assert_equal %w[all all], template.template_steps.pluck(:approvals_required)
    end

    test "steps default to the engine's any consensus" do
      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT) { step "Manager", group: "manager" }

      assert_equal "any", template.template_steps.sole.approvals_required
    end

    test "a consensus count is stored as the string the ledger expects" do
      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
        step "Board", group: "manager", approvals_required: 2
      end

      assert_equal "2", template.template_steps.sole.approvals_required
    end

    test "timeout_after accepts a duration and a flow-wide default" do
      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT, timeout_after: 1.day) do
        step "Manager", group: "manager"
        step "CFO",     group: "cfo", timeout_after: 2.days
      end

      assert_equal 86_400, template.template_steps.find_by(name: "Manager").timeout_after
      assert_equal 172_800, template.template_steps.find_by(name: "CFO").timeout_after
    end

    test "defaults the template to active so the flow actually fires" do
      assert_equal "active", define_two_step_flow.status

      draft = ApprovalEngine.define_flow("Draft flow", tenant: TENANT, status: "draft") do
        step "Manager", group: "manager"
      end

      assert_equal "draft", draft.status
    end

    test "on(:create) uses the model's conventional event name" do
      template = define_two_step_flow

      assert_equal Invoice.approval_event_name(:create), template.trigger_rules.sole.event_name
    end

    test "on without when: routes the event unconditionally" do
      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        on :create
        step "Manager", group: "manager"
      end

      assert_equal({ "==" => [ 1, 1 ] }, template.trigger_rules.sole.condition)
      assert_not_nil route!, "the tautology has to survive TriggerRule's presence validation and evaluate true"
    end

    # --- when: sugar all the way through to a real route -----------------

    test "the when: sugar compiles to JSON Logic the evaluator matches" do
      define_two_step_flow

      approval = route!

      assert_equal "pending", approval.status
      assert_equal %w[Manager CFO], approval.steps.order(:layer).pluck(:name)
      assert_equal 1, approval.steps.pending.count
      assert_equal 1, approval.steps.waiting.count
    end

    test "a numeric when: value stays numeric" do
      define_two_step_flow

      assert_equal({ ">" => [ { "var" => "amount" }, 10_000.0 ] }, TriggerRule.sole.condition)

      small = Invoice.create!(tenant_id: TENANT, amount: 100, department: "IT")
      assert_nil route!(small), "a string-cast threshold would compare \"100\" > \"10000.0\" and match"
    end

    test "raw JSON Logic passes through untouched" do
      raw = { "or" => [ { ">" => [ { "var" => "amount" }, 10_000 ] }, { "==" => [ { "var" => "department" }, "IT" ] } ] }

      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        on "invoice.created", when: raw
        step "Manager", group: "manager"
      end

      assert_equal raw, template.trigger_rules.sole.condition
    end

    test "an in: list compiles to the shape the cookbook documents" do
      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        on "invoice.created", when: { department: { in: %w[Legal Finance] } }
        step "Manager", group: "manager"
      end

      assert_equal({ "in" => [ { "var" => "department" }, %w[Legal Finance] ] }, template.trigger_rules.sole.condition)
    end

    # --- idempotency -----------------------------------------------------

    test "re-running the same flow changes nothing" do
      template = define_two_step_flow
      touched = template.template_steps.pluck(:updated_at) << template.updated_at

      assert_no_difference row_counts do
        define_two_step_flow
      end

      assert_equal touched, template.reload.template_steps.pluck(:updated_at) << template.updated_at,
                   "an update! over unchanged attributes must not even touch updated_at"
    end

    test "re-running keeps step ids so admin links survive" do
      before = define_two_step_flow.template_steps.order(:layer).pluck(:id)

      after = define_two_step_flow.template_steps.order(:layer).pluck(:id)

      assert_equal before, after
    end

    test "a changed group is updated in place" do
      step_id = define_two_step_flow.template_steps.find_by(name: "Manager").id

      ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        step "Manager", group: "director"
        step "CFO",     group: "cfo"
      end

      manager = TemplateStep.find(step_id)
      assert_equal "director", manager.assigned_group
    end

    test "a removed step is deleted" do
      define_two_step_flow

      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        step "Manager", group: "manager"
      end

      assert_equal [ "Manager" ], template.template_steps.pluck(:name)
      assert_equal 1, TemplateStep.count
    end

    test "a changed condition is updated, not duplicated" do
      define_two_step_flow

      ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        on :create, when: { amount: { gt: 50_000 } }
        step "Manager", group: "manager"
      end

      assert_equal 1, TriggerRule.count
      assert_equal({ ">" => [ { "var" => "amount" }, 50_000.0 ] }, TriggerRule.sole.condition)
    end

    test "a removed on deactivates the rule instead of destroying it, so provenance survives" do
      define_two_step_flow
      approval = route!
      rule = approval.trigger_rule

      # The block still declares routing, so dropping this event really means
      # "retire that rule" — a block with no `on` at all means something else
      # entirely (the admin owns routing) and is asserted separately below.
      ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        on :update, when: { amount: { gt: 10_000 } }
        step "Manager", group: "manager"
      end

      assert_not rule.reload.active?
      assert_equal rule, approval.reload.trigger_rule, "the approval still knows which rule routed it"
      assert_nil route!(Invoice.create!(tenant_id: TENANT, amount: 30_000, department: "IT")),
                 "a deactivated rule routes nothing new"
    end

    test "a block with no on leaves existing rules alone" do
      define_two_step_flow
      rule = TriggerRule.sole

      ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        step "Manager", group: "manager"
      end

      assert rule.reload.active?
      assert_equal 1, TriggerRule.count
    end

    test "raises when two templates already share the tenant and name" do
      first  = TrackTemplate.create!(tenant_id: TENANT, name: FLOW, status: "active")
      second = TrackTemplate.create!(tenant_id: TENANT, name: FLOW, status: "active")

      error = assert_raises(FlowDefinition::DefinitionError) { define_two_step_flow }

      assert_includes error.message, first.id
      assert_includes error.message, second.id
    end

    test "an admin's archive is re-asserted back to the declared status" do
      template = define_two_step_flow
      template.update!(status: "archived")

      assert_equal "active", define_two_step_flow.status
    end

    # --- in-flight approvals ---------------------------------------------

    test "rewriting a flow leaves an approval already in flight untouched" do
      define_two_step_flow
      approval = route!

      ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        on :create, when: { amount: { gt: 10_000 } }
        step "Director", group: "director"
      end

      assert_equal %w[Manager CFO], approval.reload.steps.order(:layer).pluck(:name)

      approval.steps.pending.sole.approve!(by: User.find_by(role: "manager"))

      assert_equal "pending", approval.steps.find_by(name: "CFO").reload.status
    end

    test "requesting changes after a rewrite replays the ledger, not the new template" do
      define_two_step_flow
      approval = route!

      ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        on :create, when: { amount: { gt: 10_000 } }
        step "Director", group: "director"
      end
      approval.steps.pending.sole.request_changes!(by: User.find_by(role: "manager"))

      second = approval.reload.steps.for_iteration(2).order(:layer)
      assert_equal %w[Manager CFO], second.pluck(:name),
                   "IterationBuilder clones from track.steps, so a rework replays the audited steps"
    end

    test "a step removed from a flow doesn't strand a running approval" do
      define_two_step_flow
      approval = route!

      ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        on :create, when: { amount: { gt: 10_000 } }
        step "CFO", group: "cfo"
      end

      approval.steps.pending.sole.approve!(by: User.find_by(role: "manager"))
      approval.reload.steps.pending.sole.approve!(by: User.find_by(role: "cfo"))

      assert_equal "approved", approval.reload.status
    end

    # --- validation ------------------------------------------------------

    test "raises when a flow declares no steps" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) { on "invoice.created" }
      end

      assert_includes error.message, "sit pending forever"
    end

    test "raises on a duplicate step name" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
          step "Manager", group: "manager"
          step "Manager", group: "cfo"
        end
      end

      assert_includes error.message, "declares two steps named \"Manager\""
    end

    test "raises on an invalid consensus spec" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
          step "Board", group: "manager", approvals_required: "two"
        end
      end

      assert_includes error.message, "step \"Board\" has approvals_required \"two\""
      assert error.message.end_with?("must be :any, :all, :majority, a percentage like \"60%\", or a positive integer.")
    end

    test "raises when a step inside a parallel block sets its own approvals_required" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
          parallel do
            step "Legal", group: "legal", approvals_required: 2
          end
        end
      end

      assert_includes error.message, "Every step in a layer shares one consensus policy"
    end

    test "raises on a nested parallel block" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
          parallel do
            parallel { step "Legal", group: "legal" }
          end
        end
      end

      assert_equal "parallel blocks can't be nested.", error.message
    end

    test "raises on a parallel block with no steps" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) { parallel { } }
      end

      assert_includes error.message, "declares no steps"
    end

    test "raises when a rule reads an attribute the model doesn't expose" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
          on :create, when: { total: { gt: 1 } }
          step "Manager", group: "manager"
        end
      end

      assert_includes error.message, "reads total"
      assert_includes error.message, "it exposes amount, department"
    end

    test "finds an unexposed attribute nested inside raw JSON Logic too" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
          on "invoice.created", when: { "or" => [ { ">" => [ { "var" => "amount" }, 1 ] },
                                                  { "==" => [ { "var" => "totl" }, "IT" ] } ] }
          step "Manager", group: "manager"
        end
      end

      assert_includes error.message, "reads totl"
    end

    test "skips the exposure check when no model is given" do
      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
        on "invoice.created", when: { total: { gt: 1 } }
        step "Manager", group: "manager"
      end

      assert_equal({ ">" => [ { "var" => "total" }, 1 ] }, template.trigger_rules.sole.condition)
    end

    test "raises on an unknown group when config.approval_groups is set" do
      ApprovalEngine.configure { |c| c.approval_groups = %w[manager cfo] }

      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) { step "Manager", group: "managr" }
      end

      assert_includes error.message, "isn't in config.approval_groups (manager, cfo)"
    end

    test "allows any group when config.approval_groups is nil" do
      assert_nil ApprovalEngine.config.approval_groups

      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT) { step "Manager", group: "whatever" }

      assert_equal "whatever", template.template_steps.sole.assigned_group
    end

    test "raises when a step has no group" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) { step "Manager", group: "" }
      end

      assert_includes error.message, "needs a group:"
    end

    test "raises when the actor class can't resolve approval groups" do
      ApprovalEngine.configure { |c| c.actor_class = "Invoice" }

      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) { step "Manager", group: "manager" }
      end

      assert_equal "Invoice must define `self.resolve_approval_group(group_name, target)`.", error.message
    end

    test "raises when the actor class doesn't resolve to a loaded class" do
      ApprovalEngine.configure { |c| c.actor_class = "NoSuchActor" }

      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) { step "Manager", group: "manager" }
      end

      assert_includes error.message, "which doesn't resolve to a loaded class"
    end

    test "raises when no tenant can be resolved" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW) { step "Manager", group: "manager" }
      end

      assert_equal "define_flow needs a tenant: — pass one, or set config.current_tenant_method.", error.message
    end

    test "falls back to the configured current tenant" do
      ApprovalEngine.configure { |c| c.current_tenant_method = -> { TENANT } }

      template = ApprovalEngine.define_flow(FLOW) { step "Manager", group: "manager" }

      assert_equal TENANT, template.tenant_id
    end

    test "raises on an unknown on option" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
          on "invoice.created", condition: {}
          step "Manager", group: "manager"
        end
      end

      assert_equal "on: unknown option(s) [:condition]. It takes when:, priority: and active:.", error.message
    end

    test "raises when on(:create) is used without model:" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
          on :create
          step "Manager", group: "manager"
        end
      end

      assert_includes error.message, "needs the model: option"
    end

    test "raises when model: hasn't called has_approvals" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: User) { step "Manager", group: "manager" }
      end

      assert_includes error.message, "hasn't called has_approvals"
    end

    test "raises on a duplicate event and priority pair" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
          on :create, when: { amount: { gt: 1 } }
          on :create, when: { amount: { gt: 2 } }
          step "Manager", group: "manager"
        end
      end

      assert_includes error.message, "declares two rules for \"invoice.created\" at priority 0"
    end

    test "two rules on the same event are fine at different priorities" do
      template = ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice) do
        on :create, when: { amount: { gt: 100_000 } }, priority: 10
        on :create, when: { amount: { gt: 10_000 } }
        step "Manager", group: "manager"
      end

      assert_equal [ 10, 0 ], template.trigger_rules.by_priority.pluck(:priority)
    end

    test "raises on a non-positive timeout_after" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT, timeout_after: 0) { step "Manager", group: "manager" }
      end

      assert_includes error.message, "must be a positive number of seconds"

      assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) { step "Manager", group: "manager", timeout_after: -1 }
      end
    end

    test "raises on a malformed when: with one error class" do
      error = assert_raises(FlowDefinition::DefinitionError) do
        ApprovalEngine.define_flow(FLOW, tenant: TENANT) do
          on "invoice.created", when: { amount: { bigger_than: 1 } }
          step "Manager", group: "manager"
        end
      end

      assert_includes error.message, "the when: for \"invoice.created\" is invalid"
    end

    test "nothing is written when a validation fails" do
      assert_no_difference row_counts do
        assert_raises(FlowDefinition::DefinitionError) do
          ApprovalEngine.define_flow(FLOW, tenant: TENANT) { step "Manager", group: "" }
        end
      end
    end

    test "a failed redefine rolls back everything it had already rewritten" do
      template = define_two_step_flow
      before = template.template_steps.pluck(:name, :layer, :assigned_group).sort

      # A blank event name is caught by TriggerRule's own presence validation,
      # i.e. after the template's status and both of its steps have already been
      # rewritten — which is the case that proves the reconcile is one transaction
      # rather than three independent writes.
      assert_no_difference row_counts do
        assert_raises(ActiveRecord::RecordInvalid) do
          ApprovalEngine.define_flow(FLOW, tenant: TENANT, model: Invoice, status: "archived") do
            on ""
            step "Director", group: "manager"
          end
        end
      end

      assert_equal "active", template.reload.status
      assert_equal before, template.template_steps.pluck(:name, :layer, :assigned_group).sort
    end

    # --- return value ----------------------------------------------------

    test "returns the template so it can be handed to run_approval!(templates:)" do
      template = define_two_step_flow

      assert_instance_of TrackTemplate, template

      approval = @invoice.run_approval!(templates: [ template ])

      assert_equal 1, approval.tracks.count
      assert_equal %w[Manager CFO], approval.steps.order(:layer).pluck(:name)
    end

    test "ApprovalEngine.flow looks a defined flow up by name" do
      template = define_two_step_flow

      assert_equal template, ApprovalEngine.flow(FLOW, tenant: TENANT)
      assert_nil ApprovalEngine.flow("Nothing defined", tenant: TENANT)
    end
  end
end
