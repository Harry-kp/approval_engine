require "test_helper"

module ApprovalEngine
  class ApprovalsControllerTest < ActionDispatch::IntegrationTest
    include Engine.routes.url_helpers
    include ApprovalEngine::ApprovalFixtures

    setup do
      @invoice = Invoice.create!(tenant_id: TENANT, amount: 6000)
      @approval = Approval.create!(tenant_id: TENANT, target: @invoice, status: "pending", event_name: "invoice.created")
      track = Track.create!(tenant_id: TENANT, approval: @approval, name: "Finance")
      manager = create_user(role: :manager)
      @step = track.steps.create!(tenant_id: TENANT, name: "Manager", status: "pending", assigned_actor: manager)
    end

    test "index lists approvals and renders status filters" do
      get approvals_path

      assert_response :success
      assert_select "h1", "Approvals"
      assert_select "td.ae-mono", /Invoice##{@invoice.id}/
    end

    test "index filters by status" do
      Approval.create!(tenant_id: TENANT, target: @invoice, status: "quarantined")

      get approvals_path(status: "quarantined")

      assert_response :success
      assert_select "span.ae-badge.is-quarantined"
    end

    test "show renders tracks, steps and the audit trail" do
      @step.approve!(by: @step.assigned_actor)

      get approval_path(@approval)

      assert_response :success
      assert_select "h2", /Finance/
      assert_select "span.ae-badge.is-approved"
    end
  end
end
