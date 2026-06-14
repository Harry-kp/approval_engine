require "test_helper"
require "rails/generators/test_case"
require "generators/approval_engine/views/views_generator"

module ApprovalEngine
  class ViewsGeneratorTest < Rails::Generators::TestCase
    tests ApprovalEngine::Generators::ViewsGenerator
    destination File.expand_path("../../tmp/generator", __dir__)
    setup :prepare_destination

    test "copies the controller and views into the host app" do
      run_generator

      assert_file "app/controllers/approvals_controller.rb" do |content|
        assert_match(/class ApprovalsController/, content)
        assert_match(/step\.public_send\(method, by: current_user/, content)
      end
      assert_file "app/views/approvals/index.html.erb" do |content|
        assert_match(/My approvals/, content)
        assert_match(/approve_approval_path/, content)
      end
    end
  end
end
