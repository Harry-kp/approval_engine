require "test_helper"

module ApprovalEngine
  class DelegationTest < ApprovalEngine::TestCase
    setup do
      @alice = create_user(role: :manager, name: "Alice")
      @bob   = create_user(role: :manager, name: "Bob")
    end

    test "active_for returns only currently-effective delegations" do
      current = Delegation.create!(tenant_id: TENANT, delegator: @alice, delegatee: @bob,
                                   starts_at: 1.day.ago, ends_at: 1.day.from_now)
      Delegation.create!(tenant_id: TENANT, delegator: @alice, delegatee: @bob,
                         starts_at: 10.days.ago, ends_at: 5.days.ago) # expired

      active = Delegation.active_for(@alice, tenant_id: TENANT)

      assert_equal [ current.id ], active.pluck(:id)
    end

    test "a deactivated lease is not in effect" do
      Delegation.create!(tenant_id: TENANT, delegator: @alice, delegatee: @bob,
                         starts_at: 1.day.ago, ends_at: 1.day.from_now, active: false)

      assert_empty Delegation.active_for(@alice, tenant_id: TENANT)
    end

    test "rejects an end date that precedes the start" do
      delegation = Delegation.new(tenant_id: TENANT, delegator: @alice, delegatee: @bob,
                                  starts_at: 1.day.from_now, ends_at: 1.day.ago)

      assert_not delegation.valid?
      assert_includes delegation.errors[:ends_at], "must be after starts_at"
    end
  end
end
