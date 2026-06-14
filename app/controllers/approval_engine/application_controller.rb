module ApprovalEngine
  # Base controller for the mounted ops dashboard. It deliberately inherits from
  # ActionController::Base (not the host's ApplicationController) so the
  # dashboard is self-contained; wrap the mount in your own auth constraint to
  # protect it.
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception
    layout "approval_engine/dashboard"
  end
end
