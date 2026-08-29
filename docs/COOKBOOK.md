# Cookbook

Scan for the scenario that matches yours and copy the recipe. Each one maps to a
documented use case and is exercised by the test suite, so "it's in the
cookbook" means "it's covered."

Assumes you've armed a model and configured an actor class — see the
[README](../README.md) quickstart.

- [Routing & templates](#routing--templates)
- [Previewing](#previewing)
- [Acting on approvals](#acting-on-approvals)
- [Consensus](#consensus)
- [Parallel review](#parallel-review)
- [Delegation](#delegation)
- [Withdrawing & escalating](#withdrawing--escalating)
- [Side-effects & chaining](#side-effects--chaining)
- [Notifications](#notifications)
- [Integrating with your model's status](#integrating-with-your-models-status)
- [Multi-tenancy](#multi-tenancy)
- [Safety](#safety)
- [Customizing behavior](#customizing-behavior)
- [UI & monitoring](#ui--monitoring)

---

## Routing & templates

### "One flow shouldn't take four `create!` calls" (defining a flow in code)

`ApprovalEngine.define_flow` writes the template, its ordered steps, and the
rules that route to it in one block:

```ruby
# db/seeds.rb
ApprovalEngine.define_flow "High-value invoice", tenant: "acme", model: Invoice do
  on :create, when: { amount: { gt: 10_000 } }

  step "Manager sign-off", group: "manager"
  step "CFO sign-off",     group: "cfo"
end
```

Each `step` is the next layer down, so that reads "Manager, then CFO". `on`
takes a lifecycle symbol — resolved through `model:` into `"invoice.created"`,
so the rule and the engine read from one source — or any event-name string you
fire yourself, and it accepts `priority:` and `active:` as well as `when:`.
`when:` is sugar over JSON Logic: `{ amount: { gt: 10_000 } }`,
`{ department: "IT" }` for equality, `{ region: { in: %w[EU UK] } }` for a set.
Several keys AND together, and raw JSON Logic passes straight through for
anything the sugar can't say (an `or`, arithmetic).

Same-layer review is a `parallel` block. Consensus is declared on the block
rather than the steps inside it, because a layer carries one policy for every
step in it — and it defaults to `:all`, since "Legal and IT review at the same
time" means both:

```ruby
ApprovalEngine.define_flow "Major capital spend", tenant: "acme", model: Invoice do
  on :create, when: { amount: { gt: 100_000 } }, priority: 10

  step "Manager sign-off", group: "manager"
  parallel(approvals_required: :all) do
    step "Legal review", group: "legal"
    step "IT review",    group: "it"
  end
  step "CFO sign-off", group: "cfo", timeout_after: 2.days
end
```

A plain `step` also takes `approvals_required:` and `timeout_after:`; a
flow-wide `define_flow(..., timeout_after:)` sets the default for every step
that doesn't name its own.

It writes ordinary `TrackTemplate` / `TemplateStep` / `TriggerRule` rows —
nothing downstream can tell a defined flow from a hand-built one, and the
[longhand below](#i-want-invoices-over-10k-to-need-extra-approval-conditional-routing)
is the same thing spelled out. `define_flow` returns the template, and
`ApprovalEngine.flow(name, tenant:)` looks one up later, which is how a defined
flow reaches `run_approval!(templates: [...])`:

```ruby
contract.run_approval!(templates: [ ApprovalEngine.flow("Legal", tenant: "acme"),
                                    ApprovalEngine.flow("IT",    tenant: "acme") ])
```

This is setup code, so it fails loudly and early — the opposite of runtime rule
evaluation, which deliberately fails closed and silent. A rule that reads an
attribute the model doesn't expose, a consensus spec that isn't one, two steps
with the same name, a group that isn't in `config.approval_groups`, a
non-positive `timeout_after`: each stops the seed with a sentence explaining
itself, instead of resolving into a flow that silently never fires.

> **Put it in `db/seeds.rb`, not an initializer.** It opens a transaction and
> takes an advisory lock, so it needs a live database connection —
> `rails db:create` and `assets:precompile` don't have one.

> **Never hand it user input.** `when:` accepts raw JSON Logic and stores it
> verbatim. The vetted path for rules an admin authors is
> [the rule editor](#an-admin-should-change-the-10k-threshold-without-a-deploy-the-rule-editor),
> which is constrained on purpose.

One flow is one template is one track. Scatter-gather *across* tracks can't be
expressed in a block — a trigger rule structurally routes to exactly one
template — so that stays `run_approval!(templates: [...])`, as above.

Covered by [`test/services/approval_engine/flow_definition_test.rb`](https://github.com/Harry-kp/approval_engine/blob/main/test/services/approval_engine/flow_definition_test.rb).

### "My seeds run on every deploy — won't that duplicate the flow?" (reconciling a definition)

No. A flow is keyed on `(tenant, name)`, and `define_flow` reconciles what it
finds rather than inserting: the block is the desired state, and re-running it
with nothing changed changes nothing. What reconciles, exactly:

| Declaration | On a re-run |
| --- | --- |
| The template | Found by `(tenant, name)`; its `status` is re-asserted, so a flow an admin archived comes back `active` |
| A step | Matched **by name** and updated in place, so the ids an admin UI links to survive |
| A renamed step | Reads as a remove plus an add — the name is the identity |
| A step you stopped declaring | Destroyed |
| A rule | Matched by `(event_name, priority)` and updated in place |
| A rule you stopped declaring | **Deactivated, never destroyed** — an approval keeps its `trigger_rule` as provenance, so deleting it would erase "which rule started this?" from every approval it ever spawned |
| A block with no `on` at all | Leaves existing rules alone, so routing can stay the admin's |

Two deploys seeding at once take an advisory lock scoped to that one flow, so
they can't race into two templates with the same name. If a tenant somehow
already holds two templates with the name, `define_flow` refuses rather than
guessing which one it owns.

**An approval already in flight is untouched by any of it.** The ledger holds
copies, not references: `ApprovalBuilder` stamps each template step's name,
layer, consensus and timeout *onto* the `Step` rows when it builds an approval,
and a rework iteration is cloned from those ledger rows rather than from the
template. A running approval therefore holds no live reference to anything a
redefinition rewrites, and finishes with the steps it started with — including
a step you deleted from the flow this morning.

The flip side: code and the UI can't half-own one flow, because the next run of
the block re-asserts everything it declares. Pick an owner per flow. A block
with no `on` is the useful middle — steps in code, routing in the admin.

Covered by [`test/services/approval_engine/flow_definition_test.rb`](https://github.com/Harry-kp/approval_engine/blob/main/test/services/approval_engine/flow_definition_test.rb)
("re-running the same flow changes nothing", "rewriting a flow leaves an
approval already in flight untouched").

### "I want invoices over $10k to need extra approval" (conditional routing)

```ruby
template = ApprovalEngine::TrackTemplate.create!(
  tenant_id: account.id, name: "High-value invoice", status: "active"
)
template.template_steps.create!(name: "CFO", layer: 1, assigned_group: "cfo")

# The rule owns routing: which event fires this template, and under what condition.
template.trigger_rules.create!(
  tenant_id: account.id, event_name: Invoice.approval_event_name(:create),
  condition: { ">" => [{ "var" => "amount" }, 10_000] }
)
```

Now creating an invoice over $10k spawns the approval automatically.

> **Avoid event-name typos.** Auto-triggers emit a conventional name
> (`"invoice.created"` / `"invoice.updated"` / `"invoice.destroyed"`). If a
> rule's `event_name` doesn't match, it simply never fires — silently. Use
> `Invoice.approval_event_name(:create)` instead of a literal string so the rule
> and the engine read from the same source, and verify wiring with
> `invoice.preview_approval(event: Invoice.approval_event_name(:create)).triggered?`.

### "How do I write rule conditions?" (JSON Logic)

A `condition` is a [JSON Logic](https://jsonlogic.com) expression evaluated
against the payload your model exposes via `exposes_for_approval`. **Every
`{ "var" => "x" }` must name an exposed attribute** — an unknown var reads as a
clean non-match, so the rule silently won't fire.

```ruby
# amount > 10000
{ ">" => [{ "var" => "amount" }, 10_000] }

# department is "IT"
{ "==" => [{ "var" => "department" }, "IT"] }

# amount > 10000 AND not the IT department
{ "and" => [
  { ">"  => [{ "var" => "amount" }, 10_000] },
  { "!=" => [{ "var" => "department" }, "IT"] }
] }

# high-value OR explicitly flagged high-risk
{ "or" => [
  { ">" => [{ "var" => "amount" }, 50_000] },
  { "==" => [{ "var" => "is_high_risk" }, true] }
] }

# department is one of a set
{ "in" => [{ "var" => "department" }, ["Legal", "Finance"]] }
```

Confirm a condition matches your data without starting an approval:

```ruby
invoice.preview_approval(event: "invoice.created").triggered? # => true / false
```

### "I want to expose `total_cents` to the rule builder as `amount`" (safe payloads)

```ruby
class Invoice < ApplicationRecord
  has_approvals

  exposes_for_approval do
    attribute :amount, type: :decimal, source: ->(i) { i.total_cents / 100.0 }
    attribute :department, type: :string, source: :department_name
    attribute :is_high_risk, type: :boolean, source: :requires_manual_audit?
  end
end
```

Only these declared attributes ever reach the rules engine — never the raw model.

### "Approvers should depend on the record, not a static list"

`resolve_approval_group` receives the record being approved as its second
argument (`target`), so the group can be resolved relative to it — the
submitter's manager, the record's department head, the tenant's admins. Return
one record or many; the engine creates one step per returned actor.

```ruby
class User < ApplicationRecord
  def self.resolve_approval_group(group_name, target)
    case group_name
    when "department_head" then where(role: "head", department_id: target.department_id)
    when "account_admins"  then target.account.users.where(role: "admin")
    when "reviewers"       then where(role: "reviewer").where.not(id: target.created_by_id) # no self-approval
    else where(role: group_name)
    end
  end
end
```

`target` is whatever record triggered the run (the model with
`has_approvals`). If your groups are global, ignore `target` and just
match on the role.

### "Anyone (or any admin) on a team can approve" (team-based approval)

The common shape: users belong to teams, teams have roles, and a record needs
sign-off from *someone* on the relevant team. The key insight is that **the
actor is the user, not the team** — the team is just the group your resolver
expands into its members. "Anyone suffices" is `approvals_required: :any`.

Resolve the group to the team's members (or just its admins):

```ruby
class User < ApplicationRecord
  def self.resolve_approval_group(group_name, target)
    case group_name
    when "team"        then target.team.users                       # anyone on the team
    when "team_admins" then target.team.users.where(role: :admin)   # only team admins
    else where(role: group_name)
    end
  end
end
```

Then the template step picks the group and the "any one of them" policy:

```ruby
template.template_steps.create!(name: "Team sign-off", layer: 1,
                                assigned_group: "team", approvals_required: :any)
```

The engine creates one pending step per team member; the **first** to
`approve!` resolves the layer (the rest are cancelled). Want admins only? Use
`assigned_group: "team_admins"`. Want a sequence — any member, then an admin?
Two layers (`"team"` at layer 1, `"team_admins"` at layer 2).

> **Scale note.** This creates one step per resolved member, which is ideal for
> small groups (admins, a handful of reviewers). For "anyone on a 200-person
> team," that fan-out is wasteful — there you can assign the step to the `Team`
> record itself (`assigned_actor` is polymorphic), but then *you* own "is this
> user a member who may act?" since the engine can't know your membership graph.
> For most apps, resolving to members + `any` is the right, simplest choice.

### "I want to trigger an approval myself instead of on create"

`on:` lists the lifecycle events that *auto-start* an approval (default
`[:create]`). Pass `on: []` to turn that off, then start approvals yourself —
whenever you choose, with an event name that matches a rule you defined.

```ruby
class Invoice < ApplicationRecord
  has_approvals on: [] # don't auto-start on create
end
```

```ruby
# Later, wherever it makes sense in your code — a controller action, a model
# method, a background job:
def resubmit
  invoice.update!(status: "resubmitted")
  invoice.run_approval!(event: "invoice.resubmitted")
  # the engine looks up the rule whose event_name is "invoice.resubmitted" and
  # starts that approval (or does nothing if no rule matches)
end
```

### "Different transitions should trigger different approvals" (rejected → X, accepted → Y)

The `event:` is just a string — trigger from wherever your transition happens,
with whatever name you like. Define a template + rule per event:

```ruby
class Invoice < ApplicationRecord
  has_approvals on: [] # you drive the triggers

  def reject!
    update!(status: "rejected")
    run_approval!(event: "invoice.rejected")   # → the rejection-review approval
  end

  def accept!
    update!(status: "accepted")
    run_approval!(event: "invoice.accepted")   # → the fulfilment approval
  end
end
```

The same works from a state machine (e.g. AASM `after` hooks) or a controller
action. Domain transitions like "rejected"/"accepted" are yours to define — the
engine just routes whatever event name you hand it.

### "Auto-route on update too, not only on create"

```ruby
class Invoice < ApplicationRecord
  has_approvals on: [:create, :update] # uses "invoice.created" / "invoice.updated"

  # Gate it so only the transitions you care about route (otherwise *every*
  # save evaluates rules):
  def trigger_approval?(lifecycle)
    lifecycle == :update ? saved_change_to_amount? : true
  end
end
```

### "Several approvals match — let the user pick which to start, not priority"

`run_approval!` auto-picks the highest-priority match. When you'd
rather a human choose, list the candidates and start the chosen one(s) yourself:

```ruby
candidates = invoice.approval_candidates(event: "invoice.created")
candidates.map { |plan| [plan.template.name, plan.steps.map(&:name)] }
# => [["Compliance", ["Officer"]], ["Finance", ["Manager", "CFO"]]]

chosen = candidates.find { |plan| plan.template.name == "Finance" }.template
invoice.run_approval!(templates: chosen)        # just this one

# ...or start several at once as parallel tracks:
invoice.run_approval!(templates: candidates.map(&:template))
```

The same `run_approval!` either routes by rules (`event:`) or starts
exactly what you hand it (`templates:`). `approval_candidates` writes nothing;
the `templates:` form skips rule evaluation entirely.

---

## Previewing

### "I want to warn the user what approval an action will trigger — before they commit"

```ruby
plan = invoice.preview_approval(event: "invoice.created")

if plan.triggered?
  plan.template.name                       # => "High-value invoice"
  plan.steps.map(&:name)                   # => ["Manager", "CFO"]
  plan.actors_for(plan.steps.first)        # => [#<User Maria>]  (who'd be assigned)
elsif plan.no_approval_required?
  # proceed without ceremony
end
```

It writes nothing, and it reads the **in-memory** record — so you can preview an
unsaved change ("if I set the amount to $20k, who'd need to sign off?"):

```ruby
invoice.amount = 20_000 # not saved
invoice.preview_approval(event: "invoice.created").steps.map(&:name)
```

A preview is a point-in-time hint, not a contract — an admin could change a rule
before the real action. The authoritative routing still happens at
`run_approval!`.

---

## Acting on approvals

### "Show an approver what's pending on them" (the inbox)

`actionable_by` is an approver's inbox — pending steps assigned to them *plus*
any they cover via an active delegation. It's a normal scope, so chain `.count`,
`.order`, pagination, etc. Preload `target` to show *what* needs approval:

```ruby
pending = ApprovalEngine::Step.actionable_by(current_user)
                              .includes(track: { approval: :target })
                              .order(:created_at)

pending.count                       # => how many are on me
pending.each do |step|
  step.target                       # the Invoice (etc.) awaiting approval
  step.name                         # "CFO sign-off"
  step.approve!(by: current_user)   # ...or step.reject!(by: current_user)
end
```

Who can view this is your call — wrap it in your own authorization.

### "I want a manager to approve" (standard approval)

```ruby
step = ApprovalEngine::Step.actionable_by(current_user).first
step.approve!(by: current_user, comment: "Looks good")
```

### "I want to reject a step" (rejection is consensus-aware)

```ruby
step.reject!(by: current_user)
```

A reject is a "no" vote that respects the layer's consensus, short-circuiting
as early as is valid:

- **A sole approver, or any `:all` layer** — one reject fails the whole
  track immediately (and the approval with it). This is the usual
  "VP rejects, approval is dead" case.
- **`:any`, `:majority`, a percentage, or a count** — a reject only fails the
  layer once the required approvals are *unreachable* (every `:any` approver
  rejected; too few voters left to reach a count). Until then the track
  stays open for the remaining voters.

A failed layer never advances to the next one.

### "I want to send a document back for fixes" (approval changes)

```ruby
step.request_changes!(by: current_user) # appends iteration 2; history is kept
```

---

## Consensus

A layer's `approvals_required` says how many of its actors must approve. It is
resolved against the live group size, so you express *policy* ("a majority")
without hard-coding *headcount* — the engine does the arithmetic when the
approval is built. Accepted values:

| Value | Meaning |
| --- | --- |
| `:any` | One approval suffices (the default) |
| `:all` | Every actor must approve |
| `:majority` | More than half: `(group / 2) + 1` |
| `"60%"` | At least 60% of the group, rounded up |
| `2` | Exactly this many approvals |

### "Any one of five senior devs can approve"

```ruby
template.template_steps.create!(
  name: "Senior review", layer: 1, assigned_group: "senior_dev", approvals_required: :any
)
```

### "All three directors must approve"

```ruby
template.template_steps.create!(
  name: "Board", layer: 1, assigned_group: "director", approvals_required: :all
)
```

### "A majority of the board must approve"

```ruby
template.template_steps.create!(
  name: "Board", layer: 1, assigned_group: "board", approvals_required: :majority
)
```

Express the same as a ratio (`approvals_required: "60%"`) or a fixed count
(`approvals_required: 2`). A count larger than the resolved group raises at
build time — it could never resolve.

### "Manager first, then CFO" (sequential layers)

```ruby
template.template_steps.create!(name: "Manager", layer: 1, assigned_group: "manager")
template.template_steps.create!(name: "CFO",     layer: 2, assigned_group: "cfo")
```

Layer 2 stays `waiting` until layer 1 resolves.

---

## Parallel review

### "Legal and IT need to review at the same time" (scatter-gather)

```ruby
ApprovalEngine::ApprovalBuilder.build_parallel!(
  templates: [legal_template, it_template], target: contract
)
```

One approval, two tracks running at once. By default it's approved when *both*
tracks approve and torn down if either is hard-rejected.

### "Any 2 of our 3 regional offices must sign off" (gather consensus)

The gather takes the same `approvals_required` vocabulary a layer does — so
"all tracks" is just the default, not the only option:

```ruby
ApprovalEngine::ApprovalBuilder.build_parallel!(
  templates: [emea_template, apac_template, amer_template],
  target: contract,
  approvals_required: "2"   # :any / :all / :majority / "60%" / a count
)
# or, from the host record:
contract.run_approval!(templates: [emea, apac, amer], approvals_required: :majority)
```

Now one office rejecting doesn't veto the deal — the approval keeps gathering as
long as the count is still reachable, and only fails once it isn't. A fixed count
larger than the number of tracks raises at build time (it could never resolve).

---

## Delegation

### "My peer should approve while I'm on vacation"

```ruby
ApprovalEngine::Delegation.create!(
  tenant_id: account.id, delegator: alice, delegatee: bob,
  starts_at: Time.current, ends_at: 1.week.from_now
)

step.actionable_by?(bob) # => true while the lease is active
step.approve!(by: bob)    # audit records Alice as intended, Bob as actual
```

---

## Withdrawing & escalating

### "The requester retracted it / the PO was voided" (withdraw)

`cancel!` is the third terminal outcome beside approved and rejected — for when
the thing being approved no longer needs a decision. It cancels any open
tracks/steps, leaves the history intact, and fires `after_cancelled(reason)`.

```ruby
approval.cancel!(reason: "Purchase order voided by requester")
approval.status # => "cancelled"
```

### "This approver is unresponsive — hand it to someone else" (escalate)

`reassign!` moves a *pending* step to another actor without restarting the flow.
The reassignment is recorded on the ledger (original assignee as intended, the
person who reassigned as actual), and the step stays pending in its layer. This
is the natural partner to timeouts:

```ruby
def on_step_timeout(step)
  step.reassign!(to: backup_for(step), by: nil, comment: "auto-escalated after SLA")
  # ...or step.expire! to deny instead of escalate
end
```

---

## Side-effects & chaining

### "Pay the invoice once it's fully approved" (chaining)

```ruby
class Invoice < ApplicationRecord
  has_approvals

  def after_approved
    PaymentService.disburse_funds!(self) # runs via the outbox, off the approval
  end
end
```

Other hooks: `after_rejected(reason)`, `after_cancelled(reason)`,
`after_step_activated(step)`, `after_step_approved(step)`,
`after_step_rejected(step)`, `after_step_changes_requested(step)`,
`after_step_expired(step)`, `after_step_reassigned(step)`, `on_step_timeout(step)`,
`on_step_reminder(step)`, `on_quarantined(reason)`.

Callbacks fire through the outbox: **at-least-once and unordered**. Make them
idempotent, and don't assume one fires before another (e.g. `after_step_approved`
before `after_approved`) — if you need ordering, derive it from the ledger.

### "Notify another system without coupling to my model"

Prefer pub/sub to callbacks? Every outbox event is also an
`ActiveSupport::Notifications` instrument named `approval_engine.<event_name>`,
with payload keys `record`, `target`, and `tenant_id`:

```ruby
ActiveSupport::Notifications.subscribe("approval_engine.approval.approved") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  AuditMailer.request_approved(event.payload[:target]).deliver_later
end
```

The full channel list:

| Notification | Fires when |
| --- | --- |
| `approval_engine.approval.approved` | an approval gathers to approved |
| `approval_engine.approval.rejected` | an approval is rejected |
| `approval_engine.approval.cancelled` | an approval is withdrawn via `cancel!` |
| `approval_engine.approval.quarantined` | a malformed rule quarantined the approval |
| `approval_engine.step.activated` | a step became actionable |
| `approval_engine.step.approved` | a step is approved |
| `approval_engine.step.rejected` | a step is rejected |
| `approval_engine.step.changes_requested` | a step is sent back for rework |
| `approval_engine.step.expired` | a step is expired (timed-out denial) |
| `approval_engine.step.timed_out` | a step's SLA elapsed (signal only) |
| `approval_engine.step.reminded` | the reminder sweep nudged a quiet step |
| `approval_engine.step.reassigned` | a step was handed to another actor |

### "If Stripe is down, the approve click shouldn't 500" (async safety)

This is automatic: state transitions commit instantly, side-effects run in the
outbox relay job. A failing callback is recorded and retried (with backoff),
never bubbling into the approval.

> **Make your callbacks idempotent.** Delivery is *at-least-once* — a worker can
> die after disbursing funds but before the event is marked processed, so a
> callback may run more than once. Guard irreversible work with your own
> idempotency key (e.g. `return if already_disbursed?`).

> **Schedule `ApprovalEngine::OutboxEvent.drain!`** (e.g. every few minutes) as a
> safety net for events whose relay job was lost — required if your ActiveJob
> adapter doesn't retry. It skips in-flight events, so it never double-delivers.

---

## Notifications

The engine ships six emails and sends none of them until you say so. Everything
in this section is inert while `config.notifications_enabled` is false, which is
the default: upgrading the gem must never start mailing an adopter's real users.

### "Tell the approver something is waiting on them" (turning notifications on)

Three settings, and all three matter:

```ruby
# config/initializers/approval_engine.rb
ApprovalEngine.configure do |config|
  config.notifications_enabled = true                    # 1. the master switch
  config.mailer_from           = "approvals@acme.com"    # 2. a sender
  config.approval_url_builder  = lambda do |approval|    # 3. somewhere to go
    Rails.application.routes.url_helpers.invoice_url(approval.target)
  end
end
```

1. **`notifications_enabled`** — nothing below it has any effect while this is
   false.
2. **A From address** — either `mailer_from`, or point `config.parent_mailer` at
   your `ApplicationMailer` and inherit its `default from:` (and its layout,
   which is usually the real reason to). Without one, Action Mailer has nothing
   to hand the SMTP server, and the failure surfaces deep inside the delivery
   job, far from the setting that caused it.
3. **`approval_url_builder`** — the engine cannot know your routes. Without it
   the mail still sends and arrives with nowhere to go.

Who receives what:

| Notification | Fires when | Goes to |
| --- | --- | --- |
| `step_activated` | a step becomes actionable | the assigned actor |
| `step_reminder` | the sweep nudges a quiet step | the assigned actor |
| `step_reassigned` | a step is handed to someone else | the new assignee |
| `changes_requested` | a step is sent back for rework | `config.approval_recipients` |
| `approval_approved` | an approval gathers to approved | `config.approval_recipients` |
| `approval_rejected` | an approval is rejected | `config.approval_recipients` |

The engine knows who approves; only you know who asked. So the bottom three stay
silent — configured, enabled, and silent — until you say where they go:

```ruby
config.approval_recipients = ->(approval) { [ approval.target.submitter ] }
```

Addresses are read off an actor with `config.actor_email_method` (`:email` by
default). An actor who has no address, or doesn't respond to the method at all,
is skipped rather than raised on — and if that leaves no recipient, the
notification is logged and dropped. A missing email is a configuration problem,
not a reason to fail an approval.

Mail rides the outbox you already have. `ApprovalEngine::Notifier` builds the
message inside `ProcessOutboxJob` — so only ever from state that has already
committed — and `deliver_later`s it, so a dead SMTP server retries the *mail*
and never the outbox event (which would re-run your `after_approved` alongside
it). A notification that raises is logged and dropped; it can never fail an
approval. The cost is the outbox's own contract: delivery is at-least-once, so
an approver may occasionally get the same message twice.

Covered by [`test/services/approval_engine/notifier_test.rb`](https://github.com/Harry-kp/approval_engine/blob/main/test/services/approval_engine/notifier_test.rb)
and [`test/mailers/approval_engine/notification_mailer_test.rb`](https://github.com/Harry-kp/approval_engine/blob/main/test/mailers/approval_engine/notification_mailer_test.rb).

### "Nudge an approver who has gone quiet" (reminders)

Set how long a step may sit unanswered, then run the sweep on whatever recurring
mechanism you already have (solid_queue recurring tasks, sidekiq-cron, the
`whenever` gem, a cron job hitting a rake task):

```ruby
config.reminder_after = 2.days.to_i   # nil, the default, means reminders off
```

```ruby
ApprovalEngine::ReminderSweepJob.perform_later                  # all tenants
ApprovalEngine::ReminderSweepJob.perform_later(tenant_id: account.id)
ApprovalEngine::Step.sweep_reminders!                           # or synchronously
```

A nudge is not a verdict. Nothing about the step's authority changes and the
only write is the `reminded_at` stamp that stops it being nudged again, so each
step is reminded **at most once**: sweeping hourly makes the nudge arrive
sooner, never twice. Requesting changes builds a fresh iteration of steps, which
re-arms it. The sweep is a no-op while `reminder_after` is nil, so scheduling it
before you configure the threshold is harmless, and one step raising is logged
and skipped rather than starving the batch.

`reminded_at` arrives in the 1.1 migration, so an app that upgrades the gem and
forgets to migrate loses reminders (and nothing else — every other path stays
away from the column):

```sh
rails approval_engine:install:migrations
rails db:migrate
```

Reminders do not require the mailer. The sweep emits `step.reminded` through the
outbox like any other event, so with notifications off you can nudge over Slack,
push, or anything else from the host callback:

```ruby
class Invoice < ApplicationRecord
  has_approvals

  def on_step_reminder(step)
    Slack.dm(step.assigned_actor, "Still waiting on you: #{self}")
  end
end
```

What counts as "late", and what to do about it beyond a nudge, stays yours —
[timeouts](#approvers-should-have-a-deadline-timeouts) are the harder-edged
tool, and they never decide either.

Covered by [`test/models/approval_engine/reminder_test.rb`](https://github.com/Harry-kp/approval_engine/blob/main/test/models/approval_engine/reminder_test.rb).

### "The mail should sound like us" (overriding the templates)

Drop your own copy at
`app/views/approval_engine/notification_mailer/<action>.html.erb`; your app's
view path is searched before the engine's. There is no generator for this, and
there doesn't need to be — the file path is the whole API.

> **Override both formats of an action together.** Action Mailer takes an
> action's templates from the first view path that has *any* of them, so a lone
> `.html.erb` in your app silences the engine's `.text.erb` and leaves you with
> a single-part message.

The views assign nothing but plain Strings and Integers — no view ever calls a
method on one of your records, which is what makes them usable by any app
whatever its models are called. What you have to work with: `@target_label`,
`@event_name`, `@url` everywhere; `@step_name`, `@track_name`, `@actor_label` on
the four step messages; plus `@waiting_hours` (`step_reminder`), `@comment`
(`changes_requested`) and `@reason` (`approval_rejected`).

Subjects come from the locale file, so rewording one is a key in your own
`en.yml` rather than a fork:

```yaml
en:
  approval_engine:
    notification_mailer:
      step_activated:
        subject: "%{target} needs your sign-off"
```

To take one message over entirely, subclass and point the config at it. The
other five keep the engine's implementation:

```ruby
class ApprovalMailer < ApprovalEngine::NotificationMailer
  def step_activated(step, to:)
    mail(to: to, subject: "Sign off on #{step.name}")
  end
end

config.mailer_class = "ApprovalMailer"
```

### "Send everything except reassignments" (silencing one notification)

```ruby
config.notification_events -= [ :step_reassigned ]
```

Two gates are checked before anything is built: the master switch, which keeps
an upgrade silent, and this list, which mutes one message while the layer stays
on. Removing an event here is not the same as removing the underlying signal —
the outbox event, the `approval_engine.*` instrumentation, and your host
callbacks all still fire.

---

## Integrating with your model's status

### "My model already has a status column — how does approval fit in?"

There are **two different states**, and keeping them separate is the whole trick:

| State | Owner | Example values |
| --- | --- | --- |
| **Business status** (`invoice.status`) | **you** | `draft`, `approved`, `rejected` |
| **Approval/process status** (the approval) | the engine | `pending`, `approved`, `quarantined` |

The engine **never touches your `status` column** — it can't know your
vocabulary. It runs the *process* and tells you the *outcome*; you decide what
that means for your model. Adopting the engine doesn't replace your `status`, it
replaces the **manual flip** of it: a human used to set `status = approved`
directly; now a governed process decides and reflects the result back.

```ruby
class Invoice < ApplicationRecord
  enum :status, { draft: 0, pending_approval: 1, approved: 2, rejected: 3 }
  has_approvals on: []

  # Submitting is YOUR transition — it also kicks off the approval:
  def submit!
    pending_approval!
    run_approval!(event: "invoice.created")
  end

  # The engine reports the outcome; YOU map it onto your status:
  def after_approved          = approved!
  def after_rejected(_ = nil) = rejected!
  def on_quarantined(reason)  = Rails.logger.error("Approval misconfigured: #{reason}")
end
```

**Your existing queries keep working** — `Invoice.approved` still returns
approved invoices, because the callback flips `status` when the approval
finishes. The only addition is the in-flight window: one new `pending_approval`
value, set on submit.

**Don't add a second column for the process status — derive it:**

```ruby
invoice.approval_status      # latest approval status — no column needed
invoice.approval_in_flight?  # is an approval running right now?
```

Think of it as: the approval ledger is the authoritative record of *what
happened*; your `status` column is a projection of the latest decision, kept in
sync by the callbacks. Only denormalize the process status into a real column if
you must query it across many records at scale — a deliberate optimization, not
the default.

---

## Multi-tenancy

### "Tenant A's approvals must never bleed into tenant B"

Scope everything by `tenant_id`. Rules are evaluated within a tenant:

```ruby
invoice.run_approval!(event: "invoice.created", tenant_id: account.id)
```

Templates, rules, approvals, and ledger rows all carry `tenant_id`; a tenant
only ever sees its own rules.

---

## Safety

### "A typo in a custom rule shouldn't crash the app" (graceful failure)

A *missing* attribute is a clean non-match — the approval simply doesn’t start.
A *malformed* rule (e.g. an unknown operator) quarantines the approval instead
of raising:

```ruby
ApprovalEngine::Approval.quarantined # surfaced for ops to fix

# Want errors loud in development instead?
ApprovalEngine.configure { |c| c.raise_on_rule_errors = true }
```

---

## Customizing behavior

Every hook below is an ordinary method on your model — override it the normal
Ruby way, and call `super` when you want to extend rather than replace.

### Gate when auto-routing fires — `trigger_approval?(lifecycle)`

Receives the lifecycle (`:create` / `:update` / `:destroy`). Ignore the argument
if you don't need it.

```ruby
def trigger_approval?(lifecycle)
  lifecycle == :update ? saved_change_to_amount? : true
end
```

### Change how the tenant is resolved — `approval_tenant_id`

Defaults to `config.current_tenant_method`. Override if the tenant lives on the
record:

```ruby
private

def approval_tenant_id
  account_id
end
```

### Extend the rules payload — `serialize_for_approval`

Prefer the `exposes_for_approval` DSL, but you can override for full control
(`super` returns the DSL-built payload):

```ruby
def serialize_for_approval
  super.merge("region" => office.region)
end
```

### React to outcomes

These aren't overrides — you simply *define* them and the engine calls them
(see [Side-effects & chaining](#side-effects--chaining)):
`after_approved`, `after_rejected(reason)`, `after_cancelled(reason)`,
`on_quarantined(reason)`, `after_step_activated(step)`,
`after_step_approved(step)`, `after_step_rejected(step)`,
`after_step_changes_requested(step)`, `after_step_expired(step)`,
`after_step_reassigned(step)`, `on_step_timeout(step)`, `on_step_reminder(step)`.

---

## UI & monitoring

### "I want to see everything a record has gone through"

`approval_history` assembles the full read-only picture — every approval, the
step tree, and a chronological timeline of actions with actors and comments. The
gem builds the data (eager-loaded, no N+1); **you** decide who may see it and how
to render it (a customer "track your approval" page, an internal audit screen…).

```ruby
history = invoice.approval_history

history.empty?      # => false
history.latest      # => most recent Approval
history.approvals   # => all approvals, newest first (tracks/steps preloaded)

history.events.each do |entry|
  entry.event         # "approved" / "rejected" / "changes_requested"
  entry.actual_actor  # who acted
  entry.by_proxy?     # true if a delegate acted for the assignee
  entry.comment       # "Fix the totals"
  entry.step          # the step (name, layer, iteration) it belongs to
  entry.created_at
end
```

> Who sees this is your call — wrap it in your own authorization. The engine
> never decides whether it's a user-facing or admin-only view.

### "I want the approvals page to match our theme" (own the views)

```sh
rails generate approval_engine:views
```

Copies an unstyled controller + views into your app for you to restyle.

### "I want to see stuck approvals without writing SQL" (dashboard)

```ruby
# config/routes.rb
authenticate :admin_user, ->(u) { u.super_admin? } do
  mount ApprovalEngine::Engine => "/approval_engine"
end
```

The dashboard's detail page also shows a **time-in-step** column per step.

### "An admin should change the $10k threshold without a deploy" (the rule editor)

The mounted dashboard is read-only. The write surface is a separate, opt-in
admin at `/admin` inside the mount, and it is off by default:

```ruby
# config/initializers/approval_engine.rb
ApprovalEngine.configure { |c| c.admin_enabled = true }
```

Routes are drawn once at boot, so that belongs in an initializer and needs a
restart. While the flag is false the admin paths simply aren't there (404), and
the controllers re-check it on every request rather than trusting boot time.

What it gives an admin: templates, their steps, and their trigger rules, with
full CRUD, plus a cross-template rule index ordered the way the evaluator
resolves rules — `event_name` ascending, `priority` descending. Activating a
draft template, retiring a rule, or moving a threshold are all writes, no deploy.

The rule editor is a field/operator/value builder with no JavaScript in it. The
field dropdown offers exactly what your models declared in
`exposes_for_approval` — an unexposed variable reads as a clean non-match, which
is the most common way a hand-typed rule silently never fires. The operators are
`ApprovalEngine::Condition`'s (`eq`, `not_eq`, `gt`, `gte`, `lt`, `lte`, `in`,
`not_in`), several rows AND together, and the value is cast to the attribute's
declared type before storage, so `amount > "10000"` can't become a rule that
compares a number against a string and quietly never matches.

A condition the simple form can't represent — an `or`, a nested group, a
substring `in` — opens in a raw JSON Logic textarea instead of being flattened
into something it isn't. Raw input still has to parse, has to be a JSON object
(a bare array or number would evaluate as a literal and match *every* event of
its name), and is capped at 8 KB.

> **`admin_enabled` is not authentication.** It decides whether the write routes
> exist, not who may reach them, and the engine ships no auth of its own — so
> the mount stays wrapped in your own constraint either way:
>
> ```ruby
> authenticate :admin_user, ->(u) { u.super_admin? } do
>   mount ApprovalEngine::Engine => "/approval_engine"
> end
> ```
>
> It is off by default for one reason: 1.0 shipped a read-only dashboard that
> hosts mounted behind whatever auth they already had, and a gem upgrade must
> never turn a read surface into a write one on its own. It also needs a
> full-stack host — sessions for CSRF, and flash — so it is not available under
> `config.api_only`.

A template whose rules have already routed approvals refuses to be deleted, and
says so: deleting it would cascade to its rules and nullify the provenance
column on every approval they ever routed. Archive it instead — history wins
over the delete.

If the flow also lives in a `define_flow` block, remember that the next seed run
re-asserts everything that block declares, including the threshold an admin just
changed. [Pick one owner per flow](#my-seeds-run-on-every-deploy--wont-that-duplicate-the-flow-reconciling-a-definition).

Covered by [`test/integration/admin_routes_test.rb`](https://github.com/Harry-kp/approval_engine/blob/main/test/integration/admin_routes_test.rb)
and [`test/controllers/approval_engine/admin/`](https://github.com/Harry-kp/approval_engine/tree/main/test/controllers/approval_engine/admin).

### "How long is each decision taking, and where is it stuck?" (cycle time)

Each step records `activated_at` (when it became actionable) and `decided_at`
(when a human resolved it), so latency is exact even across multi-layer flows —
no re-deriving from the audit log:

```ruby
step.waiting_for        # seconds the step has been (or was) actionable
step.time_to_decision   # seconds from actionable -> resolved (nil until decided)

# Where is this approval stuck right now? (the longest-pending step)
slow = approval.current_bottleneck
slow && "#{slow.assigned_actor.name} has had this #{(slow.waiting_for / 3600).round}h"
```

The engine reports the durations; **you** decide what counts as "late" and what
to do about it. A nightly job is the usual shape — find stale steps and nudge
their approvers through your own mailer:

```ruby
ApprovalEngine::Step.pending.find_each do |step|
  next if step.waiting_for < 2.days
  ApprovalReminderMailer.nudge(step.assigned_actor, step.target).deliver_later
end
```

SLA thresholds, reminders, escalation, and leaderboards are yours to build —
the gem deliberately doesn't impose a definition of "too slow".

### "How close is this layer to consensus?" (live tally)

When a layer gathers several approvers, `track.layer_tally(layer)` returns the
same facts the engine decides on — so a UI can show "N of M approved" and *why*
a layer is met, failed, or still undecided, without re-implementing the
consensus math:

```ruby
track.layer_tally(1)
# => { required: 2, approved: 1, rejected: 0, pending: 2, waiting: 0,
#      group_size: 3, outcome: :undecided }
```

It defaults to the track's latest iteration; pass `iteration:` to read a
specific rework round. `outcome` is `:met` / `:failed` / `:undecided` — and a
layer that hasn't opened yet (all steps still `waiting`) reads `:undecided`, not
`:failed`, since those `waiting` steps are still approvals waiting to happen.

### "Approvers should have a deadline" (timeouts)

Give a step an SLA on its template — seconds it gets **once it becomes
actionable** (a `waiting` step's clock doesn't run until its layer opens):

```ruby
template.template_steps.create!(
  name: "CFO", layer: 1, assigned_group: "cfo", timeout_after: 2.days.to_i
)
```

Run the sweep on whatever schedule you already use (cron + ActiveJob,
solid_queue recurring, sidekiq-cron, …):

```ruby
ApprovalEngine::TimeoutSweepJob.perform_later   # background, every few minutes
ApprovalEngine::Step.sweep_timeouts!            # or synchronously in a rake task
```

When a deadline passes the engine fires **once** and calls your callback — it
does **not** decide the step. **ApprovalEngine never auto-approves; silence is
not consent.** You choose the honest reaction:

```ruby
class Invoice < ApplicationRecord
  has_approvals

  def on_step_timeout(step)
    step.expire!   # deny: a distinct `expired` terminal state, no human actor on the ledger
    # …or escalate: reassign to a backup (your logic) — still needs a real human "yes"
    # …or just nudge: ApprovalReminderMailer.nudge(step.assigned_actor, step.target).deliver_later
  end
end
```

`step.expire!` records an `expired` event with **no** actual actor and fails the
layer consensus-aware — the ledger never claims someone approved (or rejected) a
step they simply never got to. For business-hours / holiday SLAs, set an absolute
`step.timeout_at` yourself (you own the calendar) instead of `timeout_after`.
