module ApprovalEngine
  # An append-only record of a single ledger event. Audit rows are write-once:
  # they capture the *intended* actor (who the step was assigned to) alongside
  # the *actual* actor (who acted, possibly a delegate), giving compliance teams
  # a tamper-evident trail of every decision.
  class AuditLog < ApplicationRecord
    belongs_to :step, class_name: "ApprovalEngine::Step", foreign_key: "approval_engine_step_id"
    belongs_to :intended_actor, polymorphic: true, optional: true
    # Optional: a system event (e.g. `timed_out`/`expired`) has no human actor.
    belongs_to :actual_actor, polymorphic: true, optional: true

    validates :tenant_id, :event, presence: true

    scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }
    scope :recent, -> { order(created_at: :desc) }

    # True when the acting actor differed from the assigned one — i.e. a
    # delegate approved on someone's behalf. A system event (no actual actor) is
    # never a proxy.
    def by_proxy?
      actual_actor_id.present? && intended_actor_id.present? && intended_actor != actual_actor
    end

    # The ledger never rewrites history.
    def readonly?
      persisted?
    end
  end
end
