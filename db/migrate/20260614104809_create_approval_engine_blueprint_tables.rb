class CreateApprovalEngineBlueprintTables < ActiveRecord::Migration[7.0]
  def change
    # The reusable blueprint an approval is stamped from. Event-agnostic: which
    # event triggers it is a routing concern owned by TriggerRule, not the template.
    create_table :approval_engine_track_templates, id: :uuid do |t|
      t.string :tenant_id, null: false, index: true
      t.string :name, null: false
      t.string :status, null: false, default: "draft"

      t.timestamps
    end

    # The ordered layers of a template (custom index name keeps it under 63 chars).
    create_table :approval_engine_template_steps, id: :uuid do |t|
      t.references :approval_engine_track_template,
                   null: false,
                   foreign_key: true,
                   type: :uuid,
                   index: { name: "idx_ae_tpl_steps_on_tpl_id" }
      t.string :name, null: false
      t.integer :layer, null: false, default: 1
      t.string :approvals_required, null: false, default: "any"
      t.string :assigned_group, null: false
      # Optional SLA: seconds the step gets once it becomes actionable. nil = no
      # deadline. Stamped onto each concrete Step; the host sweeps for breaches.
      t.integer :timeout_after

      t.timestamps
    end

    # The JSON Logic routing rules.
    create_table :approval_engine_trigger_rules, id: :uuid do |t|
      t.string :tenant_id, null: false, index: true
      t.string :event_name, null: false
      t.jsonb :condition, null: false, default: {}
      t.integer :priority, null: false, default: 0
      t.references :approval_engine_track_template,
                   null: false,
                   foreign_key: true,
                   type: :uuid,
                   index: { name: "idx_ae_trigger_rules_on_tpl_id" }
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :approval_engine_trigger_rules, :condition, using: :gin

    add_check_constraint :approval_engine_track_templates,
                         "status IN ('draft','active','archived')",
                         name: "chk_approval_engine_template_status"
    add_check_constraint :approval_engine_template_steps,
                         "approvals_required ~ '^([1-9][0-9]*%?|any|all|majority)$'",
                         name: "chk_approval_engine_template_step_approvals_required"

    # Rule resolution runs on every triggering event — make it one index scan.
    add_index :approval_engine_trigger_rules, %i[tenant_id event_name active priority],
              name: "idx_ae_trigger_rules_resolution"
  end
end