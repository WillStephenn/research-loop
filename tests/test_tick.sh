#!/usr/bin/env bash
#
# test_tick.sh - behavioural tests for tick.sh, the heartbeat that runs the
# orchestrator once its self-chosen due time has passed.
#
#   ./tests/test_tick.sh
#
# WHAT IS WORTH PINNING, and why these and not others:
#
#   THE DUE TIME     a call before it exits 0 without running the agent, and a
#                    missing or unreadable one runs a tick. Failing open means a
#                    bad state file costs one extra tick and never stalls the loop.
#   THE LOCK         a live tick makes a second call skip. A lock whose holder is
#                    gone is reaped, and that death leaves a breadcrumb, because
#                    nothing else saw it. A lock held by an unrelated process that
#                    reused the pid is not a live tick.
#   DEATH            a non-zero exit leaves a breadcrumb naming the reason and the
#                    session, a dead tick does not get to choose its successor's
#                    wake, and a clean tick retires the breadcrumb.
#   THE SCHEDULE     a request is consumed once, clamped against the clock when the
#                    tick ends, and a due time a human parked further out survives.
#   RESUME           a usage-limit death resumes its session when asked to, and
#                    every other death restarts fresh.
#
# NO NETWORK, NO REAL AGENT. Every call runs a fake agent through RL_AGENT_CMD
# (a command that records that it ran, or exits however the case needs), against
# a scratch state directory and journal under a mktemp dir removed on exit. The
# final assertion checks the repo's own state/ directory was never created.
#
# Exit codes: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
T="$REPO/bin/tick.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tick-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Exported because the fake agents are single-quoted strings that the agent's own
# shell expands, so they can write into the scratch directory.
export WORK

REAL_STATE_EXISTED=0; [[ -e "$REPO/state" ]] && REAL_STATE_EXISTED=1

export RL_STATE="$WORK/state"
export RL_JOURNAL="$WORK/journal.ndjson"
# A call that forgets to override the agent must not start a real one.
export RL_AGENT_CMD="true"
unset RL_CONFIG

STATE="$RL_STATE"
UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

reset() { rm -rf "$STATE" "$WORK"/marker* "$WORK/seen"* "$WORK/env"*; }

# near A B TOLERANCE : are two epochs within TOLERANCE seconds of each other?
near() { local d=$(( $1 - $2 )); (( d < 0 )) && d=$(( -d )); (( d <= $3 )); }

wake()    { head -1 "$STATE/next-wake" 2>/dev/null; }
crumb()   { sed -n "s/^$1=//p" "$STATE/tick-aborted" 2>/dev/null | head -1; }
set_due() { mkdir -p "$STATE"; echo "$1" > "$STATE/next-wake"; }

# run_tick [args]: sets $out and $rc. The agent is whatever $AGENT says.
AGENT="true"
run_tick() { out="$(RL_AGENT_CMD="$AGENT" "$T" "$@" 2>&1)"; rc=$?; }

# A scratch config that keeps the shipped one and overrides some keys.
write_conf() {
    {
        printf '. "%s/config/loop.conf"\n' "$REPO"
        printf '%s\n' "$@"
    } > "$WORK/loop.conf"
}

# ---------------------------------------------------------------------------
echo "== the due time =="
reset
AGENT="touch $WORK/marker"
set_due $(( $(date +%s) + 3600 ))
run_tick
if [[ $rc -eq 0 && ! -e "$WORK/marker" ]]; then ok "before the due time it exits 0 without running the agent"; else
    bad "before the due time it exits 0 without running the agent (rc=$rc)"; fi
if [[ -z "$out" ]]; then ok "and says nothing, so a cron log stays quiet"; else bad "and says nothing (got: $out)"; fi
run_tick --verbose
if [[ "$out" == *"SKIP: not due"* ]]; then ok "--verbose says so"; else bad "--verbose says so (got: $out)"; fi

reset
run_tick
if [[ $rc -eq 0 && -e "$WORK/marker" ]]; then ok "with no due time at all it runs a tick (fails open)"; else
    bad "with no due time at all it runs a tick (rc=$rc)"; fi

reset
set_due "garbage"
run_tick
if [[ -e "$WORK/marker" ]]; then ok "an unreadable due time runs a tick too"; else bad "an unreadable due time runs a tick too"; fi

reset
set_due $(( $(date +%s) - 60 ))
run_tick
if [[ $rc -eq 0 && -e "$WORK/marker" ]]; then ok "a due time in the past runs a tick"; else bad "a due time in the past runs a tick"; fi

reset
set_due $(( $(date +%s) + 3600 ))
run_tick --force
if [[ -e "$WORK/marker" ]]; then ok "--force runs whatever the due time says"; else bad "--force runs whatever the due time says"; fi

reset
set_due $(( $(date +%s) - 7200 ))
run_tick
if [[ "$out" == *"LATE: woke 2h"* ]]; then ok "a tick two hours late says so"; else bad "a tick two hours late says so (got: $out)"; fi

echo "== --dry-run changes nothing =="
reset
AGENT="touch $WORK/marker"
run_tick --dry-run
if [[ $rc -eq 0 && ! -e "$WORK/marker" ]]; then ok "the agent is not run"; else bad "the agent is not run"; fi
if [[ "$out" == *"DRY RUN: would run: touch $WORK/marker"* ]]; then ok "it prints the command it would run"; else
    bad "it prints the command it would run (got: $out)"; fi
if [[ ! -e "$STATE" ]]; then ok "and creates no state at all"; else bad "and creates no state at all"; fi

# ---------------------------------------------------------------------------
echo
echo "== what the agent is given =="
reset; mkdir -p "$WORK/env"
AGENT='pwd > "$WORK/env/cwd"; echo "$RL_SESSION_ID" > "$WORK/env/sid"; echo "$RL_STATE" > "$WORK/env/state"; read -r x; echo "stdin=$?" > "$WORK/env/stdin"'
run_tick
if [[ "$(cat "$WORK/env/cwd" 2>/dev/null)" == "$REPO" ]]; then ok "it runs from the repo root"; else
    bad "it runs from the repo root (got '$(cat "$WORK/env/cwd" 2>/dev/null)')"; fi
if [[ "$(cat "$WORK/env/sid" 2>/dev/null)" =~ $UUID_RE ]]; then ok "RL_SESSION_ID is a fresh UUID"; else
    bad "RL_SESSION_ID is a fresh UUID (got '$(cat "$WORK/env/sid" 2>/dev/null)')"; fi
if [[ "$(cat "$WORK/env/state" 2>/dev/null)" == "$STATE" ]]; then ok "RL_STATE is exported, so schedule_next.sh agrees"; else
    bad "RL_STATE is exported"; fi
if [[ "$(cat "$WORK/env/stdin" 2>/dev/null)" == "stdin=1" ]]; then ok "stdin is closed, so a prompt cannot hang the tick"; else
    bad "stdin is closed (got '$(cat "$WORK/env/stdin" 2>/dev/null)')"; fi
if [[ -f "$STATE/last-tick-stdout.log" ]]; then ok "its output is captured"; else bad "its output is captured"; fi

# ---------------------------------------------------------------------------
echo
echo "== a clean tick, and the schedule it installs =="
reset
AGENT="true"
before="$(date +%s)"
run_tick
if [[ $rc -eq 0 ]]; then ok "exits 0 when the agent does"; else bad "exits 0 when the agent does (got $rc)"; fi
if near "$(wake)" $(( before + 3600 )) 5; then ok "a tick that asked for nothing gets the 60 minute default"; else
    bad "a tick that asked for nothing gets the 60 minute default (got $(wake))"; fi
if [[ ! -e "$STATE/tick-aborted" && ! -e "$STATE/tick.lock" ]]; then ok "no breadcrumb, and the lock is released"; else
    bad "no breadcrumb, and the lock is released"; fi
if [[ -f "$STATE/last-tick" ]]; then ok "last-tick is recorded"; else bad "last-tick is recorded"; fi
if [[ "$out" == *"START tick"* && "$out" == *"NEXT:"* && "$out" == *"END tick (exit 0"* ]]; then ok "it logs START, NEXT and END"; else
    bad "it logs START, NEXT and END (got: $out)"; fi

reset
AGENT='bin/schedule_next.sh --in-minutes 120 --reason "fake job finishes" >/dev/null'
before="$(date +%s)"
run_tick
if near "$(wake)" $(( before + 7200 )) 5; then ok "the agent's request is honoured"; else
    bad "the agent's request is honoured (got $(wake), wanted about $(( before + 7200 )))"; fi
if [[ ! -e "$STATE/next-wake-request" ]]; then ok "the request is consumed exactly once"; else bad "the request is consumed exactly once"; fi
if [[ "$out" == *"fake job finishes"* ]]; then ok "and the NEXT line gives its reason"; else bad "and the NEXT line gives its reason"; fi

echo "== a request is clamped against the clock when the tick ends =="
reset
AGENT='printf "next_wake_epoch=%s\nreason=stale\n" $(( $(date +%s) - 5000 )) > "$RL_STATE/next-wake-request"'
before="$(date +%s)"
run_tick
if near "$(wake)" $(( before + 900 )) 5; then ok "a request already in the past is raised to the floor"; else
    bad "a request already in the past is raised to the floor (got $(wake))"; fi
reset
AGENT='printf "next_wake_epoch=%s\nreason=far\n" $(( $(date +%s) + 900000 )) > "$RL_STATE/next-wake-request"'
before="$(date +%s)"
run_tick
if near "$(wake)" $(( before + 57600 )) 5; then ok "a request beyond the ceiling is lowered to it"; else
    bad "a request beyond the ceiling is lowered to it (got $(wake))"; fi
write_conf SCHEDULE_MIN_MINUTES=2 SCHEDULE_MAX_MINUTES=30 SCHEDULE_DEFAULT_MINUTES=7
reset
AGENT="true"
before="$(date +%s)"
out="$(RL_CONFIG="$WORK/loop.conf" RL_AGENT_CMD="$AGENT" "$T" 2>&1)"; rc=$?
if near "$(wake)" $(( before + 420 )) 5; then ok "the default comes from SCHEDULE_DEFAULT_MINUTES"; else
    bad "the default comes from SCHEDULE_DEFAULT_MINUTES (got $(wake))"; fi

echo "== a request left from before the tick does not pin its cadence =="
reset
AGENT="true"
mkdir -p "$STATE"
printf 'next_wake_epoch=%s\nreason=old\n' $(( $(date +%s) + 99999 )) > "$STATE/next-wake-request"
set_due $(( $(date +%s) - 10 ))
before="$(date +%s)"
run_tick
if near "$(wake)" $(( before + 3600 )) 5; then ok "an old request is dropped, so the tick gets the default"; else
    bad "an old request is dropped (got $(wake))"; fi

echo "== a due time a human parked further out survives =="
reset
AGENT="true"
park=$(( $(date +%s) + 200000 ))
set_due "$park"
run_tick --force
if [[ "$(wake)" == "$park" ]]; then ok "a forced tick leaves a later due time alone"; else
    bad "a forced tick leaves a later due time alone (got $(wake), wanted $park)"; fi
if [[ "$out" == *"PAUSE"* ]]; then ok "and says it did"; else bad "and says it did"; fi
reset
AGENT="true"
set_due $(( $(date +%s) + 600 ))
run_tick --force
if near "$(wake)" $(( $(date +%s) + 3600 )) 5; then ok "CONTROL: a due time sooner than the default is replaced"; else
    bad "CONTROL: a due time sooner than the default is replaced (got $(wake))"; fi

# ---------------------------------------------------------------------------
echo
echo "== a dead tick =="
reset
AGENT='bin/schedule_next.sh --in-minutes 400 --reason "chosen by a tick about to die" >/dev/null; echo boom; exit 7'
before="$(date +%s)"
run_tick --force
if [[ $rc -eq 1 ]]; then ok "exits 1"; else bad "exits 1 (got $rc)"; fi
if [[ "$(crumb exit_status)" == "7" && "$(crumb reason)" == "error" ]]; then ok "leaves a breadcrumb with the status and reason"; else
    bad "leaves a breadcrumb with the status and reason (status '$(crumb exit_status)', reason '$(crumb reason)')"; fi
if [[ -n "$(crumb aborted_at)" && -n "$(crumb tick_started_at)" ]]; then ok "and both timestamps"; else bad "and both timestamps"; fi
if [[ "$(crumb capture)" == "$STATE/last-tick-stdout.log" && "$(cat "$STATE/last-tick-stdout.log")" == *boom* ]]; then ok "and points at the captured output"; else
    bad "and points at the captured output"; fi
if near "$(wake)" $(( before + 3600 )) 5; then ok "its wake request is discarded, so the successor arrives on the default"; else
    bad "its wake request is discarded (got $(wake), wanted about $(( before + 3600 )))"; fi
if [[ "$out" == *"discarding the wake request"* && "$out" == *"| boom"* ]]; then ok "and it says so and shows the output tail"; else
    bad "and it says so and shows the output tail"; fi
if [[ ! -e "$STATE/tick.lock" ]]; then ok "the lock is released"; else bad "the lock is released"; fi
if [[ -f "$STATE/last-tick" ]]; then ok "last-tick is recorded even for a death"; else bad "last-tick is recorded even for a death"; fi
if [[ ! -e "$STATE/next-wake-request" ]]; then ok "and no request is left behind"; else bad "and no request is left behind"; fi

echo "== --breadcrumb =="
out="$("$T" --breadcrumb 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"reason=error"* ]]; then ok "prints it and exits 0"; else bad "prints it and exits 0 (rc=$rc)"; fi

echo "== the next clean tick retires it =="
set_due $(( $(date +%s) - 10 ))
AGENT='"'"$T"'" --breadcrumb > "$WORK/seen"'
run_tick
if [[ "$(cat "$WORK/seen" 2>/dev/null)" == *"reason=error"* ]]; then ok "the agent could read it while it ran"; else bad "the agent could read it while it ran"; fi
if [[ ! -e "$STATE/tick-aborted" && -n "$(ls "$STATE/aborted-archive" 2>/dev/null)" ]]; then ok "afterwards it is archived"; else
    bad "afterwards it is archived"; fi
out="$("$T" --breadcrumb 2>&1)"; rc=$?
if [[ $rc -eq 1 && "$out" == *"ended cleanly"* ]]; then ok "and --breadcrumb exits 1"; else bad "and --breadcrumb exits 1 (rc=$rc)"; fi

echo "== a second death before reconciling replaces the breadcrumb =="
reset
AGENT="exit 3"
run_tick --force
AGENT="exit 4"
run_tick --force
if [[ "$(crumb exit_status)" == "4" ]]; then ok "the breadcrumb describes the newest death"; else
    bad "the breadcrumb describes the newest death (got '$(crumb exit_status)')"; fi

echo "== how it died =="
reset
AGENT="echo \"You've hit your session limit, resets 5:20pm\"; exit 1"
run_tick --force
if [[ "$(crumb reason)" == "usage_limit" ]]; then ok "a usage limit message is classified as usage_limit"; else
    bad "a usage limit message is classified as usage_limit (got '$(crumb reason)')"; fi
reset
AGENT="exit 143"
run_tick --force
if [[ "$(crumb reason)" == "killed" ]]; then ok "exit 143 is classified as killed"; else bad "exit 143 is classified as killed (got '$(crumb reason)')"; fi
reset
AGENT="exit 137"
run_tick --force
if [[ "$(crumb reason)" == "killed" ]]; then ok "exit 137 is classified as killed"; else bad "exit 137 is classified as killed (got '$(crumb reason)')"; fi
reset
AGENT="echo 'usage limit reached'; exit 1"
write_conf "USAGE_LIMIT_PATTERN=''"
out="$(RL_CONFIG="$WORK/loop.conf" RL_AGENT_CMD="$AGENT" "$T" --force 2>&1)"
if [[ "$(crumb reason)" == "error" ]]; then ok "with no USAGE_LIMIT_PATTERN nothing is classified as a usage limit"; else
    bad "with no USAGE_LIMIT_PATTERN nothing is classified as a usage limit (got '$(crumb reason)')"; fi

echo "== the session id =="
SID="0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
reset
AGENT="echo '{\"type\":\"result\",\"session_id\":\"$SID\"}'; exit 1"
run_tick --force
if [[ "$(crumb session_id)" == "$SID" ]]; then ok "a session id the command prints is recorded"; else
    bad "a session id the command prints is recorded (got '$(crumb session_id)')"; fi
reset
AGENT='echo "$RL_SESSION_ID" > "$WORK/marker-sid"; exit 1'
run_tick --force
if [[ -n "$(crumb session_id)" && "$(crumb session_id)" == "$(cat "$WORK/marker-sid" 2>/dev/null)" ]]; then ok "a command that uses RL_SESSION_ID has that id recorded"; else
    bad "a command that uses RL_SESSION_ID has that id recorded (got '$(crumb session_id)')"; fi
reset
AGENT="exit 1"
run_tick --force
if [[ -z "$(crumb session_id)" ]]; then ok "a command that never mentions a session records none"; else
    bad "a command that never mentions a session records none (got '$(crumb session_id)')"; fi

# ---------------------------------------------------------------------------
echo
echo "== resuming a usage-limit death =="
write_conf 'AGENT_RESUME_CMD='"'"'echo "resumed $RL_RESUME_SESSION after $RL_ASLEEP_MINUTES" > "$WORK/marker-resume"'"'"
reset
AGENT="echo \"out of usage credits\"; echo '{\"session_id\":\"$SID\"}'; exit 1"
RL_CONFIG="$WORK/loop.conf" run_tick --force
AGENT="touch $WORK/marker-fresh"
RL_CONFIG="$WORK/loop.conf" run_tick --force
if [[ "$(cat "$WORK/marker-resume" 2>/dev/null)" == "resumed $SID after "[0-9]* ]]; then ok "the next tick resumes the session with RL_RESUME_SESSION set"; else
    bad "the next tick resumes the session (got '$(cat "$WORK/marker-resume" 2>/dev/null)')"; fi
if [[ ! -e "$WORK/marker-fresh" ]]; then ok "and does not also start a fresh agent"; else bad "and does not also start a fresh agent"; fi
if [[ "$out" == *"RECOVERY: usage-limit death, resuming session $SID"* ]]; then ok "it says so"; else bad "it says so (got: $out)"; fi
if [[ ! -e "$STATE/tick-aborted" ]]; then ok "a resumed tick that finishes retires the breadcrumb"; else bad "a resumed tick that finishes retires the breadcrumb"; fi

reset; rm -f "$WORK/marker-resume"
AGENT="echo \"out of usage credits\"; echo '{\"session_id\":\"$SID\"}'; exit 1"
run_tick --force
AGENT="touch $WORK/marker-fresh"
run_tick --force
if [[ -e "$WORK/marker-fresh" && ! -e "$WORK/marker-resume" ]]; then ok "with no AGENT_RESUME_CMD it restarts fresh"; else
    bad "with no AGENT_RESUME_CMD it restarts fresh"; fi

reset; rm -f "$WORK/marker-resume" "$WORK/marker-fresh"
AGENT="echo '{\"session_id\":\"$SID\"}'; exit 1"
RL_CONFIG="$WORK/loop.conf" run_tick --force
AGENT="touch $WORK/marker-fresh"
RL_CONFIG="$WORK/loop.conf" run_tick --force
if [[ -e "$WORK/marker-fresh" && ! -e "$WORK/marker-resume" ]]; then ok "any other death restarts fresh, even with a session id"; else
    bad "any other death restarts fresh, even with a session id"; fi

reset; rm -f "$WORK/marker-resume" "$WORK/marker-fresh"
AGENT="echo 'usage limit reached'; exit 1"
RL_CONFIG="$WORK/loop.conf" run_tick --force
AGENT="touch $WORK/marker-fresh"
RL_CONFIG="$WORK/loop.conf" run_tick --force
if [[ -e "$WORK/marker-fresh" && ! -e "$WORK/marker-resume" ]]; then ok "a usage-limit death with no known session restarts fresh"; else
    bad "a usage-limit death with no known session restarts fresh"; fi

echo "== --dry-run says it would resume =="
reset
AGENT="echo 'usage limit reached'; echo '{\"session_id\":\"$SID\"}'; exit 1"
RL_CONFIG="$WORK/loop.conf" run_tick --force
RL_CONFIG="$WORK/loop.conf" run_tick --force --dry-run
if [[ "$out" == *"would resume session $SID"* ]]; then ok "after a usage-limit death"; else bad "after a usage-limit death (got: $out)"; fi

# ---------------------------------------------------------------------------
echo
echo "== the lock =="
reset
AGENT="sleep 4"
RL_AGENT_CMD="$AGENT" "$T" >/dev/null 2>&1 &
bg=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "$STATE/tick.lock/pid" ]] && break; sleep 0.2
done
if [[ "$(cat "$STATE/tick.lock/pid" 2>/dev/null)" == "$bg" ]]; then ok "a running tick holds the lock with its own pid"; else
    bad "a running tick holds the lock with its own pid (got '$(cat "$STATE/tick.lock/pid" 2>/dev/null)', wanted $bg)"; fi
AGENT="touch $WORK/marker-second"
run_tick --force
if [[ $rc -eq 0 && ! -e "$WORK/marker-second" && "$out" == *"still running"* ]]; then ok "a second call skips, says why, and exits 0"; else
    bad "a second call skips and exits 0 (rc=$rc, out: $out)"; fi
wait "$bg"
if [[ ! -e "$STATE/tick.lock" ]]; then ok "the lock is released when the tick ends"; else bad "the lock is released when the tick ends"; fi

reset
mkdir -p "$STATE/tick.lock"
AGENT="touch $WORK/marker"
run_tick
if [[ $rc -eq 0 && ! -e "$WORK/marker" && "$out" == *"still running"* ]]; then ok "a brand new lock with no pid yet is respected"; else
    bad "a brand new lock with no pid yet is respected (rc=$rc)"; fi

reset
mkdir -p "$STATE/tick.lock"
( exit 0 ) & dead=$!; wait "$dead"
echo "$dead" > "$STATE/tick.lock/pid"
echo "2026-01-01T00:00:00Z" > "$STATE/tick.lock/started"
AGENT='"'"$T"'" --breadcrumb > "$WORK/seen"'
run_tick
if [[ $rc -eq 0 && "$out" == *"reaping stale lock"* ]]; then ok "a lock whose holder is gone is reaped and the tick runs"; else
    bad "a lock whose holder is gone is reaped (rc=$rc, out: $out)"; fi
if [[ "$(cat "$WORK/seen" 2>/dev/null)" == *"reason=lost"* && "$(cat "$WORK/seen" 2>/dev/null)" == *"tick_started_at=2026-01-01T00:00:00Z"* ]]; then ok "and the reaped tick's death was left as a breadcrumb for the agent"; else
    bad "and the reaped tick's death was left as a breadcrumb (saw: $(cat "$WORK/seen" 2>/dev/null))"; fi

reset
sleep 20 & other=$!
mkdir -p "$STATE/tick.lock"; echo "$other" > "$STATE/tick.lock/pid"
AGENT="touch $WORK/marker"
run_tick
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
if [[ -e "$WORK/marker" && "$out" == *"reaping stale lock"* ]]; then ok "a live process that is not a tick is not a lock holder (pid reuse)"; else
    bad "a live process that is not a tick is not a lock holder"; fi

reset
mkdir -p "$STATE"; echo "keep me" > "$STATE/tick-aborted"
mkdir -p "$STATE/tick.lock"; ( exit 0 ) & dead=$!; wait "$dead"; echo "$dead" > "$STATE/tick.lock/pid"
AGENT="exit 9"
run_tick
if [[ "$(crumb exit_status)" == "9" ]]; then ok "an existing breadcrumb is not overwritten by a reap, only by a newer death"; else
    bad "an existing breadcrumb handling (got '$(crumb exit_status)')"; fi

# ---------------------------------------------------------------------------
echo
echo "== usage errors =="
reset
out="$(RL_AGENT_CMD= "$T" --frobnicate 2>&1)"; rc=$?
if [[ $rc -eq 2 && "$out" == *"unknown argument: --frobnicate"* ]]; then ok "an unknown flag exits 2 and is named"; else
    bad "an unknown flag exits 2 and is named (rc=$rc)"; fi
write_conf "AGENT_CMD=''"
out="$(env -u RL_AGENT_CMD RL_CONFIG="$WORK/loop.conf" "$T" 2>&1)"; rc=$?
if [[ $rc -eq 2 && "$out" == *"no AGENT_CMD"* ]]; then ok "no AGENT_CMD anywhere exits 2 and says how to set one"; else
    bad "no AGENT_CMD anywhere exits 2 (rc=$rc, out: $out)"; fi
if [[ ! -e "$STATE/tick.lock" ]]; then ok "and takes no lock"; else bad "and takes no lock"; fi
out="$("$T" --help 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$out" == "tick.sh - "* ]]; then ok "--help prints the header comment and exits 0"; else
    bad "--help prints the header comment and exits 0"; fi

# ---------------------------------------------------------------------------
# The guard on this whole file: none of the above touched the repo.
# ---------------------------------------------------------------------------
echo
echo "== the repo itself was never written to =="
if [[ $REAL_STATE_EXISTED -eq 0 && ! -e "$REPO/state" ]]; then ok "no state/ directory appeared in the repo"; else
    if [[ $REAL_STATE_EXISTED -eq 1 ]]; then ok "state/ already existed and this run used scratch space"; else
        bad "a state/ directory appeared in the repo"; fi; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
