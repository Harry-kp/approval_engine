require "test_helper"

module ApprovalEngine
  # The outbox is a queue: one row per activation, decision and outcome, and
  # nothing reads a relayed row again. Without a sweep the table grows forever.
  class OutboxRetentionTest < ApprovalEngine::TestCase
    setup do
      invoice   = Invoice.create!(tenant_id: TENANT, amount: 6000)
      @approval = Approval.create!(tenant_id: TENANT, target: invoice, status: "approved")
    end

    def event(processed:, processed_at: nil, failed_at: nil)
      OutboxEvent.create!(tenant_id: TENANT, event_name: "approval.approved", record: @approval).tap do |e|
        e.update_columns(processed: processed, processed_at: processed_at, failed_at: failed_at)
      end
    end

    test "purges relayed events past the window, and keeps recent ones" do
      old    = event(processed: true, processed_at: 60.days.ago)
      recent = event(processed: true, processed_at: 1.day.ago)

      assert_equal 1, OutboxEvent.purge!

      assert_not OutboxEvent.exists?(old.id)
      assert OutboxEvent.exists?(recent.id)
    end

    test "never purges work that has not been relayed" do
      pending = event(processed: false, processed_at: nil)

      OutboxEvent.purge!(older_than: 0.seconds)

      assert OutboxEvent.exists?(pending.id), "an unrelayed event is still owed to the host"
    end

    # An event that exhausted its retries is evidence of a broken callback.
    test "keeps dead letters however old they are" do
      dead = event(processed: true, processed_at: 90.days.ago, failed_at: 90.days.ago)

      OutboxEvent.purge!

      assert OutboxEvent.exists?(dead.id)
    end

    test "honours an explicit window and returns the count deleted" do
      event(processed: true, processed_at: 10.days.ago)
      event(processed: true, processed_at: 10.days.ago)

      assert_equal 2, OutboxEvent.purge!(older_than: 7.days)
    end
  end
end
