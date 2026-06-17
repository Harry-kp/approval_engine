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
- [Side-effects & chaining](#side-effects--chaining)
- [Integrating with your model's status](#integrating-with-your-models-status)
- [Multi-tenancy](#multi-tenancy)
- [Safety](#safety)
- [Customizing behavior](#customizing-behavior)
- [UI & monitoring](#ui--monitoring)

---

## Routing & templates

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

Other hooks: `after_rejected(reason)`, `after_step_approved(step)`,
`after_step_rejected(step)`, `after_step_changes_requested(step)`,
`after_step_expired(step)`, `on_step_timeout(step)`, `on_quarantined(reason)`.

Callbacks fire through the outbox: **at-least-once and unordered**. Make them
idempotent, and don't assume one fires before another (e.g. `after_step_approved`
before `after_approved`) — if you need ordering, derive it from the ledger.

### "Notify another system without coupling to my model"

```ruby
ActiveSupport::Notifications.subscribe("approval_engine.approval.approved") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  AuditMailer.request_approved(event.payload[:target]).deliver_later
end
```

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
`after_approved`, `after_rejected(reason)`,
`on_quarantined(reason)`, `after_step_approved(step)`,
`after_step_rejected(step)`, `after_step_changes_requested(step)`,
`after_step_expired(step)`, `on_step_timeout(step)`.

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
