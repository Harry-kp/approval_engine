require "test_helper"

module ApprovalEngine
  # The only test that touches global routing state.
  class AdminRoutesTest < ActionDispatch::IntegrationTest
    include Engine.routes.url_helpers

    # Redraws the engine's routes with the admin back on, and — the part that
    # matters — leaves the reloader in a *loaded* state.
    def restore_admin_routes!
      ApprovalEngine.config.admin_enabled = true
      Rails.application.reload_routes!
      Rails.application.reload_routes_unless_loaded
      admin_track_templates_path
    end

    test "admin routes are not drawn when the admin is disabled" do
      ApprovalEngine.config.admin_enabled = false
      Rails.application.reload_routes!

      # Not "the controller refused" — the route does not exist.
      get "/approval_engine/admin/track_templates"
      assert_response :not_found
      assert_not Engine.routes.url_helpers.respond_to?(:admin_track_templates_path)
    ensure
      restore_admin_routes!
    end

    test "the read-only dashboard is unchanged for a host that never opts in" do
      ApprovalEngine.config.admin_enabled = false
      Rails.application.reload_routes!

      get "/approval_engine/approvals"

      assert_response :success
      # No nav and no flash region — exactly the 1.0 page.
      assert_select "nav.ae-nav", false
      assert_select ".ae-flash", false
      assert_select "header.ae-top .ae-tag", "ops dashboard"
    ensure
      restore_admin_routes!
    end

    test "the admin routes are drawn again once the host opts in" do
      restore_admin_routes!

      get "/approval_engine/admin/track_templates"

      assert_response :success
      assert_select "h1", "Templates"
    end
  end
end
