module ApprovalEngine
  # Periodic safety net that fires the timeout signal for every step whose
  # deadline has passed. Schedule it with whatever recurring mechanism you
  # already run (solid_queue recurring tasks, sidekiq-cron, the `whenever` gem,
  # a Kubernetes CronJob hitting a rake task, ...):
  #
  #   ApprovalEngine::TimeoutSweepJob.perform_later              # all tenants
  #   ApprovalEngine::TimeoutSweepJob.perform_later(tenant_id: account.id)
  #
  # Idempotent: each step times out at most once, so running it more often only
  # makes timeouts fire sooner — it never double-fires.
  class TimeoutSweepJob < ApplicationJob
    queue_as { ApprovalEngine.config.outbox_queue }

    def perform(tenant_id: nil)
      Step.sweep_timeouts!(tenant_id: tenant_id)
    end
  end
end
