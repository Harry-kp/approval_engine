class AddRemindedAtToSteps < ActiveRecord::Migration[7.0]
  # When the sweep last nudged this step, so a nudge fires once per step.
  # Nullable with no backfill — a metadata-only ALTER, and an app that upgrades
  # without running it loses reminders, never approvals.
  def change
    add_column :approval_engine_steps, :reminded_at, :datetime

    # Builds with a lock, so on a very large table create it by hand first and
    # let `if_not_exists` make this a no-op:
    #
    #   CREATE INDEX CONCURRENTLY idx_ae_steps_remindable
    #     ON approval_engine_steps (activated_at)
    #     WHERE reminded_at IS NULL AND status = 'pending';
    add_index :approval_engine_steps, :activated_at,
              where: "reminded_at IS NULL AND status = 'pending'",
              name: "idx_ae_steps_remindable",
              if_not_exists: true
  end
end
