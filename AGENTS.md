# AGENTS.md

Mountable Rails engine, published on rubygems as `approval_engine`. Ruby >= 3.2,
PostgreSQL only (jsonb, gin, `gen_random_uuid()`).

## Commands

Every command below was run against this repo. `bin/rails` drives the throwaway
host app in `test/dummy/`, which is why engine tasks carry the `app:` prefix.

- Install + prepare DB: `bin/setup` (set `DATABASE_URL` if Postgres isn't on the default socket)
- Test (all): `bin/rails app:test`
- Test (one file): `bin/rails app:test TEST=test/models/approval_engine/step_test.rb`
- Test (one case): `bin/rails app:test TEST=<file> TESTOPTS="-n=/percentage/"`
- Coverage: `COVERAGE=1 bin/rails app:test` → `coverage/index.html`
- Lint: `bundle exec rubocop` (`-a` to autocorrect)
- Package smoke test: `gem build approval_engine.gemspec`
- REPL: `bin/console` · Dashboard with seed data: `bin/demo`

There is no type checker. Lint and tests are the whole gate, and CI runs exactly
those two across Ruby 3.2–3.4 / Rails 7.1–8.x.

## Structure

- `app/models/approval_engine/` — the append-only ledger: `Approval` → `Track` → `Step`, plus value objects (`Consensus`) and shared concerns.
- `app/services/approval_engine/` — things that build or decide: `ApprovalBuilder`, `FlowDefinition` (the `define_flow` DSL), `RuleEvaluator`.
- `lib/approval_engine/` — the host-facing surface: `Configuration`, `Condition`, `TestHelpers`. Changing a name here is a breaking change for consumers.
- `lib/generators/**/templates/` — copied verbatim into host apps, never executed here (and filtered out of coverage). Don't expect tests to cover them.
- `test/dummy/` — the host app the suite boots. Not product; rubocop ignores it.

## Conventions

- **Mechanism, not policy.** The engine owns the generic, dangerous parts; the host owns business logic through seams (config callables, model callbacks, the DSL). New features preserve that boundary.
- **Rich models over service objects.** Prefer ActiveRecord behaviour and bang methods to procedural managers.
- Before writing a helper, grep for one. Three models already share `ConsensusValidatable` and `Outboxable`; a fourth copy of a validation or an outbox write belongs in a concern, not in the model.
- Same name, different job is normal here — `guard_consensus!` and `actor_label` each exist twice on purpose. Read both before "de-duplicating" them.
- Style is whatever `rubocop-rails-omakase` says.

## Gotchas

- **A stale `test/dummy/db/schema.rb` fails the entire suite** with `UnknownAttributeError` / `UndefinedTable` — errors that look like broken code but mean a stale database. Rails' `maintain_test_schema` loads that dump over your migrations. Fix: `rm test/dummy/db/schema.rb && bin/setup`. The file is gitignored and regenerated.
- Engine and dummy migrations interleave by timestamp but run from separate paths, so the engine needs **two** passes. `bin/setup` and CI both do this; a single `app:db:migrate` can leave you short.
- **`test/docs_test.rb` treats the README and CHANGELOG as API.** It asserts every `config.*` key, `ApprovalEngine.*` call and `rails generate` line in the README really exists, that README images are absolute URLs that resolve in-repo, and that every CHANGELOG version heading has a link reference. Rename a config key without updating the README and the suite fails — that is the test doing its job.
- Adding a config key means three places: `Configuration`, the install template at `lib/generators/approval_engine/install/templates/approval_engine.rb`, and the README.
- `db/migrate/` is excluded from rubocop and kept verbatim. Don't reformat it.
- `Step#transition!` is the chokepoint for every human decision: it takes a pessimistic lock on the approval, re-checks `pending?`, then writes the status, the audit row and the outbox event together. `approve!` / `reject!` / `request_changes!` all route through it. Keep that atomicity — the outbox is the only thing stopping a failing host callback from rolling back an approval.

## Working on an issue

1. Reproduce with a failing test in the existing test file for that module.
2. Fix with minimal churn; reuse existing helpers.
3. `bundle exec rubocop` and `bin/rails app:test` must both be green.
4. Add a `CHANGELOG.md` entry under "Unreleased" (create the section if absent).
5. Branch `fix/<short-desc>` or `feat/<short-desc>`; conventional commit message.
6. PR description: root cause, what changed, tests added.
