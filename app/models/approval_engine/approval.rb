module ApprovalEngine
  # The aggregate root of one approval run: a host record + the event that
  # spawned it, fanning out into one or more parallel tracks.
  #
  # An approval is approved only once *every* track approves (scatter-gather),
  # and rejected the moment any single track is hard-rejected. Progression
  # methods here are always invoked while the approval row is locked by the
  # acting step's transition, so they do not lock again themselves.
  class Approval < ApplicationRecord
    STATUSES = %w[pending approved rejected quarantined cancelled].freeze
    TERMINAL_STATUSES = %w[approved rejected quarantined cancelled].freeze

    belongs_to :target, polymorphic: true
    has_many :tracks, class_name: "ApprovalEngine::Track", foreign_key: "approval_engine_approval_id", dependent: :destroy
    has_many :steps, through: :tracks

    validates :tenant_id, presence: true
    validates :status, inclusion: { in: STATUSES }

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

    # Called as each track completes. The approval approves once no track
    # is left unapproved.
    def try_complete!
      return if terminal?
      return if tracks.where.not(status: "approved").exists?

      update!(status: "approved")
      emit_outbox("approval.approved")
    end

    # A track was hard-rejected: tear the whole approval down.
    def reject!(reason: nil)
      return if terminal?

      update!(status: "rejected")
      cancel_remaining_tracks!
      emit_outbox("approval.rejected", reason)
    end

    private

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
