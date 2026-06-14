Rails.application.routes.draw do
  mount ApprovalEngine::Engine => "/approval_engine"
end
