require "test_helper"

module ApprovalEngine
  class IterationBuilderTest < ApprovalEngine::TestCase
    setup do
      @manager = create_user(role: :manager)
      @cfo = create_user(role: :cfo)
      approval = Approval.create!(tenant_id: TENANT, target: Invoice.create!(tenant_id: TENANT), status: "pending")
      @track = Track.create!(tenant_id: TENANT, approval: approval, name: "Main")
      @layer1 = @track.steps.create!(tenant_id: TENANT, name: "Manager", layer: 1, status: "approved", assigned_actor: @manager)
      @layer2 = @track.steps.create!(tenant_id: TENANT, name: "CFO", layer: 2, status: "changes_requested", assigned_actor: @cfo)
    end

    test "clones the whole iteration into a fresh cycle with layer 1 reactivated" do
      assert_difference -> { @track.steps.where(iteration: 2).count } => 2 do
        IterationBuilder.build_next_iteration!(@layer2)
      end

      fresh = @track.steps.where(iteration: 2).order(:layer)
      assert_equal %w[pending waiting], fresh.pluck(:status)
      assert_equal [ @manager, @cfo ], fresh.map(&:assigned_actor)
      assert_equal %w[Manager CFO], fresh.pluck(:name)
    end

    test "the original iteration is left untouched" do
      IterationBuilder.build_next_iteration!(@layer2)

      assert_equal "approved", @layer1.reload.status
      assert_equal "changes_requested", @layer2.reload.status
    end
  end
end
