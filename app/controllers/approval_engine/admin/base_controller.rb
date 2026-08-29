module ApprovalEngine
  module Admin
    # Base for the opt-in admin — the only place in the engine that edits
    # blueprints. Inherits the dashboard's layout and CSRF posture.
    class BaseController < ApplicationController
      helper ApprovalEngine::ApplicationHelper
      helper ApprovalEngine::Admin::BaseHelper

      before_action :ensure_admin_enabled

      helper_method :exposed_attribute_groups, :known_event_names, :default_tenant_id

      private

      # Routes are drawn once at boot, so re-check per request: a host that
      # flips the flag off must not still have a write surface.
      def ensure_admin_enabled
        head :not_found unless ApprovalEngine.config.admin_enabled
      end

      # What a rule may read, so the dropdown offers real names. An unexposed
      # var is a clean non-match — a rule that silently never fires.
      def exposed_attribute_groups
        @exposed_attribute_groups ||= approvable_models.to_h { |model| [ model.name, exposed_options_for(model) ] }
                                                       .reject { |_name, options| options.empty? }
      end

      # Nothing exposed means nothing a rule can read, so omit it entirely.
      def exposed_options_for(model)
        model.approval_exposure.attributes.values.map do |attribute|
          [ "#{attribute.name} (#{attribute.type})", attribute.name.to_s ]
        end
      end

      # Conventional names plus ones already in use. A datalist, not a select —
      # any string is still allowed.
      def known_event_names
        @known_event_names ||= begin
          conventional = approvable_models.flat_map do |model|
            ApprovalEngine::Approvable::LIFECYCLE_EVENTS.each_key.map { |lifecycle| model.approval_event_name(lifecycle) }
          end
          (conventional | TriggerRule.distinct.pluck(:event_name)).compact.sort
        end
      end

      # So a typed value is stored as the type the payload carries — otherwise
      # `amount > "10000"` compares a number to a string and never matches.
      # Scoped by event prefix, falling back to every exposed attribute.
      def attribute_types(event_name)
        element = event_name.to_s.split(".").first
        models  = approvable_models.select { |model| model.model_name.element == element }
        models  = approvable_models if models.empty?
        models.reverse.reduce({}) { |types, model| types.merge(model.approval_exposure.attributes.transform_values(&:type)) }
      end

      # In development classes load on demand, so a cold-booted admin would
      # offer an empty field list. Eager loading once is the price.
      def approvable_models
        @approvable_models ||= begin
          Rails.application.eager_load! unless Rails.application.config.eager_load
          ApprovalEngine.approvable_models
        end
      end

      # Prefill only. The dashboard is a cross-tenant ops surface and stays one:
      # `current_tenant_method` is nil by default and an ops mount has no tenant
      # in scope, so scoping reads to it would usually show an empty page.
      def default_tenant_id
        tenant = ApprovalEngine.current_tenant
        tenant.respond_to?(:id) ? tenant.id : tenant
      end
    end
  end
end
