module ApprovalEngine
  # Stamps a concrete, actionable ledger (Approval → Track → Steps) out of one
  # or more abstract TrackTemplates.
  #
  # A single template builds a single-track approval. Several templates build a
  # scatter-gather approval: one parallel track per template, all active at once,
  # gathering per the approval's `approvals_required` (`:all` by default).
  #
  # Each template step is expanded into one Step per resolved actor — so "any
  # one of five senior devs" becomes five sibling steps sharing one consensus
  # policy. Only each track's first layer starts `pending`; later layers wait
  # until the layer before them resolves.
  class ApprovalBuilder
    class BuilderError < StandardError; end

    # Build a single-track approval from one template. `event_name` is the event
    # that triggered this run (nil when started manually) — recorded on the
    # Approval for audit/display. `trigger_rule` is the rule that matched, when
    # auto-routed, so the approval remembers its provenance.
    def self.build!(template:, target:, event_name: nil, trigger_rule: nil)
      new(templates: [ template ], target: target, event_name: event_name, trigger_rule: trigger_rule).build!
    end

    # Build a scatter-gather approval, one parallel track per template.
    # `approvals_required` is the gather consensus (default `:all`).
    def self.build_parallel!(templates:, target:, event_name: nil, approvals_required: "all")
      raise BuilderError, "build_parallel! needs at least one template" if templates.blank?

      new(templates: templates, target: target, event_name: event_name, approvals_required: approvals_required).build!
    end

    def initialize(templates:, target:, event_name: nil, trigger_rule: nil, approvals_required: "all")
      @templates           = templates
      @target              = target
      @event_name          = event_name
      @trigger_rule        = trigger_rule
      @approvals_required  = approvals_required.to_s
    end

    def build!
      guard_gather_consensus!
      ActiveRecord::Base.transaction do
        approval = build_approval
        templates.each { |template| build_track!(approval, template) }
        approval
      end
    end

    # The fail-closed quarantine state. Built when a dynamic rule blows up, so
    # ops can see exactly why a track never started instead of hitting a 500.
    def self.build_quarantine_approval!(target:, tenant_id:, reason:)
      Approval.create!(tenant_id: tenant_id, target: target, status: "quarantined").tap do |approval|
        OutboxEvent.create!(
          tenant_id: approval.tenant_id,
          event_name: "approval.quarantined",
          record: approval,
          error_payload: reason
        )
      end
    end

    private

    attr_reader :templates, :target, :event_name, :trigger_rule, :approvals_required

    def build_approval
      Approval.create!(
        tenant_id: templates.first.tenant_id,
        target: target,
        status: "pending",
        event_name: event_name,
        trigger_rule: trigger_rule,
        approvals_required: approvals_required
      )
    end

    def build_track!(approval, template)
      track = Track.create!(
        tenant_id: template.tenant_id,
        approval: approval,
        name: template.name,
        status: "pending"
      )
      build_steps(track, template)
    end

    def build_steps(track, template)
      first_layer = template.template_steps.minimum(:layer)

      template.template_steps.ordered.each do |tpl_step|
        actors = resolve_actors(tpl_step)
        guard_consensus!(tpl_step, actors)

        actors.each do |actor|
          track.steps.create!(
            tenant_id: template.tenant_id,
            name: tpl_step.name,
            layer: tpl_step.layer,
            iteration: 1,
            status: tpl_step.layer == first_layer ? "pending" : "waiting",
            approvals_required: tpl_step.approvals_required,
            timeout_after: tpl_step.timeout_after,
            assigned_actor: actor
          )
        end
      end
    end

    def resolve_actors(tpl_step)
      actors = Array(host_actor_resolver.resolve_approval_group(tpl_step.assigned_group, target)).compact

      if actors.empty?
        raise BuilderError, "No actors resolved for group '#{tpl_step.assigned_group}'. " \
                            "Check #{host_actor_resolver}.resolve_approval_group."
      end

      actors
    end

    # A layer needing more approvals than it has actors could never resolve —
    # fail loudly at build time instead of silently stranding the approval in
    # `pending` forever. (Only an absolute count can exceed the group; relative
    # specs like :majority / "60%" are always satisfiable.)
    def guard_consensus!(tpl_step, actors)
      required = Consensus.new(tpl_step.approvals_required).required(actors.size)
      return if required <= actors.size

      raise BuilderError, "Step '#{tpl_step.name}' needs #{required} approval(s) but only " \
                          "#{actors.size} actor(s) resolved for group '#{tpl_step.assigned_group}' " \
                          "— it could never resolve."
    end

    # The gather twin of guard_consensus!: a fixed count exceeding the track
    # count could never resolve.
    def guard_gather_consensus!
      raise BuilderError, "approvals_required #{approvals_required.inspect} is not a valid consensus spec." unless Consensus.valid?(approvals_required)

      required = Consensus.new(approvals_required).required(templates.size)
      return if required <= templates.size

      raise BuilderError, "approval needs #{required} track approval(s) but only #{templates.size} " \
                          "track(s) were given — it could never resolve."
    end

    def host_actor_resolver
      klass = actor_class

      unless klass.respond_to?(:resolve_approval_group)
        raise BuilderError, "#{klass} must define `self.resolve_approval_group(group_name, target)`."
      end

      klass
    end

    def actor_class
      ApprovalEngine.config.actor_class_constant
    rescue NameError => e
      raise BuilderError, "ApprovalEngine.config.actor_class is #{ApprovalEngine.config.actor_class.inspect}, " \
                          "which doesn't resolve to a loaded class (#{e.message})."
    end
  end
end
