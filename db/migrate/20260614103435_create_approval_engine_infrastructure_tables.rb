class CreateApprovalEngineInfrastructureTables < ActiveRecord::Migration[7.0]
  # Host records are referenced polymorphically, so these columns have to hold
  # whatever the approved models use as a primary key. String fits a bigint, a
  # UUID and a ULID alike; `t.references`' bigint default would cast a UUID to 0
  # and silently lose the target.
  def change
    create_table :approval_engine_outbox_events, id: :uuid do |t|
      t.string :tenant_id, null: false
      t.string :event_name, null: false
      t.references :record, polymorphic: true, null: false, type: :uuid
      t.boolean :processed, null: false, default: false, index: true
      t.datetime :processed_at
      t.text :error_payload

      t.timestamps
    end

    create_table :approval_engine_delegations, id: :uuid do |t|
      t.string :tenant_id, null: false
      t.references :delegator, polymorphic: true, type: :string, null: false
      t.references :delegatee, polymorphic: true, type: :string, null: false
      t.datetime :starts_at, null: false
      t.datetime :ends_at, null: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    # Serves the inbox's `in_effect.where(delegatee:)` time-window lookup.
    add_index :approval_engine_delegations,
              %i[delegatee_type delegatee_id active starts_at ends_at],
              name: "idx_ae_delegations_lookup"

    # Partial index keeps the outbox `drain!` backlog scan tiny.
    add_index :approval_engine_outbox_events, :created_at,
              where: "processed = false",
              name: "idx_ae_outbox_unprocessed"
  end
end