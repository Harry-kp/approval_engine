class CreateInvoices < ActiveRecord::Migration[8.1]
  def change
    create_table :invoices do |t|
      t.string :tenant_id
      t.decimal :amount, precision: 12, scale: 2, default: "0.0", null: false
      t.string :department
      t.string :state, default: "submitted", null: false

      t.timestamps
    end
  end
end
