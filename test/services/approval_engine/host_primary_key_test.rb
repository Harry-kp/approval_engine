require "test_helper"

# A real constant, not an anonymous class: reading a polymorphic association
# back constantizes the stored type name.
class UuidWidget < ActiveRecord::Base
  self.table_name = "uuid_widgets"
end

module ApprovalEngine
  # Approvals reference host records polymorphically, so those columns have to
  # hold whatever the approved models use as a primary key. `t.references`
  # defaults to bigint, which casts a UUID to 0 — the row saves, and the ledger
  # points at nothing. They are strings instead, which fit every key shape.
  class HostPrimaryKeyTest < ApprovalEngine::TestCase
    setup do
      create_user(role: :manager)
      @template = create_template(event: "widget.created", steps: [ { name: "Manager", group: "manager" } ])
      connection.execute("DROP TABLE IF EXISTS uuid_widgets")
      connection.execute(<<~SQL)
        CREATE TABLE uuid_widgets (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name varchar)
      SQL
    end

    teardown { connection.execute("DROP TABLE IF EXISTS uuid_widgets") }

    test "a host record with a UUID primary key keeps its target" do
      widget = uuid_widget_class.create!(name: "Thing")

      approval = ApprovalBuilder.build!(template: @template, target: widget, event_name: "widget.created")

      assert_equal widget.id, approval.reload.target_id
      assert_equal widget, approval.target
    end

    test "a host record with a bigint primary key keeps its target" do
      invoice = Invoice.create!(tenant_id: TENANT, amount: 20_000, department: "IT")

      approval = ApprovalBuilder.build!(template: @template, target: invoice, event_name: "invoice.created")

      assert_equal invoice, approval.reload.target
    end

    test "a UUID actor is assigned and readable back off the step" do
      widget = uuid_widget_class.create!(name: "Thing")
      approval = ApprovalBuilder.build!(template: @template, target: widget, event_name: "widget.created")

      step = approval.steps.sole
      assert_equal User.sole, step.assigned_actor
      assert_equal widget, step.target
    end

    test "every polymorphic reference to a host record is a string column" do
      { Approval => %w[target_id], Step => %w[assigned_actor_id],
        AuditLog => %w[actual_actor_id intended_actor_id],
        Delegation => %w[delegator_id delegatee_id] }.each do |model, columns|
        columns.each do |column|
          assert_equal :string, model.type_for_attribute(column).type,
                       "#{model.table_name}.#{column} must fit any host primary key"
        end
      end
    end

    private

    def connection
      ActiveRecord::Base.connection
    end

    def uuid_widget_class
      UuidWidget
    end
  end
end
