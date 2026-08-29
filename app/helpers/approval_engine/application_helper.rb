module ApprovalEngine
  module ApplicationHelper
    STATUS_TONES = {
      "pending" => "is-pending", "waiting" => "is-waiting",
      "approved" => "is-approved", "rejected" => "is-rejected",
      "changes_requested" => "is-changes-requested", "cancelled" => "is-cancelled",
      "quarantined" => "is-quarantined",
      # Template lifecycle, which the admin renders through the same badge.
      "draft" => "is-waiting", "active" => "is-approved", "archived" => "is-cancelled"
    }.freeze

    # The admin nav exists only when the host opted in *and* the routes were
    # drawn for it — a flag flipped after boot leaves the helpers undefined,
    # and a host that never opts in gets exactly the 1.0 read-only page.
    def admin_ui?
      ApprovalEngine.config.admin_enabled && respond_to?(:admin_track_templates_path)
    end

    def status_badge(status)
      tag.span(status.to_s.tr("_", " "), class: "ae-badge #{STATUS_TONES.fetch(status.to_s, "is-pending")}")
    end

    def actor_label(actor)
      return "—" if actor.nil?

      name = actor.try(:name) || actor.try(:email) || actor.try(:to_s)
      "#{actor.class.name}##{actor.id} (#{name})"
    end

    def target_label(target)
      return "—" if target.nil?

      "#{target.class.name}##{target.id}"
    end
  end
end
