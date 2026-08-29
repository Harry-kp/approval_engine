module ApprovalEngine
  module Admin
    # Runtime CRUD for the layers of a template. Steps have no page of their
    # own: the template's show page is their index, so every action lands back
    # there and the admin always sees a layer in the context of its siblings.
    class TemplateStepsController < BaseController
      before_action :set_track_template
      before_action :set_template_step, only: %i[edit update destroy]

      def new
        # Layers are 1-based and ordered; the next one is almost always what an
        # admin means by "add a step", so offer it rather than making them count.
        @template_step = @track_template.template_steps.build(
          layer: (@track_template.template_steps.maximum(:layer) || 0) + 1,
          approvals_required: "any"
        )
      end

      def create
        @template_step = @track_template.template_steps.build(template_step_params)
        if @template_step.save
          redirect_to admin_track_template_path(@track_template), notice: "Step added."
        else
          render :new, status: 422
        end
      end

      def edit
      end

      def update
        if @template_step.update(template_step_params)
          redirect_to admin_track_template_path(@track_template), notice: "Step updated."
        else
          render :edit, status: 422
        end
      end

      def destroy
        @template_step.destroy
        redirect_to admin_track_template_path(@track_template), notice: "Step deleted."
      end

      private

      def set_track_template
        @track_template = TrackTemplate.find(params[:track_template_id])
      end

      # Scoped through the parent so an id from another template is a 404 rather
      # than a cross-template edit.
      def set_template_step
        @template_step = @track_template.template_steps.find(params[:id])
      end

      # `approval_engine_track_template_id` is deliberately absent: the parent
      # comes from the nested route, never from the form.
      def template_step_params
        params.require(:template_step).permit(:name, :layer, :assigned_group, :approvals_required, :timeout_after)
      end
    end
  end
end
