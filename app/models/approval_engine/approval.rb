module ApprovalEngine
  # The aggregate root of one approval run: a host record + the event that
  # spawned it, fanning out into one or more parallel tracks.
  #
  # The gather is consensus-aware: `approvals_required` says how many of the
  # tracks must approve (`:all` by default — unanimity — but also `:any`,
  # `:majority`, a percentage, or a fixed count, exactly like a layer). The
  # approval approves once enough tracks have, and fails only once enough have
  # hard-rejected that the target is unreachable — so one track saying no doesn't
  # veto a "2 of 3 departments" gather. Progression methods here are always
  # invoked while the approval row is locked by the acting step's transition, so
  # they do not lock again themselves.
  class Approval < ApplicationRecord
    STATUSES = %w[pending approved rejected quarantined cancelled].freeze
    TERMINAL_STATUSES = %w[approved rejected quarantined cancelled].freeze

    belongs_to :target, polymorphic: true
    # The rule that auto-routed this approval, when one did (nil for a manual
    # run_approval!(templates:) start). Lets a host show *which* rule fired and
    # why, and keeps that provenance stable even if the rule is later edited.
    belongs_to :trigger_rule,
               class_name: "ApprovalEngine::TriggerRule",
               foreign_key: "approval_engine_trigger_rule_id",
               optional: true
    has_many :tracks, class_name: "ApprovalEngine::Track", foreign_key: "approval_engine_approval_id", dependent: :destroy
    has_many :steps, through: :tracks

    validates :tenant_id, presence: true
    validates :status, inclusion: { in: STATUSES }
    validate :approvals_required_is_valid

    scope :pending, -> { where(status: "pending") }
    scope :quarantined, -> { where(status: "quarantined") }
    scope :terminal, -> { where(status: TERMINAL_STATUSES) }
    scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }

    STATUSES.each do |state|
      define_method(:"#{state}?") { status == state }
    end

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    # Convenience readers for the common single-track case. An approval always
    # has at least one track, so when there's exactly one these read more
    # naturally than `tracks.first`. They raise (ActiveRecord::SoleRecord
    # exceeded) once the approval has fanned out, so a caller is never silently
    # handed the wrong track — reach for `tracks` / `steps` then.
    def track
      tracks.sole
    end

    def step
      steps.sole
    end

    # The step this approval is currently waiting on the longest — i.e. *where*
    # it's stuck right now. The oldest still-pending step across all tracks, or
    # nil if nothing is pending. `step.waiting_for` gives the elapsed seconds; the
    # host decides what counts as "late" and whether to nudge or escalate.
    def current_bottleneck
      steps.pending.order(:activated_at).first
    end

    # Re-evaluate the gather after any track reaches a terminal outcome (a track
    # approving via `complete!` or hard-rejecting via `fail!`). Approves once
    # enough tracks have approved, fails once the required count is unreachable,
    # and otherwise waits — the same met/failed/undecided logic a layer uses for
    # its steps, applied across tracks. A no-op until something is decided.
    def gather!
      return if terminal?

      case track_outcome
      when :met
        update!(status: "approved")
        cancel_remaining_tracks!
        emit_outbox("approval.approved")
      when :failed
        reject!(reason: "required track approvals are no longer reachable")
      end
    end

    # Tear the whole approval down — the gather can no longer be satisfied (or a
    # caller is hard-rejecting it). Cancels any tracks still open.
    def reject!(reason: nil)
      return if terminal?

      update!(status: "rejected")
      cancel_remaining_tracks!
      emit_outbox("approval.rejected", reason)
    end

    private

    # :met / :failed / :undecided for the gather. `required` tracks must approve,
    # resolved from `approvals_required` against the live group (non-cancelled
    # tracks). Met once enough have; failed once even every track still pending
    # couldn't reach `required`; undecided otherwise.
    def track_outcome
      group = tracks.where.not(status: "cancelled").count
      return :undecided if group.zero?

      approved = tracks.where(status: "approved").count
      pending  = tracks.where(status: "pending").count
      required = Consensus.new(approvals_required).required(group)

      if approved >= required then :met
      elsif (approved + pending) < required then :failed
      else :undecided
      end
    end

    def approvals_required_is_valid
      return if Consensus.valid?(approvals_required)

      errors.add(:approvals_required, "must be :any, :all, :majority, a percentage like \"60%\", or a positive integer")
    end

    def cancel_remaining_tracks!
      tracks.where(status: %w[pending]).find_each do |track|
        track.steps.where(status: Track::OPEN_STEP_STATUSES).find_each do |step|
          step.update!(status: "cancelled")
        end
        track.update!(status: "cancelled")
      end
    end

    def emit_outbox(event_name, reason = nil)
      OutboxEvent.create!(
        tenant_id: tenant_id,
        event_name: event_name,
        record: self,
        error_payload: reason
      )
    end
  end
end
