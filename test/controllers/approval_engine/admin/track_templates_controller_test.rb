require "test_helper"

module ApprovalEngine
  module Admin
    class TrackTemplatesControllerTest < ActionDispatch::IntegrationTest
      include Engine.routes.url_helpers
      include ApprovalEngine::ApprovalFixtures

      setup do
        # The dummy app opts in at boot, but ApprovalEngine::TestCase resets the
        # configuration around every one of its tests and Minitest randomises
        # order, so the flag is re-asserted rather than assumed.
        ApprovalEngine.config.admin_enabled = true
        @template = create_template(
          event: "invoice.created",
          steps: [ { name: "Manager", group: "manager" } ],
          name: "High-value invoice"
        )
      end

      teardown { ApprovalEngine.config.admin_enabled = true }

      test "index lists templates with grouped step and rule counts" do
        create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 1 ] })

        get admin_track_templates_path

        assert_response :success
        assert_select "h1", "Templates"
        assert_select "td", "High-value invoice"
        assert_select "tbody tr" do
          assert_select "td", "1" # one step and one rule
        end
      end

      test "index filters by tenant" do
        create_template(steps: [ { name: "Legal", group: "legal" } ], tenant: "other", name: "Other tenant flow")

        get admin_track_templates_path(tenant_id: "other")

        assert_response :success
        assert_select "td", "Other tenant flow"
        assert_select "td", { text: "High-value invoice", count: 0 }
      end

      test "create makes a template" do
        assert_difference -> { TrackTemplate.count }, 1 do
          post admin_track_templates_path,
               params: { track_template: { tenant_id: TENANT, name: "Legal review", status: "draft" } }
        end

        assert_redirected_to admin_track_template_path(TrackTemplate.find_by(name: "Legal review"))
      end

      test "create re-renders with errors when the name is blank" do
        assert_no_difference -> { TrackTemplate.count } do
          post admin_track_templates_path,
               params: { track_template: { tenant_id: TENANT, name: "", status: "draft" } }
        end

        assert_response :unprocessable_entity
        assert_select ".ae-errors"
      end

      test "activating a template needs no deploy" do
        draft = create_template(steps: [ { name: "CFO", group: "cfo" } ], status: "draft", name: "Draft flow")

        patch admin_track_template_path(draft), params: { track_template: { status: "active" } }

        assert_redirected_to admin_track_template_path(draft)
        assert_equal "active", draft.reload.status
      end

      test "show renders the steps and rules of a template" do
        create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 10_000 ] })

        get admin_track_template_path(@template)

        assert_response :success
        assert_select "h1", /High-value invoice/
        assert_select "td", "Manager"
        assert_select "td", "amount is greater than 10000"
      end

      test "destroy removes a template that has never routed anything" do
        assert_difference -> { TrackTemplate.count }, -1 do
          delete admin_track_template_path(@template)
        end

        assert_redirected_to admin_track_templates_path
      end

      test "destroy refuses a template whose rules have routed approvals" do
        create_rule(template: @template, condition: { ">" => [ { "var" => "amount" }, 1 ] })
        create_user(role: :manager)
        invoice = Invoice.create!(tenant_id: TENANT, amount: 6000)
        invoice.run_approval!(event: "invoice.created", tenant_id: TENANT)

        assert_no_difference -> { TrackTemplate.count } do
          delete admin_track_template_path(@template)
        end

        assert_redirected_to admin_track_template_path(@template)
        assert TrackTemplate.exists?(@template.id)
        assert_match(/Archive it/, flash[:alert])
      end

      test "every action 404s while the admin is disabled" do
        ApprovalEngine.config.admin_enabled = false

        get admin_track_templates_path
        assert_response :not_found

        get admin_track_template_path(@template)
        assert_response :not_found

        post admin_track_templates_path, params: { track_template: { tenant_id: TENANT, name: "Sneaky" } }
        assert_response :not_found
        assert_nil TrackTemplate.find_by(name: "Sneaky")

        delete admin_track_template_path(@template)
        assert_response :not_found
        assert TrackTemplate.exists?(@template.id)
      end
    end
  end
end
