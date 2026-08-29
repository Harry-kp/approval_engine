# Launch posts

Every post for the 1.1.0 launch, written out and ready to paste. Nothing here is
shipped in the gem.

Do not post any of it until [checklist.md](checklist.md) is green. A post that
links a gem you can't `bundle add` is worse than no post.

> ## ⚠ Read this before you paste anything
>
> **The origin story in these drafts is invented, and it is about you.** Every
> post says some version of *"I wrote this same code at three jobs and got tired
> of it"* — at lines 34, 46, 118, 194, 316 and 435 below. Nobody told me that;
> it is a plausible-sounding story that was written to give the posts a voice,
> and it is a claim about your career that will appear under your name.
>
> Replace it with what actually happened before posting. If the real answer is
> "I built it for one job" or "I built it because I wanted to", say that — a
> smaller true story reads better than a bigger invented one, and this is exactly
> the kind of detail a commenter asks a follow-up question about.
>
> Everything else in these drafts is checked against the code. This is not.

## The rules these follow

- **Lead with the problem, in the first two sentences.** Never with the gem.
- **One code block per post** — the `define_flow` quickstart, identical
  everywhere, because it is the thing a reader is deciding about. The dev.to
  article is the exception and carries three, because it is an article.
- **Say it is young, with a real number.** 1.0 shipped in June 2026 and was
  never announced. There are no production users. Never imply otherwise.
- **Link the repo.** There is no hosted demo and no demo URL — the way to see it
  running is `bin/demo` from a clone. Do not invent one.
- **No emoji, no exclamation marks, no adjectives doing an engineer's job.**
  Banned outright: revolutionary, game-changing, seamless, blazing, effortless,
  battle-tested, production-ready, enterprise-grade.
- **End with a question**, and mean it. The point of this launch is to find out
  what the gem cannot express.

The voice is a working engineer who wrote the same approval code at three jobs
and got tired of it. Not a marketer with a gem.

---

## 1. r/rails — self-post

**Title**

> I extracted the approval-workflow code I'd rewritten at three jobs into a Rails engine

**Body**

Every Rails app I've worked on eventually grew an approval step, and it always
started the same way: an `approved` boolean and an `approved_by_id`. Then
Finance wanted a second signature over $10k. Then Legal and IT had to review the
same contract at once. Then someone went on leave and their queue backed up.
Then an auditor asked who approved invoice #4471 and on whose behalf, and the
honest answer was "it's spread across three callbacks and a status column we
overwrite."

I have now written that machinery three times at three companies. The third time
I wrote it as a gem instead.

`approval_engine` is a mountable engine. The flow is data, not code:

```ruby
ApprovalEngine.define_flow "High-value invoice", tenant: account.id, model: Invoice do
  on :create, when: { amount: { gt: 10_000 } }

  step "Manager sign-off", group: "manager"
  step "CFO sign-off",     group: "cfo"
end
```

Create an invoice over $10k and it routes itself. An approver's inbox is
`ApprovalEngine::Step.actionable_by(current_user)` — a normal scope, including
anything they cover by delegation — and acting on one is
`step.approve!(by: current_user)`. Groups resolve at runtime against your own
models, so nobody maintains a copy of your org chart in a workflow table.

The decisions worth arguing about:

- Routing rules are JSON Logic in a `jsonb` column, not Ruby. An admin moves
  "over $10k" to "over $25k unless EMEA" without a deploy, and there is no
  `eval` reachable from a database row.
- The ledger is append-only. A rejection or a "needs changes" appends a new
  iteration instead of rewinding a status column, so the history is still there
  when someone asks for it a year later.
- Every transition takes an approval-scoped pessimistic lock, so two people
  clicking Approve in the same second cannot both count.
- Side effects — pay the invoice, hit the API, send the mail — go through a
  transactional outbox relayed by ActiveJob. A down payment provider cannot roll
  back an approval. Delivery is at-least-once, so your callbacks have to be
  idempotent. That is the real tradeoff and it is in the README, not a footnote.
- No Redis, no Sidekiq required. ActiveJob only, so SolidQueue is fine.

Also in there: parallel tracks (Legal and IT at once), consensus per layer
(`:any` / `:all` / `:majority` / `"60%"` / a fixed count) resolved against the
live group size, time-bound delegation that records intended vs actual actor,
per-step timeouts that fire a callback and never auto-approve, an optional
browser editor for the routing rules, and optional built-in notification mail.
Both of those last two are off by default — upgrading a gem should not add a
write surface or start mailing your users.

Honest status: this is 1.1.0 and it is young. 1.0 shipped in June and I never
announced it anywhere, so the user count is one. PostgreSQL only, because the
routing needs `jsonb`. The API is stable and every cookbook recipe is covered by
the test suite, but I would much rather find out it is wrong now than after
you have shipped it.

- Repo: https://github.com/Harry-kp/approval_engine
- Cookbook (copy-paste recipes): https://github.com/Harry-kp/approval_engine/blob/main/docs/COOKBOOK.md

What shape do your approvals actually take? I am most curious about the ones
that would not fit this — "approve on behalf of a group whose membership changes
mid-flight" is the one I already know is rough.

---

## 2. r/ruby — self-post

**Title**

> Approval rules that change without a deploy: what I learned storing logic as JSON Logic instead of Ruby

**Body**

A customer emails: "our threshold is £25,000, not £10,000." The number lives in a
Ruby file. So it is a branch, a PR, a review, a deploy and a changelog entry —
for a number. Do that four times for four customers and the conditional in
`Invoice#requires_cfo?` is unreadable and nobody will touch it.

I hit this at three different jobs and solved it badly twice. The third time I
pulled the solution out into a gem, and the interesting part is not the approval
workflow — it is where the rule lives.

A rule is a JSON Logic AST in a `jsonb` column, and the flow that owns it is one
block:

```ruby
ApprovalEngine.define_flow "High-value invoice", tenant: account.id, model: Invoice do
  on :create, when: { amount: { gt: 10_000 } }

  step "Manager sign-off", group: "manager"
  step "CFO sign-off",     group: "cfo"
end
```

`when:` is sugar; what gets stored is `{">" => [{"var" => "amount"}, 10_000]}`,
evaluated against a payload the model explicitly whitelists with an
`exposes_for_approval` block. Three things I would defend:

**JSON Logic over a Ruby DSL stored as a string.** No `eval`, no arbitrary code
execution from a database row, and a predictable AST shape a form builder can
render. The cost is that nobody wants to hand-write an AST, so authoring needs
its own layer — a `Condition` object that maps a field/operator/value triple
both ways and returns `nil`, honestly, when an AST is too complex for the simple
form, rather than flattening it into something it isn't. That fallback turned
out to be more design work than the evaluator.

**A whitelist, not the model.** The rules engine never sees an ActiveRecord
object. It sees a flat string-keyed hash of exactly what the model declared. A
rule cannot reach through an association into somewhere it shouldn't, and
renaming `total_cents` does not silently break a customer's rule.

**Failing closed, quietly.** A missing key is a clean non-match — JSON Logic
treats it as false, so the approval simply doesn't start. Only a *malformed*
rule quarantines the approval into a visible failure state. Neither crashes a
web worker at 2am because someone typo'd a variable in an admin form.
`config.raise_on_rule_errors = true` makes it loud in development, which you
want, because "fails silently" and "fails invisibly" are different things and
only one of them is acceptable.

The gem around it is `approval_engine`: a mountable Rails engine for multi-step
human approvals, with an append-only ledger, sequential and parallel tracks,
consensus per layer, delegation, and a transactional outbox so a down external
API cannot roll back an approval.

It is young and worth saying so plainly. 1.1.0, PostgreSQL only, shipped 1.0 in
June and never announced it, so real-world usage is approximately me. The design
is what I would like scrutinised, more than the code.

- https://github.com/Harry-kp/approval_engine
- Architecture and the ADRs: https://github.com/Harry-kp/approval_engine/blob/main/docs/ARCHITECTURE.md

Has anyone here gone the other way — user-editable logic as a restricted Ruby
DSL rather than a data format? I keep circling back to whether the safety was
worth the authoring layer I had to build on top of it.

---

## 3. Hacker News — Show HN

**Title** (70 characters)

> Show HN: ApprovalEngine – multi-step approval workflows for Rails apps

Alternate, if you want the mechanism in the title (62 characters):

> Show HN: An append-only approval ledger for Rails applications

**First comment** — post it immediately after submitting.

Author here. Every app I've worked on eventually grew an approval step, and it
always started as an `approved` boolean. Then a second signature over $10k, then
two departments reviewing at once, then someone on leave whose queue backs up,
then an auditor asking who approved invoice #4471 and on whose behalf. By then
the answer lives in three callbacks and a status column that has been
overwritten twice. I rewrote that machinery at three jobs. This is the third
version, pulled out as a gem.

The flow is data rather than code:

    ApprovalEngine.define_flow "High-value invoice", tenant: account.id, model: Invoice do
      on :create, when: { amount: { gt: 10_000 } }

      step "Manager sign-off", group: "manager"
      step "CFO sign-off",     group: "cfo"
    end

Three decisions I would defend, and one I am unsure about:

1. Append-only ledger. A rejection or a request for changes appends a new
iteration rather than resetting a status, so history is a consequence of the
design instead of a second audit table someone has to remember to write to.

2. Rules as JSON Logic in a jsonb column, not Ruby. Admins change thresholds
without a deploy and there is no eval reachable from a database row. The cost is
a whole authoring layer, because nobody hand-writes an AST — that was more work
than the engine.

3. Transactional outbox for side effects. Approving commits instantly; paying
the invoice happens in an ActiveJob relay. A down payment provider cannot roll
back an approval. The tradeoff is at-least-once delivery, so host callbacks have
to be idempotent, and that is in the README rather than in a footnote.

The one I am unsure about: timeouts never decide. When a step's SLA elapses the
engine fires a callback and stops — it will not auto-approve, because silence is
not consent, and it will not auto-reject, because that is a decision nobody
made. You get expire! (an honest terminal denial with no actor on the ledger) or
reassign!. Every workflow tool I have used auto-advances on timeout and I think
they are wrong, but I have also never had to run a million-approval backlog.

What it does not do, plainly:

- No authentication. The mounted dashboard and the optional rule editor have
none of their own; you wrap the mount in your app's constraint. The rule editor
is off by default, because a gem upgrade must not turn a read surface into a
write surface.
- No authorization model. It will tell you whether a user is the assignee or an
active delegate. Who may see an approval at all is your app's question.
- No opinion about "late". It records when a step became actionable and when it
was decided, and hands you the numbers. SLA policy, escalation trees and
leaderboards are yours.
- No scheduler, no Redis, no Sidekiq. ActiveJob only. You schedule the sweeps
with whatever you already run.
- PostgreSQL only. The routing needs jsonb and gin.
- It does not touch your status column. It runs the process and reports the
outcome; mapping that onto your own vocabulary stays your code.

Honest state of it: 1.1.0, MIT, Rails 7.1+. 1.0 shipped in June and I never
told anyone, so the user count is basically one. The API is stable and every
documented recipe is covered by tests, but it has not met your edge cases yet
and I would like it to.

Repo: https://github.com/Harry-kp/approval_engine
Architecture and ADRs: https://github.com/Harry-kp/approval_engine/blob/main/docs/ARCHITECTURE.md

There is no hosted demo — `bin/demo` from a clone seeds a live approval and
boots the dashboard, which is as close as I can get you without asking you to
trust a server I run.

Most useful thing you could tell me: the approval shape at your company that
this obviously cannot express.

---

## 4. dev.to — article

**Title**

> The approval workflow you're about to write for the third time

**Front matter**

    tags: ruby, rails, opensource, architecture
    cover_image: https://raw.githubusercontent.com/Harry-kp/approval_engine/main/assets/social-preview.png
    canonical_url: (set only if you cross-post it somewhere else first)

**Body**

It always starts the same way. A model needs a human to say yes, so you add two
columns:

```ruby
add_column :invoices, :approved,       :boolean, default: false
add_column :invoices, :approved_by_id, :bigint
```

That is the correct amount of code for the problem as stated. I want to be clear
about that, because everything below is what happens when the problem stops
being as stated.

## Month two

Finance wants a second signature over $10,000. You add `cfo_approved_at`, a
method that checks both, and a branch in the mailer.

## Month five

Legal and IT both need to review contracts, at the same time, and either can
block. Two booleans will not express "at the same time", so you add a
`review_status` string and a small state machine, and the mailer branch becomes
three.

## Month nine

Priya is on leave for a fortnight and eleven invoices are sitting in her queue.
Someone asks whether Sam can approve them "as Priya". You add
`approved_on_behalf_of` and try not to think about what it means for the audit
report.

## Month eleven

Compliance asks who approved invoice #4471, when, and whether that person was
authorised at the time. You open the record. `approved` is `true`.
`approved_by_id` points at Sam. There is no trace of the rejection in month
seven, because the resubmit set `approved` back to `false`, and that was the
whole history.

I have lived some version of those eleven months at three companies. The third
time, I stopped writing it into the app and wrote it as a gem.

## What the extraction looks like

```ruby
ApprovalEngine.define_flow "High-value invoice", tenant: account.id, model: Invoice do
  on :create, when: { amount: { gt: 10_000 } }

  step "Manager sign-off", group: "manager"
  step "CFO sign-off",     group: "cfo"
end
```

Create an invoice over $10k and it routes itself. That block is idempotent — it
reconciles the same rows rather than stacking a fourth copy — so it lives in
`db/seeds.rb` and runs on every deploy. An approver's inbox is a scope,
`ApprovalEngine::Step.actionable_by(current_user)`, which includes anything they
cover by delegation, and acting on a step is one call:
`step.approve!(by: current_user, comment: "Checked against the PO")`. Groups
resolve at runtime against your own models, so nobody is maintaining a copy of
your org chart inside a workflow table.

## The three decisions that matter

**The ledger is append-only.** An approval is `Approval → Track → Step`, and a
step is never rewound. Rejecting or requesting changes appends a *new iteration*
of the steps, so month seven's rejection is still there in month eleven. The
audit trail is not a feature bolted next to the workflow; it is the workflow,
read in order. That is the part a boolean column can never give you, and the
part you need exactly once, urgently, under pressure.

**The rules are not in Ruby.** A routing rule is a JSON Logic expression in a
`jsonb` column, evaluated against a payload your model explicitly whitelists:

```ruby
class Invoice < ApplicationRecord
  has_approvals

  exposes_for_approval do
    attribute :amount,     type: :decimal
    attribute :department, type: :string, source: ->(i) { i.department.name }
  end
end
```

The rules engine never sees your model, only that flat hash. So a customer's
"£25,000, not £10,000, and not for EMEA" is a database write rather than a
deploy, and there is no `eval` reachable from a row. A missing key is a clean
non-match and the approval simply does not start; only a genuinely malformed
rule quarantines, and it does that visibly instead of crashing a web worker.

**Side effects cannot roll back an approval.** Paying the invoice, calling the
API, sending the mail — all of it goes into a transactional outbox and is
relayed by ActiveJob after the transition commits. Stripe being down is not a
500 on someone's Approve click. The honest cost: delivery is at-least-once and
unordered, so your `after_approved` has to be idempotent. That is in the README,
not a footnote, because it is the sharp edge.

## What it deliberately will not do

It never auto-approves. Give a step a timeout and when the deadline passes the
engine calls you back — it does not decide. You can `expire!` it, an honest
denial recorded with no actor because nobody acted, or reassign it to a backup.
Silence is not consent, and no library should quietly turn a missed deadline
into a signature.

It also has no opinion about who may see any of this, no authentication on the
dashboard, and no definition of "late". Those belong to your app, and it would
be worse if the gem guessed. The rule editor and the notification mail added in
1.1 both ship switched off for the same reason: upgrading a dependency should
never add a write surface or start mailing someone else's users.

## Where it actually is

`approval_engine` is at 1.1.0. MIT, PostgreSQL only (the routing needs `jsonb`),
Rails 7.1 through 8.x. It is young: 1.0 shipped in June, I never announced it,
and the user count is essentially one. The API is stable and every recipe in the
cookbook is exercised by the test suite — but it has not met your edge cases yet.

```ruby
gem "approval_engine"
```

- Repo: https://github.com/Harry-kp/approval_engine
- Cookbook: https://github.com/Harry-kp/approval_engine/blob/main/docs/COOKBOOK.md
- Architecture and ADRs: https://github.com/Harry-kp/approval_engine/blob/main/docs/ARCHITECTURE.md

There is no hosted demo. `bin/demo` from a clone seeds a live approval and boots
the dashboard, which is the honest version of "try it".

If you have built this in-house — and if you are reading this, you probably
have — which part of your version could this one not express?

---

## 5. Ruby Weekly — submission blurb

Submit through the "suggest a link" form at https://rubyweekly.com/. Peter Cooper
rewrites submissions, so give him facts and one hook, not adjectives.

> ApprovalEngine is a mountable Rails engine for multi-step human approvals —
> manager then CFO, Legal and IT in parallel, "any two of five reviewers" —
> built on an append-only ledger, so the audit trail is a consequence of the
> design rather than a second table. Routing rules are JSON Logic stored in
> `jsonb`, so admins change a threshold without a deploy, and side effects run
> through a transactional outbox on ActiveJob, so a down payment API cannot roll
> back an approval. 1.1.0 adds a `define_flow` DSL, an opt-in browser editor for
> the routing rules, and opt-in notification mail; it is PostgreSQL-only, MIT,
> and young — 1.0 shipped in June without an announcement.

---

## 6. Short Ruby newsletter — submission blurb

Submit to Lucian Ghinda via https://newsletter.shortruby.com/ (the submission
form, or a DM). That newsletter carries the "why" well, so this one is slightly
more personal.

> Harshit extracted the approval-workflow code he had rewritten at three jobs
> into `approval_engine`, a mountable Rails engine for multi-step human
> approvals: sequential and parallel tracks, consensus per layer (`:any` /
> `:all` / `:majority` / a percentage), time-bound delegation that records
> intended vs actual actor, and an append-only ledger where a rejection appends
> a new iteration instead of resetting a status column. The 1.1.0 release adds a
> `define_flow` DSL that puts a whole flow — its steps and the JSON Logic rule
> that routes it — in one readable block. Worth a look for the design choices
> too: the architecture doc is written as ADRs, including why timeouts never
> auto-approve.

---

## 7. rubyflow.com

A link aggregator: a title, a URL, and a short body. Free, indexed, two minutes.

**Title**

> ApprovalEngine 1.1: approval flows for Rails, defined in one block

**URL**

> https://github.com/Harry-kp/approval_engine

**Body**

> A mountable Rails engine for multi-step human approvals — manager then CFO,
> Legal and IT in parallel, "any two of five reviewers" — on an append-only
> ledger, with routing rules stored as JSON Logic so admins can change a
> threshold without a deploy. 1.1 adds `define_flow`, which puts a template, its
> ordered steps and the rule that routes to it into one idempotent block you can
> run from `db/seeds.rb` on every deploy, plus an opt-in browser editor for the
> rules and opt-in notification mail. PostgreSQL and ActiveJob; no Redis or
> Sidekiq. MIT, and young — 1.0 shipped in June and was never announced.
