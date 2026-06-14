# Coverage (SimpleCov) is started from the dummy app's boot, gated on COVERAGE=1,
# so it instruments the engine's lib/ as well as app/ — see /.simplecov.

# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
ActiveRecord::Migrator.migrations_paths = [ File.expand_path("../test/dummy/db/migrate", __dir__) ]
ActiveRecord::Migrator.migrations_paths << File.expand_path("../db/migrate", __dir__)
require "rails/test_help"

module ApprovalEngine
  # Builder helpers shared across tests so each test reads as intent, not setup.
  module ApprovalFixtures
    TENANT = "tenant-1".freeze

    def create_user(role:, name: role.to_s.titleize)
      User.create!(name: name, role: role.to_s)
    end

    # steps: array of hashes — { name:, layer:, group:, approvals_required: }
    # `event:` is the event the matching rule routes (templates are event-agnostic);
    # it's remembered so `create_rule` can default to it without repeating yourself.
    def create_template(event: nil, steps:, tenant: TENANT, name: "Flow", status: "active")
      template = TrackTemplate.create!(tenant_id: tenant, name: name, status: status)
      (@fixture_events ||= {})[template.id] = event if event
      steps.each do |attrs|
        template.template_steps.create!(
          name: attrs.fetch(:name, "Step"),
          layer: attrs.fetch(:layer, 1),
          assigned_group: attrs.fetch(:group),
          approvals_required: attrs.fetch(:approvals_required, "any").to_s,
          timeout_after: attrs[:timeout_after]
        )
      end
      template
    end

    def create_rule(template:, condition:, event: (@fixture_events ||= {})[template.id], tenant: template.tenant_id, priority: 0)
      template.trigger_rules.create!(
        tenant_id: tenant,
        event_name: event,
        condition: condition,
        priority: priority
      )
    end
  end

  # Base class for engine tests: resets configuration between runs so one test's
  # `ApprovalEngine.configure` block can't leak into the next.
  class TestCase < ActiveSupport::TestCase
    include ApprovalFixtures

    setup do
      ApprovalEngine.reset_configuration!
      ApprovalEngine.configure { |c| c.actor_class = "User" }
    end

    teardown { ApprovalEngine.reset_configuration! }

    # Count real SQL queries in a block (ignoring schema/transaction/cached) so
    # tests can prove a query count is *constant* as data grows — i.e. no N+1.
    def count_queries
      queries = 0
      counter = lambda do |_name, _start, _finish, _id, payload|
        sql = payload[:sql]
        next if payload[:name] == "SCHEMA" || payload[:cached]
        next if /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i.match?(sql)

        queries += 1
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
      queries
    end
  end
end
