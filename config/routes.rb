ApprovalEngine::Engine.routes.draw do
  # Read-only ops dashboard. Mount behind your own auth, e.g.:
  #   authenticate :admin_user, ->(u) { u.super_admin? } do
  #     mount ApprovalEngine::Engine => "/approval_engine"
  #   end
  root to: "approvals#index"
  resources :approvals, only: %i[index show]

  # The runtime rule editor — the engine's only write surface, so it is drawn
  # only when the host asks for it. Routes are drawn once at boot, well after
  # config/initializers run, so reading the flag here is safe; a flag flipped
  # later needs a restart (the controllers re-check it per request anyway).
  if ApprovalEngine.config.admin_enabled
    namespace :admin do
      root to: "track_templates#index"
      resources :track_templates do
        resources :template_steps, only: %i[new create edit update destroy]
        resources :trigger_rules, only: %i[new create edit update destroy]
      end
      resources :trigger_rules, only: %i[index]
    end
  end
end
