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

    # The live consensus tally for one layer (within an iteration) — the same
    # facts `advance!` decides on, exposed as a read so a host UI can show
    # "N of M approved" and *why* a layer is met/failed/undecided without
    # re-deriving the consensus math (which only the engine should own).
    #
    #   track.layer_tally(1)
    #   # => { required: 2, approved: 1, rejected: 0, pending: 2, waiting: 0,
    #   #      group_size: 3, outcome: :undecided }
    #
    # Defaults to the track's latest iteration. A layer that hasn't opened yet
    # (all steps still `waiting`) reads as `:undecided`, not `:failed`. Returns a
    # zeroed `:undecided` tally for a layer that has no steps.
    def layer_tally(layer, iteration: steps.maximum(:iteration))
      tally_for(steps.for_iteration(iteration).for_layer(layer))
    end

    private

    # :met, :failed, or :undecided for a layer — just the verdict slice of the
    # full tally. Both approve! and reject! funnel through advance! → here, so
    # rejection respects the layer's consensus policy instead of being a veto.
    def layer_outcome(layer_steps)
      tally_for(layer_steps)[:outcome]
    end

    # Met once `required` approvals are in; failed only once unreachable — even
    # the steps still to come (pending + not-yet-opened `waiting`) couldn't reach
    # it. advance! only sees the active layer, where waiting is 0, so it's unchanged.
    def tally_for(layer_steps)
      spec = layer_steps.first&.approvals_required
      return { required: 0, approved: 0, rejected: 0, pending: 0, waiting: 0, group_size: 0, outcome: :undecided } if spec.nil?

      approved = layer_steps.approved.count
      pending  = layer_steps.pending.count
      waiting  = layer_steps.waiting.count
      rejected = layer_steps.where(status: "rejected").count
      group    = layer_steps.where.not(status: "cancelled").count
      required = Consensus.new(spec).required(group)

      outcome =
        if approved >= required then :met
        elsif (approved + pending + waiting) < required then :failed
        else :undecided
        end

      { required: required, approved: approved, rejected: rejected, pending: pending, waiting: waiting, group_size: group, outcome: outcome }
    end

    # This track can't reach consensus: reject it, then let the approval
    # re-gather (one rejected track no longer forces the whole approval down).
    def fail!
      update!(status: "rejected")
      cancel_open_steps!
      approval.gather!
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
      approval.gather!
    end

    def cancel_open_steps!
      cancel_steps(steps.where(status: OPEN_STEP_STATUSES))
    end

    def cancel_steps(relation)
      relation.find_each { |s| s.update!(status: "cancelled") }
    end
  end
end
