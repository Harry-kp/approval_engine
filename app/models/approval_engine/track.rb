module ApprovalEngine
  # One track of an approval (e.g. "Finance" or "Legal"). A track holds
  # ordered layers of steps; a layer resolves once its consensus policy is met,
  # which activates the next layer or completes the track.
  #
  # All progression happens synchronously inside the acting step's lock, so a
  # track is never observed in a half-advanced state.
  class Track < ApplicationRecord
    STATUSES = %w[pending approved rejected cancelled].freeze
    OPEN_STEP_STATUSES = %w[waiting pending].freeze

    belongs_to :approval, class_name: "ApprovalEngine::Approval", foreign_key: "approval_engine_approval_id"
    has_many :steps, class_name: "ApprovalEngine::Step", foreign_key: "approval_engine_track_id", dependent: :destroy

    validates :tenant_id, :name, presence: true
    validates :status, inclusion: { in: STATUSES }

    scope :pending, -> { where(status: "pending") }
    scope :approved, -> { where(status: "approved") }

    STATUSES.each do |state|
      define_method(:"#{state}?") { status == state }
    end

    # A step was approved or rejected: re-evaluate its layer and short-circuit.
    # The layer resolves the moment its consensus is *met*, fails the moment its
    # consensus is *unreachable*, and otherwise waits for more votes. Both
    # approve! and reject! funnel through here so rejection respects the layer's
    # consensus policy instead of being a blanket veto.
    def advance!(step)
      layer_steps = steps.for_iteration(step.iteration).for_layer(step.layer)

      case layer_outcome(layer_steps)
      when :met
        cancel_steps(layer_steps.pending) # remaining votes are no longer needed
        activate_next_layer(step) || complete!
      when :failed
        fail!
      end
    end

    # An approver requested changes: cancel this iteration's open work and
    # append a fresh iteration. The track stays pending.
    def advance_after_changes_requested!(step)
      cancel_open_steps!
      IterationBuilder.build_next_iteration!(step)
    end

    private

    # :met, :failed, or :undecided for a layer. The layer needs `required`
    # approvals, computed from its `approvals_required` spec against the live
    # group size (non-cancelled steps). It's met once enough have approved, and
    # failed once even all the still-pending steps couldn't reach `required`.
    def layer_outcome(layer_steps)
      spec = layer_steps.first&.approvals_required
      return :undecided if spec.nil?

      approved = layer_steps.approved.count
      pending  = layer_steps.pending.count
      group    = layer_steps.where.not(status: "cancelled").count
      required = Consensus.new(spec).required(group)

      return :met if approved >= required
      return :failed if (approved + pending) < required

      :undecided
    end

    # Consensus can no longer be reached: tear the track (and approval) down.
    def fail!
      update!(status: "rejected")
      cancel_open_steps!
      approval.reject!(reason: "Track '#{name}' did not reach consensus")
    end

    # Activate the next *existing* layer above this one — not blindly layer + 1 —
    # so non-contiguous layer numbers (1, 3, 5…) don't strand a waiting layer or
    # complete the track prematurely.
    def activate_next_layer(step)
      scope = steps.for_iteration(step.iteration).waiting.where("layer > ?", step.layer)
      next_layer = scope.minimum(:layer)
      return false unless next_layer

      scope.where(layer: next_layer).find_each { |s| s.update!(status: "pending") }
      true
    end

    def complete!
      update!(status: "approved")
      approval.try_complete!
    end

    def cancel_open_steps!
      cancel_steps(steps.where(status: OPEN_STEP_STATUSES))
    end

    def cancel_steps(relation)
      relation.find_each { |s| s.update!(status: "cancelled") }
    end
  end
end
