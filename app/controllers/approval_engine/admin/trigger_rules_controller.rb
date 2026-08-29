module ApprovalEngine
  module Admin
    # Runtime CRUD for routing rules: which template an event picks, and under
    # what condition, is data an admin edits rather than code someone deploys.
    class TriggerRulesController < BaseController
      PAGE_LIMIT = 100
      # "Add another condition" without JavaScript is just spare rows.
      BLANK_CONDITION_ROWS = 3
      # jsonb will accept a novel; cap it so a paste can't slow every event.
      MAX_CONDITION_BYTES = 8_192

      before_action :set_track_template, except: :index
      before_action :set_trigger_rule, only: %i[edit update destroy]

      def index
        # The order the evaluator resolves them in.
        @tenant_id = params[:tenant_id].presence
        scope = TriggerRule.includes(:track_template).order(:event_name).by_priority
        scope = scope.for_tenant(@tenant_id) if @tenant_id
        @trigger_rules = scope.limit(PAGE_LIMIT).to_a
        @total = scope.count
      end

      def new
        @trigger_rule = @track_template.trigger_rules.build(tenant_id: @track_template.tenant_id, priority: 0, active: true)
        prepare_condition_editor
      end

      def create
        @trigger_rule = @track_template.trigger_rules.build(rule_attributes)
        @trigger_rule.condition = submitted_condition
        if @condition_error.nil? && @trigger_rule.save
          redirect_to admin_track_template_path(@track_template), notice: "Rule created."
        else
          @trigger_rule.errors.add(:condition, @condition_error) if @condition_error
          prepare_condition_editor
          render :new, status: :unprocessable_entity
        end
      end

      def edit
        prepare_condition_editor
      end

      def update
        @trigger_rule.assign_attributes(rule_attributes)
        @trigger_rule.condition = submitted_condition
        if @condition_error.nil? && @trigger_rule.save
          redirect_to admin_track_template_path(@track_template), notice: "Rule updated."
        else
          @trigger_rule.errors.add(:condition, @condition_error) if @condition_error
          prepare_condition_editor
          render :edit, status: :unprocessable_entity
        end
      end

      def destroy
        # The provenance FK is `on_delete: :nullify`, so deleting a rule
        # silently erases which rule routed every approval it spawned.
        # Deactivating keeps the history — as the template guard and
        # FlowDefinition#reconcile_rules! both do.
        if routed_approvals?
          redirect_to admin_track_template_path(@track_template),
                      alert: "This rule has already routed approvals. Untick Active instead — " \
                             "deleting it would erase which rule started them."
        else
          @trigger_rule.destroy
          redirect_to admin_track_template_path(@track_template), notice: "Rule deleted."
        end
      end

      private

      def set_track_template
        @track_template = TrackTemplate.find(params[:track_template_id])
      end

      def set_trigger_rule
        @trigger_rule = @track_template.trigger_rules.find(params[:id])
      end

      def routed_approvals?
        Approval.where(approval_engine_trigger_rule_id: @trigger_rule.id).exists?
      end

      # Tolerant of a missing key: `new`/`edit` render the same editor.
      def trigger_rule_params
        @trigger_rule_params ||= params.fetch(:trigger_rule, ActionController::Parameters.new)
                                       .permit(:tenant_id, :event_name, :priority, :active,
                                               :condition_mode, :condition_json,
                                               conditions: [ :field, :operator, :value ])
      end

      # Assembled, never mass-assigned — the form submits triples or raw JSON,
      # and neither is the column's value.
      def rule_attributes
        trigger_rule_params.except(:condition_mode, :condition_json, :conditions)
      end

      def advanced_mode?
        trigger_rule_params[:condition_mode] == "advanced"
      end

      # nil with `@condition_error` set when unreadable, so the action
      # re-renders the form rather than blowing up on the admin.
      def submitted_condition
        advanced_mode? ? parsed_raw_condition : built_condition
      end

      def parsed_raw_condition
        json = trigger_rule_params[:condition_json].to_s
        raise ArgumentError, "is too large (max #{MAX_CONDITION_BYTES} bytes)" if json.bytesize > MAX_CONDITION_BYTES

        parsed = JSON.parse(json)
        # JSON Logic evaluates a non-object as a literal, so an array or bare
        # number would match *every* event of its name.
        raise ArgumentError, %(must be a JSON Logic object, e.g. {">": [{"var": "amount"}, 10000]}) unless parsed.is_a?(Hash)

        parsed
      rescue JSON::ParserError => e
        @condition_error = "isn't valid JSON: #{e.message}"
        nil
      rescue ArgumentError => e
        @condition_error = e.message
        nil
      end

      def built_condition
        types = attribute_types(trigger_rule_params[:event_name])
        conditions = submitted_condition_rows.map do |row|
          ApprovalEngine::Condition.new(
            field: row[:field], operator: row[:operator], value: row[:value], type: types[row[:field].to_s]
          )
        end
        ApprovalEngine::Condition.to_json_logic(conditions)
      rescue ArgumentError => e
        # Condition raises for a blank field, bad operator, or no rows.
        @condition_error = e.message
        nil
      end

      # Blank rows are the JavaScript-free "add another", so drop them.
      def submitted_condition_rows
        Array(trigger_rule_params[:conditions]).reject { |row| row[:field].blank? }
      end

      # `Condition.parse` returns nil for an AST the simple form can't hold —
      # the signal to open the raw editor rather than mangle a hand-written rule.
      def prepare_condition_editor
        stored = @trigger_rule.condition
        parsed = ApprovalEngine::Condition.parse(stored)
        @condition_simple = stored.blank? || !parsed.nil?
        @condition_mode   = trigger_rule_params[:condition_mode].presence || (@condition_simple ? "simple" : "advanced")
        @condition_json   = trigger_rule_params[:condition_json].presence ||
                            (stored.present? ? JSON.pretty_generate(stored) : "")
        @condition_rows   = submitted_condition_rows.presence || stored_condition_rows(parsed)
        @blank_rows       = BLANK_CONDITION_ROWS
      end

      def stored_condition_rows(parsed)
        Array(parsed).map do |condition|
          { "field" => condition.field, "operator" => condition.operator.to_s,
            "value" => helpers.condition_value_for_form(condition) }
        end
      end
    end
  end
end
