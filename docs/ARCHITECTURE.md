# Architecture & Engineering Document: `approval_engine`

**Enterprise-Grade Approval Orchestration for Ruby on Rails**

> **This is the design rationale, not a usage guide.** For how to install and
> use the gem, see the [README](../README.md) and [Cookbook](COOKBOOK.md), which
> are kept in sync with the code. Snippets here illustrate intent and may differ
> from the shipped API. (`acts_as_tenant` below is an external gem, shown only as
> an example of how a host might supply `current_tenant_method`.)

## 1. Introduction & Philosophy

`approval_engine` is a Ruby on Rails engine designed specifically for B2B SaaS platforms. It solves the hardest problem in enterprise software—concurrent, multi-tenant state machines and dynamic approval routing—without sacrificing the developer happiness of "The Rails Way".

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

---

## 3. Non-Functional Requirements

* **Zero External Dependencies:** Do not force Redis or Sidekiq. Rely strictly on `ActiveJob` for background processing.
* **Race-Condition Immunity:** Utilize database-level pessimistic locking (`lock!`) during state transitions to prevent double-approvals.
* **Cryptographic-Style Auditability:** Maintain an append-only `AuditLogs` table tracking `intended_actor` vs. `actual_actor` for strict compliance.
* **Safe Failures (Fail Closed):** A *missing* payload key is a clean non-match (JSON Logic treats it as false), so the approval simply doesn't start. Only a *malformed* rule (e.g. an unknown operator) quarantines the approval into a "System Failure" state, rather than crashing the web worker.
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



---

## 5. Use Cases & Solutions

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
* *Solution:* Mountable Rails Engine provides a pre-built Rack admin dashboard.



---

## 6. The End Picture: Installation & Usage

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

**4. Controller Execution (Rich Models)**

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

**5. System Admin UI**

```ruby
# config/routes.rb
Rails.application.routes.draw do
  authenticate :admin_user, ->(u) { u.super_admin? } do
    mount ApprovalEngine::Engine => '/admin/approvals'
  end
end

```