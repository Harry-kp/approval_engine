require "test_helper"

module ApprovalEngine
  # Acceptance layer: end-to-end coverage of the public API through a real host
  # model (Invoice). Each test maps to a documented use case in
  # docs/ARCHITECTURE.md so the suite reads as living documentation.
  #
  #   UC1  Standard approval ............. single approval completes the approval
  #   UC2  Hard reject .................... hard reject tears the approval down
  #   UC3  Rework cycle .................. requesting changes appends a fresh iteration
  #   UC4  Conditional routing ........... matching rule builds an approval
  #   UC5  Anti-corruption payload ....... ApprovalExposureTest (unit)
  #   UC6  Multi-tenant isolation ........ RuleEvaluatorTest#tenant isolation
  #   UC7  Delegation .................... StepTest / DelegationTest
  #   UC8  Scatter-gather parallelism .... parallel tracks gather into one approval
  #   UC9  Consensus any ................. any consensus cancels siblings
  #   UC10 Consensus all ................. all consensus needs every approver
  #   UC11 Inter-department chaining ..... host callback fires (after_approved)
  #   UC12 Async safety .................. ProcessOutboxJobTest (records + re-raises)
  #   UC13 Strict auditing ............... StepTest (intended vs actual)
  #   UC14 Graceful rule failure ......... RuleEvaluatorTest#fails closed
  #   UC15 Queue agnosticism ............. ProcessOutboxJob queue_as config
  #   UC16 View flexibility .............. ViewsGeneratorTest
  #   UC17 Admin monitoring .............. ApprovalsControllerTest
  class ApprovalFlowTest < ApprovalEngine::TestCase
    setup do
      @invoice = Invoice.create!(tenant_id: TENANT, amount: 6000, department: "IT")
    end

    def route!(event: "invoice.created")
      @invoice.run_approval!(event: event, tenant_id: TENANT)
    end

    def drain_outbox!
      OutboxEvent.unprocessed.order(:created_at).each { |e| ProcessOutboxJob.perform_now(e.id) }
    end

    def pending_step_for(role)
      Step.pending.joins(:track).where(approval_engine_tracks: { tenant_id: TENANT })
          .where(assigned_actor: User.find_by(role: role.to_s)).first
    end

    test "matching rule builds an approval; non-matching builds nothing" do
      create_user(role: :manager)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 5000 ] })

      assert_difference -> { Approval.count } => 1 do
        approval = route!
        assert_equal "pending", approval.status
      end

      @invoice.update!(amount: 100)
      assert_no_difference -> { Approval.count } do
        assert_nil route!
      end
    end

    test "single approval completes the approval and fires the host callback" do
      create_user(role: :manager)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 5000 ] })

      route!
      pending_step_for(:manager).approve!(by: User.find_by(role: "manager"))

      assert_equal "approved", @invoice.approvals.first.status
      assert_equal "submitted", @invoice.reload.state, "callback is deferred to the outbox"

      drain_outbox!
      assert_equal "paid", @invoice.reload.state
    end

    test "approval_event_name gives the typo-proof conventional name (and rejects unknown lifecycles)" do
      assert_equal "invoice.created", Invoice.approval_event_name(:create)
      assert_equal "invoice.updated", Invoice.approval_event_name(:update)
      assert_raises(KeyError) { Invoice.approval_event_name(:generated) }
    end

    test "an approval can be triggered by any transition, not just creation" do
      create_user(role: :manager)
      template = create_template(event: "invoice.rejected", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { "==" => [ { "var" => "department" }, "IT" ] })

      # e.g. called from the host's own reject! / state-machine transition hook
      approval = @invoice.run_approval!(event: "invoice.rejected", tenant_id: TENANT)

      assert_equal "pending", approval.status
      assert_equal "invoice.rejected", approval.event_name
    end

    test "user manually triggers a chosen track instead of priority auto-routing" do
      create_user(role: :manager)
      finance = create_template(event: "invoice.created", name: "Finance", steps: [ { group: "manager" } ])
      create_rule(template: finance, condition: { ">" => [ { "var" => "amount" }, 0 ] }, priority: 1)
      compliance = create_template(event: "invoice.created", name: "Compliance", steps: [ { group: "manager" } ])
      create_rule(template: compliance, condition: { ">" => [ { "var" => "amount" }, 0 ] }, priority: 5)

      candidates = @invoice.approval_candidates(event: "invoice.created", tenant_id: TENANT)
      assert_equal [ "Compliance", "Finance" ], candidates.map { |p| p.template.name }

      # Priority would auto-pick Compliance; the user deliberately picks Finance.
      chosen = candidates.find { |p| p.template.name == "Finance" }.template
      approval = @invoice.run_approval!(templates: chosen)

      assert_equal [ "Finance" ], approval.tracks.pluck(:name)
    end

    test "user manually triggers several matching tracks as parallel tracks" do
      create_user(role: :manager)
      legal = create_template(event: "invoice.created", name: "Legal", steps: [ { group: "manager" } ])
      create_rule(template: legal, condition: { ">" => [ { "var" => "amount" }, 0 ] })
      it = create_template(event: "invoice.created", name: "IT", steps: [ { group: "manager" } ])
      create_rule(template: it, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      chosen = @invoice.approval_candidates(event: "invoice.created", tenant_id: TENANT).map(&:template)
      approval = @invoice.run_approval!(templates: chosen)

      assert_equal 2, approval.tracks.count
    end

    test "rejecting one track tears down the whole scatter-gather approval" do
      legal = create_user(role: :legal)
      create_user(role: :it)
      legal_tpl = create_template(event: "invoice.created", name: "Legal", steps: [ { group: "legal" } ])
      it_tpl = create_template(event: "invoice.created", name: "IT", steps: [ { group: "it" } ])

      approval = ApprovalBuilder.build_parallel!(templates: [ legal_tpl, it_tpl ], target: @invoice)
      approval.steps.where(assigned_actor: legal).first.reject!(by: legal)

      approval = Approval.find(approval.id)
      assert_equal "rejected", approval.status
      assert_equal 1, approval.steps.where(status: "cancelled").count, "the IT track's open step is cancelled"
    end

    test "non-contiguous layers activate the next existing layer, not layer+1" do
      create_user(role: :manager)
      create_user(role: :cfo)
      template = create_template(event: "invoice.created", steps: [
        { name: "Manager", layer: 1, group: "manager" },
        { name: "CFO", layer: 3, group: "cfo" } # gap: no layer 2
      ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      route!
      pending_step_for(:manager).approve!(by: User.find_by(role: "manager"))

      assert_equal "pending", Approval.first.status, "must NOT complete prematurely over the gap"
      assert_not_nil pending_step_for(:cfo), "layer 3 is activated despite the missing layer 2"
    end

    test "all-consensus stays satisfiable when a sibling step is cancelled" do
      directors = Array.new(2) { |i| create_user(role: :director, name: "D#{i}") }
      approval = Approval.create!(tenant_id: TENANT, target: @invoice, status: "pending")
      track = Track.create!(tenant_id: TENANT, approval: approval, name: "Board")
      keep = track.steps.create!(tenant_id: TENANT, layer: 1, status: "pending", approvals_required: "all", assigned_actor: directors.first)
      drop = track.steps.create!(tenant_id: TENANT, layer: 1, status: "pending", approvals_required: "all", assigned_actor: directors.last)

      drop.update!(status: "cancelled") # a peer is cancelled out of the 'all' layer
      keep.approve!(by: directors.first)

      assert_equal "approved", Approval.find(approval.id).status, "'all' resolves on the remaining (non-cancelled) steps"
    end

    test "a terminal approval ignores further transitions" do
      create_user(role: :manager)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })
      route!
      pending_step_for(:manager).approve!(by: User.find_by(role: "manager"))
      approval = Approval.first
      assert_equal "approved", approval.status

      assert_no_difference -> { OutboxEvent.count } do
        approval.send(:fail_gather!, reason: "too late") # internal teardown; guarded by terminal?
      end
      assert_equal "approved", approval.reload.status, "already-approved approval is not re-rejected"
    end

    test "preview shows what an action would trigger — even on an unsaved change" do
      create_user(role: :manager)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 5000 ] })

      @invoice.amount = 100
      assert @invoice.preview_approval(event: "invoice.created", tenant_id: TENANT).no_approval_required?

      @invoice.amount = 9000 # not saved
      plan = @invoice.preview_approval(event: "invoice.created", tenant_id: TENANT)

      assert plan.triggered?
      assert_equal "Flow", plan.template.name
      assert_equal [ "Manager" ], plan.actors_for(plan.steps.first).map(&:name)
    end

    test "single-track convenience readers read the lone track and step" do
      create_user(role: :manager)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      approval = route!

      assert_equal "Flow", approval.track.name
      assert_equal "manager", approval.step.assigned_actor.role
    end

    test "any consensus: one approval cancels the sibling steps" do
      3.times { |i| create_user(role: :reviewer, name: "Reviewer #{i}") }
      template = create_template(event: "invoice.created", steps: [ { group: "reviewer", approvals_required: :any } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      route!
      Step.pending.first.approve!(by: User.where(role: "reviewer").first)

      approval = Approval.first
      assert_equal "approved", approval.status
      assert_equal 1, approval.steps.approved.count
      assert_equal 2, approval.steps.where(status: "cancelled").count
    end

    test "all consensus: every approver must approve" do
      2.times { |i| create_user(role: :director, name: "Director #{i}") }
      template = create_template(event: "invoice.created", steps: [ { group: "director", approvals_required: :all } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      route!
      directors = User.where(role: "director").to_a
      Step.pending.where(assigned_actor: directors.first).first.approve!(by: directors.first)
      assert_equal "pending", Approval.first.status, "not done until all approve"

      Step.pending.where(assigned_actor: directors.last).first.approve!(by: directors.last)
      assert_equal "approved", Approval.first.status
    end

    test "counted consensus: a fixed number of approvals resolves the layer" do
      3.times { |i| create_user(role: :board, name: "Member #{i}") }
      template = create_template(event: "invoice.created",
                                 steps: [ { group: "board", approvals_required: 2 } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      route!
      members = User.where(role: "board").to_a
      Step.pending.where(assigned_actor: members[0]).first.approve!(by: members[0])
      assert_equal "pending", Approval.first.status

      Step.pending.where(assigned_actor: members[1]).first.approve!(by: members[1])
      assert_equal "approved", Approval.first.status
      assert_equal 1, Approval.first.steps.where(status: "cancelled").count
    end

    test "consensus-aware reject: all fails on the first rejection" do
      2.times { |i| create_user(role: :director, name: "D#{i}") }
      template = create_template(event: "invoice.created", steps: [ { group: "director", approvals_required: :all } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })
      route!

      Step.pending.first.reject!(by: User.where(role: "director").first)

      assert_equal "rejected", Approval.first.status
    end

    test "consensus-aware reject: any survives a rejection while someone can still approve" do
      reviewers = Array.new(3) { |i| create_user(role: :reviewer, name: "R#{i}") }
      template = create_template(event: "invoice.created", steps: [ { group: "reviewer", approvals_required: :any } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })
      route!

      Step.pending.where(assigned_actor: reviewers[0]).first.reject!(by: reviewers[0])
      assert_equal "pending", Approval.first.status, "two reviewers can still approve"

      Step.pending.where(assigned_actor: reviewers[1]).first.approve!(by: reviewers[1])
      assert_equal "approved", Approval.first.status
    end

    test "consensus-aware reject: a counted layer tolerates rejects until the count is unreachable" do
      board = Array.new(3) { |i| create_user(role: :board, name: "B#{i}") }
      template = create_template(event: "invoice.created",
                                 steps: [ { group: "board", approvals_required: 2 } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })
      route!

      Step.pending.where(assigned_actor: board[0]).first.reject!(by: board[0])
      assert_equal "pending", Approval.first.status, "the remaining 2 could still reach the count"

      Step.pending.where(assigned_actor: board[1]).first.reject!(by: board[1])
      assert_equal "rejected", Approval.first.status, "only 1 approver left, can't reach 2"
    end

    test "sequential layers activate one after another" do
      create_user(role: :manager)
      create_user(role: :cfo)
      template = create_template(event: "invoice.created", steps: [
        { name: "Manager", layer: 1, group: "manager" },
        { name: "CFO", layer: 2, group: "cfo" }
      ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      route!
      assert_equal 1, Step.pending.count, "only layer 1 is actionable"
      assert_equal 1, Step.waiting.count

      pending_step_for(:manager).approve!(by: User.find_by(role: "manager"))
      assert_equal "pending", Approval.first.status
      assert_not_nil pending_step_for(:cfo), "layer 2 is activated"

      pending_step_for(:cfo).approve!(by: User.find_by(role: "cfo"))
      assert_equal "approved", Approval.first.status
    end

    test "hard reject tears the approval down and fires the rejection callback" do
      create_user(role: :manager)
      create_user(role: :cfo)
      template = create_template(event: "invoice.created", steps: [
        { name: "Manager", layer: 1, group: "manager" },
        { name: "CFO", layer: 2, group: "cfo" }
      ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      route!
      pending_step_for(:manager).reject!(by: User.find_by(role: "manager"))

      approval = Approval.first
      assert_equal "rejected", approval.status
      assert_equal 1, approval.steps.where(status: "cancelled").count, "the waiting CFO step is cancelled"

      drain_outbox!
      assert_equal "rejected", @invoice.reload.state
    end

    test "UC8 scatter-gather: parallel tracks run at once and gather into one approval" do
      legal = create_user(role: :legal)
      it_reviewer = create_user(role: :it)
      legal_tpl = create_template(event: "invoice.created", name: "Legal", steps: [ { group: "legal" } ])
      it_tpl = create_template(event: "invoice.created", name: "IT", steps: [ { group: "it" } ])

      approval = ApprovalBuilder.build_parallel!(templates: [ legal_tpl, it_tpl ], target: @invoice)

      assert_equal 2, approval.tracks.count
      assert_equal 2, approval.steps.pending.count, "both tracks are active simultaneously"
      assert_raises(ActiveRecord::SoleRecordExceeded, "no lone track once fanned out") { approval.track }

      legal_step = approval.steps.where(assigned_actor: legal).first
      legal_step.approve!(by: legal)
      assert_equal "pending", Approval.find(approval.id).status, "approval still waiting on the IT track"

      approval.steps.pending.first.approve!(by: it_reviewer)
      assert_equal "approved", Approval.find(approval.id).status, "gathers once every track approves"
    end

    # The gather is consensus-aware, exactly like a layer: "2 of 3 departments".
    def three_department_approval(approvals_required:)
      %i[legal it finance].each { |r| create_user(role: r) }
      tpls = %i[legal it finance].map { |r| create_template(event: "invoice.created", name: r.to_s, steps: [ { group: r.to_s } ]) }
      ApprovalBuilder.build_parallel!(templates: tpls, target: @invoice, approvals_required: approvals_required)
    end

    test "counted gather: approves once enough tracks approve, cancelling the rest" do
      approval = three_department_approval(approvals_required: "2")

      approval.steps.where(assigned_actor: User.find_by(role: "legal")).first.approve!(by: User.find_by(role: "legal"))
      assert_equal "pending", Approval.find(approval.id).status, "one of two — still gathering"

      approval.steps.where(assigned_actor: User.find_by(role: "it")).first.approve!(by: User.find_by(role: "it"))
      approval = Approval.find(approval.id)
      assert_equal "approved", approval.status, "two approvals reach the count"
      assert_equal 1, approval.tracks.where(status: "cancelled").count, "the finance track is no longer needed"
    end

    test "counted gather: one rejected track does not veto a still-reachable count" do
      approval = three_department_approval(approvals_required: "2")

      approval.steps.where(assigned_actor: User.find_by(role: "legal")).first.reject!(by: User.find_by(role: "legal"))
      assert_equal "pending", Approval.find(approval.id).status, "IT + Finance can still reach 2 — not a veto"

      approval.steps.where(assigned_actor: User.find_by(role: "it")).first.approve!(by: User.find_by(role: "it"))
      approval.steps.where(assigned_actor: User.find_by(role: "finance")).first.approve!(by: User.find_by(role: "finance"))
      assert_equal "approved", Approval.find(approval.id).status
    end

    test "counted gather: fails once the required count becomes unreachable" do
      approval = three_department_approval(approvals_required: "2")

      approval.steps.where(assigned_actor: User.find_by(role: "legal")).first.reject!(by: User.find_by(role: "legal"))
      approval.steps.where(assigned_actor: User.find_by(role: "it")).first.reject!(by: User.find_by(role: "it"))

      assert_equal "rejected", Approval.find(approval.id).status, "only finance left — 2 is unreachable"
    end

    test "a gather count exceeding the number of tracks is rejected at build time" do
      create_user(role: :legal)
      tpl = create_template(event: "invoice.created", name: "Legal", steps: [ { group: "legal" } ])

      error = assert_raises(ApprovalBuilder::BuilderError) do
        ApprovalBuilder.build_parallel!(templates: [ tpl ], target: @invoice, approvals_required: "3")
      end
      assert_match(/never resolve/, error.message)
    end

    test "build_parallel! refuses to scatter one approval across tenants" do
      here  = create_template(event: "invoice.created", name: "A", steps: [ { group: "manager" } ])
      there = create_template(event: "invoice.created", name: "B", tenant: "other-tenant", steps: [ { group: "manager" } ])

      error = assert_raises(ApprovalBuilder::BuilderError) do
        ApprovalBuilder.build_parallel!(templates: [ here, there ], target: @invoice)
      end
      assert_match(/one tenant/, error.message)
    end

    test "cancel! withdraws an in-flight approval and cancels its open steps" do
      create_user(role: :manager)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })
      route!
      approval = Approval.first
      step = pending_step_for(:manager)

      approval.cancel!(reason: "PO voided")

      assert_equal "cancelled", approval.reload.status
      assert_equal "cancelled", step.reload.status, "open steps are cancelled too"
      assert OutboxEvent.exists?(event_name: "approval.cancelled"), "fires the cancellation event"
    end

    test "cancel! is a no-op once the approval is terminal" do
      create_user(role: :manager)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })
      route!
      pending_step_for(:manager).approve!(by: User.find_by(role: "manager"))
      approval = Approval.first

      assert_no_difference -> { OutboxEvent.count } do
        approval.cancel!(reason: "too late")
      end
      assert_equal "approved", approval.reload.status
    end

    test "reassign! hands a pending step to another actor, audited, still pending" do
      manager = create_user(role: :manager)
      backup  = create_user(role: :backup)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })
      route!
      step = pending_step_for(:manager)

      step.reassign!(to: backup, by: manager, comment: "covering while away")

      step.reload
      assert_equal backup, step.assigned_actor
      assert_equal "pending", step.status, "reassignment doesn't resolve the step"
      assert step.actionable_by?(backup)
      assert_equal "reassigned", step.audit_logs.order(:created_at).last.event
      assert OutboxEvent.exists?(event_name: "step.reassigned")
    end

    test "reassign! refuses a step that is no longer pending" do
      manager = create_user(role: :manager)
      backup  = create_user(role: :backup)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })
      route!
      step = pending_step_for(:manager)
      step.approve!(by: manager)

      assert_raises(ActiveRecord::RecordInvalid) { step.reassign!(to: backup) }
    end

    test "engine errors share one rescue point under ApprovalEngine::Error" do
      assert ApprovalBuilder::BuilderError < ApprovalEngine::Error
      assert RuleEvaluator::EvaluationError < ApprovalEngine::Error
    end

    test "requesting changes appends a fresh iteration without erasing history" do
      create_user(role: :manager)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      route!
      manager = User.find_by(role: "manager")
      original = pending_step_for(:manager)
      original.request_changes!(by: manager)

      assert_equal "changes_requested", original.reload.status, "history is preserved"
      assert_equal "pending", Approval.first.status, "approval keeps going"

      fresh = Step.where(iteration: 2)
      assert_equal 1, fresh.count
      assert_equal "pending", fresh.first.status
    end

    test "majority consensus: resolves once more than half approve" do
      3.times { |i| create_user(role: :board, name: "B#{i}") }
      template = create_template(event: "invoice.created",
                                 steps: [ { group: "board", approvals_required: :majority } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      route!
      board = User.where(role: "board").to_a
      Step.pending.where(assigned_actor: board[0]).first.approve!(by: board[0])
      assert_equal "pending", Approval.first.status, "1 of 3 is not yet a majority"

      Step.pending.where(assigned_actor: board[1]).first.approve!(by: board[1])
      assert_equal "approved", Approval.first.status, "2 of 3 is a majority"
    end

    test "run_approval! demands exactly one of event: or templates:" do
      assert_raises(ArgumentError) { @invoice.run_approval!(event: "invoice.created", templates: []) }
      assert_raises(ArgumentError) { @invoice.run_approval! }
    end

    test "host record exposes its latest approval, in-flight flag, and status" do
      create_user(role: :manager)
      template = create_template(event: "invoice.created", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      assert_nil @invoice.approval_status, "nothing has happened yet"
      assert_not @invoice.approval_in_flight?

      route!
      assert @invoice.approval_in_flight?, "a pending approval is in flight"
      assert_equal "pending", @invoice.approval_status
      assert_equal @invoice.approvals.last, @invoice.latest_approval

      pending_step_for(:manager).approve!(by: User.find_by(role: "manager"))
      assert_equal "approved", @invoice.approval_status
      assert_not @invoice.approval_in_flight?, "an approved run is terminal, not in flight"
    end

    test "current_bottleneck is the longest-pending step; activation is stamped per layer" do
      create_user(role: :manager)
      create_user(role: :cfo)
      template = create_template(event: "invoice.created", steps: [
        { name: "Manager", layer: 1, group: "manager" },
        { name: "CFO", layer: 2, group: "cfo" }
      ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 0 ] })

      route!
      approval = Approval.first
      cfo_step = approval.steps.find_by(layer: 2)

      assert_equal pending_step_for(:manager), approval.current_bottleneck, "only layer 1 is pending"
      assert_nil cfo_step.activated_at, "layer 2 isn't actionable yet"

      pending_step_for(:manager).approve!(by: User.find_by(role: "manager"))

      assert_equal cfo_step.reload, approval.current_bottleneck, "the CFO step is now the bottleneck"
      assert_not_nil cfo_step.activated_at, "layer 2's activation was stamped when it opened"
    end
  end

  # Auto-triggering rides on after_commit, which only fires on a real commit, so
  # this case opts out of transactional fixtures and cleans up by hand.
  class AutoTriggerTest < ActiveSupport::TestCase
    include ApprovalEngine::ApprovalFixtures
    self.use_transactional_tests = false

    setup do
      ApprovalEngine.reset_configuration!
      ApprovalEngine.configure do |c|
        c.actor_class = "User"
        c.current_tenant_method = -> { Struct.new(:id).new(TENANT) }
      end
      Invoice.approval_trigger_events = %i[create update].freeze
      create_user(role: :manager)
      template = create_template(event: "invoice.updated", steps: [ { group: "manager" } ])
      create_rule(template: template, condition: { ">" => [ { "var" => "amount" }, 1000 ] })
    end

    teardown do
      Invoice.approval_trigger_events = [].freeze
      ApprovalEngine.reset_configuration!
      [ AuditLog, OutboxEvent, Step, Track, Approval, TriggerRule,
        TemplateStep, TrackTemplate, Invoice, User ].each(&:delete_all)
    end

    test "updating a record auto-triggers the <model>.updated track" do
      invoice = Invoice.create!(tenant_id: TENANT, amount: 5000, department: "IT")
      assert_equal 0, Approval.count, "no invoice.updated rule fires on create"

      invoice.update!(amount: 6000)

      assert_equal 1, Approval.where(event_name: "invoice.updated").count
    end

    test "overriding trigger_approval? gates the auto-trigger" do
      Invoice.approval_trigger_events = %i[create].freeze
      create_template(event: "invoice.created", steps: [ { group: "manager" } ])
        .trigger_rules.create!(tenant_id: TENANT, event_name: "invoice.created",
                               condition: { ">" => [ { "var" => "amount" }, 0 ] })
      Invoice.define_method(:trigger_approval?) { |_lifecycle = nil| false }

      Invoice.create!(tenant_id: TENANT, amount: 5000, department: "IT")

      assert_equal 0, Approval.count, "override returning false skips auto-routing"
    ensure
      Invoice.remove_method(:trigger_approval?) # fall back to the concern default
    end

    test "the lifecycle set is data-driven — :destroy works with no new code" do
      Invoice.approval_trigger_events = %i[destroy].freeze
      create_template(event: "invoice.destroyed", steps: [ { group: "manager" } ])
        .trigger_rules.create!(tenant_id: TENANT, event_name: "invoice.destroyed",
                               condition: { ">" => [ { "var" => "amount" }, 0 ] })

      Invoice.create!(tenant_id: TENANT, amount: 5000, department: "IT").destroy!

      assert_equal 1, Approval.where(event_name: "invoice.destroyed").count
    end
  end
end
