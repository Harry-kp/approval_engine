module ApprovalEngine
  # Periodic nudge for approvers who have gone quiet: fires the reminder signal
  # for every pending step that has been waiting longer than
  # `config.reminder_after`. Schedule it with whatever recurring mechanism you
  # already run (solid_queue recurring tasks, sidekiq-cron, the `whenever` gem,
  # a Kubernetes CronJob hitting a rake task, ...):
  #
  #   ApprovalEngine::ReminderSweepJob.perform_later              # all tenants
  #   ApprovalEngine::ReminderSweepJob.perform_later(tenant_id: account.id)
  #
  # Idempotent: each step is nudged at most once, so running it hourly only makes
  # the nudge arrive sooner — it never mails the same person twice. A no-op until
  # `config.reminder_after` is set, so scheduling it early is harmless.
  class ReminderSweepJob < ApplicationJob
    queue_as { ApprovalEngine.config.outbox_queue }

    def perform(tenant_id: nil)
      Step.sweep_reminders!(tenant_id: tenant_id)
    end
  end
end
