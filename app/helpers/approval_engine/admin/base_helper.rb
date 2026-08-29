module ApprovalEngine
  module Admin
    # View-side vocabulary for the rule and step editors — how a value reads in
    # a form, which concerns this admin and nothing else in the engine.
    module BaseHelper
      # A list round-trips as a comma-separated string, as Condition reads it.
      def condition_value_for_form(condition)
        condition.list? ? Array(condition.value).join(", ") : condition.value.to_s
      end

      # A one-line reading for the index. What the simple form can't represent
      # has no honest summary, so say so rather than print half the AST.
      def condition_summary(rule)
        parsed = ApprovalEngine::Condition.parse(rule.condition)
        return "Custom JSON Logic" if parsed.nil?

        parsed.map do |condition|
          "#{condition.field} #{ApprovalEngine::Condition::LABELS[condition.operator]} #{condition_value_for_form(condition)}"
        end.join(" and ")
      end

      # Plus a group for an attribute nobody exposes, when the rule names one:
      # that reads as a clean non-match, so surface it rather than drop it.
      def field_groups_including(field)
        groups = exposed_attribute_groups
        return groups if field.blank? || groups.any? { |_model, options| options.any? { |_label, value| value == field.to_s } }

        [ [ "Not exposed — this rule can never match", [ [ field.to_s, field.to_s ] ] ] ] + groups.to_a
      end

      # "any" and "all" are about the layer's approvers, not how many layers.
      def consensus_hint
        "any = one approver is enough · all = every approver · majority · a percentage like 60% · a count like 2"
      end

      def timeout_label(seconds)
        return "—" if seconds.blank?

        ActiveSupport::Duration.build(seconds.to_i).inspect
      end
    end
  end
end
