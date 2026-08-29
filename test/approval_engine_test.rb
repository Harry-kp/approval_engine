require "test_helper"

class ApprovalEngineTest < ActiveSupport::TestCase
  test "it has a version number" do
    assert ApprovalEngine::VERSION
  end

  test "has_approvals registers the model for the admin" do
    assert_includes ApprovalEngine.approvable_models, Invoice
  end

  test "a name that no longer resolves is dropped" do
    ApprovalEngine.register_approvable("GoneModel")

    assert_not_includes ApprovalEngine.approvable_models.map(&:name), "GoneModel"
  ensure
    ApprovalEngine.approvable_model_names.delete("GoneModel")
  end
end

module ApprovalEngine
  class AdminConfigurationTest < ApprovalEngine::TestCase
    # The single most important default in this release: 1.0 hosts mounted a
    # read-only dashboard, and `bundle update` must never hand them a write
    # surface.
    test "the admin is off by default" do
      assert_equal false, ApprovalEngine::Configuration.new.admin_enabled
    end
  end
end
