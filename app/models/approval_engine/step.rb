module ApprovalEngine
  # A single node in the immutable approval ledger.
  #
  # Steps move strictly forward through their lifecycle — they are never reset
  # backwards. Requesting changes appends a fresh iteration instead (see
  # IterationBuilder), preserving the historical truth of every attempt.
  #
  # The bang methods (#approve!, #reject!, #request_changes!) take a
  # pessimistic lock, write an audit row, advance the surrounding track, and
  # drop a transactional-outbox event — all in one transaction — so concurrent
  # "Approve" clicks can never double-resolve a step.
  class Step < ApplicationRecord
    # Lifecycle. `waiting` steps belong to a future layer and are not yet
    # actionable; they are activated to `pending` once the prior layer resolves.
    STATUSES = %w[waiting pending approved rejected changes_requested expired cancelled].freeze
    TERMINAL_STATUSES = %w[approved rejected changes_requested expired cancelled].freeze

    # Allowed forward transitions. Anything else is rejected to keep the ledger
    # append-only. `expired` is a distinct terminal state — a deadline lapse is
    # never recorded as an approval or a human rejection.
    TRANSITIONS = {
      "waiting" => %w[pending cancelled],
      "pending" => %w[approved rejected changes_requested expired cancelled]
    }.freeze

    belongs_to :track, class_name: "ApprovalEngine::Track", foreign_key: "approval_engine_track_id"
    belongs_to :assigned_actor, polymorphic: true
    has_many :audit_logs, class_name: "ApprovalEngine::AuditLog", foreign_key: "approval_engine_step_id", dependent: :destroy

    has_one :approval, through: :track

    validates :tenant_id, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :layer, :iteration, numericality: { greater_than: 0 }
    validate :approvals_required_is_valid

    before_update :guard_immutable_transition
    before_save :stamp_timing

    scope :waiting, -> { where(status: "waiting") }
    scope :pending, -> { where(status: "pending") }
    scope :approved, -> { where(status: "approved") }
    scope :terminal, -> { where(status: TERMINAL_STATUSES) }
    scope :resolved, -> { where.not(status: %w[waiting pending]) }
    scope :for_iteration, ->(iteration) { where(iteration: iteration) }
    scope :for_layer, ->(layer) { where(layer: layer) }
    scope :assigned_to, ->(actor) { where(assigned_actor: actor) }
    scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }
    # Pending steps whose deadline has passed and that haven't fired yet — the
    # set the timeout sweep acts on. Each step times out at most once.
    scope :overdue, ->(as_of = Time.current) {
      pending.where(timed_out_at: nil).where.not(timeout_at: nil).where("timeout_at <= ?", as_of)
    }

    # An approver's inbox: pending steps the actor may act on — assigned to them
    # directly *plus* those they cover via an active delegation. The scope form
    # of `#actionable_by?`. Chain `.count`, `.order`, pagination, etc.
    scope :actionable_by, ->(actor, tenant: nil) {
      type = actor.class.polymorphic_name
      delegated_ids = Delegation.in_effect.where(delegatee: actor, delegator_type: type).pluck(:delegator_id)
      rel = pending.where(assigned_actor_type: type, assigned_actor_id: [ actor.id, *delegated_ids ])
      tenant ? rel.for_tenant(tenant) : rel
    }

    # True when `actor` may act on this step — either the assigned actor or one
    # of their active delegates. Authorization itself stays with the host app;
    # this is the helper they reason about.
    def actionable_by?(actor)
      return false unless pending?
      return true if assigned_actor == actor

      Delegation.active_for(assigned_actor, tenant_id: tenant_id).exists?(delegatee: actor)
    end

    STATUSES.each do |state|
      define_method(:"#{state}?") { status == state }
    end

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    # The host record this step is ultimately approving (e.g. the Invoice).
    # Preload an inbox with `.includes(track: { approval: :target })`.
    def target
      track&.approval&.target
    end

    # Seconds a human took to decide this step — from when it became actionable
    # (`activated_at`) to when it was approved/rejected/changes-requested
    # (`decided_at`). nil until decided (or for cancelled steps, never decided).
    def time_to_decision
      return unless activated_at && decided_at

      decided_at - activated_at
    end

    # Seconds this step has been (or was) actionable: `now - activated_at` while
    # pending, `decided_at - activated_at` once resolved. nil before activation.
    # Useful for "how long has this been sitting in someone's queue?".
    def waiting_for
      return unless activated_at

      (decided_at || Time.current) - activated_at
    end

    def approve!(by:, comment: nil)
      transition!(to: "approved", event: "approved", by: by, comment: comment) do
        track.advance!(self)
      end
    end

    def reject!(by:, comment: nil)
      transition!(to: "rejected", event: "rejected", by: by, comment: comment) do
        track.advance!(self)
      end
    end

    def request_changes!(by:, comment: nil)
      transition!(to: "changes_requested", event: "changes_requested", by: by, comment: comment) do
        track.advance_after_changes_requested!(self)
      end
    end

    # The deadline passed while this step was still pending. This is a *signal*,
    # not a verdict: it records a `timed_out` event and fires the host's
    # `on_step_timeout` callback, but does NOT decide the step — silence is never
    # consent. The host chooses the reaction (`expire!`, escalate, remind). Fires
    # at most once; idempotent under concurrent sweeps.
    def time_out!
      track.approval.with_lock do
        reload
        return self unless pending? && timed_out_at.nil?

        update!(timed_out_at: Time.current)
        record_audit(event: "timed_out", by: nil, comment: nil)
        emit_outbox("step.timed_out")
      end

      self
    end

    # Honest denial when an approver never acted in time: the step becomes
    # `expired` (a distinct terminal state — never "approved", never a human
    # "rejected"), with no human actor on the ledger. Resolves the surrounding
    # layer consensus-aware, like a reject. Idempotent if already resolved.
    def expire!(comment: nil)
      return self if terminal?

      transition!(to: "expired", event: "expired", by: nil, comment: comment) do
        track.advance!(self)
      end
    end

    # Fire the timeout signal for every overdue step. Safe to run as often as you
    # like (each step times out once); scope to a tenant in multi-tenant cron.
    # Returns the number swept. TimeoutSweepJob wraps this for background runs.
    def self.sweep_timeouts!(tenant_id: nil)
      scope = tenant_id ? overdue.for_tenant(tenant_id) : overdue
      swept = 0
      scope.find_each do |step|
        step.time_out!
        swept += 1
      end
      swept
    end

    private

    # The shared transition pipeline. We lock the *approval* — the aggregate
    # root — before touching anything, so every transition within an approval is
    # fully serialized. That makes double-approvals impossible and lets a layer
    # safely cancel its sibling steps without deadlocking against them.
    #
    # The yielded block advances the track/approval synchronously, so the
    # ledger is always internally consistent by the time the transaction
    # commits. External side-effects are deferred to the transactional outbox.
    def transition!(to:, event:, by:, comment:)
      track.approval.with_lock do
        reload

        unless pending?
          errors.add(:status, "must be pending to be #{event} (was #{status})")
          raise ActiveRecord::RecordInvalid, self
        end

        update!(status: to)
        record_audit(event: event, by: by, comment: comment)
        yield if block_given?
        emit_outbox("step.#{event}")
      end

      self
    end

    def record_audit(event:, by:, comment:)
      audit_logs.create!(
        tenant_id: tenant_id,
        event: event,
        intended_actor: assigned_actor,
        actual_actor: by,
        comment: comment
      )
    end

    def emit_outbox(event_name)
      OutboxEvent.create!(tenant_id: tenant_id, event_name: event_name, record: self)
    end

    def guard_immutable_transition
      return unless will_save_change_to_status?

      from, to = status_change_to_be_saved
      allowed = TRANSITIONS.fetch(from, [])
      return if allowed.include?(to)

      errors.add(:status, "cannot transition from #{from} to #{to}")
      throw :abort
    end

    def approvals_required_is_valid
      return if Consensus.valid?(approvals_required)

      errors.add(:approvals_required, "must be :any, :all, :majority, a percentage like \"60%\", or a positive integer")
    end

    # Stamp the cycle-time facts wherever a step's status changes — at build, on
    # waiting->pending activation, and on a human decision — so latency reporting
    # never has to re-derive timing from the audit log. `||=` keeps the first
    # value, so re-saves don't move the clock. Cancelled steps were never decided,
    # so they stay decided_at: nil.
    DECISION_STATUSES = %w[approved rejected changes_requested].freeze

    def stamp_timing
      if status == "pending"
        self.activated_at ||= Time.current
        # Deadline = actionable + the SLA window. `||=` lets the host set an
        # absolute `timeout_at` directly (e.g. computed against business hours).
        self.timeout_at ||= activated_at + timeout_after if timeout_after
      end
      self.decided_at ||= Time.current if DECISION_STATUSES.include?(status)
    end
  end
end
