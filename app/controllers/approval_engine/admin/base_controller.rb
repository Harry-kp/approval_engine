module ApprovalEngine
  module Admin
    # Base for the opt-in admin: the write half of the mounted dashboard, and
    # the only place in the engine that edits blueprints. It inherits the
    # dashboard's layout and CSRF posture and adds the one thing the routes
    # can't guarantee — that the flag is *still* on for this request.
    class BaseController < ApplicationController
      helper ApprovalEngine::ApplicationHelper
      helper ApprovalEngine::Admin::BaseHelper

      before_action :ensure_admin_enabled

      helper_method :exposed_attribute_groups, :known_event_names, :default_tenant_id

      private

      # Routes are drawn once at boot. A host that flips the flag off, or that
      # points its own route at these controllers, must not get a write surface,
      # so the check is repeated here rather than trusted from boot time.
      def ensure_admin_enabled
        head :not_found unless ApprovalEngine.config.admin_enabled
      end

      # The whitelisted surface a rule may read, grouped by model, so the field
      # dropdown offers the names `exposes_for_approval` actually declared. An
      # unexposed var is a clean non-match, i.e. a rule that silently never
      # fires — the single most common way a hand-typed rule goes wrong.
      def exposed_attribute_groups
        @exposed_attribute_groups ||= approvable_models.to_h { |model| [ model.name, exposed_options_for(model) ] }
                                                       .reject { |_name, options| options.empty? }
      end

      # A model armed with `has_approvals` but no `exposes_for_approval` block
      # has nothing a rule may read, so it is left out entirely rather than
      # offered as an empty group.
      def exposed_options_for(model)
        model.approval_exposure.attributes.values.map do |attribute|
          [ "#{attribute.name} (#{attribute.type})", attribute.name.to_s ]
        end
      end

      # Event names the engine itself emits, plus the ones rules already use, so
      # a domain event someone triggers by hand is offered too. It's a datalist,
      # not a select: any string is still allowed.
      def known_event_names
        @known_event_names ||= begin
          conventional = approvable_models.flat_map do |model|
            ApprovalEngine::Approvable::LIFECYCLE_EVENTS.each_key.map { |lifecycle| model.approval_event_name(lifecycle) }
          end
          (conventional | TriggerRule.distinct.pluck(:event_name)).compact.sort
        end
      end

      # Declared types, so a value typed into a text field is stored as the type
      # the payload will carry. `amount > "10000"` compares a number to a string
      # and quietly never matches; this is what stops that. Scoped to the model
      # the event belongs to ("invoice.created" -> Invoice), falling back to
      # every exposed attribute for a hand-named domain event.
      def attribute_types(event_name)
        element = event_name.to_s.split(".").first
        models  = approvable_models.select { |model| model.model_name.element == element }
        models  = approvable_models if models.empty?
        models.reverse.reduce({}) { |types, model| types.merge(model.approval_exposure.attributes.transform_values(&:type)) }
      end

      # The registry only knows classes Rails has actually loaded, and in
      # development it loads them on demand — a cold-booted admin would offer an
      # empty field list. Eager loading once is the price of an honest one.
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
