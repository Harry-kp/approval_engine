require "digest"

module ApprovalEngine
  # The declarative flow builder behind `ApprovalEngine.define_flow`. It
  # reconciles a block of `on` / `step` / `parallel` declarations into the same
  # TrackTemplate / TemplateStep / TriggerRule rows an admin would author by
  # hand, so nothing downstream — ApprovalBuilder, the dashboard, the rule
  # builder — can tell a seeded flow from a hand-built one.
  #
  # Everything it can catch, it catches at definition time. This is setup code a
  # developer runs at deploy, so a typo should stop the seed with a sentence
  # explaining itself — the exact opposite of runtime rule evaluation, which
  # deliberately fails closed and silent so a bad rule can't 500 a host request.
  #
  # Re-running is safe. The flow is keyed on (tenant_id, name); steps are matched
  # by name and updated in place so the ids an admin UI links to survive; and a
  # rule the block stopped declaring is *deactivated*, never destroyed.
  #
  # An approval already in flight is untouched by any of that. ApprovalBuilder
  # copies a template step's name/layer/consensus/timeout onto the ledger when it
  # stamps the approval, and IterationBuilder clones a rework iteration from
  # those ledger rows rather than from the template — so a running approval holds
  # no live reference to anything this class rewrites, and finishes with the
  # steps it started with.
  class FlowDefinition
    class DefinitionError < ApprovalEngine::Error; end

    # A rule needs a condition — TriggerRule validates its presence and {} is
    # blank — so "route this event unconditionally" is spelled as a tautology.
    ALWAYS = { "==" => [ 1, 1 ] }.freeze

    # The options `on` understands. Listed rather than taken as keywords because
    # `when` is a Ruby keyword: `def on(event, when: nil)` parses but the value
    # is unreachable as a local.
    RULE_OPTIONS = %i[when priority active].freeze

    # Repeated verbatim from TemplateStep's validation so the same mistake reads
    # the same wherever it surfaces.
    CONSENSUS_HINT = "must be :any, :all, :majority, a percentage like \"60%\", or a positive integer".freeze

    # Named for what they are, not `Step`/`Rule`, so nothing in this file can
    # accidentally read as the ledger's ApprovalEngine::Step.
    DeclaredStep = Struct.new(:name, :group, :layer, :approvals_required, :timeout_after, keyword_init: true)
    DeclaredRule = Struct.new(:event_name, :condition, :priority, :active, keyword_init: true)

    def self.run(name:, tenant:, model:, status:, timeout_after:, &block)
      definition = new(name: name, tenant: tenant, model: model, status: status, timeout_after: timeout_after)
      definition.instance_eval(&block) if block
      definition.commit!
    end

    # The same coercion `Approvable#approval_tenant_id` does, plus `.to_s`
    # because `tenant_id` is a string column the reconciler compares in Ruby.
    def self.tenant_id_for(tenant)
      tenant.respond_to?(:id) ? tenant.id.to_s : tenant.to_s
    end

    def initialize(name:, tenant:, model:, status:, timeout_after:)
      @name = name.to_s
      guard_name!

      @tenant_id      = resolve_tenant!(tenant)
      @model          = model
      @status         = status.to_s
      @timeout_after  = seconds(timeout_after, "timeout_after")
      @declared_steps = []
      @declared_rules = []
      @layer          = 0

      guard_status!
      guard_model!
    end

    # --- block DSL -------------------------------------------------------

    # One layer of approval. `group` is the name handed to the host's
    # `resolve_approval_group(group_name, target)`; the engine expands it into
    # one step per actor that returns.
    def step(name, group:, approvals_required: nil, timeout_after: nil)
      if @open_layer && approvals_required
        raise DefinitionError,
              "step #{name.to_s.inspect} sets approvals_required inside a parallel block. Every step " \
              "in a layer shares one consensus policy (the engine reads a single spec per layer), so " \
              "declare it on the block: parallel(approvals_required: #{approvals_required.inspect})."
      end

      spec = @open_layer_consensus || approvals_required || :any
      guard_step_name!(name)
      guard_group!(name, group)
      guard_consensus!("step #{name.to_s.inspect}", spec)

      @declared_steps << DeclaredStep.new(
        name: name.to_s,
        group: group.to_s,
        layer: @open_layer || next_layer!,
        approvals_required: spec.to_s,
        timeout_after: seconds(timeout_after, "step #{name.to_s.inspect}: timeout_after") || @timeout_after
      )
    end

    # Steps that run at the same time, as one layer of the track.
    #
    # The consensus policy is declared here and never on the steps inside,
    # because `Track#tally_for` reads a single spec for the whole layer and
    # counts every actor in it — per-step specs would silently let whichever row
    # came first decide for the others.
    #
    # The default is `:all`, not the engine's `:any`: "Legal and IT review at the
    # same time" means both. Note the count is flat across the layer, so `:all`
    # over a 3-person Legal group and a 2-person IT group needs all five. "One
    # from each group" is a different shape — parallel *tracks*, which is
    # `run_approval!(templates: [...])`, not a layer.
    def parallel(approvals_required: :all, &block)
      raise DefinitionError, "parallel needs a block of steps." unless block
      raise DefinitionError, "parallel blocks can't be nested." if @open_layer

      guard_consensus!("parallel", approvals_required)
      layer                 = next_layer!
      @open_layer           = layer
      @open_layer_consensus = approvals_required

      begin
        instance_eval(&block)
      ensure
        @open_layer = @open_layer_consensus = nil
      end

      declared_here = @declared_steps.count { |declared| declared.layer == layer }

      if declared_here.zero?
        raise DefinitionError, "a parallel block in flow #{@name.inspect} declares no steps — it would leave " \
                               "an empty layer nothing can resolve."
      end

      guard_absolute_count_across_groups!(approvals_required, declared_here)
    end

    # An absolute count reads as "flat across the layer", which is how
    # `Track#tally_for` counts at runtime — but `ApprovalBuilder#guard_consensus!`
    # validates the same count against each template step's *own* actor list
    # before an approval is stamped. So `parallel(approvals_required: 2)` over
    # two one-person groups looks resolvable, and then every approval raises
    # BuilderError at build time instead. Rather than write a template that only
    # fails later, and far from here, refuse it now: a relative spec expresses
    # the same intent and is satisfiable however the groups resolve.
    def guard_absolute_count_across_groups!(spec, step_count)
      return unless step_count > 1
      return unless /\A\d+\z/.match?(spec.to_s)

      raise DefinitionError,
            "parallel in flow #{@name.inspect} sets approvals_required #{spec.to_s.inspect} across " \
            "#{step_count} groups. A plain count is checked against each group's own members when an " \
            "approval is built, so this would raise at approval time unless every group had at least " \
            "#{spec} people. Use :all, :any, :majority or a percentage, which hold however the groups resolve."
    end

    # A rule that routes an event to this flow. `event` is either a literal event
    # name ("invoice.created") or a lifecycle symbol resolved through the model,
    # which is how a rule and the engine stay reading from one source. Options
    # are `when:`, `priority:` and `active:`; `when:` omitted means "always".
    # May be called more than once — a template can carry several rules.
    def on(event, **options)
      unknown = options.keys - RULE_OPTIONS
      if unknown.any?
        raise DefinitionError, "on: unknown option(s) #{unknown.inspect}. It takes when:, priority: and active:."
      end

      event_name = resolve_event_name(event)
      condition  = compile_condition(event_name, options[:when])
      priority   = integer_priority(options.fetch(:priority, 0))

      if @declared_rules.any? { |rule| rule.event_name == event_name && rule.priority == priority }
        raise DefinitionError, "flow #{@name.inspect} declares two rules for #{event_name.inspect} at " \
                               "priority #{priority}. Give them different priorities so the order they " \
                               "are tried in is explicit."
      end

      warn_unrouted_lifecycle(event)
      @declared_rules << DeclaredRule.new(
        event_name: event_name, condition: condition, priority: priority, active: options.fetch(:active, true)
      )
    end

    # --- reconciliation --------------------------------------------------

    def commit!
      guard_steps_declared!
      guard_unique_step_names!
      guard_actor_class!

      ActiveRecord::Base.transaction do
        lock!
        template = upsert_template!
        reconcile_steps!(template)
        reconcile_rules!(template)
        template
      end
    end

    private

    # Two deploys can run db/seeds.rb at the same time. Without this, the
    # find-or-create in upsert_template! races into two templates with the same
    # name. Scoped to this one flow so unrelated flows never contend, and
    # released when the transaction ends.
    def lock!
      key = Digest::SHA256.digest("approval_engine.flow:#{@tenant_id}:#{@name}").unpack1("q>")
      # The key is coerced to an Integer immediately before interpolation, which
      # is what makes this provably injection-free; the tenant and the name never
      # reach the SQL themselves. `execute` rather than `select_value` because
      # the function returns void, which has no ActiveRecord type to decode.
      ActiveRecord::Base.connection.execute("SELECT pg_advisory_xact_lock(#{key.to_i})")
    end

    # There is no unique index on (tenant_id, name) — an existing install may
    # already hold duplicates, so adding one could break a production migrate —
    # which means the invariant is enforced here, and refuses to guess.
    def upsert_template!
      matches = TrackTemplate.for_tenant(@tenant_id).where(name: @name).order(:created_at).to_a

      if matches.size > 1
        raise DefinitionError,
              "tenant #{@tenant_id.inspect} already has #{matches.size} templates named #{@name.inspect} " \
              "(#{matches.map(&:id).join(", ")}). define_flow can't tell which one it owns — archive or " \
              "rename the extras first."
      end

      template = matches.first || TrackTemplate.new(tenant_id: @tenant_id, name: @name)
      template.update!(status: @status)
      template
    end

    # Steps are matched by name and updated in place, so re-running a seed keeps
    # the ids an admin UI links to. Nothing outside the template points at a
    # template step — ApprovalBuilder copies its facts onto the ledger when an
    # approval is built — so rewriting them can never disturb an approval already
    # in flight. Renaming a step therefore reads as a remove plus an add.
    def reconcile_steps!(template)
      # group_by, not index_by: a hand-built template can hold two steps with the
      # same name, and index_by would keep the last and strand the other forever.
      existing = template.template_steps.group_by(&:name)

      @declared_steps.each do |declared|
        same_name = existing.delete(declared.name) || []
        record    = same_name.shift || template.template_steps.new(name: declared.name)
        same_name.each(&:destroy!)

        record.update!(
          layer: declared.layer,
          assigned_group: declared.group,
          approvals_required: declared.approvals_required,
          timeout_after: declared.timeout_after
        )
      end

      existing.each_value { |orphans| orphans.each(&:destroy!) }
      template.template_steps.reset
    end

    # Rules are updated and deactivated, never destroyed. An Approval keeps the
    # rule that routed it as provenance, on a foreign key declared
    # `on_delete: :nullify` — so destroying a rule would not error, it would
    # quietly erase "which rule started this?" from every approval it ever
    # spawned. Deactivating stops it routing anything new, which is what dropping
    # an `on` from a flow actually means.
    #
    # Asymmetric with steps on purpose: a template with no steps is always a bug,
    # but a flow whose steps live in code and whose routing an admin owns in the
    # UI is a legitimate shape, so a block with no `on` leaves rules alone.
    def reconcile_rules!(template)
      return if @declared_rules.empty?

      existing = template.trigger_rules.group_by { |rule| [ rule.event_name, rule.priority ] }

      @declared_rules.each do |declared|
        same_key = existing.delete([ declared.event_name, declared.priority ]) || []
        record   = same_key.shift || template.trigger_rules.new
        same_key.each { |dupe| dupe.update!(active: false) }

        record.update!(
          tenant_id: @tenant_id,
          event_name: declared.event_name,
          condition: declared.condition,
          priority: declared.priority,
          active: declared.active
        )
      end

      existing.each_value { |retired| retired.each { |rule| rule.update!(active: false) } }
      template.trigger_rules.reset
    end

    # --- declaration helpers ---------------------------------------------

    def next_layer!
      @layer += 1
    end

    def resolve_tenant!(tenant)
      tenant = ApprovalEngine.current_tenant if tenant.nil?

      if tenant.nil? || (tenant.respond_to?(:empty?) && tenant.empty?)
        raise DefinitionError, "define_flow needs a tenant: — pass one, or set config.current_tenant_method."
      end

      self.class.tenant_id_for(tenant)
    end

    def resolve_event_name(event)
      return event.to_s unless event.is_a?(Symbol)

      unless @model
        raise DefinitionError, "on(#{event.inspect}) needs the model: option so the flow can ask it for the " \
                               "conventional event name — or pass the event name as a string."
      end

      begin
        @model.approval_event_name(event)
      rescue KeyError
        raise DefinitionError, "on(#{event.inspect}) isn't a lifecycle #{@model} understands — it knows " \
                               "#{ApprovalEngine::Approvable::LIFECYCLE_EVENTS.keys.inspect}. Pass a string " \
                               "for any other event name."
      end
    end

    # Condition.from raises ArgumentError for its own vocabulary problems; wrap
    # them so a caller only ever has to rescue one error class.
    def compile_condition(event_name, clause)
      return ALWAYS if clause.blank?

      condition = ApprovalEngine::Condition.from(clause, types: condition_types)
      guard_exposed_attributes!(event_name, condition)
      condition
    rescue ArgumentError => e
      raise DefinitionError, "flow #{@name.inspect}: the when: for #{event_name.inspect} is invalid — #{e.message}."
    end

    # Cast a `when:` value the same way the payload will be coerced, so a rule
    # can never compare a number against a string and quietly never match. The
    # default is :raw so a field the model doesn't declare passes through with
    # whatever Ruby type the caller wrote.
    def condition_types
      return Hash.new(:raw) unless @model.respond_to?(:approval_exposure)

      @model.approval_exposure.attributes.each_with_object(Hash.new(:raw)) do |(attribute_name, attribute), types|
        types[attribute_name] = attribute.type
      end
    end

    # Every attribute name a condition reads, however deeply nested. Condition's
    # own `parse` can't serve here: it returns nil for an `or` or a nested `and`,
    # and hand-written raw JSON Logic is exactly where the typo lives.
    def condition_vars(node)
      case node
      when Hash  then node.key?("var") ? Array(var_name(node["var"])) : node.values.flat_map { |value| condition_vars(value) }
      when Array then node.flat_map { |value| condition_vars(value) }
      else []
      end
    end

    # JSON Logic's `var` operand is not always a bare attribute name. It is also
    # written `["amount", 0]` to supply a default, and `"line_item.total"` to
    # walk into nested data — both of which the evaluator implements. Comparing
    # either form verbatim against the exposure list rejected a rule that works,
    # and blamed an attribute name nobody had written. An empty operand means
    # "the whole payload", which reads nothing in particular, so it is skipped.
    def var_name(operand)
      key = Array(operand).first.to_s
      return nil if key.empty?

      key.split(".").first
    end

    def integer_priority(value)
      Integer(value)
    rescue ArgumentError, TypeError
      raise DefinitionError, "on: priority must be an integer, got #{value.inspect}."
    end

    # Durations and plain second counts both land as an Integer of seconds, which
    # is what the column holds. A zero or negative deadline would expire the step
    # the moment it opened, so it is rejected rather than stored.
    def seconds(value, label)
      return nil if value.nil?

      converted = value.is_a?(Numeric) || value.is_a?(ActiveSupport::Duration) ? value.to_i : nil
      return converted if converted&.positive?

      raise DefinitionError, "#{label} must be a positive number of seconds (or a duration like 2.days), " \
                             "got #{value.inspect}."
    end

    # --- guards ----------------------------------------------------------

    def guard_name!
      raise DefinitionError, "define_flow needs a name." if @name.empty?
    end

    def guard_status!
      return if TrackTemplate::STATUSES.include?(@status)

      raise DefinitionError, "define_flow status #{@status.inspect} is not one of " \
                             "#{TrackTemplate::STATUSES.join(", ")}."
    end

    def guard_model!
      return if @model.nil?
      return if @model.respond_to?(:approval_exposure)

      raise DefinitionError, "model: #{@model} hasn't called has_approvals, so it has no exposed attributes " \
                             "or event names to check against."
    end

    def guard_step_name!(name)
      return if name.present?

      raise DefinitionError, "step needs a name — it is how a step is identified across re-runs."
    end

    def guard_group!(step_name, group)
      if group.blank?
        raise DefinitionError, "step #{step_name.to_s.inspect} needs a group: — the name your " \
                               "resolve_approval_group turns into actors."
      end

      allowed = ApprovalEngine.config.approval_groups
      return if allowed.nil?

      known = Array(allowed).map(&:to_s)
      return if known.include?(group.to_s)

      raise DefinitionError, "step #{step_name.to_s.inspect} uses group #{group.to_s.inspect}, which isn't " \
                             "in config.approval_groups (#{known.join(", ")})."
    end

    # Validate with Consensus, the same predicate the model and the Postgres
    # check constraint use, so the DSL can never invent a second spelling.
    def guard_consensus!(subject, spec)
      return if Consensus.valid?(spec)

      raise DefinitionError, "#{subject} has approvals_required #{spec.to_s.inspect} — #{CONSENSUS_HINT}."
    end

    def guard_steps_declared!
      return if @declared_steps.any?

      raise DefinitionError, "flow #{@name.inspect} declares no steps. An approval built from it would " \
                             "create a track with nothing to approve and sit pending forever."
    end

    def guard_unique_step_names!
      duplicate = @declared_steps.map(&:name).tally.find { |_name, count| count > 1 }
      return unless duplicate

      raise DefinitionError, "flow #{@name.inspect} declares two steps named #{duplicate.first.inspect}. " \
                             "Step names identify a step across re-runs, so they have to be unique within a flow."
    end

    # The same check ApprovalBuilder makes at build time, brought forward: a
    # missing resolver is a certainty rather than a possibility, so there is no
    # reason to make the first approval discover it.
    def guard_actor_class!
      klass = begin
        ApprovalEngine.config.actor_class_constant
      rescue NameError => e
        raise DefinitionError, "ApprovalEngine.config.actor_class is " \
                               "#{ApprovalEngine.config.actor_class.inspect}, which doesn't resolve to a " \
                               "loaded class (#{e.message})."
      end

      return if klass.respond_to?(:resolve_approval_group)

      raise DefinitionError, "#{klass} must define `self.resolve_approval_group(group_name, target)`."
    end

    # A JSON Logic var that names nothing the model exposes reads as a clean
    # non-match, so the rule just silently never fires. That is the right runtime
    # behaviour and the wrong thing to discover in production.
    def guard_exposed_attributes!(event_name, condition)
      return unless @model.respond_to?(:approval_exposure)

      exposed = @model.approval_exposure.attributes.keys
      unknown = condition_vars(condition).uniq - exposed
      return if unknown.empty?

      raise DefinitionError,
            "flow #{@name.inspect}: the rule for #{event_name.inspect} reads #{unknown.join(", ")}, which " \
            "#{@model} doesn't expose (it exposes #{exposed.join(", ")}). Add it to exposes_for_approval or " \
            "fix the name — an unexposed var reads as a clean non-match, so the rule would never fire."
    end

    # on(:create) asks for auto-routing, so say so when the model isn't armed for
    # it. Not fatal: plenty of hosts fire run_approval!(event:) themselves.
    def warn_unrouted_lifecycle(event)
      return unless event.is_a?(Symbol)
      return unless @model.respond_to?(:approval_trigger_events)
      return if @model.approval_trigger_events.include?(event)

      Rails.logger&.warn("[ApprovalEngine] flow #{@name.inspect} routes #{@model}.#{event}, but #{@model} " \
                         "declares has_approvals(on: #{@model.approval_trigger_events.inspect}) — nothing " \
                         "will fire it automatically.")
    end
  end
end
