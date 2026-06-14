# ApprovalEngine

[![CI](https://github.com/Harry-kp/approval_engine/actions/workflows/ci.yml/badge.svg)](https://github.com/Harry-kp/approval_engine/actions/workflows/ci.yml)
![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.1-CC342D)
![Rails](https://img.shields.io/badge/rails-%3E%3D%207.0.8-D30001)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

Multi-tenant, immutable-ledger human approval flows for Rails.

Use it when a manager approves an invoice, then a CFO. Or Legal and IT
in parallel. Or "any two of five reviewers." ApprovalEngine supplies the
generic machinery: an append-only ledger, race-safe transitions, runtime
routing rules, and async side-effects. You decide what gets approved, who
approves, and what happens next.

## Is this for you?

Use it when you have:

- Multi-step, human-in-the-loop approvals, sequential or parallel
- Routing rules that admins change at runtime, without a deploy
- A need to audit who approved what, when, and on whose behalf
- Concurrency that must never double-approve

Look elsewhere when:

- You just need a boolean `approved` flag. A column and a method are simpler.
- You need a state machine for non-approval domains. Try
  [AASM](https://github.com/aasm/aasm) or
  [state_machines](https://github.com/state-machines/state_machines).
- You're not on PostgreSQL. The routing engine needs `jsonb` and `gin`.

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

## Quickstart

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

Define a template, its ordered steps, and the rule that triggers it.

```ruby
template = ApprovalEngine::TrackTemplate.create!(
  tenant_id: "acme", name: "High-value invoice", status: "active"
)
template.template_steps.create!(name: "Manager", layer: 1, assigned_group: "manager")
template.template_steps.create!(name: "CFO", layer: 2, assigned_group: "cfo")
template.trigger_rules.create!(
  tenant_id: "acme", event_name: "invoice.created",
  condition: { ">" => [{ "var" => "amount" }, 10_000] }
)
```

Trigger a run.

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

## See it live

Run the demo against a clone of this repo, not your own app. It needs
PostgreSQL running.

```sh
bin/demo
# seeds sample data and boots the dashboard at
# http://localhost:3000/approval_engine
```

Or explore the API in a console preloaded with sample data.

```sh
bin/console
>> Rails.application.load_seed
>> ApprovalEngine::Step.pending.first.approve!(by: User.find_by(role: "manager"))
```

The mounted dashboard lists every approval, filters by status, and drills
into tracks, steps, and the full audit trail. It is read-only, with
bundled styling.

## Configuration

```ruby
# config/initializers/approval_engine.rb
ApprovalEngine.configure do |config|
  config.actor_class           = "User"                 # who approves
  config.current_tenant_method = -> { Current.account } # anything with #id
  config.outbox_queue          = :default               # ActiveJob queue for side-effects
  config.raise_on_rule_errors  = false                  # fail closed in production
end
```

`current_tenant_method` defaults to `nil`. While it is nil, auto-routing
on create silently no-ops, since the engine cannot scope the rules.
Single-tenant apps can return a constant, e.g.
`-> { Struct.new(:id).new("default") }`.

No Redis or Sidekiq required. Side-effects run through ActiveJob, so
SolidQueue, Sidekiq, or the async adapter all work.

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

## Cookbook

See **[docs/COOKBOOK.md](docs/COOKBOOK.md)** for copy-paste recipes
covering every supported case, from "any two of five reviewers" to "Legal
and IT in parallel" to delegation and requesting changes.

## How it works

| Concern | Mechanism |
| --- | --- |
| Auditability | Append-only `Step` ledger; requesting changes appends an iteration instead of editing history |
| Concurrency | Approval-scoped pessimistic lock around every transition, so no double-approvals |
| Routing | JSON Logic ASTs in `jsonb`, evaluated by [`shiny_json_logic`](https://rubygems.org/gems/shiny_json_logic) |
| Side-effects | Transactional outbox relayed by ActiveJob, so a down API never rolls back an approval |
| Safety | A malformed rule quarantines the approval instead of raising |

A missing attribute is a clean non-match, since JSON Logic treats it as
`false`, so the approval just doesn’t start. Only a malformed rule, such
as an unknown operator, quarantines. The approval never crashes either
way. Set `config.raise_on_rule_errors = true` to surface errors loudly.

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
