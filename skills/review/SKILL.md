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

When the scope is a GitHub PR, post your findings as a single PR comment so the
review is visible where the work happens:

```bash
gh pr comment <number-or-url> --body "<your findings, in the Findings Format above>"
```

Lead with a one-line verdict (e.g. "No blockers" or "2 P0s, 1 P1"), then the
findings ordered by severity. Keep it to one comment; do not approve or merge.

## Working in repos (reuse worktrees)

Reuse existing checkouts and git worktrees wherever possible; do not clone a
fresh copy of a repo for every PR. To inspect a PR's code:

1. Work from the canonical clone of that repo if one already exists.
2. Create at most one reusable worktree for reviews (e.g. a `review` worktree),
   and `git fetch` + check out the PR branch into it for each review:
   `gh pr checkout <number>` (or `git worktree add` once, then reuse it).
3. Never accumulate one worktree or clone per PR; clean up or reuse so the
   repo directories do not blow up over time.
