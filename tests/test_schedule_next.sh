#!/usr/bin/env bash
#
# test_schedule_next.sh - behavioural tests for schedule_next.sh, the tool an
# orchestrator calls before it stops to say when its successor should wake.
#
#   ./tests/test_schedule_next.sh
#
# WHAT IS WORTH PINNING, and why these and not others:
#
#   THE TWO FILES    a schedule writes the due time AND a request, and the due
#                    time takes effect at once. A hand-run schedule that sat
#                    inert behind an older due time looked like it did nothing.
#   THE BOUNDS       below the floor and above the ceiling are clamped, not
#                    refused, and the exit code says so (1). Both bounds come
#                    from config, with built-in defaults when a scratch config
#                    leaves them out.
#   THE REASON       it lands in the request and in a wake_scheduled journal
#                    event, because the successor judges its own estimate by it.
#                    A journal that cannot be written must never fail a schedule:
#                    the due time is already on disk.
#   EXIT CODES       0 / 1 / 2 are a documented interface the orchestrator
#                    branches on, so every one of them gets a test.
#
# NO NETWORK, NO REPO WRITES. Every invocation runs against a scratch state
# directory (RL_STATE) and a scratch journal (RL_JOURNAL) under a mktemp dir
# removed on exit. The final assertions check the repo's own state/ and journal
# were never touched.
#
# Exit codes: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
S="$REPO/bin/schedule_next.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/schedule-next-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REAL_STATE_EXISTED=0; [[ -e "$REPO/state" ]] && REAL_STATE_EXISTED=1
REAL_JOURNAL="$REPO/registry/journal.ndjson"
REAL_JOURNAL_MD5="$(md5of "$REAL_JOURNAL" 2>/dev/null || echo absent)"

export RL_STATE="$WORK/state"
export RL_JOURNAL="$WORK/journal.ndjson"
unset RL_CONFIG

reset() { rm -rf "$RL_STATE" "$RL_JOURNAL"; }

# near A B TOLERANCE : are two epochs within TOLERANCE seconds of each other?
near() { local d=$(( $1 - $2 )); (( d < 0 )) && d=$(( -d )); (( d <= $3 )); }

due()      { head -1 "$RL_STATE/next-wake" 2>/dev/null; }
req_get()  { sed -n "s/^$1=//p" "$RL_STATE/next-wake-request" 2>/dev/null | head -1; }

# A scratch config that keeps the shipped one and overrides the bounds.
write_conf() {
    {
        printf '. "%s/config/loop.conf"\n' "$REPO"
        printf '%s\n' "$@"
    } > "$WORK/loop.conf"
}

# ---------------------------------------------------------------------------
echo "== a schedule writes the due time and a request =="
reset
before="$(date +%s)"
out="$("$S" --in-minutes 120 --reason "experiment X finishes in about 2 hours" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "exits 0 for a request inside the bounds"; else bad "exits 0 (got $rc: $out)"; fi
if near "$(due)" $(( before + 7200 )) 5; then ok "the due time is now plus the requested minutes"; else
    bad "the due time is now plus 120 minutes (got $(due), wanted about $(( before + 7200 )))"; fi
if [[ "$(req_get next_wake_epoch)" == "$(due)" ]]; then ok "the request carries the same time"; else
    bad "the request carries the same time"; fi
if [[ "$(req_get requested_minutes)" == "120" ]]; then ok "the request records the minutes"; else
    bad "the request records the minutes"; fi
if [[ "$(req_get reason)" == "experiment X finishes in about 2 hours" ]]; then ok "the request carries the reason"; else
    bad "the request carries the reason"; fi
if [[ "$out" == *"next wake set for"* ]]; then ok "says what it set"; else bad "says what it set"; fi

echo "== a second schedule replaces the first at once =="
"$S" --in-minutes 30 --reason "second" >/dev/null 2>&1
if near "$(due)" $(( $(date +%s) + 1800 )) 5; then ok "the due time moved"; else bad "the due time moved"; fi
if [[ "$(req_get reason)" == "second" ]]; then ok "and so did the request"; else bad "and so did the request"; fi
leftover="$(find "$RL_STATE" -name '*.partial*' | wc -l | tr -d ' ')"
if [[ "$leftover" == "0" ]]; then ok "no half-written temp files are left behind"; else bad "temp files left behind: $leftover"; fi

# ---------------------------------------------------------------------------
echo
echo "== the bounds: clamped, not refused =="
reset
out="$("$S" --in-minutes 1 --reason "too soon" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]]; then ok "below the floor exits 1"; else bad "below the floor exits 1 (got $rc)"; fi
if near "$(due)" $(( $(date +%s) + 900 )) 5; then ok "and is raised to the 15 minute default floor"; else
    bad "and is raised to the 15 minute default floor"; fi
if [[ "$out" == *"clamped 1 min up to the 15 min floor"* ]]; then ok "and says so"; else bad "and says so"; fi
if [[ "$(req_get requested_minutes)" == "15" ]]; then ok "the request holds the clamped value"; else
    bad "the request holds the clamped value"; fi

reset
out="$("$S" --in-minutes 5000 --reason "too late" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]]; then ok "above the ceiling exits 1"; else bad "above the ceiling exits 1 (got $rc)"; fi
if near "$(due)" $(( $(date +%s) + 57600 )) 5; then ok "and is lowered to the 16 hour default ceiling"; else
    bad "and is lowered to the 16 hour default ceiling"; fi

reset
"$S" --in-minutes 99999999999999999999 --reason "absurd" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 1 ]] && near "$(due)" $(( $(date +%s) + 57600 )) 5; then ok "an absurdly long request is clamped, not overflowed"; else
    bad "an absurdly long request is clamped, not overflowed (rc=$rc)"; fi

reset
"$S" --in-minutes 0 --reason "zero" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 1 ]]; then ok "zero minutes is clamped to the floor"; else bad "zero minutes is clamped to the floor (got $rc)"; fi

echo "== the bounds come from config =="
write_conf SCHEDULE_MIN_MINUTES=2 SCHEDULE_MAX_MINUTES=30
reset
RL_CONFIG="$WORK/loop.conf" "$S" --in-minutes 1 --reason r >/dev/null 2>&1; rc=$?
if [[ $rc -eq 1 && "$(req_get requested_minutes)" == "2" ]]; then ok "a configured floor of 2 clamps 1 up to 2"; else
    bad "a configured floor of 2 clamps 1 up to 2 (rc=$rc, got $(req_get requested_minutes))"; fi
RL_CONFIG="$WORK/loop.conf" "$S" --in-minutes 5 --reason r >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 && "$(req_get requested_minutes)" == "5" ]]; then ok "CONTROL: 5 is inside the configured bounds"; else
    bad "CONTROL: 5 is inside the configured bounds (rc=$rc)"; fi
RL_CONFIG="$WORK/loop.conf" "$S" --in-minutes 99 --reason r >/dev/null 2>&1; rc=$?
if [[ $rc -eq 1 && "$(req_get requested_minutes)" == "30" ]]; then ok "a configured ceiling of 30 clamps 99 down to 30"; else
    bad "a configured ceiling of 30 clamps 99 down to 30 (rc=$rc)"; fi

echo "== a config without the keys falls back to the built-in bounds =="
printf 'HYPOTHESIS_FAMILIES=(a)\n' > "$WORK/bare.conf"
reset
RL_CONFIG="$WORK/bare.conf" "$S" --in-minutes 1 --reason r >/dev/null 2>&1; rc=$?
if [[ $rc -eq 1 && "$(req_get requested_minutes)" == "15" ]]; then ok "the floor defaults to 15"; else
    bad "the floor defaults to 15 (rc=$rc, got $(req_get requested_minutes))"; fi
write_conf SCHEDULE_MIN_MINUTES=banana SCHEDULE_MAX_MINUTES=10 SCHEDULE_MIN_MINUTES=50
RL_CONFIG="$WORK/loop.conf" "$S" --in-minutes 20 --reason r >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 && "$(req_get requested_minutes)" == "20" ]]; then ok "an inverted floor and ceiling fall back to the defaults"; else
    bad "an inverted floor and ceiling fall back to the defaults (rc=$rc, got $(req_get requested_minutes))"; fi

# ---------------------------------------------------------------------------
echo
echo "== the journal =="
reset
"$S" --in-minutes 120 --reason "experiment X finishes" >/dev/null 2>&1
line="$(tail -n 1 "$RL_JOURNAL" 2>/dev/null)"
ev="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("event"))' "$line" 2>/dev/null)"
note="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("note"))' "$line" 2>/dev/null)"
if [[ "$ev" == "wake_scheduled" ]]; then ok "journals a wake_scheduled event"; else bad "journals a wake_scheduled event (got '$ev')"; fi
if [[ "$note" == *"in 120 min"* && "$note" == *"experiment X finishes"* ]]; then ok "the note carries the time and the reason"; else
    bad "the note carries the time and the reason (got '$note')"; fi
"$S" --in-minutes 1 --reason "chained" >/dev/null 2>&1
note="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]).get("note"))' "$(tail -n 1 "$RL_JOURNAL")")"
if [[ "$note" == *"clamped up from 1m"* ]]; then ok "a clamp is recorded in the note"; else bad "a clamp is recorded in the note (got '$note')"; fi

reset
"$S" --in-minutes 60 --reason r --no-journal >/dev/null 2>&1
if [[ ! -e "$RL_JOURNAL" ]]; then ok "--no-journal writes no journal line"; else bad "--no-journal writes no journal line"; fi
if [[ -n "$(due)" ]]; then ok "and still sets the due time"; else bad "and still sets the due time"; fi

reset
out="$(RL_JOURNAL=/dev/null/nowhere/j.ndjson "$S" --in-minutes 60 --reason r 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "an unwritable journal does not fail the schedule"; else bad "an unwritable journal does not fail the schedule (got $rc)"; fi
if [[ "$out" == *"could not journal"* ]]; then ok "but it warns"; else bad "but it warns (got: $out)"; fi
if [[ -n "$(due)" ]]; then ok "and the due time is on disk"; else bad "and the due time is on disk"; fi

echo "== a newline in the reason cannot break the request =="
reset
"$S" --in-minutes 60 --reason $'line one\nline two' >/dev/null 2>&1
if [[ "$(wc -l < "$RL_STATE/next-wake-request" | tr -d ' ')" == "4" ]]; then ok "the request is still four lines"; else
    bad "the request is still four lines"; fi
if [[ "$(req_get reason)" == "line one line two" ]]; then ok "the newline became a space"; else bad "the newline became a space"; fi

# ---------------------------------------------------------------------------
echo
echo "== usage errors exit 2 =="
reset
out="$("$S" 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "no arguments exits 2"; else bad "no arguments exits 2 (got $rc)"; fi
if [[ "$out" == *"--in-minutes is required"* ]]; then ok "and says what is missing"; else bad "and says what is missing"; fi
out="$("$S" --in-minutes soon --reason r 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "a non-numeric --in-minutes exits 2"; else bad "a non-numeric --in-minutes exits 2 (got $rc)"; fi
"$S" --in-minutes -5 --reason r >/dev/null 2>&1; rc=$?
if [[ $rc -eq 2 ]]; then ok "a negative --in-minutes exits 2"; else bad "a negative --in-minutes exits 2 (got $rc)"; fi
out="$("$S" --frobnicate 2>&1)"; rc=$?
if [[ $rc -eq 2 && "$out" == *"unknown argument: --frobnicate"* ]]; then ok "an unknown flag exits 2 and is named"; else
    bad "an unknown flag exits 2 and is named (rc=$rc)"; fi
if [[ ! -e "$RL_STATE/next-wake" ]]; then ok "a refused request leaves no due time behind"; else bad "a refused request leaves no due time behind"; fi

out="$("$S" --in-minutes 60 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"warning: no --reason"* ]]; then ok "a missing --reason is a warning, not an error"; else
    bad "a missing --reason is a warning, not an error (rc=$rc)"; fi

out="$("$S" --help 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$out" == "schedule_next.sh - "* ]]; then ok "--help prints the header comment and exits 0"; else
    bad "--help prints the header comment and exits 0"; fi

# ---------------------------------------------------------------------------
echo
echo "== --show reports and changes nothing =="
reset
out="$("$S" --show 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"none set"* && "$out" == *"pending request: (none)"* ]]; then ok "with nothing set it says so"; else
    bad "with nothing set it says so (got: $out)"; fi
"$S" --in-minutes 120 --reason "show me" >/dev/null 2>&1
before_md5="$(md5of "$RL_STATE/next-wake")$(md5of "$RL_STATE/next-wake-request")"
out="$("$S" --show 2>&1)"
if [[ "$out" == *"in 119 min"* || "$out" == *"in 120 min"* ]]; then ok "after a schedule it shows the minutes left"; else
    bad "after a schedule it shows the minutes left (got: $out)"; fi
if [[ "$out" == *"show me"* ]]; then ok "and the pending reason"; else bad "and the pending reason"; fi
json="$("$S" --show --json 2>&1)"
keys="$(python3 -c 'import json,sys;print(" ".join(sorted(json.loads(sys.argv[1]))))' "$json" 2>/dev/null)"
if [[ "$keys" == "minutes_until_next_wake next_wake now pending_request pending_request_reason" ]]; then ok "--show --json is parseable with the documented keys"; else
    bad "--show --json is parseable with the documented keys (got: $keys)"; fi
after_md5="$(md5of "$RL_STATE/next-wake")$(md5of "$RL_STATE/next-wake-request")"
if [[ "$before_md5" == "$after_md5" ]]; then ok "--show leaves both files byte-identical"; else bad "--show leaves both files byte-identical"; fi
if [[ "$(wc -l < "$RL_JOURNAL" | tr -d ' ')" == "1" ]]; then ok "and journals nothing"; else bad "and journals nothing"; fi

# ---------------------------------------------------------------------------
# The guard on this whole file: none of the above touched the repo.
# ---------------------------------------------------------------------------
echo
echo "== the repo itself was never written to =="
if [[ $REAL_STATE_EXISTED -eq 0 && ! -e "$REPO/state" ]]; then ok "no state/ directory appeared in the repo"; else
    if [[ $REAL_STATE_EXISTED -eq 1 ]]; then ok "state/ already existed and this run used scratch space"; else
        bad "a state/ directory appeared in the repo"; fi; fi
now_md5="$(md5of "$REAL_JOURNAL" 2>/dev/null || echo absent)"
if [[ "$now_md5" == "$REAL_JOURNAL_MD5" ]]; then ok "registry/journal.ndjson is byte-identical to before the run"; else
    bad "registry/journal.ndjson CHANGED during the test run"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
