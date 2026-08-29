module ApprovalEngine
  module Admin
    # View-side vocabulary for the rule and step editors. It lives here rather
    # than on the models because every method is about how a value *reads in a
    # form*, which is a concern of this admin and of nothing else in the engine.
    module BaseHelper
      # A list round-trips through the form as a comma-separated string, which
      # is exactly what Condition reads back for `in` / `not in`.
      def condition_value_for_form(condition)
        condition.list? ? Array(condition.value).join(", ") : condition.value.to_s
      end

      # A one-line, human reading of a rule's condition for the index table. A
      # condition the simple form can't represent has no short honest summary,
      # so it says so rather than printing a misleading half of the AST.
      def condition_summary(rule)
        parsed = ApprovalEngine::Condition.parse(rule.condition)
        return "Custom JSON Logic" if parsed.nil?

        parsed.map do |condition|
          "#{condition.field} #{ApprovalEngine::Condition::LABELS[condition.operator]} #{condition_value_for_form(condition)}"
        end.join(" and ")
      end

      # The field dropdown's groups, plus — when the rule already names an
      # attribute nobody exposes — a group saying so. An unexposed var reads as
      # a clean non-match, i.e. a rule that silently never fires, so the form
      # surfaces it instead of dropping the admin's field on save.
      def field_groups_including(field)
        groups = exposed_attribute_groups
        return groups if field.blank? || groups.any? { |_model, options| options.any? { |_label, value| value == field.to_s } }

        [ [ "Not exposed — this rule can never match", [ [ field.to_s, field.to_s ] ] ] ] + groups.to_a
      end

      # Spelled out because "any" and "all" are the two people guess wrong: they
      # are about how many of the layer's approvers must act, not how many
      # layers run.
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
