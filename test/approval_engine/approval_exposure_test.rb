require "test_helper"

module ApprovalEngine
  class ApprovalExposureTest < ActiveSupport::TestCase
    Sample = Struct.new(:amount, :department, :flag, keyword_init: true) do
      def risky? = flag
    end

    def build(&block)
      ApprovalExposure.new.tap { |e| e.instance_eval(&block) }
    end

    test "reads attributes by name and coerces by declared type" do
      exposure = build do
        attribute :amount, type: :decimal
        attribute :department, type: :string
      end

      payload = exposure.serialize(Sample.new(amount: 6000, department: :IT, flag: false))

      assert_equal 6000.0, payload["amount"]
      assert_equal "IT", payload["department"]
    end

    test "resolves a symbol source as a method call" do
      exposure = build { attribute :is_risky, type: :boolean, source: :risky? }

      assert_equal true, exposure.serialize(Sample.new(flag: true)).fetch("is_risky")
    end

    test "resolves a proc source with the record" do
      exposure = build { attribute :double, type: :integer, source: ->(r) { r.amount * 2 } }

      assert_equal 200, exposure.serialize(Sample.new(amount: 100)).fetch("double")
    end

    test "exposes a schema for UI rule builders" do
      exposure = build do
        attribute :amount, type: :decimal
        attribute :department, type: :string
      end

      assert_equal(
        [ { name: "amount", type: :decimal }, { name: "department", type: :string } ],
        exposure.schema
      )
    end

    test "dup keeps attribute sets independent" do
      base = build { attribute :amount, type: :decimal }
      extended = base.dup
      extended.attribute(:department, type: :string)

      assert_equal %w[amount], base.attributes.keys
      assert_equal %w[amount department], extended.attributes.keys
    end
  end
end
