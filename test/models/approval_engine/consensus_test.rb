require "test_helper"

module ApprovalEngine
  class ConsensusTest < ApprovalEngine::TestCase
    test "resolves relative specs against the live group size" do
      assert_equal 1, Consensus.new(:any).required(5)
      assert_equal 5, Consensus.new(:all).required(5)
      assert_equal 3, Consensus.new(:majority).required(5), "majority of 5 is 3"
      assert_equal 3, Consensus.new(:majority).required(4), "majority of 4 is 3, not 2"
    end

    test "resolves a percentage by rounding up, never below one" do
      assert_equal 3, Consensus.new("60%").required(5), "ceil(3.0) is 3"
      assert_equal 2, Consensus.new("25%").required(5), "ceil(1.25) is 2"
      assert_equal 1, Consensus.new("1%").required(5), "always at least one"
    end

    test "resolves an absolute count verbatim, ignoring group size" do
      assert_equal 2, Consensus.new(2).required(5)
      assert_equal 2, Consensus.new("2").required(5)
    end

    test "validates the accepted vocabulary" do
      %i[any all majority].each { |spec| assert Consensus.valid?(spec) }
      assert Consensus.valid?("60%")
      assert Consensus.valid?(2)

      assert_not Consensus.valid?("two-thirds")
      assert_not Consensus.valid?("0")
      assert_not Consensus.valid?(nil)
    end
  end
end
