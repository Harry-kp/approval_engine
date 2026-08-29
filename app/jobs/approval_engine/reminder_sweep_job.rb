module ApprovalEngine
  # Nudges approvers who have gone quiet longer than `config.reminder_after`.
  # Schedule it with whatever recurring mechanism you already run:
  #
  #   ApprovalEngine::ReminderSweepJob.perform_later              # all tenants
  #   ApprovalEngine::ReminderSweepJob.perform_later(tenant_id: account.id)
  #
  # Each step is nudged at most once, and it is a no-op until `reminder_after`
  # is set, so running it often and scheduling it early are both harmless.
  class ReminderSweepJob < ApplicationJob
    queue_as { ApprovalEngine.config.outbox_queue }

    def perform(tenant_id: nil)
      Step.sweep_reminders!(tenant_id: tenant_id)
    end
  end
end
