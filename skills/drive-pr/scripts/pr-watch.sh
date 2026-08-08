#!/usr/bin/env bash
# pr-watch.sh: event-gated PR watcher for the drive-pr loop.
#
# Runs under a persistent Claude Code Monitor. Stdout is the event stream:
# every line printed here wakes the driving agent, so the watch loop prints
# nothing while there is nothing to act on. Diagnostics go to stderr.
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
#   pr-watch.sh --repo OWNER/REPO --pr N --1h-cache      watch, main session
#   pr-watch.sh --repo OWNER/REPO --pr N --5min-cache    watch, subagent
#   pr-watch.sh --repo OWNER/REPO --pr N --seed          capture baseline, exit
#   pr-watch.sh --repo OWNER/REPO --pr N --status        one diff, no writes
#   pr-watch.sh --diff-test cur.json base.json           render diff of fixtures
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
REPO="" PR="" MODE="" ACTION="watch" ALLOW_CLOSED=0
DIFF_CUR="" DIFF_BASE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR="$2"; shift 2 ;;
    --1h-cache) MODE="1h"; shift ;;
    --5min-cache) MODE="5m"; shift ;;
    --seed) ACTION="seed"; shift ;;
    --status) ACTION="status"; shift ;;
    --allow-closed) ALLOW_CLOSED=1; shift ;;
    --diff-test) ACTION="diff-test"; DIFF_CUR="$2"; DIFF_BASE="$3"; shift 3 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "gh is required" >&2; exit 2; }

if [ "$ACTION" != "diff-test" ]; then
  [ -n "$REPO" ] && [ -n "$PR" ] || { echo "--repo OWNER/REPO and --pr N are required" >&2; exit 2; }
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

STATE_FILE="$STATE_DIR/$(printf '%s' "$REPO" | tr '/' '_')__${PR}.json"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

IN_PROGRESS_MARKER="auto-generated comment: review in progress"

# --- fetch: one full REST snapshot into $TMP/cur.json. Returns 1 on any hard failure.
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
    def snip: (.body // "") | gsub("[\r\n\t]+"; " ") | .[0:240];
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
  REPO="${REPO:-test/repo}" PR="${PR:-0}"
  compute_diff "$DIFF_CUR" "$DIFF_BASE" >"$TMP/diff.json"
  if diff_has_triggers "$TMP/diff.json"; then render_burst "$TMP/diff.json"; else echo "CLEAN no triggers"; fi
  exit 0
fi

SELF_LOGIN=$(gh api user --jq .login 2>/dev/null || echo "")

case "$ACTION" in
  seed)
    fetch || { echo "SEED_FAILED could not fetch $REPO#$PR" >&2; exit 1; }
    mkdir -p "$STATE_DIR"
    to_baseline "$TMP/cur.json" >"$STATE_FILE"
    jq -r --arg repo "$REPO" --arg pr "$PR" \
      '"SEEDED \($repo)#\($pr) sha=\(.sha[0:9]) failures=\(.failures | length) comments=\(.comments | length) dirty=\(.dirty)"' \
      "$STATE_FILE"
    exit 0
    ;;
  status)
    fetch || { echo "STATUS_FAILED could not fetch $REPO#$PR" >&2; exit 1; }
    if [ "$ALLOW_CLOSED" != "1" ] && ! jq -e '.open' "$TMP/cur.json" >/dev/null; then
      echo "TERMINAL $REPO#$PR is merged or closed; nothing to watch"
      exit 0
    fi
    if [ ! -f "$STATE_FILE" ]; then
      echo "NO_BASELINE run --seed first (or start the watch, which seeds itself)"
      exit 0
    fi
    compute_diff "$TMP/cur.json" "$STATE_FILE" >"$TMP/diff.json"
    if diff_has_triggers "$TMP/diff.json"; then render_burst "$TMP/diff.json"; else
      jq -r '"CLEAN nothing new (\(.pending) pending)"' "$TMP/diff.json"
    fi
    exit 0
    ;;
esac

# --- watch mode ---------------------------------------------------------------
echo "watching $REPO#$PR mode=$MODE floor=${FLOOR}s poll=${POLL}s state=$STATE_FILE" >&2
errs=0
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

  if ! fetch; then
    errs=$((errs + 1))
    echo "fetch failed ($errs/$ERR_THRESHOLD): $(tail -1 "$TMP/err.log" 2>/dev/null)" >&2
    if [ "$errs" -ge "$ERR_THRESHOLD" ]; then
      echo "WAKE_ERROR gh failed $errs consecutive polls on $REPO#$PR; check gh auth status and gh api rate_limit, then re-arm"
      exit 1
    fi
    sleep "$POLL"
    continue
  fi
  errs=0

  if [ "$ALLOW_CLOSED" != "1" ] && ! jq -e '.open' "$TMP/cur.json" >/dev/null; then
    echo "TERMINAL $REPO#$PR is merged or closed; watcher exiting"
    exit 0
  fi

  if [ ! -f "$STATE_FILE" ]; then
    mkdir -p "$STATE_DIR"
    to_baseline "$TMP/cur.json" >"$STATE_FILE"
    jq -r '"seeded baseline: failures=\(.failures | length) comments=\(.comments | length) sha=\(.sha[0:9])"' \
      "$STATE_FILE" >&2
    sleep "$POLL"
    continue
  fi

  compute_diff "$TMP/cur.json" "$STATE_FILE" >"$TMP/diff.json"
  now=$(date +%s)
  gap=$((now - last_emit))

  if diff_has_triggers "$TMP/diff.json"; then
    if [ "$gap" -ge "$FLOOR" ]; then
      render_burst "$TMP/diff.json"
      to_baseline "$TMP/cur.json" >"$STATE_FILE"
      last_emit=$now
      keepwarm_used=0
    fi
    # below the floor: hold, changes accumulate into one burst
  else
    if [ "$gap" -ge "$FLOOR" ]; then
      if [ "$MODE" = "5m" ]; then
        if [ "$keepwarm_used" -lt "$MAX_KEEPWARM" ]; then
          keepwarm_used=$((keepwarm_used + 1))
          echo "KEEPWARM $keepwarm_used/$MAX_KEEPWARM nothing new on $REPO#$PR; this wake only renews your 5m cache, reply one short line and stop"
          last_emit=$now
        else
          echo "STANDDOWN $REPO#$PR idle through $MAX_KEEPWARM cache renewals (~$(( (MAX_KEEPWARM + 1) * FLOOR / 60 ))min); watcher exiting, do not re-arm, the user picks this up later"
          exit 0
        fi
      else
        if [ "$gap" -ge "$IDLE_LIMIT" ]; then
          echo "STANDDOWN $REPO#$PR idle for $((gap / 60))min; watcher exiting, do not re-arm, the user picks this up later"
          exit 0
        fi
      fi
    fi
  fi

  sleep "$POLL"
done
