# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-08-29

Three things 1.0 left you to build: authoring a flow, editing routing rules in a
browser, and telling anyone there was something waiting. Nothing in 1.0 changed
behaviour, and every new surface is off until you switch it on.

### Added

- `ApprovalEngine.define_flow(name, tenant:, model:)` — a declarative DSL for a
  whole flow (the template, its ordered steps, and the rules that route to it)
  in one block, instead of three `create!` calls whose relationship you have to
  already know:

      ApprovalEngine.define_flow "High-value invoice", tenant: "acme", model: Invoice do
        on :create, when: { amount: { gt: 10_000 } }

        step "Manager sign-off", group: "manager"
        step "CFO sign-off",     group: "cfo", timeout_after: 2.days
      end

  Each `step` is its own layer in declaration order; a `parallel(approvals_required:)`
  block puts several in one layer, under one consensus policy. `on` takes a
  lifecycle symbol resolved through `model:` or any event name you fire
  yourself, plus `when:`, `priority:` and `active:`. Idempotent on
  `(tenant_id, name)`: it reconciles the same rows rather than creating a second
  flow, so a seed file can re-run on every deploy — steps are matched by name and
  updated in place so the ids the admin UI links to survive, and a rule the block
  stopped declaring is deactivated rather than destroyed. It needs a live
  connection, so it belongs in `db/seeds.rb` or a rake task, not an initializer.
  **In-flight approvals are untouched** — they were stamped from the blueprint at
  build time and never re-read it. `TrackTemplate` / `TemplateStep` /
  `TriggerRule` remain public API and are unchanged; `define_flow` writes exactly
  the rows you would have. `ApprovalEngine.flow(name, tenant:)` reads the
  template back, for `run_approval!(templates: [...])`.
- `ApprovalEngine::Condition` — the translation layer between a
  field/operator/value triple and the JSON Logic AST stored in
  `TriggerRule#condition`, shared by the DSL's `when:` sugar and the admin rule
  builder. It covers `eq`, `not_eq`, `gt`, `gte`, `lt`, `lte`, `in` and
  `not_in`, ANDs multiple conditions together, and casts values to the types
  `exposes_for_approval` declared so a rule can't compare a number against a
  string and quietly never match. `Condition.parse` returns `nil` — not an empty
  result — for an AST it cannot represent, so **a rule someone hand-wrote is
  never silently flattened into something it isn't.**
- A built-in admin UI for templates, their steps, and their trigger rules,
  mounted under `/admin` inside the engine — the code behind the README's
  standing claim that admins change routing without a deploy. Gated behind
  `config.admin_enabled` (**default `false`**, so an existing 1.0 mount stays
  read-only across the upgrade), re-checked per request rather than trusted from
  boot, and drawn once at boot so it needs a restart. The rule editor is a
  zero-JavaScript field/operator/value form whose field list comes from
  `exposes_for_approval`, with an automatic fallback to a raw JSON Logic textarea
  for any condition the simple form cannot represent. **Turning it on is not
  authentication**: it decides whether the write routes exist, not who may reach
  them, so the mount still needs your own constraint. The approvals dashboard
  itself stays read-only.
- Built-in notifications — six messages (`step_activated`, `step_reminder`,
  `step_reassigned`, `changes_requested`, `approval_approved`,
  `approval_rejected`) rendered in HTML and text by
  `ApprovalEngine::NotificationMailer`, dispatched by `ApprovalEngine::Notifier`
  from inside `ProcessOutboxJob` so mail rides the existing transactional outbox:
  a flaky SMTP host retries with backoff and never touches the approval. Off
  unless `config.notifications_enabled = true`: **upgrading does not start
  emailing your users.** Enabling it also needs a From address (`mailer_from`, or
  a `parent_mailer` that declares one) and `approval_url_builder`, without which
  the mail arrives with nowhere to go; the three approval-level messages stay
  silent until `approval_recipients` says who asked. Recipients otherwise resolve
  off the actor via `actor_email_method` (`:email` by default), and an actor with
  no address is skipped rather than raised on. Views are overridden by dropping
  copies into `app/views/approval_engine/notification_mailer/`. Delivery is
  at-least-once, as with every outbox event. The `approval_engine.*`
  `ActiveSupport::Notifications` remain the escape hatch for hosts that would
  rather send their own.
- `ApprovalEngine::ReminderSweepJob` — nudges approvers who have gone quiet for
  longer than `config.reminder_after` (nil by default, so scheduling the job
  before setting it does nothing). Idempotent via a new `reminded_at` column on
  steps, so each step is nudged at most once and running the sweep hourly only
  makes the nudge arrive sooner.
- `config.approval_groups` — an optional allowlist of the group names
  `define_flow` may route to. `nil`, the default, means no vocabulary is declared
  and nothing is checked; set it and a `group:` typo stops the seed instead of
  resolving zero actors at build time.

### Changed

- `spec.summary` and `spec.description` now lead with what the gem does rather
  than how it is built, so the RubyGems snippet reads as a problem instead of a
  spec sheet. `documentation_uri` points at the cookbook, `source_code_uri` is
  pinned to the repository rather than derived from `homepage`, and
  `docs/ARCHITECTURE.md` / `docs/COOKBOOK.md` now ship inside the gem.
- Rewrote the README around the problem it solves: the job in the first line,
  screenshots of a real approval above the fold, a single-block 60-second
  quickstart built on `define_flow`, an honest "what to do when a boolean flag
  stops fitting" instead of a bullet sending most readers away, and an
  `Alternatives` section naming the neighbours. `test/docs_test.rb` now fails the
  build if the README documents a config key, an `ApprovalEngine` method, a
  generator, or an image that does not exist.

### Fixed

- Approvals attached to a host record whose primary key is a UUID silently lost
  their target. The polymorphic reference columns were created by
  `t.references`, which defaults to bigint, so a UUID cast to `0`: the row
  saved, no error was raised, and `approval.target` read back `nil`. They are
  string columns now, which fit a bigint, a UUID and a ULID alike.

### Upgrading from 1.0

Nothing to do, and nothing to migrate before the gem will run. Both new
surfaces default to off: no mail is sent and no write endpoint exists until you
ask for them. **Nothing that touches your users or calls your code turns itself
on because you bumped a version.**

One thing does change without asking, and it is worth knowing about. The ledger
now emits a `step.activated` outbox event when a step becomes actionable —
roughly one extra outbox row and relay job per step. It reaches your app only if
you subscribe to it: `ActiveSupport::Notifications` subscribers matching
`approval_engine.*` will start seeing `approval_engine.step.activated`, and a
model that happens to define `after_step_activated(step)` will start having it
called. If neither is true of your app, the only difference is the extra rows.

There is one new migration, and only the reminder sweep reads the column it
adds, so it is needed when you want reminders and not before:

    bin/rails approval_engine:install:migrations
    bin/rails db:migrate

## [1.0.0] - 2026-06-17

First public release. The API below is stable.

### Added

- Immutable, append-only approval ledger (`Approval` → `Track` → `Step`) with
  forward-only state transitions and write-once `AuditLog` rows.
- `has_approvals` model macro and the `exposes_for_approval`
  anti-corruption DSL for whitelisting attributes to the rules engine.
- Dynamic, tenant-scoped routing via JSON Logic (`shiny_json_logic`), with
  fail-closed quarantine on malformed rules.
- `preview_approval(event:)` — a side-effect-free dry run that returns
  a `ApprovalPlan` describing what an action *would* trigger (which template,
  steps, and assignees), so hosts can warn users before they commit.
- `Step.actionable_by(actor)` — an approver's inbox scope: pending steps assigned
  to them plus those they cover via an active delegation. Plus `Step#target` to
  show what each step is approving. Powers a "my pending approvals" UI.
- Cycle-time facts on every step: `activated_at` (became actionable) and
  `decided_at` (human resolved it), stamped automatically — with `step.waiting_for`
  / `step.time_to_decision` readers and `approval.current_bottleneck` (the
  longest-pending step). The dashboard shows a time-in-step column. SLA
  thresholds, reminders, and escalation stay the host's to define.
- Per-step timeouts: `timeout_after` on a template step (the clock starts when the
  step becomes actionable), swept by `ApprovalEngine::TimeoutSweepJob` /
  `Step.sweep_timeouts!`, surfaced via the `on_step_timeout(step)` host callback. A
  timeout fires once and never decides the step — `step.expire!` is the honest
  terminal denial (a distinct `expired` state, recorded with no actual actor).
  **ApprovalEngine never auto-approves: silence is not consent.**
- `record.approval_history` — a read-only `History` view of everything a record
  has gone through: all approvals (newest first, eager-loaded), and a
  chronological timeline of step actions with actors and comments. The host
  decides who may see it.
- `Model.approval_event_name(:create)` returns the conventional auto-trigger
  event name, so rules can reference it instead of a hand-typed literal that
  could silently drift (raises on an unknown lifecycle).
- Trigger approvals on any event/transition — `run_approval!(event:)`
  accepts any event name, and `has_approvals(on: [:create, :update])`
  auto-routes on update too (gated per-lifecycle via `trigger_approval?`).
- `approval_candidates(event:)` lists every matching approval (not just the
  top-priority one), and `run_approval!(templates:)` starts a chosen
  one (or several, as parallel tracks) — so a user can decide instead of the
  engine auto-routing by priority.
- `approval.trigger_rule` — provenance: the `TriggerRule` that auto-routed an
  approval (nil for a manual `run_approval!(templates:)` start), captured at
  build time so it stays stable even if the rule is edited or retired later.
- Consensus per layer via `approvals_required`: `:any`, `:all`, `:majority`, a
  percentage like `"60%"`, or a fixed count — resolved against the live group
  size, so authors express policy without hard-coding headcount.
- `track.layer_tally(layer)` — a public read of a layer's live consensus tally
  (`required` / `approved` / `rejected` / `pending` / `waiting` / `group_size` /
  `outcome`), so a UI can show "N of M approved" and *why* a layer is
  met/failed/undecided without re-deriving the consensus math the engine owns. A
  layer that hasn't opened yet (all steps still `waiting`) reads as `:undecided`,
  not `:failed` — `waiting` steps count as still-reachable approvals.
- Consensus-aware rejection: a reject respects the layer's policy, failing the
  approval as soon as the required approvals become unreachable (one no for
  `:all`; every actor for `:any`; too few voters left to reach a count) rather
  than vetoing on the first no. A failed layer never advances.
- Sequential multi-layer tracks with automatic layer activation.
- Scatter-gather parallel tracks via `ApprovalBuilder.build_parallel!` — one
  approval gathers across several simultaneous tracks. The gather is
  consensus-aware: `approvals_required` (on `build_parallel!` /
  `run_approval!(templates:, approvals_required:)`) says how many tracks must
  approve — `:all` by default (unanimity, the historical behaviour), but also
  `:any` / `:majority` / `"60%"` / a fixed count, so "2 of 3 departments must
  sign off" is expressible. One track rejecting no longer vetoes a still-reachable
  gather; a count that exceeds the number of tracks raises at build time.
- Append-only "approval changes" cycles (`request_changes!`) that send an approval
  back for a fresh iteration while preserving history.
- `approval.cancel!(reason:)` — withdraw an in-flight approval: the third terminal
  outcome beside approved and rejected, for when the thing being approved is voided
  or retracted. Cancels open tracks/steps, keeps history, fires `after_cancelled`.
- `step.reassign!(to:, by:, comment:)` — hand a stuck step to another actor without
  restarting the flow (the escalation partner to timeouts), recorded on the ledger
  and firing `after_step_reassigned`.
- `ApprovalEngine::Error` base class for every error the engine raises
  (`BuilderError`, `EvaluationError` reparented), so a host can rescue one type.
- Time-bound delegation with intended-vs-actual actor auditing.
- Transactional outbox that relays host callbacks and
  `ActiveSupport::Notifications` asynchronously via ActiveJob.
- Pessimistic, approval-scoped locking that makes double-approvals impossible.
- `approval_engine:install` and `approval_engine:views` generators.
- A read-only, mountable ops dashboard.

### Onboarding & hygiene

- Reworked the README golden path (verified end-to-end): a "What you must
  provide" checklist, a self-contained quickstart, a mandatory `preview ...
  .triggered?` verification step, and loud warnings about the silent-failure
  traps (unset tenant, `event_name` mismatch, `draft` templates, unexposed vars).
- Added a JSON Logic "Authoring rules" cookbook section (and/or/in/equality
  examples) and rewrote the install generator's POST_INSTALL into a warned,
  ordered checklist.
- Removed the redundant `ApprovalEngine::Web` alias (mount `ApprovalEngine::Engine`),
  pruned generator dead code (unused mailer, layout, rake stub), normalized the
  blueprint migration, and retired the stale handoff doc.

### Hardened

- Eliminated N+1s in the dashboard (approval list track-counts, detail-page
  actors) and `approval_history`; `History#events` is now a single bounded,
  DB-ordered query with preloaded actors (proven N+1-free by query-count tests).
- Added hot-path indexes: track `(request_id, status)`, step layer-consensus
  `(branch_id, iteration, layer, status)`, approval `(target, created_at)`,
  audit-log `(tenant_id, created_at)`, trigger-rule resolution, a delegation
  time-window composite, and a partial index for the outbox drain.
- DB `CHECK` constrains `approvals_required` to the accepted vocabulary on both
  steps and template-steps (a raw insert can't store a spec the engine can't
  resolve).
- `drain!` is bounded (age + limit) so a backlog can't enqueue everything at once.
- Outbox relay now holds its row lock for the whole transaction (concurrent
  workers can't double-deliver), retries with backoff (`retry_on`), retires
  events whose target was purged instead of looping forever, and `drain!` skips
  in-flight events. Host callbacks are at-least-once and unordered — make them
  idempotent. Exhausted retries now dead-letter the row (`failed_at`) so `drain!`
  can't resurrect a poison event forever; delivery errors are recorded in a
  separate `delivery_error` column so a retry never clobbers the semantic reason
  (`error_payload`) the host callback reads; and the timeout sweep isolates a
  single step's failure so it can't starve the rest of the batch.
- Database `CHECK` constraints enforce every status and `approvals_required`
  value, so the ledger can't be corrupted by a raw write — not just Ruby
  validations.
- Consensus/layer edge cases that could silently strand an approval in `pending`
  are now handled: non-contiguous layers activate the next existing layer, a
  required count exceeding the resolved group raises at build time, and `:all`
  excludes cancelled siblings from its denominator.
- A misconfigured `actor_class` now raises an actionable `BuilderError` naming
  the setting, instead of a raw `NameError`.

[1.1.0]: https://github.com/Harry-kp/approval_engine/releases/tag/v1.1.0
[1.0.0]: https://github.com/Harry-kp/approval_engine/releases/tag/v1.0.0
