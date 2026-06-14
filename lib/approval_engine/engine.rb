module ApprovalEngine
  class Engine < ::Rails::Engine
    isolate_namespace ApprovalEngine

    # Make `has_approvals` available on every ActiveRecord model.
    initializer "approval_engine.model_extensions" do
      ActiveSupport.on_load(:active_record) do
        extend ApprovalEngine::ModelExtensions
      end
    end

    # Keep the engine's own tests/factories from bleeding into a host app.
    config.generators do |g|
      g.test_framework :test_unit, fixture: false
    end
  end
end
