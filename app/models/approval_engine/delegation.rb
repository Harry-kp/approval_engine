module ApprovalEngine
  # A time-bound proxy lease: while it is active, the delegatee may act on steps
  # assigned to the delegator (e.g. covering approvals during a vacation). The
  # ledger still records the delegator as the *intended* actor and the delegatee
  # as the *actual* actor, so the proxy is always visible in the audit trail.
  class Delegation < ApplicationRecord
    belongs_to :delegator, polymorphic: true
    belongs_to :delegatee, polymorphic: true

    validates :tenant_id, presence: true
    validates :starts_at, :ends_at, presence: true
    validate :ends_after_start

    scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }

    # Currently-effective delegations as of `at` (defaults to now).
    scope :in_effect, ->(at = Time.current) { where(active: true).where(starts_at: ..at).where(ends_at: at..) }

    # Active delegations *from* a given delegator, optionally tenant-scoped.
    def self.active_for(delegator, tenant_id: nil, at: Time.current)
      scope = in_effect(at).where(delegator: delegator)
      tenant_id ? scope.for_tenant(tenant_id) : scope
    end

    private

    def ends_after_start
      return if starts_at.blank? || ends_at.blank?
      return if ends_at > starts_at

      errors.add(:ends_at, "must be after starts_at")
    end
  end
end
