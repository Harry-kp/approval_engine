ApprovalEngine::Engine.routes.draw do
  # Read-only ops dashboard. Mount behind your own auth, e.g.:
  #   authenticate :admin_user, ->(u) { u.super_admin? } do
  #     mount ApprovalEngine::Engine => "/approval_engine"
  #   end
  root to: "approvals#index"
  resources :approvals, only: %i[index show]
end
