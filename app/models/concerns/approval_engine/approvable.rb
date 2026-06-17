module ApprovalEngine
  # Mixed into a host model by the `has_approvals` macro. Gives the
  # model its approval association, the `exposes_for_approval` anti-corruption
  # DSL, and the trigger that spawns an approval for a domain event.
  #
  #   class Invoice < ApplicationRecord
  #     has_approvals
  #
  #     exposes_for_approval do
  #       attribute :amount, type: :decimal
  #       attribute :department, type: :string, source: ->(i) { i.department.name }
  #     end
  #
  #     def after_approved
  #       PaymentService.disburse_funds!(self)
  #     end
  #   end
  #
  # By default, creating the record evaluates the tenant's rules and spawns the
  # matching approval. Override `trigger_approval?` to gate that, or
  # pass `has_approvals(on: [])` to opt out and trigger manually with
  # `record.run_approval!(event:)`.
  module Approvable
    extend ActiveSupport::Concern

    # The ActiveRecord lifecycle events the `on:` option understands, mapped to
    # the conventional suffix of the event they route (create -> "<model>.created").
    # Add a lifecycle here and it's wired automatically — no new methods.
    LIFECYCLE_EVENTS = { create: "created", update: "updated", destroy: "destroyed" }.freeze

    included do
      has_many :approvals,
               class_name: "ApprovalEngine::Approval",
               as: :target,
               dependent: :destroy

      # Per-class exposure, inherited and dup-on-write so subclasses can extend
      # a parent's declaration without mutating it.
      class_attribute :approval_exposure,
                      instance_writer: false,
                      default: ApprovalEngine::ApprovalExposure.new

      # Which lifecycle events auto-trigger routing. Set by the macro.
      class_attribute :approval_trigger_events, instance_writer: false, default: [].freeze

      # One generic registration for every lifecycle — no method-per-event.
      LIFECYCLE_EVENTS.each_key do |lifecycle|
        after_commit(on: lifecycle, if: -> { auto_trigger_approval?(lifecycle) }) do
          run_approval!(event: self.class.approval_event_name(lifecycle))
        end
      end
    end

    class_methods do
      # Declare the whitelisted surface the rules engine may read. Additive: can
      # be called more than once, and subclasses extend rather than replace.
      def exposes_for_approval(&block)
        exposure = approval_exposure.dup
        exposure.instance_eval(&block) if block
        self.approval_exposure = exposure
      end

      # The conventional event name an auto-trigger emits for a lifecycle
      # (:create, :update, :destroy). Use it when defining rules so the rule's
      # event_name can never drift from what the engine actually fires:
      #
      #   trigger_rules.create!(event_name: Invoice.approval_event_name(:create), ...)
      #
      # Raises for an unknown lifecycle rather than producing a silent typo.
      def approval_event_name(lifecycle)
        "#{model_name.element}.#{LIFECYCLE_EVENTS.fetch(lifecycle)}"
      end
    end

    # The flat, string-keyed payload derived from `exposes_for_approval`.
    def serialize_for_approval
      approval_exposure.serialize(self)
    end

    # Start an approval, two ways (pass exactly one):
    #
    #   run_approval!(event: "invoice.created")     # engine routes by rules
    #   run_approval!(templates: [finance, legal])  # you choose explicitly
    #
    # With `event:`, the tenant's rules are evaluated and the highest-priority
    # match is spawned — returns the approval, a quarantine approval on a rule
    # failure, or nil when nothing matched (or the tenant can't be resolved).
    #
    # With `templates:`, rule evaluation is skipped and exactly those templates
    # are started (several become parallel tracks of one approval); always
    # returns the spawned approval. Pair with `approval_candidates` to let a user
    # choose instead of the engine. `approvals_required` is the gather consensus
    # across those tracks (default `:all`).
    def run_approval!(event: nil, templates: nil, approvals_required: "all", tenant_id: approval_tenant_id)
      raise ArgumentError, "pass either event: or templates:, not both" if event && templates

      if templates
        ApprovalEngine::ApprovalBuilder.build_parallel!(templates: Array(templates), target: self, approvals_required: approvals_required)
      elsif event
        return if tenant_id.nil?

        ApprovalEngine::RuleEvaluator.call(
          event_name: event,
          tenant_id: tenant_id,
          target: self,
          payload: serialize_for_approval
        )
      else
        raise ArgumentError, "pass either event: or templates:"
      end
    end

    # Host override hook: return false to skip an automatic trigger. Receives
    # the lifecycle (:create or :update), so you can gate per-event — e.g. only
    # auto-route an update when a specific transition happened:
    #
    #   def trigger_approval?(lifecycle)
    #     lifecycle == :update ? saved_change_to_status? : true
    #   end
    def trigger_approval?(_lifecycle = nil)
      true
    end

    # Preview what `event` *would* trigger for this record, without writing
    # anything — handy for showing a user "this will go to Manager, then CFO"
    # before they commit an action. Works against the in-memory record, so you
    # can preview an unsaved change (`invoice.amount = 20_000; invoice.preview_...`).
    # Returns an ApprovalEngine::ApprovalPlan.
    def preview_approval(event:, tenant_id: approval_tenant_id)
      ApprovalEngine::RuleEvaluator.preview(
        event_name: event,
        tenant_id: tenant_id,
        target: self,
        payload: serialize_for_approval
      )
    end

    # Every approval that *would* match `event` for this record, in priority
    # order — so you can let a user choose which to trigger rather than letting
    # the engine auto-pick the top one. Returns an array of ApprovalPlan; writes
    # nothing.
    def approval_candidates(event:, tenant_id: approval_tenant_id)
      ApprovalEngine::RuleEvaluator.candidates(
        event_name: event,
        tenant_id: tenant_id,
        target: self,
        payload: serialize_for_approval
      )
    end

    # A read-only view of everything this record has gone through — approvals,
    # the step tree, and a chronological timeline of actions + comments. The
    # gem assembles it; you decide who may see it and how to render it.
    def approval_history
      ApprovalEngine::History.for(self)
    end

    def latest_approval
      approvals.order(created_at: :desc).first
    end

    def approval_in_flight?
      approvals.pending.exists?
    end

    def approval_status
      latest_approval&.status
    end

    private

    def auto_trigger_approval?(lifecycle)
      approval_trigger_events.include?(lifecycle) && trigger_approval?(lifecycle)
    end

    # Tenant id derived from the configured `current_tenant_method`. Override in
    # the host model if the tenant lives somewhere model-specific.
    def approval_tenant_id
      tenant = ApprovalEngine.current_tenant
      tenant.respond_to?(:id) ? tenant.id : tenant
    end
  end
end
