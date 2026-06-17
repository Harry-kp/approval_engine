require "test_helper"

module ApprovalEngine
  # Track#layer_tally — the public read the host UI uses to show "N of M
  # approved" and *why* a layer is met/failed/undecided, without re-deriving the
  # consensus math the engine owns. It exposes the same facts advance! decides on.
  class TrackTest < ApprovalEngine::TestCase
    setup do
      @invoice  = Invoice.create!(tenant_id: TENANT, amount: 6000)
      @approval = Approval.create!(tenant_id: TENANT, target: @invoice, status: "pending")
      @track    = @approval.tracks.create!(tenant_id: TENANT, name: "Main")
    end

    # One step per status in a layer, all sharing a consensus spec. Statuses are
    # set directly (not via approve!) so the tally read is exercised in isolation,
    # without advance! cancelling siblings the moment consensus is met.
    def seed_layer(spec, statuses, layer: 1, iteration: 1)
      statuses.each_with_index.map do |status, i|
        @track.steps.create!(
          tenant_id: TENANT, layer: layer, iteration: iteration, status: status,
          approvals_required: spec.to_s,
          assigned_actor: create_user(role: :manager, name: "U#{layer}-#{iteration}-#{i}")
        )
      end
    end

    test "counts approved/pending/rejected against the live group" do
      seed_layer(:all, %w[approved pending pending])

      tally = @track.layer_tally(1)

      assert_equal 3, tally[:required] # all of 3
      assert_equal 1, tally[:approved]
      assert_equal 2, tally[:pending]
      assert_equal 0, tally[:rejected]
      assert_equal 3, tally[:group_size]
      assert_equal :undecided, tally[:outcome]
    end

    test "outcome is :met once required approvals are in" do
      seed_layer(:majority, %w[approved approved pending]) # majority of 3 = 2

      tally = @track.layer_tally(1)
      assert_equal 2, tally[:required]
      assert_equal :met, tally[:outcome]
    end

    test "outcome is :failed once required approvals are unreachable" do
      seed_layer(:all, %w[rejected pending pending]) # all of 3, one no => 3 unreachable

      tally = @track.layer_tally(1)
      assert_equal 1, tally[:rejected]
      assert_equal :failed, tally[:outcome]
    end

    test "cancelled siblings drop out of the group size" do
      seed_layer(:all, %w[approved approved cancelled]) # all of the live 2 => met

      tally = @track.layer_tally(1)
      assert_equal 2, tally[:group_size]
      assert_equal 2, tally[:required]
      assert_equal :met, tally[:outcome]
    end

    test "percentage specs resolve against the group" do
      seed_layer("60%", %w[pending pending pending pending pending]) # ceil(0.6*5) = 3

      assert_equal 3, @track.layer_tally(1)[:required]
    end

    test "an exact count spec resolves to that count" do
      seed_layer("2", %w[approved pending pending])

      tally = @track.layer_tally(1)
      assert_equal 2, tally[:required]
      assert_equal :undecided, tally[:outcome]
    end

    test "an empty layer reads as a zeroed, undecided tally" do
      assert_equal(
        { required: 0, approved: 0, rejected: 0, pending: 0, waiting: 0, group_size: 0, outcome: :undecided },
        @track.layer_tally(99)
      )
    end

    test "a layer that hasn't opened yet reads as undecided, not failed" do
      seed_layer(:all, %w[waiting waiting], layer: 1)

      tally = @track.layer_tally(1)
      assert_equal :undecided, tally[:outcome], "an all-waiting layer is upcoming, not failed"
      assert_equal 2, tally[:waiting]
      assert_equal 0, tally[:approved]
    end

    test "defaults to the track's latest iteration" do
      seed_layer(:any, %w[pending], layer: 1, iteration: 1)
      seed_layer(:all, %w[approved approved], layer: 1, iteration: 2)

      tally = @track.layer_tally(1) # iteration 2 is the latest
      assert_equal 2, tally[:group_size]
      assert_equal :met, tally[:outcome]
    end

    test "an explicit iteration reads that iteration's tally" do
      seed_layer(:any, %w[pending], layer: 1, iteration: 1)
      seed_layer(:all, %w[approved approved], layer: 1, iteration: 2)

      assert_equal :undecided, @track.layer_tally(1, iteration: 1)[:outcome]
    end
  end
end
