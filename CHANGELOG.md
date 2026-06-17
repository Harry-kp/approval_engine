# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
  in-flight events. Host callbacks are at-least-once — make them idempotent.
- Database `CHECK` constraints enforce every status and `approvals_required`
  value, so the ledger can't be corrupted by a raw write — not just Ruby
  validations.
- Consensus/layer edge cases that could silently strand an approval in `pending`
  are now handled: non-contiguous layers activate the next existing layer, a
  required count exceeding the resolved group raises at build time, and `:all`
  excludes cancelled siblings from its denominator.
- A misconfigured `actor_class` now raises an actionable `BuilderError` naming
  the setting, instead of a raw `NameError`.

[Unreleased]: https://github.com/Harry-kp/approval_engine/commits/main
