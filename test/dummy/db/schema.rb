# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_14_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "approval_engine_approvals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_name"
    t.string "status", default: "pending", null: false
    t.bigint "target_id", null: false
    t.string "target_type", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["status"], name: "index_approval_engine_approvals_on_status"
    t.index ["target_type", "target_id", "created_at"], name: "idx_ae_approvals_target_recency"
    t.index ["target_type", "target_id"], name: "index_approval_engine_approvals_on_target"
    t.index ["tenant_id"], name: "index_approval_engine_approvals_on_tenant_id"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'approved'::character varying, 'rejected'::character varying, 'quarantined'::character varying, 'cancelled'::character varying]::text[])", name: "chk_approval_engine_approval_status"
  end

  create_table "approval_engine_audit_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "actual_actor_id"
    t.string "actual_actor_type"
    t.uuid "approval_engine_step_id", null: false
    t.text "comment"
    t.datetime "created_at", null: false
    t.string "event", null: false
    t.bigint "intended_actor_id"
    t.string "intended_actor_type"
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["actual_actor_type", "actual_actor_id"], name: "index_approval_engine_audit_logs_on_actual_actor"
    t.index ["approval_engine_step_id"], name: "index_approval_engine_audit_logs_on_approval_engine_step_id"
    t.index ["intended_actor_type", "intended_actor_id"], name: "index_approval_engine_audit_logs_on_intended_actor"
    t.index ["tenant_id", "created_at"], name: "index_approval_engine_audit_logs_on_tenant_id_and_created_at"
  end

  create_table "approval_engine_delegations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.bigint "delegatee_id", null: false
    t.string "delegatee_type", null: false
    t.bigint "delegator_id", null: false
    t.string "delegator_type", null: false
    t.datetime "ends_at", null: false
    t.datetime "starts_at", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["delegatee_type", "delegatee_id", "active", "starts_at", "ends_at"], name: "idx_ae_delegations_lookup"
    t.index ["delegatee_type", "delegatee_id"], name: "index_approval_engine_delegations_on_delegatee"
    t.index ["delegator_type", "delegator_id"], name: "index_approval_engine_delegations_on_delegator"
  end

  create_table "approval_engine_outbox_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_payload"
    t.string "event_name", null: false
    t.boolean "processed", default: false, null: false
    t.datetime "processed_at"
    t.uuid "record_id", null: false
    t.string "record_type", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "idx_ae_outbox_unprocessed", where: "(processed = false)"
    t.index ["processed"], name: "index_approval_engine_outbox_events_on_processed"
    t.index ["record_type", "record_id"], name: "index_approval_engine_outbox_events_on_record"
  end

  create_table "approval_engine_steps", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "activated_at"
    t.uuid "approval_engine_track_id", null: false
    t.string "approvals_required", default: "any", null: false
    t.bigint "assigned_actor_id", null: false
    t.string "assigned_actor_type", null: false
    t.datetime "created_at", null: false
    t.datetime "decided_at"
    t.integer "iteration", default: 1, null: false
    t.integer "layer", default: 1, null: false
    t.string "name"
    t.string "status", default: "pending", null: false
    t.string "tenant_id", null: false
    t.datetime "timed_out_at"
    t.integer "timeout_after"
    t.datetime "timeout_at"
    t.datetime "updated_at", null: false
    t.index ["approval_engine_track_id", "iteration", "layer", "status"], name: "idx_ae_steps_layer_consensus"
    t.index ["approval_engine_track_id"], name: "index_approval_engine_steps_on_approval_engine_track_id"
    t.index ["assigned_actor_type", "assigned_actor_id"], name: "index_approval_engine_steps_on_assigned_actor"
    t.index ["status"], name: "index_approval_engine_steps_on_status"
    t.index ["tenant_id", "assigned_actor_type", "assigned_actor_id", "status"], name: "idx_approval_engine_pending_tasks"
    t.index ["timeout_at"], name: "idx_ae_steps_overdue", where: "((timeout_at IS NOT NULL) AND (timed_out_at IS NULL))"
    t.check_constraint "approvals_required::text ~ '^([1-9][0-9]*%?|any|all|majority)$'::text", name: "chk_approval_engine_step_approvals_required"
    t.check_constraint "status::text = ANY (ARRAY['waiting'::character varying, 'pending'::character varying, 'approved'::character varying, 'rejected'::character varying, 'changes_requested'::character varying, 'expired'::character varying, 'cancelled'::character varying]::text[])", name: "chk_approval_engine_step_status"
  end

  create_table "approval_engine_template_steps", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "approval_engine_track_template_id", null: false
    t.string "approvals_required", default: "any", null: false
    t.string "assigned_group", null: false
    t.datetime "created_at", null: false
    t.integer "layer", default: 1, null: false
    t.string "name", null: false
    t.integer "timeout_after"
    t.datetime "updated_at", null: false
    t.index ["approval_engine_track_template_id"], name: "idx_ae_tpl_steps_on_tpl_id"
    t.check_constraint "approvals_required::text ~ '^([1-9][0-9]*%?|any|all|majority)$'::text", name: "chk_approval_engine_template_step_approvals_required"
  end

  create_table "approval_engine_track_templates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "status", default: "draft", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id"], name: "index_approval_engine_track_templates_on_tenant_id"
    t.check_constraint "status::text = ANY (ARRAY['draft'::character varying, 'active'::character varying, 'archived'::character varying]::text[])", name: "chk_approval_engine_template_status"
  end

  create_table "approval_engine_tracks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "approval_engine_approval_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "status", default: "pending", null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["approval_engine_approval_id", "status"], name: "idx_ae_tracks_approval_status"
    t.index ["approval_engine_approval_id"], name: "index_approval_engine_tracks_on_approval_engine_approval_id"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'approved'::character varying, 'rejected'::character varying, 'cancelled'::character varying]::text[])", name: "chk_approval_engine_track_status"
  end

  create_table "approval_engine_trigger_rules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.uuid "approval_engine_track_template_id", null: false
    t.jsonb "condition", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "event_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["approval_engine_track_template_id"], name: "idx_ae_trigger_rules_on_tpl_id"
    t.index ["condition"], name: "index_approval_engine_trigger_rules_on_condition", using: :gin
    t.index ["tenant_id", "event_name", "active", "priority"], name: "idx_ae_trigger_rules_resolution"
    t.index ["tenant_id"], name: "index_approval_engine_trigger_rules_on_tenant_id"
  end

  create_table "invoices", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "created_at", null: false
    t.string "department"
    t.string "state", default: "submitted", null: false
    t.string "tenant_id"
    t.datetime "updated_at", null: false
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.string "role"
    t.datetime "updated_at", null: false
  end

  add_foreign_key "approval_engine_audit_logs", "approval_engine_steps"
  add_foreign_key "approval_engine_steps", "approval_engine_tracks"
  add_foreign_key "approval_engine_template_steps", "approval_engine_track_templates"
  add_foreign_key "approval_engine_tracks", "approval_engine_approvals"
  add_foreign_key "approval_engine_trigger_rules", "approval_engine_track_templates"
end
