---
name: review
description: Review recent code changes for correctness, regressions, test strategy, design quality, and security/privacy risks before merge.
---

Perform a rigorous review of the requested scope.

## Inputs

Use one of:

- the current branch diff,
- specific files or paths from the user,
- a feature file plus related implementation.

## Review Workflow

1. Inspect behavior against acceptance criteria.
2. Identify functional bugs and regression risks first.
3. Evaluate design quality with SOLID and CUPID heuristics.
4. Evaluate tests for pyramid placement, naming, and flakiness risk.
5. Evaluate security and privacy risks (PII exposure, secrets, unsafe logging).
6. Return actionable findings ordered by severity.

## Findings Format

For each finding provide:

1. Severity (`P0` to `P3`).
2. File and line reference.
3. Why it is a problem.
4. Minimal fix direction.

If there are no findings, state that explicitly and list residual risks or testing gaps.

## Conflict Handling

If there are valid but conflicting approaches:

1. Present both options.
2. Explain tradeoffs.
3. Mark as `NEEDS USER DECISION`.

## Posting the review

When the scope is a GitHub PR, post as a PROPER review — inline comments on
the lines that have findings, and the top-level body for the summary ONLY.

Why this matters: other tooling (drive-pr loops, other reviewer agents,
CodeRabbit-style bots) fetches via the GitHub **reviews** API
(`GET /repos/.../pulls/<n>/reviews` and `/reviews/<id>/comments`). If you
just call `gh pr comment` you've posted a top-level **issue** comment,
which the reviews API does NOT return — your findings become invisible
to anything driving the PR. Inline review comments DO show up in the
reviews API, so they get picked up.

Use the REST API to post review + inline comments in a single request:

```bash
gh api -X POST "repos/<owner>/<repo>/pulls/<number>/reviews" \
  -f event=COMMENT \
  -f body="<one-line verdict + short summary, e.g. '2 P0s, 1 P1 — see inline comments'>" \
  -f 'comments[][path]=path/to/file.ts' \
  -F 'comments[][line]=42' \
  -f 'comments[][side]=RIGHT' \
  -f 'comments[][body]=**P0** — Why it is a problem. Minimal fix direction.'
```

Repeat the `comments[][...]` group once per finding. Use the Findings
Format above for each `body`. For range comments (multi-line),
add `comments[][start_line]=N` and `comments[][start_side]=RIGHT`.

The top-level `body` is the summary only: one-line verdict + the severity
counts + a pointer that details are inline. Do NOT paste full findings
into the body — keep them on the lines they refer to so a reviewer can
respond to each thread individually.

Do not approve or merge.

## Working in repos (reuse worktrees)

Reuse existing checkouts and git worktrees wherever possible; do not clone a
fresh copy of a repo for every PR. To inspect a PR's code:

1. Work from the canonical clone of that repo if one already exists.
2. Create at most one reusable worktree for reviews (e.g. a `review` worktree),
   and `git fetch` + check out the PR branch into it for each review:
   `gh pr checkout <number>` (or `git worktree add` once, then reuse it).
3. Never accumulate one worktree or clone per PR; clean up or reuse so the
   repo directories do not blow up over time.
