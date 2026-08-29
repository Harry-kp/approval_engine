# Launch checklist

Two halves: the pre-flight, which is a gate, and the submission tracker, which
is a log. Work the pre-flight in order — each item assumes the one above it
passed — and do not post anything until every box is ticked.

The gate is one sentence: **the gem is installable from a clean machine and
every link in every post resolves.**

---

## Part 1 — pre-flight

### 1. The tree is releasable

| Check | How | Pass condition |
| --- | --- | --- |
| Tests | `bin/rails app:test` | 0 failures, 0 errors |
| Eager loading | `RAILS_ENV=test bin/rails app:test` with `config.eager_load = true` in the dummy app | 0 failures — the admin's field list eager-loads, so this catches a load-order break |
| Lint | `bundle exec rubocop` | no offenses |
| Version | `lib/approval_engine/version.rb` | `1.1.0` |
| Changelog | `CHANGELOG.md` | a `## [1.1.0] - YYYY-MM-DD` heading with the real date, and a `[1.1.0]:` link reference at the bottom |
| Docs match code | Read `docs/COOKBOOK.md` and `README.md` against the config keys in `lib/approval_engine/configuration.rb` | no key documented that does not exist, and no default misstated |

Record the test counts here when they pass, so a later regression is visible:
runs `____`, assertions `____`, failures `0`.

### 2. The gem builds, and ships what it should

```sh
bundle exec rake build            # => pkg/approval_engine-1.1.0.gem
gem specification pkg/approval_engine-1.1.0.gem files | sort
```

- [ ] `app/`, `config/`, `db/`, `lib/`, `MIT-LICENSE`, `README.md`, `CHANGELOG.md` are present.
- [ ] The 1.1 migration `db/migrate/20260618000001_add_reminded_at_to_steps.rb` is present. Without it an upgrading host loses reminders.
- [ ] The mailer views under `app/views/approval_engine/notification_mailer/` are present — all sixteen files, both formats of all six actions and the two partials.
- [ ] `config/locales/approval_engine.en.yml` is present, or every subject renders as a translation-missing string.
- [ ] `assets/` is **absent**. It is not in `spec.files` and must stay out; every README image is referenced by absolute `raw.githubusercontent.com` URL for exactly this reason.
- [ ] `docs/launch/` is **absent**. This directory is working copy, not product.
- [ ] `test/` and `Rakefile` are absent.

### 3. It installs on a machine that has never seen it

Do this from the built `.gem`, not from a path or git reference — a path
reference hides a missing file in `spec.files`, which is the single most common
way a release is broken on arrival.

```sh
gem install pkg/approval_engine-1.1.0.gem
cd $(mktemp -d) && rails new host --database=postgresql --skip-test && cd host
bundle add approval_engine
bin/rails generate approval_engine:install
bin/rails db:create db:migrate
```

- [ ] The generator prints the post-install notes and writes `config/initializers/approval_engine.rb`.
- [ ] `db:migrate` runs clean, including `add_reminded_at_to_steps`.
- [ ] `bin/rails runner 'p ApprovalEngine::VERSION'` prints `1.1.0`.
- [ ] Mount the engine, boot, and load `/approval_engine` — the dashboard renders with no approvals.
- [ ] Set `config.admin_enabled = true`, restart, and load `/approval_engine/admin` — the template list renders. Then set it back to `false`, restart, and confirm the same path 404s.
- [ ] Delete the throwaway app and `gem uninstall approval_engine` before doing anything else, so nothing local masks the published gem later.

### 4. `bin/demo` works from a fresh clone

Not from your working copy. Clone the pushed branch into a new directory, so an
uncommitted file cannot make it pass.

```sh
cd $(mktemp -d) && git clone https://github.com/Harry-kp/approval_engine && cd approval_engine
bin/setup
bin/demo
```

- [ ] It seeds without error and prints the dashboard URL.
- [ ] `http://localhost:3000/approval_engine` lists the seeded approvals.
- [ ] The scatter-gather approval renders: layer 1 approved, Legal and IT pending together, CFO waiting, audit trail below.
- [ ] `bin/console` then `Rails.application.load_seed` works too — the console path is quoted in the README.

Every post that says "clone it and run `bin/demo`" is making this promise. There
is no hosted demo, so this is the only way a reader sees it run.

### 5. The README renders in both places

GitHub and rubygems.org render the same file differently and from different
roots, which is why this is two checks and not one.

- [ ] **github.com** — open the repo page. Every image loads, the anchors in the table of contents jump correctly, and no code fence has swallowed the block after it.
- [ ] **rubygems.org** — after publishing, open https://rubygems.org/gems/approval_engine and confirm the images still load. They will only load if they are absolute `https://raw.githubusercontent.com/Harry-kp/approval_engine/main/assets/...` URLs, because `assets/` is not in the gem.
- [ ] Every relative link in the README (`docs/COOKBOOK.md`, `docs/ARCHITECTURE.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`) resolves on github.com.
- [ ] The three screenshots exist on `main` at the URLs the README uses: `screenshot-dashboard.png`, `screenshot-approval.png`, `screenshot-rule-builder.png`.
- [ ] `social-preview.png` is uploaded under Settings → General → Social preview, and the description on the card is the 1.1 positioning, not the 1.0 one.

### 6. Every URL in every post resolves

Extract them and check them, rather than reading them:

```sh
grep -oE 'https?://[^ )>,"]+' docs/launch/posts.md | sort -u | \
  while read -r url; do printf '%s %s\n' "$(curl -o /dev/null -s -w '%{http_code}' -L "$url")" "$url"; done
```

- [ ] Every line reads `200`. Anything else is a broken promise in a post that cannot be edited on Hacker News.
- [ ] The repo URL, the cookbook URL and the architecture URL point at `main` and resolve.
- [ ] No post mentions a hosted demo, a demo GIF, an `approval_engine:admin` generator, or an `approval_engine:mailer_views` generator. **None of those exist.** Grep for them:

```sh
grep -nE 'fly\.dev|herokuapp|demo\.|\.gif|approval_engine:admin|mailer_views' docs/launch/posts.md
```

- [ ] That grep returns nothing.

### 7. The release is cut

Follow [RELEASING.md](../../RELEASING.md); it is tag-driven, so the tag is the
publish.

- [ ] `git tag v1.1.0 && git push origin main --tags`
- [ ] The Release workflow finishes green.
- [ ] https://rubygems.org/gems/approval_engine shows 1.1.0.
- [ ] `gem install approval_engine` on a clean machine gets 1.1.0 from RubyGems, not from your local cache.
- [ ] The GitHub release for `v1.1.0` has the CHANGELOG entry as its body, not auto-generated notes. Release pages are indexed separately and are a common landing point from search.

### 8. The repo itself is findable

Not in the repo, so it is easy to forget. All of it is under About / Settings.

- [ ] **Description** set to the 1.1 positioning sentence.
- [ ] **Website** set to https://rubygems.org/gems/approval_engine. There is no demo to point at; leaving it blank wastes the slot.
- [ ] **Topics** added (GitHub caps at 20 — leave room): `rails`, `ruby`, `rails-engine`, `ruby-gem`, `approval-workflow`, `approval-process`, `approvals`, `workflow-engine`, `workflow`, `business-process`, `human-in-the-loop`, `audit-trail`, `multi-tenant`, `json-logic`, `postgresql`, `activejob`, `saas`, `b2b-saas`. Topic pages are browsable and indexed, and the repo currently has none.
- [ ] Social preview uploaded (see step 5).

---

## Part 2 — submission tracker

Fill in the date and the resulting link as you go. The link column is the point:
it is how you find the thread again to answer the first question, which matters
more than the post.

Post over several days, not in one hour. Hacker News and Reddit both read a
burst of identical links as promotion, and you cannot answer four threads at
once anyway.

### Announcements

| # | Destination | Where | Date sent | Resulting link |
| --- | --- | --- | --- | --- |
| 1 | Hacker News — Show HN | https://news.ycombinator.com/showhn.html | | |
| 2 | r/rails | https://reddit.com/r/rails | | |
| 3 | r/ruby | https://reddit.com/r/ruby | | |
| 4 | dev.to article | https://dev.to/new | | |
| 5 | rubyflow | https://rubyflow.com | | |
| 6 | Ruby Weekly | https://rubyweekly.com (suggest a link) | | |
| 7 | Short Ruby | https://newsletter.shortruby.com | | |

Post the Show HN first-comment immediately after submitting; a Show HN with no
author comment reads as a drive-by.

### Catalogues and discoverability

These are slower, outlast the threads, and are what a search finds in six
months.

| # | Destination | Where | Date sent | Resulting link |
| --- | --- | --- | --- | --- |
| 8 | Ruby Toolbox catalog PR | https://github.com/rubytoolbox/catalog | | |
| 9 | awesome-ruby PR | https://github.com/markets/awesome-ruby | | |
| 10 | awesome-rails PR | https://github.com/gramantin/awesome-rails | | |
| 11 | ruby.libhunt.com | picked up automatically once awesome-ruby merges — no action, just confirm | | |
| 12 | Stack Overflow answers | existing "rails approval workflow gem" questions, only where genuinely on-topic | | |
| 13 | GitHub release page | https://github.com/Harry-kp/approval_engine/releases/tag/v1.1.0 | | |

Read each list's contribution rules before opening the PR. A drive-by one-line
PR from an unknown repo gets closed, and you only get one attempt at a first
impression with a maintainer.

### Where authorship must be disclosed

Say you wrote it. Every time. It costs a clause and it is the difference between
a post people engage with and a post people report.

| Destination | How to disclose |
| --- | --- |
| Hacker News | The "Show HN:" prefix is the disclosure, and the first comment opens with "Author here." Both, not either. |
| r/rails, r/ruby | The body says "I wrote this" in the first two sentences. Both subreddits treat undisclosed self-promotion as spam, and mods can see your history. |
| dev.to | The article is written in the first person about your own gem, which is disclosure enough — but do not also post it as a "roundup" or a comparison. |
| **Stack Overflow** | **Mandatory and enforced.** Any answer mentioning the gem must state that you are the author, in the answer itself. This is the one place where omitting it gets the answer deleted and the account flagged. |
| Ruby Toolbox / awesome-* PRs | Say in the PR body that you are the author of the gem you are adding. Maintainers ask anyway. |
| Ruby Weekly / Short Ruby | The submission form is understood to be from the author; say so in the note regardless. |
| rubyflow | Self-posting is the norm there, so no special handling — but the body still reads as yours, not as a third party's recommendation. |

### After the posts

- [ ] Answer every reply for the first 48 hours. The threads are the point of the launch; the gem is already written.
- [ ] Log every "it can't do X" into GitHub issues, verbatim, even the ones you disagree with. That list is the 1.2 roadmap and the only real output of this exercise.
- [ ] Record the GitHub traffic numbers a week later against the pre-launch baseline (5 unique visitors in 14 days, 1 star, 0 forks, rubygems.org the only referrer) so the next release has something to compare against.
