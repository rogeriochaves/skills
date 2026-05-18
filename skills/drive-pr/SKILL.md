---
name: drive-pr
description: Drive a PR to mergeable state — check CodeRabbit and reviewer comments, address valid ones, reply and resolve invalid ones, fix CI failures (even pre-existing ones from main), push fixes, then loop every 4.5 minutes until two consecutive clean checks. Use after opening a PR when you want it babysitted to green.
---

Can you now check the PR for coderabbit or other comments, check if they are valid and address them, if valid then do the fix and push, if not then reply to the comment and mark it as resolved. Just to be clear, check for ALL comments on the PR, bots or user, and _address_ them, meaning either fixing if valid or commenting and marking the comment as resolved it not really.

Also check the CI jobs, fix any failures, if failures are like unit, lint, typecheck or even integration, try running it locally to make sure its fixed first before pushing and waiting again on the CI

If a failure is pre-existing on main and not related to our code, it doesn't matter, fix it all the same, unless you're spending too much time trying to fix it and the scope creep would be too large, just fix it, a good boy scout always leaves the place cleaner than they found

Then, after any push, wait 4.5 min (just below your cache expiration) and check for new comments by coderabbit or CI issues to be addressed, if nothing new twice, then just relax

## What to check every loop iteration

A PR is not "green" just because CI passes. Each iteration must check ALL of:

1. **CI status** — `gh pr checks <PR>` plus `gh run list --branch <branch>` to catch failing runs that `pr checks` deduplicates behind a passing rerun.
2. **Open review threads** — `gh api graphql` for `reviewThreads(first:50){nodes{isResolved, comments...}}` and filter `isResolved==false`. A reviewer's inline thread stays unresolved until someone clicks "resolve" — a top-level reply doesn't auto-resolve it. **Posting a summary issue comment is NOT the same as resolving the inline threads.**
3. **Mergeable state** — `gh pr view <PR> --json mergeStateStatus,mergeable`. `BEHIND`, `DIRTY` (merge conflict), or `BLOCKED` all mean not actually mergeable even with green CI. A `DIRTY` state is the conflict-with-base banner GitHub shows; rebase or merge `main` to resolve, then push.
4. **New top-level issue comments** since last check — reviewers often post follow-up reviews as comments after fixes land. `gh api repos/OWNER/REPO/issues/<PR>/comments --jq '.[] | select(.created_at > "<last_check_iso>")'`.

The "two consecutive clean cycles → relax" rule fires only when ALL FOUR pass two cycles in a row. Don't stand down on green CI alone.

## After every push

Before sleeping the 4.5 min, run the four-check list once. A push that fixes CI may have also un-resolved a thread (rare but real if the diff lands in a file the thread points at).

## When a reviewer posts a second round

Reviewers commonly drop a fresh top-level review with 5–15 findings after the first round lands. Treat each finding as its own work item, with the same address-or-reply discipline. **A finding is not addressed until both the code change lands AND the inline thread is resolved.** If the finding came in as a top-level issue comment rather than an inline thread, post a reply that names the commit SHA where it landed so the reviewer can verify.
