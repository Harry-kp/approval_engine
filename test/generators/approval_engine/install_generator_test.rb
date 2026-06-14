require "test_helper"
require "rails/generators/test_case"
require "generators/approval_engine/install/install_generator"

module ApprovalEngine
  class InstallGeneratorTest < Rails::Generators::TestCase
    tests ApprovalEngine::Generators::InstallGenerator
    destination File.expand_path("../../tmp/generator", __dir__)
    setup :prepare_destination

    test "creates a configured initializer" do
      quietly { run_generator }

      assert_file "config/initializers/approval_engine.rb" do |content|
        assert_match(/ApprovalEngine\.configure do \|config\|/, content)
        assert_match(/config\.actor_class = "User"/, content)
        assert_match(/config\.raise_on_rule_errors = false/, content)
      end
    end
  end
end
