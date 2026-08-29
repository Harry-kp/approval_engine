module ApprovalEngine
  module Admin
    # Runtime CRUD for the routing rules — the claim the README makes, made
    # true: which template an event picks, under what condition, is data an
    # admin edits, not code someone deploys.
    class TriggerRulesController < BaseController
      PAGE_LIMIT = 100
      # How many empty condition rows the form offers. "Add another condition"
      # without JavaScript is just a few spare rows; blank ones are dropped.
      BLANK_CONDITION_ROWS = 3
      # A condition is an AST an admin types; a jsonb column will accept a novel
      # of one. Cap it so a pasted mistake can't slow every event down.
      MAX_CONDITION_BYTES = 8_192

      before_action :set_track_template, except: :index
      before_action :set_trigger_rule, only: %i[edit update destroy]

      def index
        # event_name asc, priority desc — the order the evaluator resolves them
        # in, so the list reads the way the engine decides.
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
        # An Approval keeps the rule that routed it as provenance, on a foreign
        # key declared `on_delete: :nullify` — so destroying a rule does not
        # error, it quietly erases "which rule started this?" from every
        # approval it ever spawned. Deactivating stops it matching anything new
        # and keeps the history, which is the same trade the template's delete
        # guard makes and the same one `FlowDefinition#reconcile_rules!` makes.
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

      # Tolerant of a missing `trigger_rule` key because `new` and `edit` render
      # the same condition editor as `create` and `update`, and read the mode
      # back out of it.
      def trigger_rule_params
        @trigger_rule_params ||= params.fetch(:trigger_rule, ActionController::Parameters.new)
                                       .permit(:tenant_id, :event_name, :priority, :active,
                                               :condition_mode, :condition_json,
                                               conditions: [ :field, :operator, :value ])
      end

      # The condition is assembled, never mass-assigned: the form submits either
      # triples or raw JSON, and neither is the column's value.
      def rule_attributes
        trigger_rule_params.except(:condition_mode, :condition_json, :conditions)
      end

      def advanced_mode?
        trigger_rule_params[:condition_mode] == "advanced"
      end

      # Whatever the form submitted, rendered down to the AST the column stores.
      # Returns nil with `@condition_error` set when the input can't be read, so
      # the action re-renders the form instead of blowing up on the admin.
      def submitted_condition
        advanced_mode? ? parsed_raw_condition : built_condition
      end

      def parsed_raw_condition
        json = trigger_rule_params[:condition_json].to_s
        raise ArgumentError, "is too large (max #{MAX_CONDITION_BYTES} bytes)" if json.bytesize > MAX_CONDITION_BYTES

        parsed = JSON.parse(json)
        # A jsonb column will happily store an array or a bare number, and JSON
        # Logic evaluates a non-object as a literal — a rule like that matches
        # *every* event of its name. Reject it here rather than ship a rule that
        # silently routes everything.
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
        # Condition raises for a blank field, an unknown operator, or no rows.
        @condition_error = e.message
        nil
      end

      # Blank rows are how the form offers "add another condition" with no
      # JavaScript, so they're dropped rather than validated.
      def submitted_condition_rows
        Array(trigger_rule_params[:conditions]).reject { |row| row[:field].blank? }
      end

      # What the editor renders. A stored AST the simple form can't represent
      # comes back from `Condition.parse` as nil — that is the signal to open in
      # the raw editor rather than silently mangle a rule someone hand-wrote.
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
