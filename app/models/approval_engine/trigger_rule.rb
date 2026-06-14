module ApprovalEngine
  # A tenant-scoped routing rule. Its `condition` is a JSON Logic AST stored in
  # JSONB; the RuleEvaluator applies it to a host payload and, on the
  # highest-priority match, spawns the linked template's approval.
  class TriggerRule < ApplicationRecord
    belongs_to :track_template, class_name: "ApprovalEngine::TrackTemplate", foreign_key: "approval_engine_track_template_id"

    validates :tenant_id, :event_name, presence: true
    validates :condition, presence: true
    validates :priority, numericality: { only_integer: true }

    scope :active, -> { where(active: true) }
    scope :for_event, ->(event) { where(event_name: event) }
    scope :for_tenant, ->(tenant_id) { where(tenant_id: tenant_id) }
    scope :by_priority, -> { order(priority: :desc) }
  end
end
