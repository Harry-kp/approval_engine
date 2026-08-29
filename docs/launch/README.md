# Launch

> **Before posting: the origin story in `posts.md` is invented.** Every draft
> claims the author wrote this same code at three jobs. That detail was written
> to give the posts a voice, not reported from life, and it will appear under a
> real name. Replace it with what actually happened. Everything else in the
> drafts is checked against the shipped code; that one thing is not.


The 1.1.0 launch runbook. This directory is working copy, not product.

`approval_engine` 1.0.0 shipped on 2026-06-17 and was never announced anywhere:
five unique visitors in the following fortnight, one star, no forks, and
rubygems.org as the only referrer it has ever had. It was not rejected — it was
never seen. That is what these files exist to fix, alongside the two gaps 1.1
closes in the gem itself: routing rules an admin can actually change in a
browser, and a notification layer that tells an approver something is waiting.

## What's here

| File | What it is |
| --- | --- |
| [posts.md](posts.md) | Every announcement, written out and ready to paste: r/rails, r/ruby, a Show HN and its author comment, a dev.to article, and blurbs for Ruby Weekly, Short Ruby and rubyflow. Plus the voice rules they all follow. |
| [checklist.md](checklist.md) | The pre-flight, in order, with the verification for each step — then the submission tracker, with a place to record the date and resulting link for every destination. |

## Not shipped in the gem

The gemspec enumerates the files it packages (`app`, `config`, `db`, `lib`, the
licence, the README, the changelog). Nothing under `docs/launch/` is among them,
and nothing here should ever be added — a published gem containing its own
marketing copy is a smell, and the pre-flight checks for its absence.

## The one rule

**Nothing goes out until the gem is installable from a clean machine and every
link in every post resolves.**

A launch post is a promise that the thing behind the link works. A broken
`bundle add`, a 404 on the cookbook, or a screenshot that renders on github.com
and not on rubygems.org spends the attention this release gets — and there is
only one first look. `checklist.md` is that gate; work it top to bottom before
anything is posted.

Two things in `posts.md` are load-bearing and easy to erode on an edit: it is
honest that this is a young gem with no production users to point at, and it
never references a hosted demo, a demo GIF, or a generator that does not exist.
Keep both true.
