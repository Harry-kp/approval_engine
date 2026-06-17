class AddDeliveryTrackingToOutboxEvents < ActiveRecord::Migration[7.0]
  # `error_payload` carries the *semantic* reason (why an approval was rejected,
  # quarantined, or cancelled) that the host callback consumes. Delivery failures
  # now record their backtrace in `delivery_error` so a retry can't clobber that
  # reason. `failed_at` is the dead-letter mark: a row whose retries are exhausted,
  # so `drain!` stops resurrecting it forever.
  def change
    add_column :approval_engine_outbox_events, :delivery_error, :text
    add_column :approval_engine_outbox_events, :failed_at, :datetime
  end
end
