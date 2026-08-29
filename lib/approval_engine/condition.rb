module ApprovalEngine
  # Translates a field/operator/value triple to and from the JSON Logic AST
  # stored in `TriggerRule#condition`. JSON Logic is the right storage format and
  # the wrong authoring format — nobody hand-writes an AST in a form field.
  #
  # Honest about its limits: anything it cannot represent parses back as `nil`,
  # which tells the admin UI to fall back to a raw-JSON editor rather than
  # silently mangle a hand-written rule.
  #
  #   Condition.new(field: "amount", operator: :gt, value: 10_000).to_json_logic
  #   # => { ">" => [{ "var" => "amount" }, 10_000] }
  class Condition
    # `:not_in` is `in` wrapped in a negation, so it maps to nil and is
    # special-cased both ways.
    OPERATORS = {
      eq: "==",
      not_eq: "!=",
      gt: ">",
      gte: ">=",
      lt: "<",
      lte: "<=",
      in: "in",
      not_in: nil
    }.freeze

    # Operators whose value is a list rather than a scalar.
    LIST_OPERATORS = %i[in not_in].freeze

    # For the operator dropdown, in display order.
    LABELS = {
      eq: "is equal to",
      not_eq: "is not equal to",
      gt: "is greater than",
      gte: "is greater than or equal to",
      lt: "is less than",
      lte: "is less than or equal to",
      in: "is one of",
      not_in: "is not one of"
    }.freeze

    attr_reader :field, :operator, :value

    # `type` mirrors the `exposes_for_approval` types, so form input of "10000"
    # is stored as 10_000 — otherwise JSON Logic compares a string to a number
    # and never matches. nil means "leave it alone", for values written in code.
    def initialize(field:, operator:, value:, type: nil)
      @field    = field.to_s
      @operator = operator.to_sym
      @type     = type&.to_sym
      @value    = cast(value)

      raise ArgumentError, "unknown operator #{@operator.inspect}" unless OPERATORS.key?(@operator)
      raise ArgumentError, "field can't be blank" if @field.empty?
    end

    def list?
      LIST_OPERATORS.include?(operator)
    end

    def to_json_logic
      comparison = { OPERATORS[list_base_operator] => [ { "var" => field }, value ] }
      operator == :not_in ? { "!" => [ comparison ] } : comparison
    end

    def ==(other)
      other.is_a?(Condition) &&
        other.field == field && other.operator == operator && other.value == value
    end
    alias eql? ==

    def hash
      [ field, operator, value ].hash
    end

    class << self
      # Reads a stored AST back into Conditions. Returns nil — not [] — when the
      # AST is anything this class cannot represent, so callers can tell "no
      # conditions" from "too complex to show". Accepts one comparison or an
      # `and` of them; anything else is nil.
      def parse(json_logic)
        return nil unless json_logic.is_a?(Hash) && json_logic.size == 1

        operator, operand = json_logic.first
        return parse_conjunction(operand) if operator == "and"

        single = parse_comparison(json_logic)
        single ? [ single ] : nil
      end

      # True when the simple form can edit this AST without losing anything.
      def simple?(json_logic)
        !parse(json_logic).nil?
      end

      # Multiple conditions are ANDed — the only combinator the simple form
      # offers. An OR builder is a much larger UI; raw JSON Logic covers it.
      def to_json_logic(conditions)
        conditions = Array(conditions)
        raise ArgumentError, "no conditions given" if conditions.empty?
        return conditions.first.to_json_logic if conditions.one?

        { "and" => conditions.map(&:to_json_logic) }
      end

      # The DSL's `when:` sugar. A bare value means :eq; raw JSON Logic passes
      # straight through. `types` maps field to exposure type for casting.
      #
      #   when: { amount: { gt: 10_000 }, region: { in: %w[EU UK] } }
      def from(clause, types: {})
        raise ArgumentError, "condition can't be blank" if clause.blank?
        return clause if raw_json_logic?(clause)

        conditions = clause.map do |field, matcher|
          type = types[field.to_s] || types[field.to_sym]

          case matcher
          when Hash
            raise ArgumentError, "#{field}: expected exactly one operator, got #{matcher.keys.inspect}" unless matcher.size == 1

            operator, value = matcher.first
            new(field: field, operator: operator, value: value, type: type)
          else
            new(field: field, operator: :eq, value: matcher, type: type)
          end
        end

        to_json_logic(conditions)
      end

      private

      # Already JSON Logic when its only key is an operator, never a field name.
      def raw_json_logic?(clause)
        return false unless clause.is_a?(Hash) && clause.size == 1

        key = clause.keys.first.to_s
        key == "and" || key == "or" || key == "!" || OPERATORS.value?(key)
      end

      def parse_conjunction(operand)
        return nil unless operand.is_a?(Array) && operand.any?

        parsed = operand.map { |clause| parse_comparison(clause) }
        parsed.all? ? parsed : nil
      end

      # One comparison, or a negated `in`.
      def parse_comparison(clause)
        return nil unless clause.is_a?(Hash) && clause.size == 1

        operator, operand = clause.first
        return parse_negation(operand) if operator == "!"
        return nil unless operand.is_a?(Array) && operand.size == 2

        symbol = OPERATORS.key(operator)
        return nil unless symbol

        variable, value = operand
        return nil unless variable.is_a?(Hash) && variable.keys == [ "var" ]
        return nil if value.is_a?(Hash) # a comparison against another var is not simple

        # JSON Logic overloads `in`: Array is membership, String is substring.
        # The simple form only speaks membership, so a substring rule is too
        # complex rather than silently re-saved with different semantics.
        return nil if symbol == :in && !value.is_a?(Array)

        new(field: variable["var"], operator: symbol, value: value)
      end

      def parse_negation(operand)
        inner = operand.is_a?(Array) ? operand.first : operand
        parsed = parse_comparison(inner)
        return nil unless parsed && parsed.operator == :in

        new(field: parsed.field, operator: :not_in, value: parsed.value)
      end
    end

    private

    # `:not_in` is stored as a negated `in`.
    def list_base_operator
      operator == :not_in ? :in : operator
    end

    def cast(raw)
      return cast_list(raw) if list?

      cast_scalar(raw)
    end

    def cast_list(raw)
      # A form submits "EU, UK"; code passes an array.
      list = raw.is_a?(String) ? raw.split(",").map(&:strip).reject(&:empty?) : Array(raw)
      list.map { |item| cast_scalar(item) }
    end

    def cast_scalar(raw)
      return nil if raw.nil?

      case @type
      when nil              then raw
      when :integer         then raw.to_i
      when :decimal, :float then raw.to_f
      when :boolean         then ActiveModel::Type::Boolean.new.cast(raw)
      when :string          then raw.to_s
      else raw
      end
    end
  end
end
