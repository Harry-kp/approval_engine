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

  # Define an approval flow declaratively: the template, its ordered steps, and
  # the rules that route to it, in one block.
  #
  #   ApprovalEngine.define_flow("High-value invoice", tenant: "acme", model: Invoice) do
  #     on :create, when: { amount: { gt: 10_000 } }
  #     step "Manager", group: "manager"
  #     step "CFO",     group: "cfo"
  #   end
  #
  # It writes ordinary TrackTemplate / TemplateStep / TriggerRule rows, so a flow
  # defined here stays editable in the admin UI afterwards — with the caveat that
  # the next run of this block re-asserts everything it declares. A flow is keyed
  # on (tenant, name); code and the UI cannot half-own one.
  #
  # Re-running reconciles the same rows rather than creating a second flow, so it
  # belongs in db/seeds.rb and is safe on every deploy. It is *not* safe in an
  # initializer: it opens a transaction and takes an advisory lock, so it needs a
  # live connection that `rails db:create` and `assets:precompile` don't have.
  #
  # This is developer setup code and must never be handed user input — `when:`
  # accepts raw JSON Logic and stores it verbatim. The vetted path for
  # admin-authored rules is the constrained simple form in ApprovalEngine::Condition.
  #
  # One flow is one template is one track. Scatter-gather across tracks cannot be
  # expressed here because a trigger rule structurally routes to exactly one
  # template; that stays `run_approval!(templates: [...])`.
  #
  # Returns the ApprovalEngine::TrackTemplate.
  def self.define_flow(name, tenant: nil, model: nil, status: "active", timeout_after: nil, &block)
    FlowDefinition.run(
      name: name, tenant: tenant, model: model, status: status, timeout_after: timeout_after, &block
    )
  end

  # The template a define_flow call owns, for handing to run_approval!(templates:)
  # when several flows should run as parallel tracks of one approval. Returns nil
  # when nothing is defined under that name.
  def self.flow(name, tenant:)
    TrackTemplate.for_tenant(FlowDefinition.tenant_id_for(tenant)).find_by(name: name)
  end

  class << self
    # Every model that has called `has_approvals`, by name. Names, not
    # constants, so the engine never pins a class the development reloader
    # will throw away — the same reason `config.actor_class` is a String.
    def register_approvable(model_name)
      approvable_model_names << model_name.to_s
    end

    def approvable_model_names
      @approvable_model_names ||= Set.new
    end

    # The registered models, resolved fresh each call. A name that no longer
    # resolves (a model deleted since boot) is dropped rather than raising.
    def approvable_models
      approvable_model_names.filter_map { |model_name| model_name.safe_constantize }
    end
  end
end
