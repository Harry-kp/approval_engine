module ApprovalEngine
  # A read-only view of everything a record has gone through: every approval it
  # spawned, the track/step tree beneath each, and a flat chronological
  # timeline of the actions taken (with actors and comments).
  #
  # It assembles the data; *who* may see it and *how* it's rendered is the host's
  # call — wrap it in your own authorization and UI.
  #
  #   history = invoice.approval_history
  #   history.approvals   # => newest-first, tree preloaded (no N+1)
  #   history.events      # => chronological audit entries across everything
  class History
    def self.for(record)
      new(record)
    end

    def initialize(record)
      @record = record
    end

    # Every approval for the record, newest first, with tracks, steps and
    # their assigned actors eager-loaded so traversal doesn't fan out into N+1
    # queries.
    def approvals
      @approvals ||= Approval.where(target: @record)
                             .includes(tracks: { steps: :assigned_actor })
                             .order(created_at: :desc)
                             .to_a
    end

    def latest
      approvals.first
    end

    def empty?
      approvals.empty?
    end

    # The "what happened" narrative: every step action (approved / rejected /
    # changes_requested) across all of this record's approvals and iterations,
    # oldest first. Queried (and ordered + capped) in the database rather than by
    # walking the whole tree in Ruby, with the polymorphic actors preloaded.
    # Each entry is an AuditLog, so the host can read its event, actors (intended
    # vs actual), comment, timestamp and step context.
    def events(limit: 500)
      AuditLog.where(approval_engine_step_id: step_ids)
              .preload(:actual_actor, :intended_actor, step: :assigned_actor)
              .order(:created_at)
              .limit(limit)
    end

    private

    # Step ids belonging to this record's approvals, as a subquery so the events
    # query stays a single statement (no per-row joins, no eager-load surprises).
    def step_ids
      Step.joins(track: :approval)
          .where(approval_engine_approvals: { target_type: @record.class.polymorphic_name, target_id: @record.id })
          .select(:id)
    end
  end
end
