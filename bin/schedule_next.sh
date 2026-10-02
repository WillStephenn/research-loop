#!/usr/bin/env bash
#
# schedule_next.sh - ask for the time of the next orchestrator wake-up.
#
# bin/tick.sh is called every few minutes by cron, launchd or a loop, but it
# only runs the agent once the clock has passed a due time held in a state
# file. This script is how an orchestrator sets that due time for its
# successor. It writes two things: the due time itself, which takes effect at
# once, and a request alongside it, which tick.sh consumes, re-clamps against
# the clock at the end of the tick and re-installs. A schedule therefore always
# replaces the previous one the moment it is written, including when run by
# hand between ticks.
#
# It also appends a `wake_scheduled` event to the journal with the time and the
# reason, so the successor can see why it woke when it did and judge whether
# the estimate held. That is how the scheduling gets better, not just
# autonomous.
#
# Writing a request is optional. If a tick writes none, tick.sh falls back to
# SCHEDULE_DEFAULT_MINUTES, so forgetting to call this is safe: it never stalls
# the loop.
#
# Bounds come from config/loop.conf (or $RL_CONFIG) and are applied twice: here,
# against the wall clock at request time, and again by tick.sh against the
# clock when the tick ends. A tick can run for an hour after calling this,
# which would otherwise leave a due time already in the past and re-fire at
# once. So a tick's schedule can still shift after this script reports it.
#
#   floor     SCHEDULE_MIN_MINUTES, default 15
#   ceiling   SCHEDULE_MAX_MINUTES, default 960 (16 hours)
#   default   SCHEDULE_DEFAULT_MINUTES, default 60, used when no request is made
#
# A request outside the bounds is clamped, not refused.
#
# Cadence is a judgement about when work can next exist, not a budget to spend
# down. Schedule for the earliest possible work: a wake that finds nothing costs
# a journal line, while a late one costs dead time that compounds.
#
# Exit codes:  0 = schedule installed as asked
#              1 = schedule installed, but clamped to the floor or ceiling
#              2 = usage error
#
# Usage:
#   bin/schedule_next.sh --in-minutes 120 --reason "experiment X finishes in about 2 hours"
#   bin/schedule_next.sh --in-minutes 15 --reason "two probes are ready and need no waiting"
#   bin/schedule_next.sh --in-minutes 60 --reason "..." --no-journal
#   bin/schedule_next.sh --show
#   bin/schedule_next.sh --show --json
#
# Environment:
#   RL_STATE    state directory (default: state/ at the repo root, gitignored).
#               Machine state rather than research history, so it stays out of
#               the journal and out of version control. tick.sh reads the same
#               variable, and the two must agree
#   RL_CONFIG   path to loop.conf (default: config/loop.conf at the repo root)
#   RL_JOURNAL  path to journal.ndjson, as in journal.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
JOURNAL_SH="$HERE/journal.sh"

CONF="${RL_CONFIG:-$REPO_ROOT/config/loop.conf}"
# shellcheck source=config/loop.conf
[[ -r "$CONF" ]] && . "$CONF"

is_count() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

MIN_MINUTES="${SCHEDULE_MIN_MINUTES:-15}"
MAX_MINUTES="${SCHEDULE_MAX_MINUTES:-960}"
is_count "$MIN_MINUTES" || MIN_MINUTES=15
is_count "$MAX_MINUTES" || MAX_MINUTES=960
(( MIN_MINUTES <= MAX_MINUTES )) || { MIN_MINUTES=15; MAX_MINUTES=960; }

STATE_DIR="${RL_STATE:-$REPO_ROOT/state}"
REQUEST="$STATE_DIR/next-wake-request"
NEXT_WAKE="$STATE_DIR/next-wake"

# Prints the file's leading comment block. Derived rather than a line range:
# a fixed `sed -n` range silently truncates the help text every time a flag is
# documented above the cut, and this file's header IS its documentation. Keep
# this one line byte-identical across the helpers if you add more of them.
usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit "${1:-0}"
}

require_python() { command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 2; }; }

# fmt EPOCH iso|hm : UTC ISO8601 or local HH:MM. Python rather than `date`,
# because the flags for formatting an epoch differ between GNU and BSD date.
fmt() {
    python3 -c '
import sys, time
e, kind = int(sys.argv[1]), sys.argv[2]
print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e)) if kind == "iso"
      else time.strftime("%H:%M", time.localtime(e)))' "$1" "$2"
}

cmd_show() {
    local json="$1" now due_epoch="" req_epoch="" req_reason=""

    now="$(date +%s)"
    [[ -f "$NEXT_WAKE" ]] && due_epoch="$(head -1 "$NEXT_WAKE" 2>/dev/null)"
    if [[ -f "$REQUEST" ]]; then
        req_epoch="$(sed -n 's/^next_wake_epoch=//p' "$REQUEST" | head -1)"
        req_reason="$(sed -n 's/^reason=//p' "$REQUEST" | head -1)"
    fi
    is_count "$due_epoch" || due_epoch=""
    is_count "$req_epoch" || req_epoch=""

    if [[ "$json" -eq 1 ]]; then
        SN_NOW="$now" SN_DUE="$due_epoch" SN_REQ="$req_epoch" SN_REASON="$req_reason" \
        python3 -c '
import json, os, time

def num(key):
    v = os.environ.get(key, "")
    return int(v) if v else None

def stamp(v):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(v)) if v else None

now, due, req = num("SN_NOW"), num("SN_DUE"), num("SN_REQ")
print(json.dumps({
    "now": stamp(now),
    "next_wake": stamp(due),
    "minutes_until_next_wake": round((due - now) / 60) if due else None,
    "pending_request": stamp(req),
    "pending_request_reason": os.environ.get("SN_REASON") or None,
}, indent=2))
'
        return 0
    fi

    if [[ -n "$due_epoch" ]]; then
        echo "next wake:       $(fmt "$due_epoch" iso)  (in $(( (due_epoch - now) / 60 )) min)"
    else
        echo "next wake:       (none set - the next heartbeat will run a tick)"
    fi
    if [[ -n "$req_epoch" ]]; then
        echo "pending request: $(fmt "$req_epoch" iso)  ${req_reason:-(no reason given)}"
    else
        echo "pending request: (none)"
    fi
}

minutes=""
reason=""
show=0
json=0
do_journal=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --in-minutes) minutes="${2:-}"; shift 2 ;;
        --reason)     reason="${2:-}"; shift 2 ;;
        --show)       show=1; shift ;;
        --no-journal) do_journal=0; shift ;;
        -j|--json)    json=1; shift ;;
        -h|--help)    usage 0 ;;
        *) echo "unknown argument: $1" >&2; usage 2 ;;
    esac
done

require_python

if [[ "$show" -eq 1 ]]; then
    cmd_show "$json"
    exit 0
fi

if [[ -z "$minutes" ]]; then
    echo "--in-minutes is required (or use --show)" >&2
    usage 2
fi
if ! is_count "$minutes"; then
    echo "--in-minutes must be a whole number of minutes, got '$minutes'" >&2
    exit 2
fi
if [[ -z "$reason" ]]; then
    # Not fatal, but the reason is the whole point: it is what lets the next
    # orchestrator judge whether this one's timing estimate was any good.
    echo "warning: no --reason given; the next orchestrator will not know why it woke when it did" >&2
fi

(( ${#minutes} > 9 )) && minutes=999999999   # more digits than any ceiling; avoids arithmetic overflow
minutes=$(( 10#$minutes ))
clamped=0
clamp_note=""
if (( minutes < MIN_MINUTES )); then
    echo "clamped $minutes min up to the ${MIN_MINUTES} min floor" >&2
    clamp_note=", clamped up from ${minutes}m"
    minutes=$MIN_MINUTES
    clamped=1
elif (( minutes > MAX_MINUTES )); then
    echo "clamped $minutes min down to the ${MAX_MINUTES} min ceiling" >&2
    clamp_note=", clamped down from ${minutes}m"
    minutes=$MAX_MINUTES
    clamped=1
fi

now="$(date +%s)"
target=$(( now + minutes * 60 ))

# Newlines would break tick.sh's line-oriented read of the request.
reason="$(printf '%s' "$reason" | tr '\n\r' '  ')"

mkdir -p "$STATE_DIR" || { echo "cannot create state directory $STATE_DIR" >&2; exit 2; }

# Written whole then moved, so a tick reading it can never see half a request.
tmp="$REQUEST.partial.$$"
cat > "$tmp" <<REQ
next_wake_epoch=$target
requested_minutes=$minutes
written_at=$(fmt "$now" iso)
reason=$reason
REQ
mv "$tmp" "$REQUEST"

# Install the due time as well as requesting it, so that a schedule always
# replaces the previous one at the moment it is written. Without this, calling
# the script by hand looks like it did nothing: the due time tick.sh actually
# reads is $NEXT_WAKE, and only a tick ending used to write that. tick.sh still
# rewrites it when a tick ends, re-clamped against the clock then, and discards
# a dead tick's request in favour of the default, because the judgement of a
# tick that just failed is the thing that is suspect.
echo "$target" > "$NEXT_WAKE.partial.$$" && mv "$NEXT_WAKE.partial.$$" "$NEXT_WAKE"

echo "next wake set for $(fmt "$target" iso) (local $(fmt "$target" hm), in ${minutes} min)"

if [[ "$do_journal" -eq 1 ]]; then
    note="next wake $(fmt "$target" iso), in ${minutes} min${clamp_note}"
    [[ -n "$reason" ]] && note="${note}: ${reason}"
    # Best effort: the due time is already on disk, and a journal problem must
    # never fail a schedule.
    "$JOURNAL_SH" append --event wake_scheduled --note "$note" >/dev/null 2>&1 \
        || echo "warning: could not journal the schedule (the wake time was still recorded)" >&2
fi

exit "$clamped"
