module ApprovalEngine
  # A single field/operator/value comparison, and the translation layer between
  # that triple and the JSON Logic AST stored in `TriggerRule#condition`.
  #
  # JSON Logic is the right *storage* format — it is portable, safe to evaluate,
  # and expressive enough for the rules people actually write. It is the wrong
  # *authoring* format for a human: nobody should have to hand-write
  # `{ ">" => [{ "var" => "amount" }, 10_000] }` in a form field or a seed file.
  #
  # So this class is the seam. It renders the common shapes down to JSON Logic
  # and reads them back up, and it is deliberately honest about its limits: a
  # condition it cannot represent round-trips as `nil` from `.parse`, which is
  # the signal for the admin UI to fall back to a raw-JSON textarea rather than
  # silently mangle a rule someone wrote by hand.
  #
  #   Condition.new(field: "amount", operator: :gt, value: 10_000).to_json_logic
  #   # => { ">" => [{ "var" => "amount" }, 10_000] }
  #
  #   Condition.parse({ ">" => [{ "var" => "amount" }, 10_000] })
  #   # => [#<Condition field="amount" operator=:gt value=10000>]
  #
  #   Condition.parse({ "some" => [...] })   # too complex for the simple form
  #   # => nil
  class Condition
    # Operators the simple form can express, mapped to their JSON Logic operator.
    # `:not_in` has no direct operator — it is `in` wrapped in a negation — so it
    # maps to nil and is special-cased on the way in and out.
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

    # Human labels for the operator dropdown, in the order they should appear.
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

    # `type` mirrors the `exposes_for_approval` attribute types, so a value that
    # arrives from an HTML form as the string "10000" is stored as the number
    # 10_000 — otherwise JSON Logic would compare a number against a string and
    # quietly never match. It defaults to nil, meaning "already the right type,
    # leave it alone": code passing a literal 10_000 must not have it stringified.
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
      # Reads a stored JSON Logic AST back into an array of Conditions, so an
      # existing rule can be re-opened in the simple form. Returns nil — not an
      # empty array — when the AST is anything this class cannot represent, so
      # callers can tell "no conditions" from "too complex to show".
      #
      # Accepts a single comparison or an `and` of comparisons; an `or`, a
      # nested `and`, arithmetic, or any unrecognised operator returns nil.
      def parse(json_logic)
        return nil unless json_logic.is_a?(Hash) && json_logic.size == 1

        operator, operand = json_logic.first
        return parse_conjunction(operand) if operator == "and"

        single = parse_comparison(json_logic)
        single ? [ single ] : nil
      end

      # True when `parse` can round-trip this AST — i.e. the simple form can edit
      # it without losing anything.
      def simple?(json_logic)
        !parse(json_logic).nil?
      end

      # Renders one or more Conditions to a single stored AST. Multiple
      # conditions are ANDed; that is the only combinator the simple form offers,
      # because an OR builder is a materially different (and much larger) UI and
      # raw JSON Logic remains available for it.
      def to_json_logic(conditions)
        conditions = Array(conditions)
        raise ArgumentError, "no conditions given" if conditions.empty?
        return conditions.first.to_json_logic if conditions.one?

        { "and" => conditions.map(&:to_json_logic) }
      end

      # Builds conditions from the DSL's `when:` sugar, so a flow definition can
      # say what it means:
      #
      #   when: { amount: { gt: 10_000 } }
      #   when: { amount: { gt: 10_000 }, region: { in: %w[EU UK] } }
      #   when: { status: "pending" }                  # bare value means :eq
      #   when: { ">" => [{ "var" => "amount" }, 1] }  # raw JSON Logic, passed through
      #
      # `types` maps field name to its declared exposure type so values cast the
      # same way the payload does.
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

      # A clause is already JSON Logic when its first key is an operator we would
      # never accept as a field name. This keeps `from` usable as a single door
      # for both the sugar and hand-written ASTs.
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

      # One comparison, or a negated `in`. Returns nil for anything else.
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

        # JSON Logic overloads `in`: an Array operand is membership, a String
        # operand is a substring test. The simple form only speaks membership,
        # so a hand-written substring rule is reported as too complex rather
        # than being read in and saved back out with different semantics.
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

    # `:not_in` is stored as a negated `in`, so it borrows `in`'s operator.
    def list_base_operator
      operator == :not_in ? :in : operator
    end

    def cast(raw)
      return cast_list(raw) if list?

      cast_scalar(raw)
    end

    def cast_list(raw)
      # A form submits "EU, UK" for a list; code passes an actual array.
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
