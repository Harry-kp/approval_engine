class Invoice < ApplicationRecord
  # Trigger tracks explicitly in tests for deterministic control rather than
  # auto-routing on create.
  has_approvals on: []

  exposes_for_approval do
    attribute :amount, type: :decimal
    attribute :department, type: :string
  end

  # Conventional side-effect callback, fired via the transactional outbox once
  # the whole approval is approved.
  def after_approved
    update!(state: "paid")
  end

  def after_rejected(_reason = nil)
    update!(state: "rejected")
  end
end
