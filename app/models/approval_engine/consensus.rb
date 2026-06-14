module ApprovalEngine
  # Value object for a layer's consensus condition. It parses the declarative
  # `approvals_required` spec and computes how many approvals a group of a given
  # size needs:
  #
  #   :any       -> 1
  #   :all       -> everyone in the group
  #   :majority  -> more than half
  #   "60%"      -> that proportion of the group (at least 1)
  #   2          -> an exact count
  #
  # Relative specs are resolved against the *live* group, so authors never have
  # to know team sizes — "majority of whoever is on the team" just works, and
  # adapts as members are added or drop out.
  class Consensus
    FORMAT = /\A([1-9][0-9]*%?|any|all|majority)\z/

    def self.valid?(spec)
      FORMAT.match?(spec.to_s)
    end

    def initialize(spec)
      @spec = spec.to_s
    end

    # How many approvals are needed out of a group of `group_size`.
    def required(group_size)
      case @spec
      when "any"      then 1
      when "all"      then group_size
      when "majority" then (group_size / 2) + 1
      when /%\z/      then [ (group_size * @spec.to_i / 100.0).ceil, 1 ].max
      else @spec.to_i
      end
    end
  end
end
