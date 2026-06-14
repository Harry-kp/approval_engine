module ApprovalEngine
  # The anti-corruption layer. Collects the explicitly whitelisted attributes a
  # host model is willing to expose to the dynamic rules engine, and produces a
  # flat, string-keyed payload from them.
  #
  # The rules engine only ever sees what was declared here — never the raw
  # model — so a SaaS admin's JSON Logic can never reach into unsafe internals.
  #
  #   exposes_for_approval do
  #     attribute :amount, type: :decimal
  #     attribute :department, type: :string, source: ->(invoice) { invoice.department.name }
  #     attribute :is_high_risk, type: :boolean, source: :requires_manual_audit?
  #   end
  class ApprovalExposure
    # A single whitelisted attribute. `source` decides how the value is read:
    #   nil    -> read the attribute/method named `name`
    #   Symbol -> call that method on the record
    #   Proc   -> call it with the record
    Attribute = Struct.new(:name, :type, :source, keyword_init: true) do
      def value_for(record)
        case source
        when nil    then record.public_send(name)
        when Symbol then record.public_send(source)
        when Proc   then source.call(record)
        else source
        end
      end
    end

    attr_reader :attributes

    def initialize
      @attributes = {}
    end

    # Keep dup'd exposures independent so per-class definitions never leak into
    # one another (class_attribute inheritance relies on this).
    def initialize_dup(other)
      super
      @attributes = other.attributes.dup
    end

    def attribute(name, type: :string, source: nil)
      @attributes[name.to_s] = Attribute.new(name: name, type: type, source: source)
    end

    # The flat payload handed to the JSON Logic evaluator.
    def serialize(record)
      @attributes.transform_values { |attr| coerce(attr.value_for(record), attr.type) }
    end

    # A description of the exposed surface — useful for powering a UI rule
    # builder (field names + types).
    def schema
      @attributes.values.map { |attr| { name: attr.name.to_s, type: attr.type } }
    end

    private

    def coerce(value, type)
      return nil if value.nil?

      case type
      when :integer         then value.to_i
      when :decimal, :float then value.to_f
      when :boolean         then ActiveModel::Type::Boolean.new.cast(value)
      when :string          then value.to_s
      else value
      end
    end
  end
end
