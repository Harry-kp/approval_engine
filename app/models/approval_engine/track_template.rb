module ApprovalEngine
  # The reusable blueprint an approval is stamped from. Authored by SaaS admins
  # (often through a UI) and selected at runtime by the matching TriggerRule.
  class TrackTemplate < ApplicationRecord
    STATUSES = %w[draft active archived].freeze

    has_many :template_steps,
             -> { ordered },
             class_name: "ApprovalEngine::TemplateStep",
             foreign_key: "approval_engine_track_template_id",
             dependent: :destroy
    has_many :trigger_rules,
             class_name: "ApprovalEngine::TriggerRule",
             foreign_key: "approval_engine_track_template_id",
             dependent: :destroy

    validates :tenant_id, :name, presence: true
    validates :status, inclusion: { in: STATUSES }

    scope :active, -> { where(status: "active") }
    scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }
  end
end
