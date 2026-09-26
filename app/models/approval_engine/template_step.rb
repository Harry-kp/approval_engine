module ApprovalEngine
  # A blueprint for a layer of approval. When an approval is built, each template
  # step is expanded into one concrete Step per resolved actor, all sharing the
  # layer's consensus condition (`approvals_required`).
  class TemplateStep < ApplicationRecord
    include ConsensusValidatable

    belongs_to :track_template, class_name: "ApprovalEngine::TrackTemplate", foreign_key: "approval_engine_track_template_id"

    validates :name, :assigned_group, presence: true
    validates :layer, numericality: { greater_than: 0 }
    # A zero or negative deadline expires the step the moment it opens.
    # FlowDefinition already refuses one; this is the same guard for rows the
    # admin writes, so both doors into this table agree.
    validates :timeout_after, numericality: { greater_than: 0 }, allow_nil: true

    scope :ordered, -> { order(:layer) }
  end
end
