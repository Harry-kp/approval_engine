module ApprovalEngine
  # Relays one outbox event to the outside world. Core ledger state is already
  # settled by the time this runs (transitions advance synchronously), so the
  # job only fires *side-effects*: optional host callbacks and an
  # ActiveSupport::Notifications instrumentation hook.
  #
  # Delivery is *at-least-once*: host callbacks may run more than once if a
  # worker dies mid-flight or the queue redelivers, so callbacks MUST be
  # idempotent. The row is locked for the whole unit of work (inside a
  # transaction) so two concurrent workers can't both deliver the same event,
  # and a failure records the error before re-raising for backoff/retry.
  class ProcessOutboxJob < ApplicationJob
    # Read the queue lazily so the host isn't forced onto a queue name we picked.
    queue_as { ApprovalEngine.config.outbox_queue }

    # Don't depend on the host's adapter happening to retry: back off and retry
    # here. A row whose argument can't be deserialised is a dead letter.
    retry_on StandardError, wait: :polynomially_longer, attempts: 8
    discard_on ActiveJob::DeserializationError

    def perform(outbox_event_id)
      # The lock is held for the whole transaction, so a concurrent worker (or a
      # drain! pass) blocks here and then sees `processed` — never double-delivers.
      OutboxEvent.transaction do
        event = OutboxEvent.unprocessed.lock.find_by(id: outbox_event_id)
        next unless event # already processed, or its record was purged

        deliver(event)
        event.mark_processed!
      end
    rescue => e
      # Persist the error outside the (rolled-back) transaction so ops can see it.
      OutboxEvent.where(id: outbox_event_id).update_all(error_payload: format_error(e), updated_at: Time.current)
      raise
    end

    private

    def deliver(event)
      run_host_callbacks(event)
      broadcast_notification(event)
    end

    # Invoke the matching host callback if the target model chose to define one.
    # The engine never requires these — they are pure convention-over-config.
    def run_host_callbacks(event)
      record = event.record
      target = target_for(record)
      return unless target

      case event.event_name
      when "step.approved"             then try_call(target, :after_step_approved, record)
      when "step.rejected"             then try_call(target, :after_step_rejected, record)
      when "step.changes_requested"    then try_call(target, :after_step_changes_requested, record)
      when "step.timed_out"            then try_call(target, :on_step_timeout, record)
      when "step.expired"              then try_call(target, :after_step_expired, record)
      when "approval.approved"         then try_call(target, :after_approved)
      when "approval.rejected"         then try_call(target, :after_rejected, event.error_payload)
      when "approval.quarantined"      then try_call(target, :on_quarantined, event.error_payload)
      end
    end

    # Native pub/sub for hosts who prefer subscribers over callbacks:
    #   ActiveSupport::Notifications.subscribe("approval_engine.approval.approved") { ... }
    def broadcast_notification(event)
      record = event.record
      ActiveSupport::Notifications.instrument(
        "approval_engine.#{event.event_name}",
        record: record,
        target: target_for(record),
        tenant_id: event.tenant_id
      )
    end

    def target_for(record)
      case record
      when Approval then record.target
      when Step     then record.approval&.target
      end
    end

    def try_call(target, method_name, *args)
      target.public_send(method_name, *args) if target.respond_to?(method_name)
    end

    def format_error(error)
      "#{error.class}: #{error.message}\n#{Array(error.backtrace).first(5).join("\n")}"
    end
  end
end
