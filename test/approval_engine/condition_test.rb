require "test_helper"
require "shiny_json_logic"

module ApprovalEngine
  class ConditionTest < ApprovalEngine::TestCase
    # --- rendering to JSON Logic ------------------------------------------------

    test "renders each scalar operator to its JSON Logic form" do
      {
        eq: "==", not_eq: "!=", gt: ">", gte: ">=", lt: "<", lte: "<="
      }.each do |symbol, operator|
        condition = Condition.new(field: "amount", operator: symbol, value: 10, type: :integer)
        assert_equal({ operator => [ { "var" => "amount" }, 10 ] }, condition.to_json_logic)
      end
    end

    test "renders in as a JSON Logic membership test" do
      condition = Condition.new(field: "region", operator: :in, value: %w[EU UK])
      assert_equal({ "in" => [ { "var" => "region" }, %w[EU UK] ] }, condition.to_json_logic)
    end

    test "renders not_in as a negated membership test" do
      condition = Condition.new(field: "region", operator: :not_in, value: %w[EU])
      assert_equal({ "!" => [ { "in" => [ { "var" => "region" }, %w[EU] ] } ] }, condition.to_json_logic)
    end

    test "ANDs multiple conditions and leaves a lone condition unwrapped" do
      amount = Condition.new(field: "amount", operator: :gt, value: 10, type: :integer)
      region = Condition.new(field: "region", operator: :eq, value: "EU")

      assert_equal amount.to_json_logic, Condition.to_json_logic([ amount ])
      assert_equal({ "and" => [ amount.to_json_logic, region.to_json_logic ] },
                   Condition.to_json_logic([ amount, region ]))
    end

    test "rejects an unknown operator and a blank field" do
      assert_raises(ArgumentError) { Condition.new(field: "amount", operator: :roughly, value: 1) }
      assert_raises(ArgumentError) { Condition.new(field: "", operator: :eq, value: 1) }
      assert_raises(ArgumentError) { Condition.to_json_logic([]) }
    end

    # --- casting ----------------------------------------------------------------
    #
    # Form input arrives as strings. If "10000" were stored verbatim, JSON Logic
    # would compare a number against a string and never match — the single most
    # likely way for a hand-built rule to silently do nothing.

    test "casts form strings using the declared exposure type" do
      assert_equal 10_000, Condition.new(field: "amount", operator: :gt, value: "10000", type: :integer).value
      assert_in_delta 99.5, Condition.new(field: "amount", operator: :gt, value: "99.5", type: :decimal).value
      assert_equal true, Condition.new(field: "urgent", operator: :eq, value: "1", type: :boolean).value
      assert_equal false, Condition.new(field: "urgent", operator: :eq, value: "0", type: :boolean).value
      assert_equal "42", Condition.new(field: "code", operator: :eq, value: 42, type: :string).value
    end

    test "splits a comma separated string into a list for list operators" do
      condition = Condition.new(field: "region", operator: :in, value: "EU, UK , US")
      assert_equal %w[EU UK US], condition.value
    end

    test "casts each member of a list" do
      condition = Condition.new(field: "tier", operator: :in, value: "1,2,3", type: :integer)
      assert_equal [ 1, 2, 3 ], condition.value
    end

    # --- parsing back ------------------------------------------------------------

    test "round-trips every operator" do
      Condition::OPERATORS.each_key do |operator|
        value = Condition::LIST_OPERATORS.include?(operator) ? %w[EU UK] : "EU"
        original = Condition.new(field: "region", operator: operator, value: value)

        parsed = Condition.parse(original.to_json_logic)

        assert_equal [ original ], parsed, "#{operator} did not round-trip"
      end
    end

    test "parses an and of comparisons" do
      ast = { "and" => [
        { ">" => [ { "var" => "amount" }, 10 ] },
        { "==" => [ { "var" => "region" }, "EU" ] }
      ] }

      parsed = Condition.parse(ast)

      assert_equal 2, parsed.size
      assert_equal "amount", parsed.first.field
      assert_equal :gt, parsed.first.operator
      assert_equal :eq, parsed.last.operator
    end

    test "returns nil for conditions the simple form cannot represent" do
      [
        { "or" => [ { "==" => [ { "var" => "a" }, 1 ] } ] },
        { "and" => [ { "or" => [] } ] },
        { "<" => [ 1, { "var" => "amount" }, 10 ] },          # between: three operands
        { "==" => [ { "var" => "a" }, { "var" => "b" } ] },   # var compared to var
        { "some" => [ { "var" => "items" }, {} ] },
        { "==" => [ { "var" => "a" }, 1 ], "extra" => 1 },
        "not a hash",
        nil
      ].each do |ast|
        assert_nil Condition.parse(ast), "expected #{ast.inspect} to be unparseable"
        assert_not Condition.simple?(ast)
      end
    end

    test "simple? is true for what parse round-trips" do
      assert Condition.simple?({ ">" => [ { "var" => "amount" }, 10 ] })
    end

    # --- the `when:` sugar --------------------------------------------------------

    test "builds JSON Logic from the operator hash sugar" do
      assert_equal({ ">" => [ { "var" => "amount" }, 10_000 ] },
                   Condition.from({ amount: { gt: 10_000 } }))
    end

    test "treats a bare value as equality" do
      assert_equal({ "==" => [ { "var" => "status" }, "pending" ] },
                   Condition.from({ status: "pending" }))
    end

    test "ANDs multiple fields in the sugar" do
      ast = Condition.from({ amount: { gt: 10_000 }, region: { in: %w[EU UK] } })

      assert_equal 2, ast["and"].size
      assert_equal({ ">" => [ { "var" => "amount" }, 10_000 ] }, ast["and"].first)
    end

    test "casts sugar values using the supplied exposure types" do
      ast = Condition.from({ amount: { gt: "10000" } }, types: { "amount" => :integer })

      assert_equal({ ">" => [ { "var" => "amount" }, 10_000 ] }, ast)
    end

    test "passes raw JSON Logic straight through" do
      raw = { ">" => [ { "var" => "amount" }, 10_000 ] }
      assert_same raw, Condition.from(raw)

      combined = { "and" => [ raw ] }
      assert_same combined, Condition.from(combined)
    end

    test "rejects a blank clause and an ambiguous multi-operator matcher" do
      assert_raises(ArgumentError) { Condition.from({}) }
      assert_raises(ArgumentError) { Condition.from(nil) }
      assert_raises(ArgumentError) { Condition.from({ amount: { gt: 1, lt: 2 } }) }
    end

    # --- the contract that actually matters ---------------------------------------
    #
    # Everything above is shape. This proves the shapes we emit are the shapes the
    # evaluator agrees with, against the real JSON Logic implementation.

    test "every rendered operator evaluates correctly through the real evaluator" do
      payload = { "amount" => 10_000, "region" => "EU" }

      {
        [ :eq,     "amount", 10_000 ]      => true,
        [ :eq,     "amount", 9_999 ]       => false,
        [ :not_eq, "amount", 9_999 ]       => true,
        [ :gt,     "amount", 9_999 ]       => true,
        [ :gt,     "amount", 10_000 ]      => false,
        [ :gte,    "amount", 10_000 ]      => true,
        [ :lt,     "amount", 10_001 ]      => true,
        [ :lte,    "amount", 10_000 ]      => true,
        [ :in,     "region", %w[EU UK] ]   => true,
        [ :in,     "region", %w[US] ]      => false,
        [ :not_in, "region", %w[US] ]      => true,
        [ :not_in, "region", %w[EU] ]      => false
      }.each do |(operator, field, value), expected|
        ast = Condition.new(field: field, operator: operator, value: value).to_json_logic

        assert_equal expected, ::ShinyJsonLogic.apply(ast, payload),
                     "#{field} #{operator} #{value.inspect} should be #{expected}"
      end
    end

    test "an ANDed condition set evaluates correctly" do
      ast = Condition.from({ amount: { gt: 5_000 }, region: { in: %w[EU UK] } })

      assert ::ShinyJsonLogic.apply(ast, { "amount" => 10_000, "region" => "EU" })
      assert_not ::ShinyJsonLogic.apply(ast, { "amount" => 10_000, "region" => "US" })
      assert_not ::ShinyJsonLogic.apply(ast, { "amount" => 1_000, "region" => "EU" })
    end

    test "a missing payload key is a clean non-match, not an error" do
      ast = Condition.from({ amount: { gt: 5_000 } })

      assert_not ::ShinyJsonLogic.apply(ast, {})
    end
  end
end
