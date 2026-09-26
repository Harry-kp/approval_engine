module ApprovalEngine
  # Validates a row's `approvals_required` against the Consensus vocabulary.
  #
  # Three tables carry the spec — an Approval gathers across tracks, a Step
  # across a layer's actors, and a TemplateStep is the blueprint both are built
  # from — so the check lives here rather than three times over. The message is
  # part of it: an admin who mistypes the spec in the rule builder and a host
  # who mistypes it in the DSL should be told the same thing.
  module ConsensusValidatable
    extend ActiveSupport::Concern

    included do
      validate :approvals_required_is_valid
    end

    private

    def approvals_required_is_valid
      return if Consensus.valid?(approvals_required)

      errors.add(:approvals_required, "must be :any, :all, :majority, a percentage like \"60%\", or a positive integer")
    end
  end
end
