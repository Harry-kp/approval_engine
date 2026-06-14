module ApprovalEngine
  # Implements the append-only iteration cycle. Rather than resetting an approved
  # step back to pending (which would destroy the audit trail), requesting
  # changes clones the track's current iteration into a fresh one, so every
  # past attempt remains permanently on the ledger.
  #
  # Always invoked while the approval is locked, so it does not lock again.
  class IterationBuilder
    def self.build_next_iteration!(from_step)
      new(from_step).build!
    end

    def initialize(from_step)
      @from_step = from_step
      @track  = from_step.track
    end

    def build!
      blueprint = track.steps.for_iteration(from_step.iteration).order(:layer, :created_at).to_a
      first_layer = blueprint.map(&:layer).min

      blueprint.each do |old_step|
        track.steps.create!(
          tenant_id: old_step.tenant_id,
          name: old_step.name,
          layer: old_step.layer,
          iteration: next_iteration,
          status: old_step.layer == first_layer ? "pending" : "waiting",
          approvals_required: old_step.approvals_required,
          timeout_after: old_step.timeout_after,
          assigned_actor: old_step.assigned_actor
        )
      end
    end

    private

    attr_reader :from_step, :track

    def next_iteration
      @next_iteration ||= from_step.iteration + 1
    end
  end
end
