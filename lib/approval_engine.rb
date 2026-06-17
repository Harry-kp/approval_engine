require "approval_engine/version"
require "approval_engine/configuration"
require "approval_engine/approval_exposure"
require "approval_engine/model_extensions"
require "approval_engine/engine"

module ApprovalEngine
  # Base class for every error the engine raises itself, so a host can rescue
  # ApprovalEngine::Error to catch them all. (Step transitions still raise the
  # Rails-idiomatic ActiveRecord::RecordInvalid.)
  class Error < StandardError; end
end
