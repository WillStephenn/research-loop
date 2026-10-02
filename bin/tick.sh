#!/usr/bin/env bash
#
# tick.sh - the heartbeat: run one orchestrator tick if one is due.
#
# Call it every few minutes from cron, launchd, a systemd timer or a
# `while sleep 300` loop (see examples/). Most calls exit within milliseconds: a
# tick only runs once the clock has passed the due time the previous tick chose
# for itself with bin/schedule_next.sh. The schedule is data, not
# configuration, so changing the cadence needs no crontab edit and no reload.
#
# What a call does, in order:
#   1. due check   exit 0 unless the due time has passed. No due time, or an
#                  unreadable one, runs a tick, so a bad state file costs one
#                  extra tick and never stalls the loop
#   2. lock        an atomic mkdir lock holding the pid. A second call while a
#                  tick is live exits 0 and says so. A lock whose holder is gone
#                  is reaped, and leaves a breadcrumb, because its tick died
#   3. run         AGENT_CMD from config (or $RL_AGENT_CMD), under bash, from the
#                  repo root, stdin closed, output captured to
#                  state/last-tick-stdout.log. RL_SESSION_ID, a fresh UUID, is
#                  exported to it. If the command prints a session id it is
#                  recorded; so is RL_SESSION_ID when the command uses it
#   4. classify    exit 0 is a clean tick: any old breadcrumb is archived.
#                  Anything else is a death, and a breadcrumb is written to
#                  state/tick-aborted naming the exit status, the reason
#                  (usage_limit, killed or error) and the session id. The next
#                  tick reads it (`bin/tick.sh --breadcrumb`) and reconciles
#   5. reschedule  consume the agent's wake request, clamped against the clock
#                  now. A tick that died does not get to choose: it gets
#                  SCHEDULE_DEFAULT_MINUTES. A tick that wrote no request gets
#                  the same, so forgetting to call schedule_next.sh is safe
#
# A usage-limit death is the one worth resuming rather than restarting: the
# conversation is healthy and its own context beats any summary of its output.
# If AGENT_RESUME_CMD is set and the breadcrumb names a session, the next tick
# runs that instead, with RL_RESUME_SESSION and RL_ASLEEP_MINUTES exported.
# Every other death restarts fresh, because the dead conversation may itself be
# the problem.
#
# A due time further out than the one a tick would install is a park, set by a
# human writing an epoch straight into state/next-wake (the one way past the
# ceiling). It outranks the default, the request and the ceiling, so a tick can
# never pull a wake earlier than a human set. It fails open: an unreadable or
# past-dated park changes nothing.
#
# There is deliberately no deadline on a tick. Stages legitimately run for
# hours, and no fixed budget can tell a long tick from a dead one. A hung agent
# holds the lock and later calls say "still running"; kill it by hand if it is
# wedged, and the next call reaps the lock and leaves a breadcrumb.
#
# tick.sh never writes the journal. The next tick does, from the breadcrumb.
#
# Exit codes:  0 = nothing to do (not due, or a tick is already running), or a
#                  tick ran and the agent exited 0, or --breadcrumb found one
#              1 = a tick ran and the agent died (a breadcrumb was written), or
#                  --breadcrumb found none
#              2 = usage error, or no AGENT_CMD to run
#
# Usage:
#   bin/tick.sh                  run a tick if one is due
#   bin/tick.sh --force          run one now, whatever the due time says
#   bin/tick.sh --dry-run        print what would run, change nothing
#   bin/tick.sh --verbose        say so when a call is skipped as not due
#   bin/tick.sh --breadcrumb     print the dead-tick breadcrumb, if there is one
#
# Environment:
#   RL_STATE      state directory (default: state/ at the repo root, gitignored).
#                 schedule_next.sh reads the same variable
#   RL_CONFIG     path to loop.conf (default: config/loop.conf at the repo root)
#   RL_AGENT_CMD  overrides AGENT_CMD from the config, which is how the tests
#                 run a fake agent
#
# State files, all under $RL_STATE:
#   next-wake              epoch seconds, the due time the first check reads
#   next-wake-request      the agent's request, consumed by the tick that made it
#   tick-aborted           the breadcrumb. Absent means the last tick ended cleanly
#   last-tick-stdout.log   the last tick's output
#   aborted-archive/       resolved breadcrumbs
#   tick.lock/             the lock (pid, started, session_id)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

STATE_DIR="${RL_STATE:-$REPO_ROOT/state}"
NEXT_WAKE="$STATE_DIR/next-wake"
REQUEST="$STATE_DIR/next-wake-request"
CAPTURE="$STATE_DIR/last-tick-stdout.log"
ABORTED="$STATE_DIR/tick-aborted"
ARCHIVE="$STATE_DIR/aborted-archive"
LOCK="$STATE_DIR/tick.lock"

# Prints the file's leading comment block. Derived rather than a line range:
# a fixed `sed -n` range silently truncates the help text every time a flag is
# documented above the cut, and this file's header IS its documentation. Keep
# this one line byte-identical across the helpers if you add more of them.
usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit "${1:-0}"
}

stamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
is_epoch() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

force=0; dry=0; verbose=0; crumb=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)       force=1; shift ;;
        --dry-run)     dry=1; shift ;;
        --verbose)     verbose=1; shift ;;
        --breadcrumb)  crumb=1; shift ;;
        -h|--help)     usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done

if [[ "$crumb" -eq 1 ]]; then
    if [[ -f "$ABORTED" ]]; then cat "$ABORTED"; exit 0; fi
    echo "no breadcrumb: the last tick ended cleanly"
    exit 1
fi

# --- the due-time check ---------------------------------------------------
# Before the config, the lock and anything else, so a skipped call is one file
# read and an exit.
now=$(date +%s)
due=""
if [[ -f "$NEXT_WAKE" ]]; then
    candidate=$(head -1 "$NEXT_WAKE" 2>/dev/null)
    is_epoch "$candidate" && due="$candidate"
fi
if [[ "$force" -ne 1 && -n "$due" && "$now" -lt "$due" ]]; then
    [[ "$verbose" -eq 1 ]] && echo "[$(stamp)] SKIP: not due for $(( (due - now) / 60 ))m"
    exit 0
fi

# --- config, with a built-in default for every key -------------------------
CONF="${RL_CONFIG:-$REPO_ROOT/config/loop.conf}"
# shellcheck source=config/loop.conf
[[ -r "$CONF" ]] && . "$CONF"

num_or() { is_epoch "${1:-}" && echo "$1" || echo "$2"; }
MIN_MIN=$(num_or "${SCHEDULE_MIN_MINUTES:-}" 15)
MAX_MIN=$(num_or "${SCHEDULE_MAX_MINUTES:-}" 960)
DEF_MIN=$(num_or "${SCHEDULE_DEFAULT_MINUTES:-}" 60)
(( MIN_MIN <= MAX_MIN )) || { MIN_MIN=15; MAX_MIN=960; }
AGENT="${RL_AGENT_CMD:-${AGENT_CMD:-}}"
RESUME_AGENT="${AGENT_RESUME_CMD:-}"
LIMIT_RE="${USAGE_LIMIT_PATTERN:-}"
LATE_SLACK=2700    # 45 minutes of slip before a late wake is reported

# fmt EPOCH : UTC ISO8601. Python rather than `date`, because the flags for
# formatting an epoch differ between GNU and BSD date.
fmt() { python3 -c 'import sys,time;print(time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime(int(sys.argv[1]))))' "$1"; }
iso_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
new_uuid() { python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null || uuidgen 2>/dev/null | tr 'A-Z' 'a-z'; }
UUID_RE='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

if [[ -z "$AGENT" ]]; then
    echo "[$(stamp)] no AGENT_CMD: set it in $CONF, or export RL_AGENT_CMD" >&2
    exit 2
fi

# A breadcrumb is read as plain key=value lines.
crumb_get() { sed -n "s/^$1=//p" "$ABORTED" 2>/dev/null | head -1; }

# Written whole then moved, so a successor can never read a half-written one.
# write_breadcrumb REASON EXIT_STATUS STARTED_ISO SESSION_ID
write_breadcrumb() {
    mkdir -p "$STATE_DIR"
    local tmp="$ABORTED.partial.$$"
    {
        echo "aborted_at=$(iso_now)"
        echo "tick_started_at=$3"
        echo "exit_status=$2"
        echo "reason=$1"
        echo "session_id=$4"
        echo "capture=$CAPTURE"
        echo "capture_bytes=$(wc -c < "$CAPTURE" 2>/dev/null | tr -d ' ')"
    } > "$tmp" && mv "$tmp" "$ABORTED"
}

# Decide now whether this tick resumes a paused session, so --dry-run can say.
resume_sid=""; asleep_min=""
if [[ -f "$ABORTED" && -n "$RESUME_AGENT" && "$(crumb_get reason)" == "usage_limit" ]]; then
    prev_sid="$(crumb_get session_id)"
    if [[ "$prev_sid" =~ ^$UUID_RE$ ]]; then
        resume_sid="$prev_sid"
        asleep_min=$(python3 - "$(crumb_get aborted_at)" <<'PY'
import sys, time, calendar
try:
    t = calendar.timegm(time.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ"))
    print(max(0, int((time.time() - t) // 60)))
except Exception:
    print("")
PY
)
    fi
fi

if [[ "$dry" -eq 1 ]]; then
    if [[ -n "$resume_sid" ]]; then
        echo "[$(stamp)] DRY RUN: would resume session $resume_sid with: $RESUME_AGENT"
    else
        echo "[$(stamp)] DRY RUN: would run: $AGENT"
    fi
    echo "[$(stamp)]          cwd=$REPO_ROOT state=$STATE_DIR"
    if [[ -n "$due" ]]; then due_txt="$(fmt "$due")"; else due_txt="(unset)"; fi
    echo "[$(stamp)]          due: $due_txt; breadcrumb: $([[ -f "$ABORTED" ]] && echo yes || echo no)"
    exit 0
fi

mkdir -p "$STATE_DIR" || { echo "[$(stamp)] FATAL: cannot create $STATE_DIR" >&2; exit 2; }

# --- the lock -------------------------------------------------------------
# Reap a lock left by a tick that died outright (a shutdown, a kill -9 of this
# script), so one bad tick cannot stall the loop. Staleness is decided by the
# holder's liveness, never by age: ticks have no deadline, so a lock held for
# ten hours by a live process is a long tick, not a stale one. The command check
# guards against pid reuse. A lock with no pid yet is given a minute, which
# covers the gap between mkdir and the pid write.
if [[ -d "$LOCK" ]]; then
    holder=$(head -1 "$LOCK/pid" 2>/dev/null)
    stale=0
    if is_epoch "$holder"; then
        if kill -0 "$holder" 2>/dev/null && ps -p "$holder" -o command= 2>/dev/null | grep -q 'tick\.sh'; then
            stale=0
        else
            stale=1
        fi
    elif [[ -n "$(find "$LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
        stale=1
    fi
    if [[ "$stale" -eq 1 ]]; then
        echo "[$(stamp)] WARN: reaping stale lock (holder ${holder:-unrecorded} is gone)"
        # Its tick died with its wrapper, so nothing classified the death.
        # Leave the breadcrumb it could not, unless an earlier one is waiting.
        if [[ ! -f "$ABORTED" ]]; then
            lost_start="$(head -1 "$LOCK/started" 2>/dev/null)"
            write_breadcrumb lost "" "${lost_start:-unknown}" "$(head -1 "$LOCK/session_id" 2>/dev/null)"
        fi
        rm -rf "$LOCK"
    fi
fi

# mkdir is atomic: if a tick is still running, skip this call rather than run
# two orchestrators against the same journal.
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "[$(stamp)] SKIP: previous tick still running"
    exit 0
fi
echo "$$" > "$LOCK/pid"
tick_start_iso="$(iso_now)"
echo "$tick_start_iso" > "$LOCK/started"
# The EXIT trap removes the lock. INT and TERM exit explicitly, because a trap
# that returns would let the script carry on running after being told to stop.
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A request written before this tick began has already done its job: it
# installed the due time that fired this tick. Left in place it would pin the
# cadence of a tick that asks for nothing.
rm -f "$REQUEST"

if [[ -n "$due" ]]; then
    slip=$(( now - due ))
    if [[ "$slip" -gt "$LATE_SLACK" ]]; then
        echo "[$(stamp)] LATE: woke $(( slip / 3600 ))h$(( (slip % 3600) / 60 ))m past the requested time"
    fi
fi

# --- run the agent --------------------------------------------------------
echo "[$(stamp)] START tick"
started_at=$(date +%s)

if [[ -n "$resume_sid" ]]; then
    sid="$resume_sid"
    cmd="$RESUME_AGENT"
    export RL_RESUME_SESSION="$resume_sid" RL_ASLEEP_MINUTES="${asleep_min:-unknown}"
    echo "[$(stamp)] RECOVERY: usage-limit death, resuming session $resume_sid (asleep ${asleep_min:-?}m)"
else
    sid="$(new_uuid)"
    cmd="$AGENT"
fi
export RL_SESSION_ID="$sid" RL_STATE="$STATE_DIR"
echo "$sid" > "$LOCK/session_id"

( cd "$REPO_ROOT" && bash -c "$cmd" ) < /dev/null > "$CAPTURE" 2>&1
status=$?

# The session id worth recording: one the command printed (a JSON result
# carries it), else the pinned one if the command used it. Otherwise none, and
# the breadcrumb says nothing rather than something that cannot be resumed.
printed=$(grep -oiE "session[_ -]?id\"?[[:space:]]*[:=][[:space:]]*\"?$UUID_RE" "$CAPTURE" 2>/dev/null \
          | tail -1 | grep -oiE "$UUID_RE" | tr 'A-Z' 'a-z')
if [[ -n "$printed" ]]; then sid="$printed"
elif [[ "$cmd" != *RL_SESSION_ID* && -z "$resume_sid" ]]; then sid=""
fi

# Recorded whatever the exit status: this answers "when did a tick last run",
# not "when did one last succeed".
date +%s > "$STATE_DIR/last-tick"

reason=""
if [[ "$status" -ne 0 ]]; then
    if [[ "$status" -eq 143 || "$status" -eq 137 ]]; then
        reason="killed"
    elif [[ -n "$LIMIT_RE" ]] && grep -qiE "$LIMIT_RE" "$CAPTURE" 2>/dev/null; then
        reason="usage_limit"
    else
        reason="error"
    fi
    write_breadcrumb "$reason" "$status" "$tick_start_iso" "$sid"
    echo "[$(stamp)] ABORTED: reason=$reason exit=$status"
    tail -n 15 "$CAPTURE" 2>/dev/null | sed 's/^/    | /'
elif [[ -f "$ABORTED" ]]; then
    # A tick that ran to completion has, by definition, reconciled what it
    # found. Retire the breadcrumb here rather than trusting the agent to
    # delete it, so a skipped reconciliation costs one redundant look and
    # not an unbounded loop.
    mkdir -p "$ARCHIVE"
    ts=$(date -u '+%Y%m%dT%H%M%SZ')
    mv "$ABORTED" "$ARCHIVE/$ts.crumb" 2>/dev/null
    echo "[$(stamp)] RECOVERY: breadcrumb resolved and archived as $ts"
fi

# --- install the next wake ------------------------------------------------
# The tick may have run for an hour since schedule_next.sh wrote its request,
# so the bounds are applied again against the clock now. A request that has
# since fallen into the past would otherwise fire again on the next call.
finished=$(date +%s)
requested=""; next_reason=""
if [[ -f "$REQUEST" ]]; then
    requested=$(sed -n 's/^next_wake_epoch=//p' "$REQUEST" | head -1)
    next_reason=$(sed -n 's/^reason=//p' "$REQUEST" | head -1)
    rm -f "$REQUEST"
fi
written_req="$requested"
if [[ "$status" -ne 0 ]]; then
    [[ -n "$requested" ]] && echo "[$(stamp)] NOTE: discarding the wake request of a tick that exited $status"
    requested=""
    next_reason="tick exited $status, falling back to the default"
fi

if is_epoch "$requested"; then
    next=$requested
else
    next=$(( finished + DEF_MIN * 60 ))
    [[ -n "$next_reason" ]] || next_reason="no request written, using the ${DEF_MIN}m default"
fi
floor=$(( finished + MIN_MIN * 60 )); ceil=$(( finished + MAX_MIN * 60 ))
if [[ "$next" -lt "$floor" ]]; then
    next=$floor; next_reason="clamped to the ${MIN_MIN}m floor: ${next_reason}"
elif [[ "$next" -gt "$ceil" ]]; then
    next=$ceil; next_reason="clamped to the ${MAX_MIN}m ceiling: ${next_reason}"
fi

# A park: a due time still in the future that schedule_next.sh did not write
# (it would match the request just consumed, even one just discarded) and that is later than what we
# are about to install. A human put it there. Preserve it.
parked=$(head -1 "$NEXT_WAKE" 2>/dev/null)
if is_epoch "$parked" && [[ "$parked" != "$written_req" && "$parked" -gt "$finished" && "$parked" -gt "$next" ]]; then
    echo "[$(stamp)] PAUSE: due time already set to $(fmt "$parked") (in $(( (parked - finished) / 60 ))m); a park outranks '${next_reason}'"
    next=$parked; next_reason="park preserved"
fi

echo "$next" > "$NEXT_WAKE.partial.$$" && mv "$NEXT_WAKE.partial.$$" "$NEXT_WAKE"
echo "[$(stamp)] NEXT: $(fmt "$next") (in $(( (next - finished) / 60 ))m), ${next_reason}"
elapsed=$(( $(date +%s) - started_at ))
echo "[$(stamp)] END tick (exit $status, ${elapsed}s)"
[[ "$status" -eq 0 ]] && exit 0
exit 1
