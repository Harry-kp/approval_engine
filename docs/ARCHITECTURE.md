# Architecture & Engineering Document: `approval_engine`

**Why the engine is shaped the way it is.**

> **This is the design rationale, not a usage guide.** For how to install and
> use the gem, see the [README](../README.md) and [Cookbook](COOKBOOK.md), which
> are kept in sync with the code. Snippets here illustrate intent and may differ
> from the shipped API. (`acts_as_tenant` below is an external gem, shown only as
> an example of how a host might supply `current_tenant_method`.)

## 1. Introduction & Philosophy

`approval_engine` is a Rails engine for multi-step human approvals. The problems it takes seriously are the ones that make people rewrite this by hand every few years: concurrent transitions that must never double-approve, routing rules that change without a deploy, and a record of who decided what that survives the decision being revised.

**The Philosophy:** Be an absolute dictator about database integrity (immutable ledgers, pessimistic locking), but rely entirely on Rails conventions (Rich Models, ActiveJob, Duck Typing, Hotwire Generators) for the developer experience.

---

## 2. Functional Requirements

* **Dynamic JSON Routing Engine:** Evaluate approval rules dynamically via database-stored JSON Logic, preventing hardcoded Ruby deployment cycles.
* **Multi-Tenant Isolation:** Strictly scope all templates, rules, and instances to a specific `tenant_id`.
* **Scatter-Gather Parallelism:** Support spawning multiple simultaneous tracks (e.g., Legal, HR, Finance) and resolving via Consensus Rules (`:all`, `:any`, `:majority`, percentages, or a fixed count).
* **Append-Only Rework Cycles:** When a step is rejected, generate a new iteration cycle rather than mutating historical database states.
* **Delegation of Authority (DoA):** Allow time-bound "Proxy" approvals (e.g., User A acts on behalf of User B while on leave).
* **Anti-Corruption Macro:** Provide a class-level DSL (`exposes_for_approval`) to explicitly whitelist model attributes and relationships safe for the JSON Rules Engine.
* **Asynchronous Side-Effects:** Guarantee that external API failures or slow mailers do not roll back the approval database transaction via the Transactional Outbox pattern.
* **Declarative Flow Definition:** Let a flow — its template, its ordered steps, and the rules that route to it — be written as one idempotent block (`ApprovalEngine.define_flow`) that reconciles the same rows on every deploy instead of stacking duplicates.
* **A Shared Authoring Vocabulary:** Provide one field/operator/value abstraction (`ApprovalEngine::Condition`) that renders to JSON Logic and reads back from it, so a rule written in a seed file and a rule written in a browser form are the same rule.
* **Runtime Rule Editing:** Provide an opt-in admin surface where a tenant's templates, steps, and routing rules are edited in the browser, with no JavaScript and no deploy — the claim the README makes, made true.
* **Approver Notification:** Ship the approver-facing half — mail on activation, reassignment, rework and outcome, plus an idempotent reminder sweep for approvers who have gone quiet — as an opt-in layer, never as an upgrade side-effect.

---

## 3. Non-Functional Requirements

* **Zero External Dependencies:** Do not force Redis or Sidekiq. Rely strictly on `ActiveJob` for background processing.
* **Race-Condition Immunity:** Utilize database-level pessimistic locking (`lock!`) during state transitions to prevent double-approvals.
* **Cryptographic-Style Auditability:** Maintain an append-only `AuditLogs` table tracking `intended_actor` vs. `actual_actor` for strict compliance.
* **Safe Failures (Fail Closed):** A *missing* payload key is a clean non-match (JSON Logic treats it as false), so the approval simply doesn't start. Only a *malformed* rule (e.g. an unknown operator) quarantines the approval into a "System Failure" state, rather than crashing the web worker.
* **Silent Upgrades:** A new surface that can write, mail, or otherwise act on someone else's users ships switched off. `bundle update approval_engine` must never change observable behaviour on its own — see ADR 9 and ADR 10.
* **Developer Ergonomics (Omakase):** No heavy Service Objects. Use Rich ActiveRecord models, bang methods, and conventional callbacks.

---

## 4. Architectural Decision Records (ADRs)

* **ADR 1: JSON Logic for Dynamic Rules**
* *Context:* SaaS clients need to define their own routing logic (e.g., "Amount > 5000").
* *Decision:* Store rules as Abstract Syntax Trees in PostgreSQL `JSONB` using the `json_logic` standard.
* *Rationale:* Prevents arbitrary code execution. Provides a predictable schema for front-end UI builders.


* **ADR 2: The Append-Only State Ledger**
* *Context:* Audits require knowing exactly what happened and when.
* *Decision:* Never `UPDATE` an `approved` step back to `pending`. Instead, insert Iteration 2 rows.
* *Rationale:* Preserves historical truth, prevents webhook double-firing, and tracks departmental bottlenecks.


* **ADR 3: The Transactional Outbox**
* *Context:* Triggering emails/APIs inside an `after_commit` callback is brittle.
* *Decision:* State changes insert a row into a `TransactionalOutbox` table. `ActiveJob` polls and processes these asynchronously.
* *Rationale:* Isolates external network failures from core database transactions.


* **ADR 4: Rich Models over Service Objects**
* *Context:* Enterprise gems often devolve into procedural Java-style `Manager` classes.
* *Decision:* Expose the ledger via rich ActiveRecord models (`ApprovalEngine::Step`).
* *Rationale:* Maximizes developer happiness by allowing standard Rails error handling (`rescue ActiveRecord::RecordInvalid`), scopes, and validations.


* **ADR 5: `Condition` as the Authoring Seam**
* *Context:* JSON Logic is the right format to *store* a rule in and the wrong format to *write* one in. Nobody should have to hand-type `{ ">" => [{ "var" => "amount" }, 10_000] }` into a form field or a seed file.
* *Decision:* One class — `ApprovalEngine::Condition` — renders a field/operator/value triple down to JSON Logic and reads it back up. Both authoring paths go through it: the `when:` sugar in `define_flow` and the admin rule builder. It reports `nil` from `.parse` for any AST it cannot represent.
* *Rationale:* One vocabulary (`eq`, `not_eq`, `gt`, `gte`, `lt`, `lte`, `in`, `not_in`, ANDed) means a rule written in `db/seeds.rb` and the same rule written in the browser are the same rule, with no second dialect to keep in sync. The honest `nil` is what lets the UI fall back to a raw textarea rather than silently rewriting a hand-written `or`, or a substring `in`, into something with different semantics. Values are cast against the declared `exposes_for_approval` type on the way in, because `amount > "10000"` compares a number against a string and quietly never matches — a failure mode with no error message anywhere.


* **ADR 6: `define_flow` Reconciles, It Never Inserts**
* *Context:* A flow that lives in the codebase has to survive being re-run on every deploy, from `db/seeds.rb`, by two deploys at once.
* *Decision:* A flow is keyed on `(tenant_id, name)` and reconciled under a per-flow Postgres advisory lock. Steps are matched **by name** and updated in place; a step no longer declared is destroyed. Rules are matched by `(event_name, priority)` and updated in place; a rule no longer declared is **deactivated, never destroyed**. A block that declares no `on` at all leaves existing rules alone.
* *Rationale:* The block is a *desired state*, not a migration, so re-running it with nothing changed must write nothing. Matching steps by name (rather than position) keeps the ids an admin UI links to. Rules are deactivated because an `Approval` records the `TriggerRule` that routed it as provenance on a `nullify` foreign key — destroying a rule would not error, it would quietly erase "which rule started this?" from every approval it ever spawned, and deactivating is what dropping an `on` actually means. The asymmetry with steps is deliberate: a template with no steps is always a bug, but a flow whose steps live in code and whose routing an admin owns in the UI is a legitimate shape.


* **ADR 7: The Ledger Copies the Blueprint, It Does Not Reference It**
* *Context:* If a `Step` held a foreign key to the `TemplateStep` it came from, editing a template would retroactively change what an approver is looking at, and deleting one would strand a running approval.
* *Decision:* `ApprovalBuilder` copies `name`, `layer`, `approvals_required` and `timeout_after` onto each `Step` row at build time, and resolves `assigned_group` into a concrete `assigned_actor` per step. `IterationBuilder` clones a rework iteration from the previous iteration's *ledger* rows, never from the template. No ledger row holds a foreign key to a blueprint row.
* *Rationale:* An approval is a historical fact and has to read the same in a year as it did on the day. This is also what makes ADR 6 possible: because nothing outside a template points at its steps, reconciliation can rewrite blueprints freely — no template versioning, no soft deletes, no "which version was this built from?" column, and no lock taken against running work. See [§5](#5-the-blueprintledger-boundary) for the full consequences, including the honest cost.


* **ADR 8: Notifications Ride the Outbox**
* *Context:* An approval nobody hears about is not a workflow, so 1.1 adds a mailer. Mail is the least reliable side-effect in the system and must not be able to disturb the most important one.
* *Decision:* `ApprovalEngine::Notifier` is dispatched from inside `ProcessOutboxJob` — never from a model callback — and it **enqueues** mail (`deliver_later`) rather than delivering it. A notification that raises is logged and swallowed.
* *Rationale:* Building the message inside the relay means mail is only ever built from state that has already committed. Enqueuing rather than delivering means a dead SMTP server retries the *mail* and never the outbox event — a retried event would re-run the host's callbacks alongside it, turning a mailer problem into a double-disbursed invoice. Swallowing follows from the same premise: built-in mail is a courtesy layered on top of the delivery contract, not part of it, so a missing template or an unreachable actor must never fail the event. The cost, stated where adopters read it rather than in a footnote: delivery is at-least-once, so an approver may occasionally receive the same nudge twice.


* **ADR 9: Notifications Are Off By Default**
* *Context:* 1.1 adds a mailer to a gem that shipped without one. Every install that upgrades already has `Step` rows assigned to real employees and customers, and their addresses are already reachable through `config.actor_class`.
* *Decision:* `config.notifications_enabled` defaults to `false` and nothing beneath it has any effect. Enabling it takes three deliberate settings — the switch, a From address (`mailer_from`, or a `parent_mailer` that already declares `default from:`), and `approval_url_builder`. The three approval-level messages additionally need `approval_recipients`.
* *Rationale:* The blast radius of getting this wrong is not a broken page; it is unsolicited mail to someone else's users, sent by a dependency they bumped a minor version of. A feature that can only be discovered by reading the changelog is a fair price for that. The other two settings are gates for the same reason at a smaller scale: without a sender there is nothing to hand the SMTP server, and without a URL the mail arrives with nowhere to go. `approval_recipients` has no safe default at all — the engine knows who *approves*, and only the host knows who *asked*. `notification_events` is the second switch: a host can keep the layer on and mute one message without writing a mailer or forking a view.


* **ADR 10: The Admin Is Off By Default**
* *Context:* 1.0 shipped a read-only ops dashboard, and hosts mounted it behind whatever authentication they already had — a `constraints` block, a Devise `authenticate`, an IP allowlist, a VPN. 1.1 adds template, step and rule CRUD to that same mount.
* *Decision:* `config.admin_enabled` defaults to `false`. The write routes are not drawn while it is false, and every admin controller re-checks the flag on each request rather than trusting boot time.
* *Rationale:* Whatever a host judged acceptable for a read surface, they did not judge it for a write surface, and the two are different threat models: reading exposes what happened, writing changes what routes where, for every future approval, silently. A gem upgrade must never make that call on someone's behalf. The per-request re-check exists because routes are drawn once at boot and a host may point their own routes at these controllers. **Turning the flag on is not authentication** — the engine ships none — so the mount stays wrapped in the host's own constraint either way. The admin also needs a full-stack host (sessions for CSRF, and flash), so it is unavailable under `config.api_only`.




---

## 5. The Blueprint/Ledger Boundary

Every table in the engine sits on one side of a line, and the line is the reason
a flow can be rewritten at any time without anyone auditing a paused deploy.

| Side | Tables | Nature |
| --- | --- | --- |
| **Blueprint** | `TrackTemplate`, `TemplateStep`, `TriggerRule` | Mutable configuration. Says what *should* happen. Owned by a `define_flow` block, or by an admin in the UI. |
| **Ledger** | `Approval`, `Track`, `Step`, `AuditLog`, `OutboxEvent` | Append-only history. Says what *did* happen. Owned by nobody; written only by transitions. |

The blueprint is read exactly once per approval, at build time, and never again.
What crosses the line then:

* `TemplateStep#name`, `#layer`, `#approvals_required` and `#timeout_after` are **copied** onto each `Step` row.
* `TemplateStep#assigned_group` is **resolved** — handed to the host's `resolve_approval_group(group_name, target)` and expanded into one `Step` per actor it returns, with a concrete `assigned_actor`.
* `TrackTemplate#name` is copied onto the `Track`, and `#tenant_id` onto every ledger row the build creates.
* The `TriggerRule` that matched is recorded on the `Approval` as provenance, on a `nullify` foreign key — the one deliberate pointer back across the line, and it is allowed to become `NULL` without taking anything with it.

What does not cross: no ledger row holds a foreign key to a `TemplateStep`. A
rework iteration is cloned by `IterationBuilder` from the previous iteration's
`Step` rows, so even the second attempt reads the ledger rather than the
blueprint.

Four consequences follow, and they are the reason to write this down:

1. **Redefining a flow cannot disturb an approval in flight.** Re-run `define_flow` mid-morning with a step removed and a threshold moved, and every approval already running finishes with the steps it started with. That is what makes ADR 6's reconciliation safe to put in `db/seeds.rb` on every deploy.
2. **Rework replays the ledger, not the template.** Requesting changes on an approval built yesterday appends an iteration containing the step you deleted from the flow this morning. That is correct: the approver is finishing the process they were shown.
3. **Reconciliation stays cheap.** Because nothing outside the template points at its steps, there is no template versioning scheme, no soft-delete tombstone, and no "which blueprint version was this built from?" column to keep honest.
4. **The cost, honestly:** a fix to a blueprint does not reach running approvals. If a template step named the wrong group, every approval already built carries the wrong assignee, and the remedy is `step.reassign!` on the ledger — not an edit to the template. The engine prefers this to the alternative, which is an audit trail that changes shape after the fact.

---

## 6. Use Cases & Solutions

### The "I Want To" User Stories

1. **The Standard Approval:** "As a manager, I want to click 'Approve' and move the invoice to the next step."
* *Solution:* Call `step.approve!(by: current_user)`.


2. **The Hard Reject:** "As a VP, I want to reject an approval entirely so it cannot proceed."
* *Solution:* Call `step.reject!(by: current_user)`.


3. **The Rollback / Approval Changes:** "As a Director, I want to kick a document back to the original submitter for fixes."
* *Solution:* Call `step.request_changes!(by: current_user)`. Engine appends Iteration 2.


4. **Conditional Routing:** "As a SaaS Admin, I want invoices over $10k to require extra approval."
* *Solution:* JSON Rules Evaluator checks payload against stored templates.


5. **Anti-Corruption / Safe Payloads:** "As a Rails Dev, I want to expose `total_cents` to the UI builder as `amount`."
* *Solution:* The `exposes_for_approval` class macro whitelists and transforms data safely.


6. **Multi-Tenancy:** "As a SaaS Customer, I don't want my approvals bleeding into another company's account."
* *Solution:* Engine enforces `tenant_id` scopes on all templates and ledger queries.


7. **Delegation (Vacation):** "As a User, I want my peer to approve my items while I am in Hawaii."
* *Solution:* `Delegation` API creates a time-bound proxy lease. Audit log notes the proxy.


8. **Parallel Approvals:** "As a Submitter, I need Legal and IT to review this simultaneously."
* *Solution:* Engine spawns a `Approval` with multiple parallel `Track` tracks.


9. **Consensus - 'Any':** "As a team, any one of the 5 senior devs can approve this PR."
* *Solution:* Step definition set to `approvals_required: :any`.


10. **Consensus - 'All':** "As a board, all 3 directors must approve the merger."
* *Solution:* Step definition set to `approvals_required: :all`.


11. **Inter-Department Chaining:** "As Finance, when I approve the hardware, I want an IT provisioning process to start."
* *Solution:* Define `def after_approved` on the host model to trigger the next domain.


12. **Asynchronous Safety:** "As a Dev, if the Stripe API is down, I don't want the user's 'Approve' click to throw a 500 error."
* *Solution:* State transitions are handled instantly; Stripe logic is deferred to the Outbox via ActiveJob.


13. **Strict Auditing:** "As a Compliance Officer, I need cryptographically secure proof of who approved what."
* *Solution:* The `AuditLogs` table tracks `intended_actor_id` and `actual_actor_id`.


14. **Graceful Rule Failure:** "As an Ops team, if we typo a variable in our custom rule, the app shouldn't crash."
* *Solution:* A missing key is a clean non-match; a *malformed* rule is rescued and forced into a safe "System Quarantined" approval state (logged for ops).


15. **Queue Agnosticism:** "As a Startup, we use SolidQueue, not Sidekiq."
* *Solution:* Engine relies exclusively on `ActiveJob::Base`.


16. **Product UI Flexibility:** "As a Designer, I want the 'My Approvals' page to match our custom Tailwind theme."
* *Solution:* `rails generate approval_engine:views` copies raw ERB files into the host app for full customization.


17. **Admin Monitoring:** "As a Support Tech, I want to see a dashboard of stuck approvals without writing custom queries."
* *Solution:* The mountable engine provides a read-only ops dashboard — every approval, filterable by status, drilling into tracks, steps, the audit trail, and a time-in-step column. It has no authentication of its own; the host wraps the mount.


18. **The Flow as One Block:** "As a Rails Dev, I don't want four `create!` calls and a hand-written AST to say 'manager, then CFO, over $10k'."
* *Solution:* `ApprovalEngine.define_flow` writes the template, its ordered steps and its rules in one block, and reconciles them on every re-run (ADR 6). It writes ordinary rows, so nothing downstream can tell a defined flow from a hand-built one.


19. **Runtime Rule Editing:** "As a SaaS Admin, I want to move the threshold from $10k to $25k myself, today."
* *Solution:* The opt-in admin (`config.admin_enabled`, ADR 10) offers a field/operator/value builder over `Condition` (ADR 5), with the field list drawn from `exposes_for_approval` and a raw JSON Logic fallback for anything the simple form cannot represent.


20. **Telling the Approver:** "As a Submitter, I want the manager to actually find out there is something waiting on them."
* *Solution:* Six built-in messages dispatched by `Notifier` from inside the outbox relay (ADR 8), off until the host enables them (ADR 9). Views are overridden by dropping files into the host's own `app/views/approval_engine/notification_mailer/`.


21. **The Quiet Approver:** "As an Ops lead, I want a nudge to go out after two days — once, not every hour."
* *Solution:* `ReminderSweepJob` / `Step.sweep_reminders!` over the `remindable` scope, stamping `reminded_at` so a step is nudged at most once. A nudge is not a verdict: **ApprovalEngine never auto-approves.**



---

## 7. The End Picture: Installation & Usage

**1. Installation**

```bash
bundle add approval_engine
rails generate approval_engine:install
rails db:migrate

```

**2. Configuration (`config/initializers/approval_engine.rb`)**

```ruby
ApprovalEngine.configure do |config|
  config.outbox_queue = :high_priority
  config.current_tenant_method = -> { Current.account }

  # Both 1.1 surfaces are off until asked for — see ADR 9 and ADR 10.
  config.notifications_enabled = true
  config.mailer_from           = "approvals@acme.com"
  config.approval_url_builder  = ->(approval) { invoice_url(approval.target) }
  config.reminder_after        = 2.days.to_i

  config.admin_enabled = true   # routes are drawn at boot; restart to apply
end

```

**3. Model Integration (The "Rails Way")**

```ruby
class Invoice < ApplicationRecord
  acts_as_tenant :account

  # Inject the engine
  has_approvals 

  # The Anti-Corruption Layer (Exposed to the JSON UI Builder)
  exposes_for_approval do
    attribute :amount, type: :decimal
    attribute :department, type: :string, source: ->(invoice) { invoice.department.name }
    attribute :is_high_risk, type: :boolean, source: :requires_manual_audit?
  end

  # Conventional Side-Effect Callback (Triggered via ActiveJob Outbox)
  def after_approved
    PaymentService.disburse_funds!(self)
  end
end

```

**4. Flow Definition (`db/seeds.rb`)**

```ruby
ApprovalEngine.define_flow "High-value invoice", tenant: account.id, model: Invoice do
  on :create, when: { amount: { gt: 10_000 } }

  step "Manager sign-off", group: "manager"

  parallel(approvals_required: :all) do
    step "Legal review", group: "legal"
    step "IT review",    group: "it"
  end

  step "CFO sign-off", group: "cfo", timeout_after: 2.days
end

```

Idempotent, so it belongs on the deploy path (ADR 6). It needs a live
connection, so it does not belong in an initializer.

**5. Controller Execution (Rich Models)**

```ruby
class ApprovalsController < ApplicationController
  def update
    # Fetch natively
    step = ApprovalEngine::Step.pending.find(params[:id])

    # Execute via Rich Model bang methods
    case params[:action_type]
    when 'approve'         then step.approve!(by: current_user, comment: params[:comment])
    when 'reject'          then step.reject!(by: current_user)          # terminal
    when 'request_changes' then step.request_changes!(by: current_user) # back for a new iteration
    end
    
    redirect_to target_record_path, notice: "Action recorded."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to target_record_path, alert: e.message
  end
end

```

**6. Mounting the Dashboard (and, optionally, the Admin)**

```ruby
# config/routes.rb
Rails.application.routes.draw do
  authenticate :admin_user, ->(u) { u.super_admin? } do
    mount ApprovalEngine::Engine => '/admin/approvals'
  end
end

```

The mount is read-only until `config.admin_enabled` is set, at which point the
template and rule editor appears at `/admin` beneath it. The constraint above is
the host's, not the engine's, and it is required either way: the flag decides
whether the write routes exist, never who may reach them (ADR 10).