require "set"

require "approval_engine/version"
require "approval_engine/configuration"
require "approval_engine/approval_exposure"
require "approval_engine/condition"
require "approval_engine/model_extensions"
require "approval_engine/engine"

module ApprovalEngine
  # Base class for every error the engine raises itself, so a host can rescue
  # ApprovalEngine::Error to catch them all. (Step transitions still raise the
  # Rails-idiomatic ActiveRecord::RecordInvalid.)
  class Error < StandardError; end

  # Define a flow — template, steps and routing rules — in one block.
  #
  #   ApprovalEngine.define_flow("High-value invoice", tenant: "acme", model: Invoice) do
  #     on :create, when: { amount: { gt: 10_000 } }
  #     step "Manager", group: "manager"
  #     step "CFO",     group: "cfo"
  #   end
  #
  # Writes ordinary rows, so the admin UI can still edit them — though the next
  # run re-asserts everything the block declares. Keyed on (tenant, name).
  #
  # Reconciles rather than inserts, so it belongs in db/seeds.rb and is safe on
  # every deploy. Not safe in an initializer: it needs a live connection.
  #
  # Developer setup code — never hand it user input; `when:` stores raw JSON
  # Logic verbatim. Admin-authored rules go through Condition's simple form.
  #
  # One flow is one template is one track; scatter-gather stays
  # `run_approval!(templates: [...])`. Returns the TrackTemplate.
  def self.define_flow(name, tenant: nil, model: nil, status: "active", timeout_after: nil, &block)
    FlowDefinition.run(
      name: name, tenant: tenant, model: model, status: status, timeout_after: timeout_after, &block
    )
  end

  # The template a define_flow call owns, for run_approval!(templates:) when
  # several flows run as parallel tracks. nil when nothing is defined.
  def self.flow(name, tenant:)
    TrackTemplate.for_tenant(FlowDefinition.tenant_id_for(tenant)).find_by(name: name)
  end

  class << self
    # Names, not constants, so the reloader is never pinned — as actor_class.
    def register_approvable(model_name)
      approvable_model_names << model_name.to_s
    end

    def approvable_model_names
      @approvable_model_names ||= Set.new
    end

    # Resolved fresh each call; a name that no longer resolves is dropped.
    def approvable_models
      approvable_model_names.filter_map { |model_name| model_name.safe_constantize }
    end
  end
end
