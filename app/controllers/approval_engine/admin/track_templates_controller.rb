module ApprovalEngine
  module Admin
    # Runtime CRUD for the blueprint an approval is stamped from. This owns
    # *what* happens; TriggerRulesController owns *when*.
    class TrackTemplatesController < BaseController
      PAGE_LIMIT = 100

      before_action :set_track_template, only: %i[show edit update destroy]

      def index
        @tenant_id = params[:tenant_id].presence
        scope = TrackTemplate.order(:tenant_id, :name)
        scope = scope.for_tenant(@tenant_id) if @tenant_id
        @track_templates = scope.limit(PAGE_LIMIT).to_a
        @total = scope.count
        @tenant_ids = TrackTemplate.distinct.order(:tenant_id).pluck(:tenant_id)
        # One grouped query for all the row counts, instead of N `.template_steps.size`.
        ids = @track_templates.map(&:id)
        @step_counts = TemplateStep.where(approval_engine_track_template_id: ids)
                                   .group(:approval_engine_track_template_id).count
        @rule_counts = TriggerRule.where(approval_engine_track_template_id: ids)
                                  .group(:approval_engine_track_template_id).count
      end

      def show
        @template_steps = @track_template.template_steps
        @trigger_rules  = @track_template.trigger_rules.by_priority
      end

      def new
        @track_template = TrackTemplate.new(tenant_id: default_tenant_id, status: "draft")
      end

      def create
        @track_template = TrackTemplate.new(track_template_params)
        if @track_template.save
          redirect_to admin_track_template_path(@track_template), notice: "Template created."
        else
          render :new, status: :unprocessable_entity
        end
      end

      def edit
      end

      def update
        if @track_template.update(track_template_params)
          redirect_to admin_track_template_path(@track_template), notice: "Template updated."
        else
          render :edit, status: :unprocessable_entity
        end
      end

      def destroy
        # Deleting a template cascades to its rules, and deleting a rule nullifies
        # the provenance column on every approval it ever routed — the ledger
        # would quietly forget which rule started it. Archiving stops the
        # template firing and keeps that history, so history wins over the delete.
        if routed_approvals?
          redirect_to admin_track_template_path(@track_template),
                      alert: "This template has already routed approvals. Archive it instead of deleting it."
        else
          @track_template.destroy
          redirect_to admin_track_templates_path, notice: "Template deleted."
        end
      end

      private

      def set_track_template
        @track_template = TrackTemplate.find(params[:id])
      end

      def routed_approvals?
        Approval.where(approval_engine_trigger_rule_id: @track_template.trigger_rules.select(:id)).exists?
      end

      def track_template_params
        params.require(:track_template).permit(:tenant_id, :name, :status)
      end
    end
  end
end
