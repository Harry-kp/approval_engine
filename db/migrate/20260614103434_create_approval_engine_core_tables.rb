class CreateApprovalEngineCoreTables < ActiveRecord::Migration[7.0]
  def change
    # The orchestrator. One per host record + event. Holds the parallel
    # track tracks and the overall outcome.
    create_table :approval_engine_approvals, id: :uuid do |t|
      t.string :tenant_id, null: false, index: true
      t.references :target, polymorphic: true, null: false, index: true
      t.string :status, null: false, default: "pending", index: true
      t.string :event_name

      t.timestamps
    end

    # A single track within an approval (e.g. "Finance", "Legal"). Approvals with
    # more than one track model scatter-gather parallelism.
    create_table :approval_engine_tracks, id: :uuid do |t|
      t.string :tenant_id, null: false
      t.references :approval_engine_approval, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.string :status, null: false, default: "pending"

      t.timestamps
    end

    # The immutable ledger row. Steps are never updated backwards: a rework
    # rejection appends a fresh iteration rather than resetting history.
    create_table :approval_engine_steps, id: :uuid do |t|
      t.string :tenant_id, null: false
      t.references :approval_engine_track, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.integer :layer, null: false, default: 1
      t.integer :iteration, null: false, default: 1
      t.string :status, null: false, default: "pending", index: true
      # How many approvals this step's layer needs: any | all | majority | "60%" | "2".
      t.string :approvals_required, null: false, default: "any"
      t.references :assigned_actor, polymorphic: true, null: false

      # Cycle-time facts for latency/bottleneck reporting: when the step became
      # actionable (pending), and when a human resolved it. Both stay null while
      # waiting; decided_at also stays null for cancelled/expired steps (never decided).
      t.datetime :activated_at
      t.datetime :decided_at

      # Timeout — three distinct facts:
      #   timeout_after : the SLA window in seconds, copied from the template like
      #                   the step's other facts (the ledger stays self-contained).
      #   timeout_at    : the deadline itself, fixed when the step is activated.
      #                   Stored (not recomputed) and indexed so the sweep stays a
      #                   plain `timeout_at <= now`, not interval arithmetic.
      #   timed_out_at  : when the timeout fired — so it fires exactly once.
      t.integer :timeout_after
      t.datetime :timeout_at
      t.datetime :timed_out_at

      t.timestamps
    end

    # Append-only audit trail. Records the intended actor (who was assigned) vs.
    # the actual actor (who acted, possibly a delegate) for strict compliance.
    create_table :approval_engine_audit_logs, id: :uuid do |t|
      t.string :tenant_id, null: false
      t.references :approval_engine_step, null: false, foreign_key: true, type: :uuid
      t.string :event, null: false
      t.references :intended_actor, polymorphic: true, null: true
      # Nullable: system events (e.g. a step timing out) have no human actor —
      # the ledger records that honestly rather than fabricating one.
      t.references :actual_actor, polymorphic: true, null: true
      t.text :comment

      t.timestamps
    end

    # Fast lookup for "my pending approvals" dashboards.
    add_index :approval_engine_steps,
              %i[tenant_id assigned_actor_type assigned_actor_id status],
              name: "idx_approval_engine_pending_tasks"

    # Enforce the enumerated values at the database level, not just in Ruby —
    # the ledger is the source of truth, so a raw write can't corrupt it.
    add_check_constraint :approval_engine_approvals,
                         "status IN ('pending','approved','rejected','quarantined','cancelled')",
                         name: "chk_approval_engine_approval_status"
    add_check_constraint :approval_engine_tracks,
                         "status IN ('pending','approved','rejected','cancelled')",
                         name: "chk_approval_engine_track_status"
    add_check_constraint :approval_engine_steps,
                         "status IN ('waiting','pending','approved','rejected','changes_requested','expired','cancelled')",
                         name: "chk_approval_engine_step_status"
    add_check_constraint :approval_engine_steps,
                         "approvals_required ~ '^([1-9][0-9]*%?|any|all|majority)$'",
                         name: "chk_approval_engine_step_approvals_required"

    # Hot-path indexes the read/write queries actually use.
    add_index :approval_engine_tracks, %i[approval_engine_approval_id status],
              name: "idx_ae_tracks_approval_status"
    add_index :approval_engine_steps, %i[approval_engine_track_id iteration layer status],
              name: "idx_ae_steps_layer_consensus"
    add_index :approval_engine_approvals, %i[target_type target_id created_at],
              name: "idx_ae_approvals_target_recency"
    add_index :approval_engine_audit_logs, %i[tenant_id created_at]

    # The timeout sweep only cares about steps with a live, unfired deadline.
    add_index :approval_engine_steps, :timeout_at,
              where: "timeout_at IS NOT NULL AND timed_out_at IS NULL",
              name: "idx_ae_steps_overdue"
  end
end
