require "test_helper"

module ApprovalEngine
  module Admin
    class TemplateStepsControllerTest < ActionDispatch::IntegrationTest
      include Engine.routes.url_helpers
      include ApprovalEngine::ApprovalFixtures

      setup do
        ApprovalEngine.config.admin_enabled = true
        @template = create_template(
          steps: [ { name: "Manager", group: "manager", layer: 1 } ],
          name: "High-value invoice"
        )
        @step = @template.template_steps.first
      end

      teardown { ApprovalEngine.config.admin_enabled = true }

      test "new prefills the next layer" do
        get new_admin_track_template_template_step_path(@template)

        assert_response :success
        assert_select "input[name=?][value=?]", "template_step[layer]", "2"
      end

      test "create appends a layer" do
        assert_difference -> { @template.template_steps.count }, 1 do
          post admin_track_template_template_steps_path(@template),
               params: { template_step: { name: "CFO", layer: 2, assigned_group: "cfo", approvals_required: "majority" } }
        end

        assert_redirected_to admin_track_template_path(@template)
        assert_equal "majority", @template.template_steps.last.approvals_required
      end

      test "create surfaces the consensus validation" do
        assert_no_difference -> { TemplateStep.count } do
          post admin_track_template_template_steps_path(@template),
               params: { template_step: { name: "CFO", layer: 2, assigned_group: "cfo", approvals_required: "2 people" } }
        end

        assert_response :unprocessable_entity
        assert_select ".ae-errors", /must be :any, :all, :majority/
      end

      test "create accepts a timeout in seconds" do
        post admin_track_template_template_steps_path(@template),
             params: { template_step: { name: "CFO", layer: 2, assigned_group: "cfo",
                                        approvals_required: "any", timeout_after: 172_800 } }

        assert_redirected_to admin_track_template_path(@template)
        assert_equal 172_800, @template.template_steps.last.timeout_after
      end

      test "update edits a step" do
        patch admin_track_template_template_step_path(@template, @step),
              params: { template_step: { name: "Line manager", layer: 1, assigned_group: "manager", approvals_required: "all" } }

        assert_redirected_to admin_track_template_path(@template)
        assert_equal "Line manager", @step.reload.name
        assert_equal "all", @step.approvals_required
      end

      test "destroy removes a step" do
        assert_difference -> { TemplateStep.count }, -1 do
          delete admin_track_template_template_step_path(@template, @step)
        end

        assert_redirected_to admin_track_template_path(@template)
      end

      test "a step from another template is not reachable through this one" do
        other = create_template(steps: [ { name: "Legal", group: "legal" } ], name: "Other")

        stranger = other.template_steps.first

        assert_no_difference -> { TemplateStep.count } do
          delete admin_track_template_template_step_path(@template, stranger)
        end

        assert_response :not_found
      end

      test "actions 404 while the admin is disabled" do
        ApprovalEngine.config.admin_enabled = false

        get new_admin_track_template_template_step_path(@template)
        assert_response :not_found

        post admin_track_template_template_steps_path(@template),
             params: { template_step: { name: "Sneaky", layer: 9, assigned_group: "x", approvals_required: "any" } }
        assert_response :not_found
        assert_nil TemplateStep.find_by(name: "Sneaky")
      end
    end
  end
end
