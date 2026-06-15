require "shiny_json_logic"

module ApprovalEngine
  # Resolves which track (if any) a host event should spawn by evaluating
  # tenant-scoped JSON Logic rules against a flat payload.
  #
  # The payload is produced by the host model's `exposes_for_approval` DSL, so
  # the engine never reaches into the host's domain directly — it only sees the
  # whitelisted attributes it was handed.
  #
  #   ApprovalEngine::RuleEvaluator.call(
  #     event_name: "invoice.created",
  #     tenant_id:  account.id,
  #     target:     invoice,
  #     payload:    invoice.serialize_for_approval
  #   )
  #
  # `call` returns the spawned Approval, the quarantine Approval on a rule
  # failure, or nil when no rule matched. `preview` runs the identical matching
  # logic but writes nothing — see ApprovalPlan.
  class RuleEvaluator
    class EvaluationError < StandardError; end

    def self.call(event_name:, tenant_id:, target:, payload:)
      new(event_name: event_name, tenant_id: tenant_id, target: target, payload: payload).call
    end

    # Side-effect-free dry run: what *would* this event trigger? Writes nothing,
    # never quarantines, never raises. Returns an ApprovalPlan.
    def self.preview(event_name:, tenant_id:, target:, payload:)
      new(event_name: event_name, tenant_id: tenant_id, target: target, payload: payload).preview
    end

    # Side-effect-free: *every* rule that matches, in priority order, so the host
    # can let a user choose which to trigger instead of auto-picking the top one.
    # Returns an array of ApprovalPlan. Broken rules are skipped, not surfaced.
    def self.candidates(event_name:, tenant_id:, target:, payload:)
      new(event_name: event_name, tenant_id: tenant_id, target: target, payload: payload).candidates
    end

    def initialize(event_name:, tenant_id:, target:, payload:)
      @event_name = event_name
      @tenant_id  = tenant_id
      @target     = target
      @payload    = payload
    end

    def call
      status, rule = find_match
      case status
      when :match
        ApprovalBuilder.build!(template: rule.track_template, target: target, event_name: event_name, trigger_rule: rule)
      when :error
        raise EvaluationError, @failure_reason if ApprovalEngine.config.raise_on_rule_errors

        quarantine(rule)
      end
    end

    def preview
      status, rule = find_match
      ApprovalPlan.new(status: status, template: rule&.track_template, target: target, reason: @failure_reason)
    end

    def candidates
      candidate_rules.filter_map do |rule|
        ApprovalPlan.new(status: :match, template: rule.track_template, target: target) if evaluate(rule) == :match
      end
    end

    private

    attr_reader :event_name, :tenant_id, :target, :payload

    # Walk rules highest-priority-first; stop at the first match or the first
    # broken rule (fail closed). Returns [status, rule] where status is one of
    # :match, :no_match, :error. Shared by `call` and `preview` so a preview can
    # never disagree with the real run.
    def find_match
      candidate_rules.each do |rule|
        case evaluate(rule)
        when :match then return [ :match, rule ]
        when :error then return [ :error, rule ]
        end
      end

      [ :no_match, nil ]
    end

    def candidate_rules
      TriggerRule.active
                 .for_event(event_name)
                 .where(tenant_id: tenant_id)
                 .order(priority: :desc)
    end

    # Evaluates one rule. A *missing* payload key is a clean non-match (JSON
    # Logic returns false). A *malformed* rule raises, which we capture as :error
    # — the caller (`call` vs `preview`) decides whether to quarantine, raise, or
    # just report. This method itself never raises.
    def evaluate(rule)
      ShinyJsonLogic.apply(rule.condition, payload) ? :match : :no_match
    rescue => e
      @failure_reason = "Rule #{rule.id} evaluation failed: #{e.class}: #{e.message}"
      :error
    end

    def quarantine(_rule)
      ApprovalBuilder.build_quarantine_approval!(
        target: target,
        tenant_id: tenant_id,
        reason: @failure_reason
      )
    end
  end
end
