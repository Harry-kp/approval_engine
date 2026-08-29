# ApprovalEngine

[![Gem Version](https://img.shields.io/gem/v/approval_engine?logo=rubygems&color=E9573F)](https://rubygems.org/gems/approval_engine)
[![Downloads](https://img.shields.io/gem/dt/approval_engine?logo=rubygems&color=blue)](https://rubygems.org/gems/approval_engine)
[![CI](https://github.com/Harry-kp/approval_engine/actions/workflows/ci.yml/badge.svg)](https://github.com/Harry-kp/approval_engine/actions/workflows/ci.yml)
![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D)
![Rails](https://img.shields.io/badge/rails-%3E%3D%207.0.8-D30001)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

**A manager approves, then the CFO. Unless it's over $50k — then Legal too.**

Every app eventually grows an approval step. It starts as an `approved` boolean
and an `approved_by_id`. Then Finance wants a second signature over $10k. Then
Legal and IT have to review the same contract at the same time. Then someone
goes on leave and their queue backs up. Then an auditor asks who approved
invoice #4471 and on whose behalf — and the honest answer is that it is spread
across three callbacks and a `status` column you have already overwritten twice.

ApprovalEngine is the generic machinery for that, extracted: an append-only
ledger of who decided what, routing rules your admins change without a deploy,
and side-effects that can't roll back an approval. You decide what gets
approved, who approves, and what happens next.

![The mounted dashboard: six approvals across pending, approved and rejected, with a time-in-step column](https://raw.githubusercontent.com/Harry-kp/approval_engine/main/assets/screenshot-dashboard.png)

![One approval in detail: layer 1 approved, Legal and IT both pending at layer 2 under all-must-approve consensus, the CFO waiting at layer 3, and the audit trail below](https://raw.githubusercontent.com/Harry-kp/approval_engine/main/assets/screenshot-approval.png)

- **A ledger, not a flag.** `Approval → Track → Step`, append-only. A rejection
  or a request for changes appends a new iteration; nothing is overwritten, so
  the history survives the question.
- **Rules, not `if`s.** Routing lives in the database as JSON Logic, scoped per
  tenant. "Over $10k" becomes "over $25k, unless EMEA" without a deploy.
- **An outbox, not callbacks.** Side-effects run through a transactional outbox
  on ActiveJob, so a down payment API can never roll back an approval.

## 60-second quickstart

Needs PostgreSQL (the routing engine uses `jsonb`), Rails 7.0.8+, Ruby 3.1+.

```sh
bundle add approval_engine
bin/rails generate approval_engine:install
bin/rails db:migrate
```

Then four small edits, and a $20,000 invoice routes itself to a manager and
then a CFO:

```ruby
# config/initializers/approval_engine.rb — the generator wrote this; fill in two lines
ApprovalEngine.configure do |config|
  config.actor_class           = "User"                 # who approves
  config.current_tenant_method = -> { Current.account } # anything with #id
end

# app/models/user.rb — who is in a group, resolved at runtime against your own models
class User < ApplicationRecord
  def self.resolve_approval_group(group_name, target)
    where(role: group_name) # `target` is the record being approved
  end
end

# app/models/invoice.rb — arm the model, and declare what a rule may read
class Invoice < ApplicationRecord
  has_approvals

  exposes_for_approval do
    attribute :amount, type: :decimal
  end

  def after_approved
    PaymentService.disburse_funds!(self)
  end
end

# db/seeds.rb — the flow itself. Idempotent, so re-running it on every deploy is safe.
account = Account.find_by!(subdomain: "acme")

ApprovalEngine.define_flow "High-value invoice", tenant: account.id, model: Invoice do
  on :create, when: { amount: { gt: 10_000 } }

  step "Manager sign-off", group: "manager"
  step "CFO sign-off",     group: "cfo"
end

# Anywhere in your app — a controller, a job, a console.
Current.account = account
invoice = Invoice.create!(amount: 20_000)   # over $10k, so it routes itself

step = ApprovalEngine::Step.actionable_by(current_user).first
step.approve!(by: current_user)   # the CFO's step opens; once they approve too,
                                  # `after_approved` fires through the outbox
```

Nothing triggered? `invoice.preview_approval(event: "invoice.created")` tells
you what would have happened, before you go any further — see
[Gotchas](#gotchas).

## Is this for you?

Use it when you have:

- Multi-step, human-in-the-loop approvals, sequential or parallel
- Routing rules that admins change at runtime, without a deploy
- A need to audit who approved what, when, and on whose behalf
- Concurrency that must never double-approve

Look elsewhere when:

- One person says yes, once, and nobody will ever ask who. A boolean column and
  a method is smaller, and smaller is right until it stops fitting — see below
  for what to do when it does.
- You need a state machine for non-approval domains. Try
  [AASM](https://github.com/aasm/aasm) or
  [state_machines](https://github.com/state-machines/state_machines).
- You're not on PostgreSQL. The routing engine needs `jsonb` and `gin`.

### When a boolean flag stops fitting

You will know: a second approver appears, or somebody asks *who* approved it, or
the threshold has to differ per customer. You don't have to give the column up.
It stops being the source of truth and becomes a projection of the ledger, so
every query, view, and scope you already wrote keeps working:

```ruby
class Invoice < ApplicationRecord
  has_approvals

  # The flag you already had. Now it is derived, not decided here.
  def after_approved
    update_column(:approved, true)
  end
end
```

Day one, nothing else in your app changes. Day thirty, you add the second layer
and the audit trail is already there.

## Installation

Add this line to your application's **Gemfile**:

```ruby
gem "approval_engine"
```

And then execute:

```sh
bundle install
rails generate approval_engine:install
rails db:migrate
```

The generator copies migrations and an initializer, and prints next steps.

## Defining a flow

A flow is three records: a template, its ordered steps, and the rule that says
which event fires it. You can still write those by hand — the admin UI does
exactly that — but for the flows that live in your codebase, `define_flow` says
the same thing in the shape of the policy it encodes:

```ruby
ApprovalEngine.define_flow "Vendor contract", tenant: account.id, model: Contract do
  on "contract.submitted", when: { value: { gte: 50_000 } }

  step "Manager sign-off", group: "manager"

  parallel(approvals_required: :all) do
    step "Legal review", group: "legal"
    step "IT review",    group: "it"
  end

  step "CFO sign-off", group: "cfo", timeout_after: 2.days
end
```

Each `step` is its own layer, in the order written. Steps inside a `parallel`
block share a layer and open together, under one consensus policy declared on
the block. Everything a template step takes, `step` takes: `approvals_required`
(`:any`, `:all`, `:majority`, a percentage like `"60%"`, or a count) and
`timeout_after`.

`on` takes a lifecycle symbol (`:create`, resolved through `model:` into the
conventional event name) or any event name you fire yourself, plus `when:`,
`priority:` and `active:`. The `when:` sugar — `{ amount: { gt: 10_000 } }` —
compiles to the JSON Logic actually stored, using `eq`, `not_eq`, `gt`, `gte`,
`lt`, `lte`, `in` and `not_in`; several keys AND together, and anything more
involved can be passed as raw JSON Logic instead.

`define_flow` is idempotent, keyed on the tenant and the flow name. Run it from
`db/seeds.rb`, a rake task, or a deploy hook and re-run it as often as you like:
it reconciles the blueprint in place instead of stacking a fourth copy of the
same template. It needs a live database connection, so it does not belong in an
initializer.

Editing a flow does not disturb work already in flight. An approval is stamped
from the blueprint when it is built and never reads it again — the steps a
manager is looking at right now are the steps that existed when the invoice was
created. New runs pick up the new shape.

Two smaller seams. `ApprovalEngine.flow(name, tenant:)` hands back the
`TrackTemplate` a definition owns, which is what
`run_approval!(templates: [...])` wants when several flows should run as
parallel tracks of one approval. And `config.approval_groups` is an optional
allowlist of the group names a flow may route to — `nil` by default, meaning
unchecked, so a typo in `group:` stops the seed only once you have declared a
vocabulary.

Prefer the records? `TrackTemplate` / `TemplateStep` / `TriggerRule` are still
public API and still work exactly as they did in 1.0 — `define_flow` writes the
same rows you would have written.

## Wiring it into your app

Teach your actor class to resolve approval groups. The engine creates one
step per returned record. `target` is the record being approved (e.g. the
Invoice); this example ignores it, but you can use it for record-scoped
groups like "this invoice's department head".

```ruby
class User < ApplicationRecord
  def self.resolve_approval_group(group_name, target)
    where(role: group_name) # `target` available for record-scoped resolution
  end
end
```

Arm a model and declare the attributes the rules engine may read.

```ruby
class Invoice < ApplicationRecord
  has_approvals

  exposes_for_approval do
    attribute :amount, type: :decimal
  end

  def after_approved
    PaymentService.disburse_funds!(self)
  end
end
```

Trigger a run. `has_approvals` auto-routes on create once
`current_tenant_method` is set; anywhere else, fire the event yourself.

```ruby
invoice = Invoice.create!(amount: 20_000)
invoice.run_approval!(event: "invoice.created", tenant_id: "acme")
```

Verify it routed before going further.

```ruby
invoice.preview_approval(event: "invoice.created", tenant_id: "acme").triggered?
# => true
```

Act on a step. `actionable_by` is the approver's inbox, including delegations.

```ruby
ApprovalEngine::Step.actionable_by(current_user).first.approve!(by: current_user)
```

### Gotchas

This gem fails closed and silent when misconfigured. If a run doesn't
trigger, `preview_approval(...).triggered?` tells you why. Check:

- The rule's `event_name` matches the event you fire.
- The template `status` is `"active"`. Draft templates never fire.
- Every attribute a rule reads is declared in `exposes_for_approval`.
- `config.current_tenant_method` is set. Until then, auto-routing on
  create is a no-op, so pass `tenant_id:` explicitly.

`define_flow` is the exception, and deliberately so. It is setup code you run at
deploy, so it raises on a typo instead of failing closed — an unexposed
attribute, an unknown lifecycle, a duplicate step name, and a group outside
`config.approval_groups` all stop the seed with a sentence explaining themselves.

## Configuration

```ruby
# config/initializers/approval_engine.rb
ApprovalEngine.configure do |config|
  config.actor_class           = "User"                 # who approves
  config.current_tenant_method = -> { Current.account } # anything with #id
  config.outbox_queue          = :default               # ActiveJob queue for side-effects
  config.raise_on_rule_errors  = false                  # fail closed in production
  config.approval_groups       = nil                    # nil = any group name is allowed
end
```

`current_tenant_method` defaults to `nil`. While it is nil, auto-routing
on create silently no-ops, since the engine cannot scope the rules.
Single-tenant apps can return a constant, e.g.
`-> { Struct.new(:id).new("default") }`.

No Redis or Sidekiq required. Side-effects run through ActiveJob, so
SolidQueue, Sidekiq, or the async adapter all work.

The two surfaces added in 1.1 — notifications and the admin UI — have their own
keys, and both are off until you set them. See below.

## Notifications

An approval only works if the approver finds out. In 1.0 that was yours to
build: the engine published the events and you wrote the mailer. It still can —
but for the common case, the engine will now send the mail. It is **off by
default**, and upgrading from 1.0 does not turn it on: your `Step` rows are
assigned to real people, and a gem upgrade must not start mailing them.

```ruby
ApprovalEngine.configure do |config|
  config.notifications_enabled = true
  config.mailer_from           = "approvals@acme.com"
  config.approval_url_builder  = ->(approval) do
    Rails.application.routes.url_helpers.invoice_url(approval.target)
  end
end
```

Those three are the minimum. Without a From address — either `mailer_from`, or a
`parent_mailer` that already declares `default from:` — Action Mailer has
nothing to hand the SMTP server. Without `approval_url_builder` the mail arrives
with nowhere to go.

Six messages ship, listed in `config.notification_events`: an approver is told
they have work waiting (`step_activated`), nudged if they go quiet
(`step_reminder`), and told when a step is handed to them (`step_reassigned`);
the requesting side is told when changes are requested (`changes_requested`) and
when the approval is approved or rejected (`approval_approved`,
`approval_rejected`). Drop one to silence it:

```ruby
config.notification_events -= [ :step_reassigned ]
```

The last three go wherever `config.approval_recipients` says — the engine knows
who approves, but only you know who asked, so while that is nil those three stay
silent. The rest resolve off the actor via `config.actor_email_method`
(`:email` by default); an actor with no address is skipped, never raised on.
`config.actor_label_method` and `config.target_label_method` decide how a person
and a record name themselves in an inbox, and fall back to something readable
rather than an object inspection.

The mails go out through the same transactional outbox as every other
side-effect, so a flaky SMTP host retries with backoff and never touches the
approval. Delivery is at-least-once, which for email means an approver may
occasionally get the same nudge twice — the tradeoff for never getting zero.

Reminders are a separate, opt-in sweep. Set how long a step may sit unanswered
and schedule the job with whatever recurring mechanism you already run:

```ruby
config.reminder_after = 2.days.to_i   # nil (the default) = reminders off
```

```ruby
ApprovalEngine::ReminderSweepJob.perform_later                  # all tenants
ApprovalEngine::ReminderSweepJob.perform_later(tenant_id: account.id)
```

Each step is nudged at most once, so running the sweep hourly only makes the
nudge arrive sooner. It never mails the same person about the same step twice.
The stamp that makes that true lives in a column added in 1.1, so an app
upgrading from 1.0 needs `bin/rails approval_engine:install:migrations` and
`bin/rails db:migrate` before scheduling the sweep — nothing else in the engine
reads it.

Make the mail yours by overriding the views: drop your own copies into
`app/views/approval_engine/notification_mailer/` and your app's view path is
searched before the engine's. Override *both* formats of an action together —
Action Mailer takes an action's templates from the first view path that has any
of them, so a lone `.html.erb` silences the engine's `.text.erb` and leaves you
with a single-part message. To take a message over wholesale, subclass
`ApprovalEngine::NotificationMailer` and point `config.mailer_class` at it, or
point `config.parent_mailer` at your `ApplicationMailer` to inherit your layout
and sender. If you would rather send everything yourself, leave
`notifications_enabled` off and subscribe to the `approval_engine.*`
[notifications](docs/COOKBOOK.md#notify-another-system-without-coupling-to-my-model)
as before. Escalation and what "late" means are still yours: the engine tells
you what happened, not what it should mean.

## Dashboard

Mount the engine and you get an ops dashboard: every approval, filterable by
status, drilling into tracks, steps, the full audit trail, and a time-in-step
column so a stuck approval is visible instead of reported.

```ruby
# config/routes.rb
authenticate :admin_user, ->(u) { u.super_admin? } do
  mount ApprovalEngine::Engine => "/approval_engine"
end
```

It is read-only and stays that way — its job is to surface stuck, quarantined
and in-flight work without anyone writing SQL, not to act on it. It has no auth
of its own; wrapping the mount is your call and your app's
([recipe](docs/COOKBOOK.md#ui--monitoring)).

Want to see it without installing anything? Clone this repo and run:

```sh
bin/demo
# seeds sample data and boots the dashboard at
# http://localhost:3000/approval_engine
```

Or explore the API in a console preloaded with the same data.

```sh
bin/console
>> Rails.application.load_seed
>> ApprovalEngine::Step.pending.first.approve!(by: User.find_by(role: "manager"))
```

## Admin UI

The README has claimed since 1.0 that admins change routing rules at runtime,
without a deploy. Since 1.1 there is a UI for it: templates, their steps, and
their trigger rules, editable in the browser under `/admin` inside the mount.
It is **off by default** — 1.0 shipped a read-only dashboard that hosts mounted
behind whatever auth they had, and a gem upgrade must never turn that into a
write surface.

```ruby
ApprovalEngine.configure do |config|
  config.admin_enabled = true
end
```

Routes are drawn once at boot, so this belongs in an initializer and needs a
restart. **Turning it on is not authentication.** It decides whether the write
routes exist at all, not who may reach them — anyone who can reach the mount can
change what routes where, so keep the mount behind your own constraint either
way.

![The admin rule editor: a field dropdown showing amount (decimal), an operator dropdown showing is greater than, a value field, and a Simple / Raw JSON Logic toggle](https://raw.githubusercontent.com/Harry-kp/approval_engine/main/assets/screenshot-rule-builder.png)

Rules get a form instead of a JSON blob: pick a field, an operator, and a value,
and the engine stores the JSON Logic. The field dropdown is populated from
`exposes_for_approval`, so it offers the names a rule may actually read — an
unexposed variable is a clean non-match, which is the single most common way a
hand-typed rule silently never fires. There is no JavaScript involved.

A rule too complex for the simple form — an `or`, a nested group, a substring
`in` — opens in a raw JSON Logic textarea instead of being quietly flattened
into something it isn't. That fallback is the point: the form is a convenience
over the storage format, never a lossy replacement for it.

## Core concepts

| Term | What it is |
| --- | --- |
| Template | The reusable blueprint: ordered layers of steps with consensus rules |
| Trigger rule | A tenant-scoped JSON Logic condition that selects a template for an event |
| Approval | One run: a host record fanned out into one or more parallel tracks |
| Track | One parallel path of layered steps within an approval |
| Step | One approval slot in the immutable ledger (`approve!` / `reject!` / `request_changes!`) |
| Consensus | How many approvals a layer needs: `approvals_required` — `:any`, `:all`, `:majority`, a percentage like `"60%"`, or a count |

Every run is `Approval -> Track -> Step`, even the one-approver case.
A single-track run is an approval with one track, not a special path.
You never build that chain by hand: start a run with
`run_approval!` and act on a step with `step.approve!`. The
layers surface only when you need them, such as parallel tracks or the
dashboard. For a single-track approval, `approval.track` and
`approval.step` read it back without `.first`.

`approvals_required` is one idea used at two levels: within a layer (how many of
its steps), and across the parallel tracks of a scatter-gather (how many tracks
must approve — `:all` by default). Beyond the happy path, an approval can be
withdrawn (`approval.cancel!`) and a stuck step escalated (`step.reassign!`).

**Reacting to outcomes** — define any of these on your model and the engine
calls them (via the outbox, at-least-once and unordered): `after_approved`,
`after_rejected(reason)`, `after_cancelled(reason)`, `on_quarantined(reason)`,
`after_step_approved/rejected/changes_requested/expired/reassigned(step)`,
`on_step_timeout(step)`. Or subscribe to the matching `approval_engine.*`
[notifications](docs/COOKBOOK.md#notify-another-system-without-coupling-to-my-model).

## Cookbook

See **[docs/COOKBOOK.md](docs/COOKBOOK.md)** for copy-paste recipes
covering every supported case, from "any two of five reviewers" to "Legal
and IT in parallel" to delegation and requesting changes.

## How it works

| Concern | Mechanism |
| --- | --- |
| Auditability | Append-only `Step` ledger; requesting changes appends an iteration instead of editing history |
| Concurrency | Approval-scoped pessimistic lock around every transition, so no double-approvals |
| Routing | JSON Logic ASTs in `jsonb`, evaluated by [`shiny_json_logic`](https://jsonlogicruby.com) |
| Side-effects | Transactional outbox relayed by ActiveJob, so a down API never rolls back an approval |
| Safety | A malformed rule quarantines the approval instead of raising |

A missing attribute is a clean non-match, since JSON Logic treats it as
`false`, so the approval just doesn’t start. Only a malformed rule, such
as an unknown operator, quarantines. The approval never crashes either
way. Set `config.raise_on_rule_errors = true` to surface errors loudly.

For the full design — the model hierarchy, the consensus/rework model, and why
the outbox exists — see **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

## Alternatives

"Which gem" is a real question, so: honest neighbours.

- **A boolean column.** Genuinely the right answer for one approver and one
  yes/no. See [above](#when-a-boolean-flag-stops-fitting) for what to do when it
  stops being.
- **[AASM](https://github.com/aasm/aasm) / [state_machines](https://github.com/state-machines/state_machines).**
  Better than this gem at modelling *your* domain's states. They don't know what
  an approver is, so multi-party consensus, delegation, and the audit trail stay
  yours to write.
- **[ringlesoft/laravel-process-approval](https://github.com/ringlesoft/laravel-process-approval).**
  The same idea in Laravel, and worth reading if you are comparing across
  ecosystems.
- **A workflow or BPM service.** If your approvals are one node in a much larger
  orchestrated process, buy that instead of building it on ActiveRecord.

This gem is young, and worth saying so plainly: 1.0 shipped in June 2026 and was
never announced, so real-world usage is close to none. The API is stable and
every documented recipe is exercised by the test suite, but it has not met your
edge cases yet.

## Development

ApprovalEngine needs Ruby 3.1+ and PostgreSQL.

```sh
bin/setup
bin/rails app:test
bundle exec rubocop
```

Point at any Postgres with `DATABASE_URL` if you're not on the default
socket. See [CONTRIBUTING.md](CONTRIBUTING.md) for the full guide.

## Contributing

Bug reports and pull approvals are welcome on GitHub at
https://github.com/Harry-kp/approval_engine. Please read
[CONTRIBUTING.md](CONTRIBUTING.md) and our
[Code of Conduct](CODE_OF_CONDUCT.md).

## License

Available as open source under the terms of the
[MIT License](https://opensource.org/licenses/MIT).
