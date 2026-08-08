#!/usr/bin/env bash
# pr-watch.sh: event-gated PR watcher for the drive-pr loop.
#
# Runs under a persistent Claude Code Monitor. Stdout is the event stream:
# every line printed here wakes the driving agent, so the watch loop prints
# nothing while there is nothing to act on. Diagnostics go to stderr.
#
# Watches ONE OR MANY pull requests in a single process. All watched PRs
# share one floor and one keepwarm clock, so idle wakes stay at one per
# boundary no matter how many PRs are covered. Never arm one Monitor per PR
# in 5min mode: that multiplies keepwarm wakes by the PR count.
#
# Wakes the agent only for:
#   - a check run, commit status or workflow run newly concluding
#     failure / timed_out / cancelled / action_required / startup_failure
#   - a new comment on any of the three comment surfaces
#     (issue comments, inline review comments, reviews)
#   - an edited comment body (CodeRabbit edits its walkthrough in place,
#     including the "Reviews paused" state)
#   - a merge conflict appearing (mergeable_state goes dirty)
#
# Never wakes for: pending CI, the authenticated user's own comments,
# empty-body approvals (auto-approve bots), CodeRabbit's "review in
# progress" placeholder, or state identical to the stored baseline.
#
# Usage:
#   pr-watch.sh --1h-cache OWNER/REPO#N [OWNER/REPO#M ...]     watch, main session
#   pr-watch.sh --5min-cache OWNER/REPO#N [...]                watch, subagent
#   pr-watch.sh --seed OWNER/REPO#N [...]                      capture baselines, exit
#   pr-watch.sh --status OWNER/REPO#N [...]                    one diff per PR, no writes
#   pr-watch.sh --diff-test cur.json base.json                 render diff of fixtures
#
# "#pr-N" is accepted as well as "#N". The legacy single-PR form
# "--repo OWNER/REPO --pr N" still works.
#
# The cache flag is required in watch mode. It sets the wake floor to the
# prompt-cache TTL of the session type: main sessions have a 1h TTL so the
# floor is 900s and an idle watch stands down after ~55min; subagents have
# a 5m TTL so the floor is 270s, idle wakes renew the cache at most
# PRWATCH_MAX_KEEPWARM (3) times, then the watch stands down.
#
# All polling is REST. GraphQL is never touched: it is a separate, scarcer
# budget and resolve-state stays an awake-agent job.
#
# Env overrides (mainly for tests): PRWATCH_POLL, PRWATCH_FLOOR,
# PRWATCH_IDLE_LIMIT, PRWATCH_MAX_KEEPWARM, PRWATCH_STATE_DIR,
# PRWATCH_NO_SELF_FILTER=1, PRWATCH_ERR_THRESHOLD.

set -uo pipefail
unset TRACEPARENT TRACESTATE 2>/dev/null || true

STATE_DIR="${PRWATCH_STATE_DIR:-$HOME/.claude/pr-watch-state}"
MODE="" ACTION="watch" ALLOW_CLOSED=0
DIFF_CUR="" DIFF_BASE=""
LEGACY_REPO="" LEGACY_PR=""
N_PRS=0

add_pr() {
  R_REPO[$N_PRS]="$1"
  R_PR[$N_PRS]="$2"
  R_ERRS[$N_PRS]=0
  R_ACTIVE[$N_PRS]=1
  N_PRS=$((N_PRS + 1))
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) LEGACY_REPO="$2"; shift 2 ;;
    --pr) LEGACY_PR="$2"; shift 2 ;;
    --1h-cache) MODE="1h"; shift ;;
    --5min-cache) MODE="5m"; shift ;;
    --seed) ACTION="seed"; shift ;;
    --status) ACTION="status"; shift ;;
    --allow-closed) ALLOW_CLOSED=1; shift ;;
    --diff-test) ACTION="diff-test"; DIFF_CUR="$2"; DIFF_BASE="$3"; shift 3 ;;
    */*'#'*)
      r="${1%%#*}"; n="${1##*#}"; n="${n#pr-}"
      case "$n" in
        ''|*[!0-9]*) echo "invalid PR number in: $1" >&2; exit 2 ;;
      esac
      add_pr "$r" "$n"
      shift ;;
    *) echo "unknown argument: $1 (expected OWNER/REPO#N or a flag)" >&2; exit 2 ;;
  esac
done

if [ -n "$LEGACY_REPO" ] || [ -n "$LEGACY_PR" ]; then
  [ -n "$LEGACY_REPO" ] && [ -n "$LEGACY_PR" ] || { echo "--repo and --pr must be passed together" >&2; exit 2; }
  add_pr "$LEGACY_REPO" "$LEGACY_PR"
fi

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "gh is required" >&2; exit 2; }

if [ "$ACTION" != "diff-test" ] && [ "$N_PRS" -eq 0 ]; then
  echo "at least one OWNER/REPO#N (or --repo OWNER/REPO --pr N) is required" >&2
  exit 2
fi
if [ "$ACTION" = "watch" ] && [ -z "$MODE" ]; then
  echo "pass --1h-cache (main session) or --5min-cache (subagent): the wake floor depends on it" >&2
  exit 2
fi

case "$MODE" in
  5m) FLOOR="${PRWATCH_FLOOR:-270}" ;;
  1h) FLOOR="${PRWATCH_FLOOR:-900}" ;;
  *)  FLOOR="${PRWATCH_FLOOR:-270}" ;;
esac
POLL="${PRWATCH_POLL:-90}"
IDLE_LIMIT="${PRWATCH_IDLE_LIMIT:-3300}"
MAX_KEEPWARM="${PRWATCH_MAX_KEEPWARM:-3}"
ERR_THRESHOLD="${PRWATCH_ERR_THRESHOLD:-5}"
NO_SELF_FILTER="${PRWATCH_NO_SELF_FILTER:-0}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

IN_PROGRESS_MARKER="auto-generated comment: review in progress"

state_file_for() {
  echo "$STATE_DIR/$(printf '%s' "$1" | tr '/' '_')__$2.json"
}

active_label() {
  local out="" i=0
  while [ $i -lt $N_PRS ]; do
    [ "${R_ACTIVE[$i]}" = "1" ] && out="$out ${R_REPO[$i]}#${R_PR[$i]}"
    i=$((i + 1))
  done
  printf '%s' "${out# }"
}

# --- fetch: one full REST snapshot of $REPO#$PR into $TMP/cur.json. Returns 1 on failure.
fetch() {
  gh api "repos/$REPO/pulls/$PR" >"$TMP/meta.json" 2>>"$TMP/err.log" || return 1
  local sha
  sha=$(jq -r '.head.sha' "$TMP/meta.json") || return 1
  [ -n "$sha" ] && [ "$sha" != "null" ] || return 1

  gh api --paginate "repos/$REPO/commits/$sha/check-runs?per_page=100" 2>>"$TMP/err.log" \
    | jq -s '[.[].check_runs[]]' >"$TMP/checks.json" || return 1
  gh api "repos/$REPO/commits/$sha/status" >"$TMP/status.json" 2>>"$TMP/err.log" || return 1
  gh api "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" 2>>"$TMP/err.log" \
    | jq '[.workflow_runs[]]' >"$TMP/runs.json" || return 1
  gh api --paginate "repos/$REPO/issues/$PR/comments?per_page=100" 2>>"$TMP/err.log" \
    | jq -s 'add // []' >"$TMP/ic.json" || return 1
  gh api --paginate "repos/$REPO/pulls/$PR/comments?per_page=100" 2>>"$TMP/err.log" \
    | jq -s 'add // []' >"$TMP/rc.json" || return 1
  gh api --paginate "repos/$REPO/pulls/$PR/reviews?per_page=100" 2>>"$TMP/err.log" \
    | jq -s 'add // []' >"$TMP/rv.json" || return 1

  jq -n \
    --slurpfile meta "$TMP/meta.json" \
    --slurpfile checks "$TMP/checks.json" \
    --slurpfile status "$TMP/status.json" \
    --slurpfile runs "$TMP/runs.json" \
    --slurpfile ic "$TMP/ic.json" \
    --slurpfile rc "$TMP/rc.json" \
    --slurpfile rv "$TMP/rv.json" \
    --arg marker "$IN_PROGRESS_MARKER" '
    def bodyhash: ((.body // "") | explode) as $e
      | "\($e | length):\($e | add // 0):\([$e | to_entries[] | (.key + 1) * .value] | add // 0)";
    def snip: (.body // "") | gsub("[\r\n\t]+"; " ") | gsub("<!--.*?-->"; "") | gsub(" +"; " ") | ltrimstr(" ") | .[0:240];
    ($meta[0]) as $m |
    {
      sha: $m.head.sha,
      open: ($m.state == "open" and (($m.merged // false) | not)),
      dirty: (($m.mergeable_state // "") == "dirty"),
      pending: (
        ([$checks[0][] | select(.status != "completed")] | length)
        + ([$runs[0][] | select(.status == "in_progress" or .status == "queued")] | length)
      ),
      failures: (
        ([$checks[0][] | select(.conclusion as $c | ["failure","timed_out","cancelled","action_required"] | index($c))
          | {key: ("cr:" + .name + ":" + .conclusion), url: (.html_url // ""), label: ("check-run \(.name): \(.conclusion)")}]
        + [$status[0].statuses[]? | select(.state == "failure" or .state == "error")
          | {key: ("st:" + .context + ":" + .state), url: (.target_url // ""), label: ("status \(.context): \(.state)")}]
        + [$runs[0][] | select(.conclusion as $c | ["failure","timed_out","cancelled","startup_failure"] | index($c))
          | {key: ("wf:" + .name + ":" + .conclusion), url: (.html_url // ""), label: ("workflow \(.name): \(.conclusion)")}])
        | unique_by(.key)
      ),
      comments: (
        ([$ic[0][] | {key: ("ic:" + (.id | tostring)), login: (.user.login // "unknown"), url: (.html_url // ""),
                      hash: bodyhash, snippet: snip,
                      progress: ((.body // "") | contains($marker))}]
        + [$rc[0][] | {key: ("rc:" + (.id | tostring)), login: (.user.login // "unknown"), url: (.html_url // ""),
                       hash: bodyhash, snippet: snip, progress: false}]
        + [$rv[0][] | select(.state != "PENDING")
                    | select(((.state == "APPROVED") and ((.body // "") == "")) | not)
                    | {key: ("rv:" + (.id | tostring)), login: (.user.login // "unknown"), url: (.html_url // ""),
                       hash: bodyhash, snippet: ("review \(.state): " + snip), progress: false}])
      )
    }' >"$TMP/cur.json"
}

# --- baseline shape stored on disk: {sha, dirty, failures: [keys], comments: {key: hash}}
to_baseline() {
  jq '{sha, dirty, failures: [.failures[].key], comments: (.comments | map({(.key): .hash}) | add // {})}' "$1"
}

# --- diff cur (snapshot shape) against base (baseline shape); emits a JSON diff object
compute_diff() {
  local cur="$1" base="$2"
  jq -n --slurpfile cur "$cur" --slurpfile base "$base" \
    --arg self "$SELF_LOGIN" --arg nofilter "$NO_SELF_FILTER" '
    def eligible: select((.progress | not) and (($nofilter == "1") or (.login != $self)));
    ($cur[0]) as $c | ($base[0]) as $b |
    {
      new_failures: [$c.failures[] | select(.key as $k | $b.failures | index($k) | not)],
      new_comments: [$c.comments[] | eligible | select($b.comments[.key] == null)],
      changed_comments: [$c.comments[] | eligible | select(($b.comments[.key] != null) and ($b.comments[.key] != .hash))],
      conflict: ($c.dirty and ($b.dirty | not)),
      pending: $c.pending
    }'
}

diff_has_triggers() {
  jq -e '(.new_failures | length) + (.new_comments | length) + (.changed_comments | length) + (if .conflict then 1 else 0 end) > 0' \
    "$1" >/dev/null
}

# --- render the wake burst from a diff object
render_burst() {
  local diff="$1"
  jq -r --arg repo "$REPO" --arg pr "$PR" '
    ((.new_failures | length) + (.new_comments | length) + (.changed_comments | length) + (if .conflict then 1 else 0 end)) as $n |
    ["WAKE_ACTION \($repo)#\($pr): \($n) new item(s) to act on"]
    + (if .conflict then ["CONFLICT merge conflict with base, mergeable_state is dirty; rebase or merge main, then push"] else [] end)
    + [.new_failures[] | "NEW_FAILURE \(.label) \(.url)"]
    + [.new_comments[] | "NEW_COMMENT \(.login) \(.url) :: \(.snippet)"]
    + [.changed_comments[] | "CHANGED_COMMENT \(.login) \(.url) :: \(.snippet)"]
    + (if .pending > 0 then ["PENDING \(.pending) check(s)/run(s) still in progress; consider waiting for them before pushing"] else [] end)
    + ["NEXT address the items above (four-check list in the drive-pr skill), reply or push; the watcher keeps running, do not re-arm"]
    | .[]' "$diff"
}

if [ "$ACTION" = "diff-test" ]; then
  SELF_LOGIN="${PRWATCH_SELF_LOGIN:-nobody}"
  REPO="test/repo" PR="0"
  compute_diff "$DIFF_CUR" "$DIFF_BASE" >"$TMP/diff.json"
  if diff_has_triggers "$TMP/diff.json"; then render_burst "$TMP/diff.json"; else echo "CLEAN no triggers"; fi
  exit 0
fi

SELF_LOGIN=$(gh api user --jq .login 2>/dev/null || echo "")

case "$ACTION" in
  seed)
    rc=0
    i=0
    while [ $i -lt $N_PRS ]; do
      REPO="${R_REPO[$i]}"; PR="${R_PR[$i]}"; STATE_FILE=$(state_file_for "$REPO" "$PR")
      if fetch; then
        mkdir -p "$STATE_DIR"
        to_baseline "$TMP/cur.json" >"$STATE_FILE"
        jq -r --arg repo "$REPO" --arg pr "$PR" \
          '"SEEDED \($repo)#\($pr) sha=\(.sha[0:9]) failures=\(.failures | length) comments=\(.comments | length) dirty=\(.dirty)"' \
          "$STATE_FILE"
      else
        echo "SEED_FAILED could not fetch $REPO#$PR" >&2
        rc=1
      fi
      i=$((i + 1))
    done
    exit $rc
    ;;
  status)
    i=0
    while [ $i -lt $N_PRS ]; do
      REPO="${R_REPO[$i]}"; PR="${R_PR[$i]}"; STATE_FILE=$(state_file_for "$REPO" "$PR")
      if ! fetch; then
        echo "STATUS_FAILED could not fetch $REPO#$PR" >&2
      elif [ "$ALLOW_CLOSED" != "1" ] && ! jq -e '.open' "$TMP/cur.json" >/dev/null; then
        echo "TERMINAL $REPO#$PR is merged or closed; nothing to watch"
      elif [ ! -f "$STATE_FILE" ]; then
        echo "NO_BASELINE $REPO#$PR: run --seed first (or start the watch, which seeds itself)"
      else
        compute_diff "$TMP/cur.json" "$STATE_FILE" >"$TMP/diff.json"
        if diff_has_triggers "$TMP/diff.json"; then render_burst "$TMP/diff.json"; else
          jq -r --arg rp "$REPO#$PR" '"CLEAN \($rp) nothing new (\(.pending) pending)"' "$TMP/diff.json"
        fi
      fi
      i=$((i + 1))
    done
    exit 0
    ;;
esac

# --- watch mode ---------------------------------------------------------------
echo "watching $(active_label) mode=$MODE floor=${FLOOR}s poll=${POLL}s state_dir=$STATE_DIR" >&2
keepwarm_used=0
last_emit=$(date +%s)
cycle=0

while :; do
  cycle=$((cycle + 1))

  # gentle on the shared REST budget: back off when it runs low
  if [ $((cycle % 5)) -eq 1 ]; then
    rem=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || echo "")
    if [ -n "$rem" ] && [ "$rem" -lt 300 ] 2>/dev/null; then
      echo "core budget low ($rem), backing off one extra poll" >&2
      sleep "$POLL"
    fi
  fi

  now=$(date +%s)
  gap=$((now - last_emit))
  can_emit=0
  [ "$gap" -ge "$FLOOR" ] && can_emit=1
  emitted=0
  held=0
  actives=0

  i=0
  while [ $i -lt $N_PRS ]; do
    if [ "${R_ACTIVE[$i]}" != "1" ]; then i=$((i + 1)); continue; fi
    actives=$((actives + 1))
    REPO="${R_REPO[$i]}"; PR="${R_PR[$i]}"; STATE_FILE=$(state_file_for "$REPO" "$PR")

    if ! fetch; then
      R_ERRS[$i]=$((${R_ERRS[$i]} + 1))
      echo "fetch failed for $REPO#$PR (${R_ERRS[$i]}/$ERR_THRESHOLD): $(tail -1 "$TMP/err.log" 2>/dev/null)" >&2
      if [ "${R_ERRS[$i]}" -ge "$ERR_THRESHOLD" ]; then
        echo "WAKE_ERROR gh failed ${R_ERRS[$i]} consecutive polls on $REPO#$PR; dropping it from the watch. Check gh auth status and gh api rate_limit, then re-arm for it"
        R_ACTIVE[$i]=0; actives=$((actives - 1)); emitted=1
      fi
      i=$((i + 1)); continue
    fi
    R_ERRS[$i]=0

    if [ "$ALLOW_CLOSED" != "1" ] && ! jq -e '.open' "$TMP/cur.json" >/dev/null; then
      echo "TERMINAL $REPO#$PR is merged or closed; dropping it from the watch"
      R_ACTIVE[$i]=0; actives=$((actives - 1)); emitted=1
      i=$((i + 1)); continue
    fi

    if [ ! -f "$STATE_FILE" ]; then
      mkdir -p "$STATE_DIR"
      to_baseline "$TMP/cur.json" >"$STATE_FILE"
      jq -r --arg rp "$REPO#$PR" \
        '"seeded baseline for \($rp): failures=\(.failures | length) comments=\(.comments | length) sha=\(.sha[0:9])"' \
        "$STATE_FILE" >&2
      i=$((i + 1)); continue
    fi

    compute_diff "$TMP/cur.json" "$STATE_FILE" >"$TMP/diff.json"
    if diff_has_triggers "$TMP/diff.json"; then
      if [ "$can_emit" = "1" ]; then
        render_burst "$TMP/diff.json"
        to_baseline "$TMP/cur.json" >"$STATE_FILE"
        emitted=1
      else
        held=1
      fi
    fi
    i=$((i + 1))
  done

  if [ "$emitted" = "1" ]; then
    last_emit=$now
    keepwarm_used=0
  elif [ "$can_emit" = "1" ] && [ "$held" = "0" ] && [ "$actives" -gt 0 ]; then
    if [ "$MODE" = "5m" ]; then
      if [ "$keepwarm_used" -lt "$MAX_KEEPWARM" ]; then
        keepwarm_used=$((keepwarm_used + 1))
        echo "KEEPWARM $keepwarm_used/$MAX_KEEPWARM nothing new on $(active_label); this wake only renews your 5m cache, reply one short line and stop"
        last_emit=$now
      else
        echo "STANDDOWN $(active_label) idle through $MAX_KEEPWARM cache renewals (~$(((MAX_KEEPWARM + 1) * FLOOR / 60))min); watcher exiting, do not re-arm, the user picks this up later"
        exit 0
      fi
    else
      if [ "$gap" -ge "$IDLE_LIMIT" ]; then
        echo "STANDDOWN $(active_label) idle for $((gap / 60))min; watcher exiting, do not re-arm, the user picks this up later"
        exit 0
      fi
    fi
  fi

  if [ "$actives" -eq 0 ]; then
    echo "ALL_DONE nothing left to watch; exiting"
    exit 0
  fi

  sleep "$POLL"
done
