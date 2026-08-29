module ApprovalEngine
  # A row in the transactional outbox. It is written in the *same* transaction
  # as the state change that produced it, then relayed asynchronously — so a
  # crashing mailer or a down payment API can never roll back an approval, and
  # no side-effect is ever silently lost.
  class OutboxEvent < ApplicationRecord
    # `record` is always an engine row (Approval or Step, UUID-keyed), never a
    # host record. The column is NOT NULL — every event is created with one — but
    # `optional: true` relaxes the load-time check so an event whose record was
    # destroyed before relay can be retired instead of poisoning the queue.
    belongs_to :record, polymorphic: true, optional: true

    validates :tenant_id, :event_name, presence: true

    scope :unprocessed, -> { where(processed: false) }
    scope :processed, -> { where(processed: true) }
    # Dead letters: delivery retries were exhausted. Excluded from drain! so a
    # permanently-failing callback isn't resurrected forever; surfaced here for
    # ops to inspect and replay (clear failed_at to let drain! pick it up again).
    scope :failed, -> { where.not(failed_at: nil) }

    # Relay the event once the producing transaction has safely committed.
    after_create_commit :enqueue_relay

    # Safety net for events whose relay job was lost (e.g. the process died
    # between commit and enqueue). Wire this to a periodic ActiveJob/cron.
    # `older_than` skips freshly-created events whose relay is likely still
    # in-flight, so draining never double-enqueues a healthy event; dead letters
    # are skipped so exhausted poison events aren't retried in perpetuity.
    def self.drain!(older_than: 1.minute, limit: 1000)
      unprocessed.where(failed_at: nil)
                 .where(created_at: ..older_than.ago)
                 .order(:created_at).limit(limit).pluck(:id).each do |id|
        ProcessOutboxJob.perform_later(id)
      end
    end

    # The outbox is a queue, not a ledger: once an event is relayed its row has
    # no reader, and one is written per step activation, decision and outcome.
    # Left alone the table grows without bound, so a host is expected to sweep
    # it — the audit trail lives in AuditLog and is never touched by this.
    #
    #   ApprovalEngine::OutboxEvent.purge!                      # processed, 30d+
    #   ApprovalEngine::OutboxEvent.purge!(older_than: 7.days)
    #
    # Returns the number of rows deleted. Dead letters are kept regardless of
    # age: an event that exhausted its retries is evidence, not litter.
    def self.purge!(older_than: 30.days, limit: 10_000)
      ids = processed.where(failed_at: nil)
                     .where(processed_at: ..older_than.ago)
                     .order(:processed_at).limit(limit).pluck(:id)
      where(id: ids).delete_all
    end

    def mark_processed!
      update!(processed: true, processed_at: Time.current, error_payload: nil, delivery_error: nil)
    end

    private

    def enqueue_relay
      ProcessOutboxJob.perform_later(id)
    end
  end
end
