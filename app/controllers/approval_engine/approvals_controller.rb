module ApprovalEngine
  # The dashboard's approval list and detail views. Read-only by design — its
  # job is to surface stuck, quarantined and in-flight work without anyone
  # writing SQL, not to act on it.
  class ApprovalsController < ApplicationController
    PAGE_LIMIT = 100

    def index
      @status = params[:status].presence
      @counts = Approval.group(:status).count
      scope = Approval.all.order(created_at: :desc)
      scope = scope.where(status: @status) if @status
      @approvals = scope.limit(PAGE_LIMIT).to_a
      @total = scope.count
      # One grouped query for all the row counts, instead of N `.tracks.size`.
      @track_counts = Track.where(approval_engine_approval_id: @approvals.map(&:id))
                             .group(:approval_engine_approval_id).count
    end

    def show
      # Preload the whole tree *including* the polymorphic actors the view renders
      # (assigned actor, and each audit log's actual/intended actor) so the page
      # is a fixed handful of queries regardless of how many steps it has.
      @approval = Approval.includes(
        tracks: { steps: [ :assigned_actor, { audit_logs: %i[actual_actor intended_actor] } ] }
      ).find(params[:id])
    end
  end
end
