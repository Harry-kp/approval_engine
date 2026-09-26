module ApprovalEngine
  # Lets a ledger row drop a transactional-outbox event about itself.
  #
  # The write lands in the same transaction as the state change that produced
  # it — that is the whole point of the outbox — so the only thing this has to
  # get right is that every row emits the same shape. `reason` carries the
  # semantic why (a rejection note, a cancellation cause) into `error_payload`,
  # which the relay hands to the host callback; steps pass nothing and the
  # column stays null, exactly as before.
  module Outboxable
    extend ActiveSupport::Concern

    private

    def emit_outbox(event_name, reason = nil)
      OutboxEvent.create!(
        tenant_id: tenant_id,
        event_name: event_name,
        record: self,
        error_payload: reason
      )
    end
  end
end
