module ApprovalEngine
  # A row in the transactional outbox. It is written in the *same* transaction
  # as the state change that produced it, then relayed asynchronously — so a
  # crashing mailer or a down payment API can never roll back an approval, and
  # no side-effect is ever silently lost.
  class OutboxEvent < ApplicationRecord
    # `record` is always an engine row (an Approval or Step, both UUID-keyed) —
    # never a host record — which is why record_id is typed uuid. optional: a
    # target may have been destroyed by the time we relay; such an event is
    # retired (marked processed) rather than becoming a poison message.
    belongs_to :record, polymorphic: true, optional: true

    validates :tenant_id, :event_name, presence: true

    scope :unprocessed, -> { where(processed: false) }
    scope :processed, -> { where(processed: true) }
    scope :failed, -> { unprocessed.where.not(error_payload: nil) }

    # Relay the event once the producing transaction has safely committed.
    after_create_commit :enqueue_relay

    # Safety net for events whose relay job was lost (e.g. the process died
    # between commit and enqueue). Wire this to a periodic ActiveJob/cron.
    # `older_than` skips freshly-created events whose relay is likely still
    # in-flight, so draining never double-enqueues a healthy event.
    def self.drain!(older_than: 1.minute, limit: 1000)
      unprocessed.where(created_at: ..older_than.ago).order(:created_at).limit(limit).pluck(:id).each do |id|
        ProcessOutboxJob.perform_later(id)
      end
    end

    def mark_processed!
      update!(processed: true, processed_at: Time.current, error_payload: nil)
    end

    private

    def enqueue_relay
      ProcessOutboxJob.perform_later(id)
    end
  end
end
