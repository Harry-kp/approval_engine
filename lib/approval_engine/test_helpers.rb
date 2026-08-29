module ApprovalEngine
  # Test support for applications using the engine.
  #
  #   require "approval_engine/test_helpers"
  #   class ActiveSupport::TestCase
  #     include ApprovalEngine::TestHelpers
  #   end
  #
  # Framework-agnostic on purpose: these are actions and queries, not
  # assertions, so they read the same under Minitest and RSpec.
  #
  #   invoice = Invoice.create!(amount: 20_000)
  #   assert_equal "Manager sign-off", pending_approval_steps(invoice).sole.name
  #
  #   approve_approval!(invoice)              # walk it to a decision
  #   assert invoice.reload.approved?         # after the outbox has run
  module TestHelpers
    # The most recent approval raised against a record, or nil.
    def approval_for(record)
      ApprovalEngine::Approval.where(target: record).order(:created_at).last
    end

    # Steps waiting on somebody right now — the inbox, for a single record.
    def pending_approval_steps(record)
      approval = approval_for(record)
      return ApprovalEngine::Step.none if approval.nil?

      approval.steps.pending
    end

    # Approve every step as it opens until the approval reaches a terminal
    # state, so a test can assert on the *outcome* without walking layers by
    # hand. Each step is approved by its own assigned actor unless `by:` names
    # someone; `limit` stops a misconfigured flow from looping forever.
    def approve_approval!(record, by: nil, limit: 50)
      approval = approval_for(record) or raise ArgumentError, "#{record.class} has no approval"

      limit.times do
        steps = approval.steps.reload.pending.to_a
        break if steps.empty?

        steps.each { |step| step.approve!(by: by || step.assigned_actor) }
        break if approval.reload.status != "pending"
      end

      approval.reload
    end

    # Reject at the first step currently waiting.
    def reject_approval!(record, by: nil, comment: nil)
      step = pending_approval_steps(record).first or raise ArgumentError, "nothing is pending on #{record.class}"
      step.reject!(by: by || step.assigned_actor, comment: comment)
      approval_for(record).reload
    end

    # Side-effects reach the host through the outbox, which is relayed by
    # ActiveJob — so in a test nothing has happened until the queue is drained.
    # This is the line whose absence makes `after_approved` look broken.
    def drain_approval_outbox!
      ApprovalEngine::OutboxEvent.unprocessed.order(:created_at).pluck(:id).each do |id|
        ApprovalEngine::ProcessOutboxJob.perform_now(id)
      end
    end

    # Approve to completion and relay the side-effects, which is what "it was
    # approved" means from the host's point of view.
    def approve_approval_and_settle!(record, by: nil)
      approve_approval!(record, by: by).tap { drain_approval_outbox! }
    end
  end
end
