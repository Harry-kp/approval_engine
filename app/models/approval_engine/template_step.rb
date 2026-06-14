module ApprovalEngine
  # A blueprint for a layer of approval. When an approval is built, each template
  # step is expanded into one concrete Step per resolved actor, all sharing the
  # layer's consensus condition (`approvals_required`).
  class TemplateStep < ApplicationRecord
    belongs_to :track_template, class_name: "ApprovalEngine::TrackTemplate", foreign_key: "approval_engine_track_template_id"

    validates :name, :assigned_group, presence: true
    validates :layer, numericality: { greater_than: 0 }
    validate :approvals_required_is_valid

    scope :ordered, -> { order(:layer) }

    private

    def approvals_required_is_valid
      return if Consensus.valid?(approvals_required)

      errors.add(:approvals_required, "must be :any, :all, :majority, a percentage like \"60%\", or a positive integer")
    end
  end
end
