# Contributing to ApprovalEngine

Thanks for taking the time to contribute! This document gets you from a fresh
clone to a green test run.

## Getting started

ApprovalEngine is a Rails engine. It needs **Ruby 3.1+** and **PostgreSQL**.

```sh
git clone https://github.com/Harry-kp/approval_engine
cd approval_engine
bin/setup
```

`bin/setup` installs dependencies and prepares the test database. If your
Postgres isn't on the default socket, point at it with `DATABASE_URL`:

```sh
DATABASE_URL=postgres://localhost bin/setup
```

## Running the suite

```sh
bin/rails app:test          # tests
bundle exec rubocop         # lint (rubocop-rails-omakase)
```

Both must be green before a PR is merged. CI runs them across Ruby 3.2–3.4.

## See it work

```sh
bin/console                 # IRB with the engine + dummy app loaded
bin/demo                    # boots the dashboard with seeded data
```

## Submitting changes

1. Open an issue first for anything non-trivial so we can agree on direction.
2. Branch off `main`.
3. Add tests — a bug fix needs a regression test; a feature needs coverage that
   maps to a use case (see `docs/COOKBOOK.md`).
4. Keep `bundle exec rubocop` and `bin/rails app:test` green.
5. Update `CHANGELOG.md` under "Unreleased".
6. Open a PR with a clear description of the problem and the approach.

## Conventions

- **Mechanism, not policy.** The engine owns the generic, dangerous parts; the
  host app owns business logic via seams (callbacks, config, the DSL). New
  features should preserve that boundary.
- **Rich models over service objects.** Prefer ActiveRecord behaviour and bang
  methods to procedural managers.
- Follow the surrounding style; `rubocop-rails-omakase` is the source of truth.

By contributing, you agree your work is licensed under the project's MIT License.
