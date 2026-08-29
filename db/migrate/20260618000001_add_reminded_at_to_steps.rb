class AddRemindedAtToSteps < ActiveRecord::Migration[7.0]
  # When the reminder sweep last nudged this step's assignee — so a nudge fires
  # once per step rather than on every sweep. Nullable, with no default and no
  # backfill: an existing install picks it up as a metadata-only ALTER, and every
  # pre-1.1 code path stays away from the column, so an app that upgrades the gem
  # but forgets this migration loses reminders, never approvals.
  def change
    add_column :approval_engine_steps, :reminded_at, :datetime

    # The reminder sweep's twin of idx_ae_steps_overdue: only un-nudged, still
    # pending steps are ever scanned. On a very large table build this by hand
    # with CREATE INDEX CONCURRENTLY first — the partial predicate is identical.
    add_index :approval_engine_steps, :activated_at,
              where: "reminded_at IS NULL AND status = 'pending'",
              name: "idx_ae_steps_remindable"
  end
end
