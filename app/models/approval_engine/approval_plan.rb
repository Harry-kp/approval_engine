module ApprovalEngine
  # A read-only description of what a given event *would* trigger, produced by
  # `RuleEvaluator.preview`. It writes nothing and resolves nothing eagerly — a
  # UX/preview aid, not a contract (rules can change before the real run, so the
  # authoritative routing still happens in `run_approval!`).
  class ApprovalPlan
    # One layer that would be created. Pure blueprint data — no DB rows.
    PlannedStep = Struct.new(:name, :layer, :assigned_group, :approvals_required, keyword_init: true)

    attr_reader :status, :template, :target, :reason

    def initialize(status:, template:, target:, reason: nil)
      @status   = status
      @template = template
      @target   = target
      @reason   = reason
    end

    # An approval would be spawned.
    def triggered?
      status == :match
    end

    # No rule matched — taking the action needs no approval.
    def no_approval_required?
      status == :no_match
    end

    # A rule is malformed; the real run would quarantine. `reason` says why.
    def error?
      status == :error
    end

    # The layers that would be created, in order. Pure template data.
    def steps
      return [] unless template

      template.template_steps.ordered.map do |tpl_step|
        PlannedStep.new(
          name: tpl_step.name,
          layer: tpl_step.layer,
          assigned_group: tpl_step.assigned_group,
          approvals_required: tpl_step.approvals_required
        )
      end
    end

    # Best-effort, read-only resolution of who would be assigned to a planned
    # step. Returns [] if the host resolver is unavailable or raises, so a
    # preview never crashes on a host-side bug.
    def actors_for(planned_step)
      klass = ApprovalEngine.config.actor_class_constant
      return [] unless klass.respond_to?(:resolve_approval_group)

      Array(klass.resolve_approval_group(planned_step.assigned_group, target)).compact
    rescue StandardError
      []
    end
  end
end
