class AddTriggerRuleToApprovals < ActiveRecord::Migration[7.0]
  # Provenance: which TriggerRule auto-routed this approval. Nullable — an
  # approval started manually via run_approval!(templates:) has no matching
  # rule. on_delete: :nullify so retiring a rule never blocks or rewrites the
  # historical approvals it once spawned (the ledger stays append-only).
  def change
    add_reference :approval_engine_approvals,
                  :approval_engine_trigger_rule,
                  type: :uuid,
                  null: true,
                  foreign_key: { to_table: :approval_engine_trigger_rules, on_delete: :nullify },
                  index: { name: "idx_ae_approvals_on_trigger_rule" }
  end
end
