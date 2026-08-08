---
name: drive-pr
description: Drive a PR to mergeable state: check CodeRabbit and reviewer comments, address valid ones, reply and resolve invalid ones, fix CI failures (even pre-existing ones from main), push fixes, then arm the pr-watch monitor and wake only when there is something new to act on. Use after opening a PR when you want it babysitted to green.
---

Can you now check the PR for coderabbit or other comments, check if they are valid and address them, if valid then do the fix and push, if not then reply to the comment and mark it as resolved. Just to be clear, check for ALL comments on the PR, bots or user, and _address_ them, meaning either fixing if valid or commenting and marking the comment as resolved it not really.

**Three feed sources, they do NOT overlap:**
1. The **reviews** API (`pulls/<n>/reviews` + `reviews/<id>/comments`): formal reviews with inline line comments. This is where well-behaved reviewer agents post.
2. The **inline-comments** API (`pulls/<n>/comments`): the inline review comment bodies themselves. REST carries everything except their resolve state.
3. The **issue-comments** API (`issues/<n>/comments`): top-level PR comments. Some agents and bots post their full review here as a single top-level comment instead of using the reviews API, if you only query reviews you'll completely miss them. Always fetch both feeds and merge.

All three are REST. Resolve state (`isResolved`) is the one thing REST cannot give you, so it is the one thing GraphQL is for, see the budget rule below.

## Poll on REST. GraphQL is a scarce budget.

REST and GraphQL have **separate** 5000/hour budgets, and GraphQL is the one that runs out. A loop that calls `reviewThreads` every cycle drains it to zero while REST sits untouched at 4996/5000, and then every other agent on the machine is locked out for the rest of the rolling hour.

Two traps make this hard to notice:

- **GraphQL exhaustion returns HTTP 200**, with body `{"errors":[{"type":"RATE_LIMIT","code":"graphql_rate_limit"}]}`. A `--jq` filter over that extracts empty or garbage rather than failing, so the loop keeps reporting numbers that are not real. Check `.resources.graphql.remaining` explicitly, never infer health from a result that parsed.
- **`gh pr view`, `gh pr checks`, `gh pr list` and `gh pr status` are GraphQL under the hood.** They look like innocent CLI conveniences, which is exactly why poll loops call them every cycle without anyone counting them against the budget. In the poll path, use the REST forms below instead.

```bash
gh api rate_limit --jq '.resources.graphql'   # budget check; rolling hour, ~15 min usually clears it
```

Reserve GraphQL for the resolve-state read and the `resolveReviewThread` mutations, batched from ONE cached `first:100` query per cycle rather than re-queried per thread. Do not nest `comments(first:N)` inside it unless you are about to act on a specific thread: cost scales with node count, so one nested page-100-of-page-100 query can cost a hundred times a flat one.

**Aggregation trap:** `--paginate --jq` runs the filter **per page**, so `length`, `group_by`, `map`, sort and dedup silently see one page only. A dupe scan done that way found 10 threads where the correct count was 22. Use `--paginate --slurp` to a file, then `jq 'flatten | ...'` over the file. `gh` rejects `--slurp` together with `--jq`, which is the point: it forces the two steps apart.

Also check the CI jobs, fix any failures, if failures are like unit, lint, typecheck or even integration, try running it locally to make sure its fixed first before pushing and waiting again on the CI

If a failure is pre-existing on main and not related to our code, it doesn't matter, fix it all the same, unless you're spending too much time trying to fix it and the scope creep would be too large, just fix it, a good boy scout always leaves the place cleaner than they found

## Waiting: arm the watcher, do not poll

After any push or batch of replies, do not hand-roll a sleep loop and do not re-check by hand. Arm the watch script under a persistent Monitor once per PR and end your turn; it wakes you only when there is something to act on.

    Monitor({
      command: "bash ~/.claude/skills/drive-pr/scripts/pr-watch.sh --repo OWNER/REPO --pr N --1h-cache",
      description: "PR N watch: CI + comments",
      persistent: true, timeout_ms: 3600000
    })

Monitor is often a deferred tool: load it first with ToolSearch ("select:Monitor") or the call fails with InputValidationError. `persistent: true` matters, without it the harness kills the watch at the 1h timeout ceiling.

The cache flag is required and there are exactly two: `--1h-cache` in a main session, `--5min-cache` inside a subagent. It sets the wake floor to the prompt-cache TTL of where you run: main sessions have a 1h TTL, so the floor is 15 min and an idle watch stands down after ~55 min; subagents have a 5m TTL, so the floor is 270s and idle wakes renew the cache at most 3 times (~18 min) before standing down. (The TTL split is measured, 2026-08, and has flipped before; re-measure if cache costs look wrong.)

What the watcher does, so you do not duplicate it: polls REST only (about 8 calls per 90s cycle, GraphQL never), diffs every poll against a per-PR baseline stored under `~/.claude/pr-watch-state/`, and stays silent unless something actionable changed. It wakes you for: a check run, commit status or workflow run newly concluding failure, timed_out, cancelled, action_required or startup_failure; a new comment on any of the three surfaces; an edited comment body (CodeRabbit edits its walkthrough in place, including "Reviews paused"); a merge conflict appearing. It never wakes you for: pending CI, your own comments, empty-body approvals (auto-approve bots), CodeRabbit's "review in progress" placeholder, or anything identical to the last wake.

Wake lines and what each one means:

- `WAKE_ACTION` with `NEW_FAILURE` / `NEW_COMMENT` / `CHANGED_COMMENT` / `CONFLICT` lines: act on exactly those items using the four-check list below, reply or push, end your turn. The watcher keeps running with an updated baseline; do not re-arm it after acting.
- `KEEPWARM n/3` (5min mode only): nothing new; the wake exists purely to renew your 5m prompt cache. Reply one short line and end your turn.
- `STANDDOWN`: the idle limit was reached and the watcher exited. Do not re-arm. Standing down is not concluding the review came back clean, it hands the wait back to the user, who picks the PR up later.
- `WAKE_ERROR`: gh failed several polls in a row. Check `gh auth status` and `gh api rate_limit`, then re-arm.
- `TERMINAL`: the PR is merged or closed; nothing to watch.

## What to check on a WAKE_ACTION (the four-check list)

A PR is not "green" just because CI passes. When the watcher wakes you with work, check ALL of:

1. **CI status**, all REST, no `gh pr checks`. `gh pr checks` is GraphQL-backed *and* deduplicates by check name, masking failing runs behind a passing rerun, so the REST form is both cheaper and more correct:

   ```bash
   sha=$(gh api repos/OWNER/REPO/pulls/<PR> --jq .head.sha)
   gh api "repos/OWNER/REPO/commits/$sha/check-runs" --jq '.check_runs[] | "\(.name)\t\(.status)\t\(.conclusion)"'
   gh api "repos/OWNER/REPO/commits/$sha/status"     --jq '.statuses[] | "\(.context)\t\(.state)"'
   gh api "repos/OWNER/REPO/actions/runs?head_sha=$sha" --jq '.workflow_runs[] | "\(.name)\t\(.status)\t\(.conclusion)"'
   ```

   **All three, not just the first.** `check-runs` is the Checks API only; legacy commit statuses live in a separate endpoint and do not appear in it. On a real langwatch PR, `check-runs` returned 83 entries and none of them were `CodeRabbit` or `action-semantic-pull-request`, which came back only from `commits/$sha/status`. Poll check-runs alone and the loop reports all-green while a required status context is red.

   That second query also confirms the latest SHA actually has a run for every workflow you expect. GitHub's push-trigger sometimes silently misses (we've seen langwatch-app-ci skip 2 consecutive pushes while pr-conventions fires fine). If a required workflow is missing for the current SHA, dispatch it manually: `gh workflow run <name>.yml --ref <branch>` and confirm with the same query.
2. **Open review threads**, the one GraphQL call per cycle, flat and cached:

   ```bash
   gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){pullRequest(number:<PR>){
     reviewThreads(first:100){nodes{id isResolved}}}}}'
   ```

   Filter `isResolved==false`, then read the bodies from REST (`pulls/<PR>/comments`) rather than nesting `comments(first:N)` into the GraphQL. A reviewer's inline thread stays unresolved until someone clicks "resolve", a top-level reply doesn't auto-resolve it. **Posting a summary issue comment is NOT the same as resolving the inline threads.**
3. **Mergeable state**, `gh api repos/OWNER/REPO/pulls/<PR> --jq '{mergeable, mergeable_state}'`, not `gh pr view --json` (GraphQL). A merge conflict shows as `mergeable_state: "dirty"`; `behind` and `blocked` also mean not actually mergeable even with green CI. Rebase or merge `main` to resolve, then push. GitHub computes `mergeable` asynchronously, so a `null` on the first read means "not computed yet", poll it once more rather than treating it as false.
4. **New top-level issue comments** since last check, reviewers often post follow-up reviews as comments after fixes land. `gh api repos/OWNER/REPO/issues/<PR>/comments --jq '.[] | select(.created_at > "<last_check_iso>")'`.

The watcher only reports what changed; this list is how you act on it. A quiet watcher means it found nothing new, trust it and do not add your own polling on top.

## After every push

Run the four-check list once, confirm the watcher is still running (it survives your pushes and re-baselines itself after every wake), then end your turn. A push that fixes CI may have also un-resolved a thread (rare but real if the diff lands in a file the thread points at).

## When a reviewer posts a second round

Reviewers commonly drop a fresh top-level review with 5–15 findings after the first round lands. Treat each finding as its own work item, with the same address-or-reply discipline. **A finding is not addressed until both the code change lands AND the inline thread is resolved.** If the finding came in as a top-level issue comment rather than an inline thread, post a reply that names the commit SHA where it landed so the reviewer can verify.
