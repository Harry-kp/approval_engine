module ApprovalEngine
  # Extended onto ActiveRecord::Base so every model gains the class macro,
  # the way `acts_as_*` gems do. Calling it mixes in the Approvable concern.
  module ModelExtensions
    # Arm a model with approvals.
    #
    #   has_approvals                          # auto-routes on create (default)
    #   has_approvals(on: [:create, :update])  # also route on update
    #   has_approvals(on: [])                  # opt out; trigger manually
    #
    # `on:` accepts any of ApprovalEngine::Approvable::LIFECYCLE_EVENTS
    # (:create, :update, :destroy), routing the conventional "<model>.created" etc.
    # For domain transitions (e.g. "invoice.rejected"), the engine isn't lifecycle
    # bound at all — just call `run_approval!(event:)` from your own action.
    def has_approvals(on: [ :create ])
      include ApprovalEngine::Approvable
      self.approval_trigger_events = Array(on).freeze
    end
  end
end
