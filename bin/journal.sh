#!/usr/bin/env bash
#
# journal.sh - append-only event journal shared across every invocation of the
# loop: orchestrator ticks, dispatched probes, evaluation stages, the ratchet.
#
# One JSON object per line (ndjson), newest appended at the end, stored at
# registry/journal.ndjson in the repo by default. It is meant to be
# version-controlled: history is never lost, and `git log -p` / `git diff`
# make the journal reviewable like any other change. Nothing in this script
# ever rewrites or deletes an existing line - only `append` adds new ones.
#
# Event vocabulary (validated - an unknown --event exits 2 rather than
# silently corrupting the log):
#   orchestrator_woke     the orchestrator started a wake cycle
#   tick_aborted          a previous tick was killed mid-stage (usually a
#                          session or resource limit) and never reached its
#                          own journal write. Recorded by its successor during
#                          reconciliation, saying what was recovered and what
#                          was discarded. Without it a dead tick is
#                          indistinguishable from a tick that never ran
#   run_started           an evaluation run was launched
#   run_healthy           a periodic check found the run progressing normally
#   run_degraded          a periodic check tripped a heuristic that flags a
#                          run gaming its own metric rather than improving it
#   run_died              the run's process is gone with no completion logged
#   run_stopped           a human or agent deliberately ended the run. Terminal:
#                         distinguishes an intentional stop from a crash so the
#                         next orchestrator does not resume it
#   run_completed         the run finished on its own terms
#   eval_started          evaluation of a completed run began
#   eval_completed        evaluation of a completed run finished
#   revision_proposed     a config change was proposed in response to a run's
#                          outcome
#   revision_implemented  that change was landed (new variant, new commit)
#   no_capacity           the orchestrator wanted to start a run but found no
#                          free resource
#   hosts_cleaned         scratch state was purged from one or more machines
#                          after their run finished (see cleanup-hosts)
#   north_star_met        the active goal-file target was satisfied on all
#                          conditions at two consecutive registered evals.
#                          Written by `north_star.sh met --record`, never by
#                          hand: its note carries the evidence in a
#                          machine-readable form so the claim can be
#                          RE-VERIFIED rather than trusted. Not terminal for
#                          the run it names - it says something about the
#                          target, not about the process
#   north_star_updated    a new target version was created by
#                          `north_star.sh ratchet --apply`. Consumes the
#                          matching north_star_met: `north_star.sh pending`
#                          reports nothing due once this line exists
#   note                  free-form, for anything that doesn't fit the above
#
# Schema (one flat JSON object per line, fixed key set, missing fields null):
#   ts        UTC ISO8601, auto-filled if not given
#   event     one of the vocabulary above (required)
#   run_id    caller-chosen identifier for a run
#   variant   the named configuration variant the run was launched with
#   branch    git branch the run was launched from
#   host      the machine the run is on (an entry from the caller's own SSH
#             config or inventory - this script does not interpret it)
#   commit    short git commit hash, auto-filled from `git rev-parse
#             --short HEAD` if not given
#   note      free-form text
#   hypothesis_id
#             the registry record this entry is evidence for (see
#             hypothesis.sh). This is the JOIN KEY: `hypothesis.sh show <id>`
#             returns the record plus every journal line carrying that id, so
#             an agent handed only an id can recover its full history.
#   screen_session
#             the detached session a probe was dispatched into, on `host`.
#             Part of the LIVENESS POINTER below.
#   remote_log
#             absolute path on `host` of the log that dispatch is writing.
#             Another part.
#   result_glob
#             absolute path pattern on `host` that the dispatched work's OUTPUT
#             artefacts land at. The COMPLETION CLAUSE, with expect_results.
#   expect_results
#             how many of them a complete run produces. A positive integer.
#   held_by
#             the stage an agent of the TICK IN PROGRESS is running against this
#             record. The HOLD - see below. Bookkeeping about the loop, not
#             evidence about the record.
#
# THE LIVENESS POINTER, and why it is three FIELDS rather than three facts in
# a note. A probe dispatched DETACHED to a remote machine outlives the tick
# that started it: its activity is on that machine, in a session and a log,
# where the journal cannot see it. `hypothesis.sh drift` decides a record in
# testing/doing is orphaned when a tick-boundary line is newer than the
# record's last activity, and the soundness argument for that (the
# orchestrator will not start a second instance of itself) holds only for
# work that happens INSIDE a tick. It does not hold here, so a LIVE detached
# sweep reads as an orphan, and drift's prescribed recovery
# (`set-state <id> open --interrupted-by ...`) would record an interruption
# that did not happen and move the record out from under the agent about to
# decide it. This has been observed in practice: a dispatching stage wrote
# host, session and log in a note's prose, and drift could not read prose.
#
# So this is a FORMAT change and not new information: pass them as fields and
# `drift` probes the machine for the session before it calls anything
# orphaned.
#
#   ./journal.sh append --event note --hypothesis-id H12 --host worker-3 \
#       --screen-session h12probe \
#       --remote-log /tmp/rl/h12_probe/run_20260101T000000Z.log \
#       --note "phase 1 dispatched detached, 54 cases, ETA ~2h"
#
# All four travel together or none does: --screen-session and --remote-log
# each REQUIRE the other, plus --host and --hypothesis-id, and a partial
# pointer is a usage error (exit 2) rather than a line that looks like a
# pointer and cannot be probed. A pointer is never retired - the record
# leaving testing/doing is what stops drift consulting it.
#
# THE COMPLETION CLAUSE, and why the pointer is TIERED rather than
# six-of-six. The liveness pointer splits drift's answer three ways off one
# question (is a session with this name running on this host?), and that
# question cannot tell a sweep that RAN TO COMPLETION from one whose agent
# DIED HOLDING IT - both leave no session behind. So the pointer may also say
# where the work's OUTPUT lands and how much of it a complete run produces:
#
#   ./journal.sh append --event note --hypothesis-id H12 --host worker-3 \
#       --screen-session h12probe \
#       --remote-log /tmp/rl/h12_probe/run_20260101T000000Z.log \
#       --result-glob '/tmp/rl/h12_probe/cells/*/manifest.json' \
#       --expect-results 60 \
#       --note "phase 1 dispatched detached, 54 cases, ETA ~2h"
#
# --result-glob and --expect-results each REQUIRE the other and both require the
# whole four-field pointer, so a half-written clause is exit 2 exactly as a
# half-written pointer is. What they are NOT is compulsory: a four-field pointer
# stays legal and behaves exactly as it did without the clause (absent ->
# orphaned), and that is deliberate - work with no output artefacts has no
# completion evidence, and forcing a glob on it would manufacture the very
# inference this exists to replace. drift says so in the report rather than
# letting the omission be silent.
#
# The glob is validated because it is SPLICED INTO A REMOTE COMMAND: absolute
# (a relative pattern would expand against the remote home directory and count
# the wrong thing, silently), and drawn from [A-Za-z0-9._/*?@%+,:=-] alone, so
# no quote, space, `;`, `$`, backtick or redirection can ride into the payload.
# --expect-results must be a POSITIVE integer: zero would make every dispatch
# instantly complete, which is the empty-match-reads-as-absent defect wearing
# the opposite sign.
#
# THE HOLD, which is the other half of the same finding. drift's tick-boundary
# heuristic decides "no agent is deciding this" from an `orchestrator_woke`
# line newer than the record's last activity - and that line is written at the
# TOP of a tick, so every record the tick then dispatches a SUBAGENT into is,
# by construction, older than the newest boundary for the rest of that tick.
# The "won't start a second instance of itself" argument does not cover it:
# the second agent is not a second tick, it is a subagent of the live one. The
# dispatching stage therefore says so:
#
#   ./journal.sh append --event note --hypothesis-id H12 \
#       --held-by probe-hypothesis --note "dispatched to score the finished sweep"
#
# --held-by requires --hypothesis-id (a hold naming no record protects nothing)
# and any non-empty label is accepted. Deliberately NOT a closed vocabulary,
# unlike --event: the value is descriptive, and refusing an unfamiliar stage
# name would cost a live agent's record its protection - which is the exact
# damage the hold exists to prevent, reintroduced by the validator.
#
# A HOLD IS NOT ACTIVITY, and drift treats it that way: it suppresses the ORPHAN
# verdict for the tick that placed it, and it does NOT reset the staleness
# clock. A dispatch is a claim that an agent exists, not evidence that anything
# happened to the record; if it counted as activity, a stage that died instantly
# on every tick would keep its record permanently fresh and so permanently
# invisible to BOTH detectors. Say what you have to say about the record in a
# separate line.
#
# Exit codes:  0 = success
#              1 = `last` found no entry matching --event, or `active-runs`
#                  found none
#              2 = usage error (missing/unknown --event, bad flag)
#
# Usage:
#   ./journal.sh append --event run_started --run-id run-042 --variant v3 \
#       --branch feature/loop-pass-1 --host worker-3
#   ./journal.sh append --event note --note "bootstrap"
#   ./journal.sh append --event eval_completed --hypothesis-id H5 --note "..."
#   ./journal.sh append --event note --hypothesis-id H12 --host worker-3 \
#       --screen-session h12probe --remote-log /tmp/rl/h12_probe/run.log \
#       --note "phase 1 dispatched detached"        # the liveness pointer
#   ./journal.sh append --event note --hypothesis-id H12 --host worker-3 \
#       --screen-session h12probe --remote-log /tmp/rl/h12_probe/run.log \
#       --result-glob '/tmp/rl/h12_probe/cells/*/manifest.json' \
#       --expect-results 60 --note "..."            # ... with its completion clause
#   ./journal.sh append --event note --hypothesis-id H12 \
#       --held-by probe-hypothesis --note "dispatched to score it"   # the hold
#   ./journal.sh tail                 # last 10, human-readable
#   ./journal.sh tail -n 25 --json    # last 25, as a JSON array
#   ./journal.sh tail --compact       # one line per entry, note truncated
#   ./journal.sh last --event run_started --json
#   ./journal.sh active-runs --json   # runs started with no terminal event yet
#
# `tail` renders one stanza per entry: a header line, the non-null metadata
# fields, then the note wrapped to the terminal. Notes here can be long essays,
# so they are also split into paragraphs on the `***` section markers the
# entries use by convention, and a leading ALL-CAPS clause is lifted onto its
# own line as a heading. Nothing is dropped: the full note is always printed.
# `--compact` gives the old one-line-per-entry table instead, with columns
# sized to the data and the note truncated to whatever room is left.
#
#   -n, --lines N   how many entries (default 10)
#   -j, --json      raw JSON array - unchanged, this is what callers parse
#   -c, --compact   one line per entry
#       --width N   wrap width (default: terminal width, or 100 when piped)
#       --no-color  suppress ANSI colour (also honours NO_COLOR, and colour
#                   is off automatically whenever stdout is not a terminal)
#
# Environment:
#   RL_JOURNAL   path to journal.ndjson (default: registry/journal.ndjson at
#                the repo root). Tests point this at a scratch journal so
#                verdict paths never write fake runs into the real one.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
JOURNAL="${RL_JOURNAL:-$REPO_ROOT/registry/journal.ndjson}"

EVENTS=(orchestrator_woke tick_aborted run_started run_healthy run_degraded run_died
        run_stopped
        run_completed eval_started eval_completed revision_proposed
        revision_implemented no_capacity hosts_cleaned
        north_star_met north_star_updated note)

# Prints the file's leading comment block. Derived rather than a line range:
# a fixed `sed -n` range silently truncates the help text every time a flag is
# documented above the cut, and this file's header IS its documentation. Keep
# this one line byte-identical across the helpers if you add more of them.
usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit "${1:-0}"
}

is_valid_event() {
    local e="$1" candidate
    for candidate in "${EVENTS[@]}"; do
        [[ "$candidate" == "$e" ]] && return 0
    done
    return 1
}

# Build one JSON line from env vars (JN_*) via python - avoids hand-rolled
# shell JSON escaping, which breaks the moment a --note contains a quote.
build_json_line() {
    JN_TS="$1" JN_EVENT="$2" JN_RUN_ID="$3" JN_VARIANT="$4" JN_BRANCH="$5" \
    JN_HOST="$6" JN_COMMIT="$7" JN_NOTE="$8" \
    JN_HYPOTHESIS_ID="$9" JN_SCREEN_SESSION="${10}" JN_REMOTE_LOG="${11}" \
    JN_RESULT_GLOB="${12}" JN_EXPECT_RESULTS="${13}" JN_HELD_BY="${14}" \
    python3 -c '
import json, os

def g(key):
    v = os.environ.get(key, "")
    if v == "":
        return None
    return v.replace("\n", " ").replace("\r", "")

expect = g("JN_EXPECT_RESULTS")

obj = {
    "ts": g("JN_TS"),
    "event": g("JN_EVENT"),
    "run_id": g("JN_RUN_ID"),
    "variant": g("JN_VARIANT"),
    "branch": g("JN_BRANCH"),
    "host": g("JN_HOST"),
    "commit": g("JN_COMMIT"),
    "note": g("JN_NOTE"),
    "hypothesis_id": g("JN_HYPOTHESIS_ID"),
    "screen_session": g("JN_SCREEN_SESSION"),
    "remote_log": g("JN_REMOTE_LOG"),
    "result_glob": g("JN_RESULT_GLOB"),
    # An integer, not a string: drift compares it against a count the
    # machine computed, and cmd_append has already refused anything but a
    # positive decimal integer.
    "expect_results": int(expect) if expect is not None else None,
    "held_by": g("JN_HELD_BY"),
}
print(json.dumps(obj))
'
}

cmd_append() {
    local event="" run_id="" variant="" branch="" host="" commit="" note=""
    local hypothesis_id="" screen_session="" remote_log=""
    local result_glob="" expect_results="" held_by=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --event)   event="$2"; shift 2 ;;
            --run-id)  run_id="$2"; shift 2 ;;
            --variant) variant="$2"; shift 2 ;;
            --branch)  branch="$2"; shift 2 ;;
            --host)    host="$2"; shift 2 ;;
            --commit)  commit="$2"; shift 2 ;;
            --note)    note="$2"; shift 2 ;;
            --hypothesis-id) hypothesis_id="$2"; shift 2 ;;
            --screen-session) screen_session="$2"; shift 2 ;;
            --remote-log)     remote_log="$2"; shift 2 ;;
            --result-glob)    result_glob="$2"; shift 2 ;;
            --expect-results) expect_results="$2"; shift 2 ;;
            --held-by)        held_by="$2"; shift 2 ;;
            -h|--help) usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done

    if [[ -z "$event" ]]; then
        echo "--event is required" >&2
        usage 2
    fi
    if ! is_valid_event "$event"; then
        echo "unknown event '$event' - must be one of: ${EVENTS[*]}" >&2
        exit 2
    fi
    # The liveness pointer is ALL FOUR OR NONE. A half-written pointer is worse
    # than no pointer: `hypothesis.sh drift` would either not find it (and go on
    # calling a live detached probe an orphan, which is the defect) or find it
    # with nothing to probe. Refusing here is the only place that can tell the
    # difference between an incomplete pointer and a deliberate omission.
    if [[ -n "$screen_session" || -n "$remote_log" ]]; then
        local missing=""
        [[ -z "$host" ]]           && missing="$missing --host"
        [[ -z "$hypothesis_id" ]]  && missing="$missing --hypothesis-id"
        [[ -z "$screen_session" ]] && missing="$missing --screen-session"
        [[ -z "$remote_log" ]]     && missing="$missing --remote-log"
        if [[ -n "$missing" ]]; then
            echo "incomplete liveness pointer - missing:$missing" >&2
            echo "a pointer is --host, --screen-session, --remote-log and" \
                 "--hypothesis-id together, or none of them: drift probes the" \
                 "named session on the named host before it calls a record" \
                 "orphaned, and cannot probe half a pointer." >&2
            exit 2
        fi
    fi

    # The COMPLETION CLAUSE is all-or-nothing WITHIN ITSELF and requires the
    # whole pointer under it. It is NOT compulsory: a four-field pointer with
    # no clause is still legal, and drift treats it exactly as it did without
    # one - work with no output artefacts has no completion evidence, and a
    # mandatory glob would only invite a fabricated one.
    if [[ -n "$result_glob" || -n "$expect_results" ]]; then
        local cmissing=""
        [[ -z "$result_glob" ]]    && cmissing="$cmissing --result-glob"
        [[ -z "$expect_results" ]] && cmissing="$cmissing --expect-results"
        [[ -z "$host" ]]           && cmissing="$cmissing --host"
        [[ -z "$hypothesis_id" ]]  && cmissing="$cmissing --hypothesis-id"
        [[ -z "$screen_session" ]] && cmissing="$cmissing --screen-session"
        [[ -z "$remote_log" ]]     && cmissing="$cmissing --remote-log"
        if [[ -n "$cmissing" ]]; then
            echo "incomplete completion clause - missing:$cmissing" >&2
            echo "--result-glob and --expect-results travel together and sit on" \
                 "top of a whole liveness pointer: drift reads the count in the" \
                 "SAME payload as the session list, and cannot split an absent" \
                 "session from a finished one on half a clause." >&2
            exit 2
        fi
        # The glob is spliced into a remote command. Absolute, because a
        # relative pattern expands against the remote home directory and counts
        # the wrong thing without saying so; and no character that could carry a
        # quote, a word break or a redirection into the payload.
        if [[ "$result_glob" != /* ]]; then
            echo "--result-glob must be an absolute path pattern (got '$result_glob')" >&2
            echo "a relative pattern is resolved against the remote home" \
                 "directory, so it would silently count the wrong files." >&2
            exit 2
        fi
        if [[ ! "$result_glob" =~ ^[A-Za-z0-9._/*?@%+,:=-]+$ ]]; then
            echo "--result-glob may use only [A-Za-z0-9._/*?@%+,:=-] (got '$result_glob')" >&2
            echo "it is spliced into a single-quoted string inside a remote" \
                 "command; a quote, a space or a shell metacharacter there is a" \
                 "broken payload at best." >&2
            exit 2
        fi
        # Zero would make every dispatch instantly complete - the
        # empty-match-reads-as-absent defect wearing the opposite sign.
        if [[ ! "$expect_results" =~ ^[1-9][0-9]*$ ]]; then
            echo "--expect-results must be a positive integer (got '$expect_results')" >&2
            echo "0 would make an empty result directory read as a finished" \
                 "sweep, which is the inference this clause exists to replace." >&2
            exit 2
        fi
    fi

    # THE HOLD. A hold naming no record protects nothing, so it needs the join
    # key. The stage label itself is free text on purpose - see the header.
    if [[ -n "$held_by" ]]; then
        if [[ -z "$hypothesis_id" ]]; then
            echo "incomplete hold - missing: --hypothesis-id" >&2
            echo "--held-by says an agent of the tick in progress is working a" \
                 "RECORD; without the join key it names nothing and drift can" \
                 "honour nothing." >&2
            exit 2
        fi
        if [[ ! "$held_by" =~ [^[:space:]] ]]; then
            echo "--held-by must name the stage holding the record (got whitespace)" >&2
            exit 2
        fi
    fi

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -z "$commit" ]]; then
        commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
    fi

    mkdir -p "$(dirname "$JOURNAL")"

    local line
    line="$(build_json_line "$ts" "$event" "$run_id" "$variant" "$branch" "$host" "$commit" "$note" "$hypothesis_id" "$screen_session" "$remote_log" "$result_glob" "$expect_results" "$held_by")" \
        || { echo "failed to build journal entry" >&2; exit 2; }

    # Single write() call so concurrent appends from different invocations
    # don't interleave - lines this size are well under PIPE_BUF.
    printf '%s\n' "$line" >> "$JOURNAL"
    echo "appended: $line"
}

# Runs that have started and not yet reached a terminal event.
#
# This exists because the loop can hold more than one run at a time. A
# separate run-status helper is deliberately single-run - "the most recent
# run_started line for this id" - so the orchestrator enumerates here and
# checks each active run individually.
#
# Fields are MERGED across every run_started line for the same run_id, latest
# non-null winning. That is not defensive coding: a run has been journalled
# twice before, the first time with --variant/--host/--branch omitted, and a
# reader that took only the last line would see a null host and call it
# UNREACHABLE.
cmd_active_runs() {
    local json=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -j|--json) json=1; shift ;;
            -h|--help) usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done

    if [[ ! -f "$JOURNAL" ]]; then
        if [[ "$json" -eq 1 ]]; then echo "[]"; else echo "(journal is empty)"; fi
        return 1
    fi

    local result
    result="$(python3 -c '
import json, sys

TERMINAL = {"run_completed", "run_died", "run_stopped"}
FIELDS = ("variant", "branch", "host", "commit", "hypothesis_id")

order, runs = [], {}
with open(sys.argv[1]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        rid = o.get("run_id")
        if not rid:
            continue
        ev = o.get("event")
        if ev == "run_started":
            if rid not in runs:
                runs[rid] = {"run_id": rid, "started": o.get("ts"), "terminal": None}
                order.append(rid)
            for f in FIELDS:
                if o.get(f) is not None:
                    runs[rid][f] = o.get(f)
        elif ev in TERMINAL and rid in runs:
            runs[rid]["terminal"] = ev

active = [runs[r] for r in order if runs[r]["terminal"] is None]
for a in active:
    a.pop("terminal", None)
    for f in FIELDS:
        a.setdefault(f, None)
print(json.dumps(active))
' "$JOURNAL")" || { echo "failed to read journal" >&2; exit 1; }

    if [[ "$json" -eq 1 ]]; then
        echo "$result"
    else
        echo "$result" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
if not rows:
    print("(no active runs)")
    sys.exit(0)
print("%-34s %-12s %-14s %-6s %s" % ("RUN_ID", "VARIANT", "HOST", "HYP", "STARTED"))
for r in rows:
    print("%-34s %-12s %-14s %-6s %s" % (
        r["run_id"], r.get("variant") or "-", r.get("host") or "-",
        r.get("hypothesis_id") or "-", r.get("started") or "-"))
'
    fi

    [[ "$result" != "[]" ]]
}

cmd_tail() {
    local n=10 json=0 compact=0 width="" color=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--lines)   n="$2"; shift 2 ;;
            -j|--json)    json=1; shift ;;
            -c|--compact) compact=1; shift ;;
            --width)      width="$2"; shift 2 ;;
            --no-color|--no-colour) color=0; shift ;;
            -h|--help)    usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done

    if [[ ! -f "$JOURNAL" ]]; then
        if [[ "$json" -eq 1 ]]; then echo "[]"; else echo "(journal is empty - no entries yet)"; fi
        return 0
    fi

    if [[ "$json" -eq 1 ]]; then
        tail -n "$n" "$JOURNAL" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
print(json.dumps(rows, indent=2))
'
        return 0
    fi

    # Wrap to the real terminal when there is one; 100 when piped, so a
    # captured tick log has stable, reviewable line breaks.
    if [[ -z "$width" ]]; then
        if [[ -t 1 ]]; then width="$(tput cols 2>/dev/null || echo 100)"; else width=100; fi
    fi
    # Colour is a terminal affordance only. Anything reading this through a
    # pipe (the orchestrator, a tick log, a grep) gets clean text.
    [[ -t 1 ]] || color=0
    [[ -n "${NO_COLOR:-}" ]] && color=0

    # The renderer reads the file itself rather than a `tail` pipe: stdin is
    # already spoken for by the heredoc carrying the program.
    python3 - "$JOURNAL" "$n" "$width" "$color" "$compact" <<'PY'
import json, re, sys, textwrap


def as_int(raw, fallback):
    try:
        return int(raw)
    except ValueError:
        return fallback


path = sys.argv[1]
n = as_int(sys.argv[2], 10)
use_colour = sys.argv[4] == "1"
compact = sys.argv[5] == "1"
# Prose is capped at 120 because long notes are hard to read back; a table is
# not prose and gets the whole terminal, since the note column is whatever the
# fixed columns leave over.
width = max(60, as_int(sys.argv[3], 100)) if compact \
    else max(48, min(as_int(sys.argv[3], 100), 120))

with open(path) as fh:
    lines = [l for l in fh if l.strip()]
if n <= 0:
    sys.exit(0)

# A malformed line is skipped rather than fatal - one bad append should not
# make the whole journal unreadable - but it is reported on stderr, because
# silently dropping a line from an append-only log is worse than a crash.
rows, bad = [], 0
for raw in lines[-n:]:
    try:
        rows.append(json.loads(raw))
    except ValueError:
        bad += 1
if bad:
    print("warning: skipped %d unparseable line(s)" % bad, file=sys.stderr)
if not rows:
    print("(journal is empty - no entries yet)")
    sys.exit(0)


def sgr(code):
    return ("\033[%sm" % code) if use_colour else ""


RESET, BOLD, DIM = sgr(0), sgr(1), sgr(2)

# Terminal and failure events need to be findable by eye in a wall of prose;
# everything else stays quiet so they stand out.
EVENT_COLOUR = {
    "run_died": sgr("1;31"),
    "run_degraded": sgr("1;31"),
    "tick_aborted": sgr("1;31"),
    "run_stopped": sgr("33"),
    "no_capacity": sgr("33"),
    "run_completed": sgr("1;32"),
    "run_healthy": sgr("32"),
    "run_started": sgr("1;36"),
    "orchestrator_woke": sgr("36"),
    "eval_started": sgr("35"),
    "eval_completed": sgr("1;35"),
    "revision_proposed": sgr("34"),
    "revision_implemented": sgr("1;34"),
    "hosts_cleaned": sgr("36"),
}

# Order matters: the fields an orienting reader looks for first. hypothesis_id
# is here because it is the join key into the registry.
META = [
    ("run_id", "run"),
    ("variant", "variant"),
    ("host", "host"),
    ("hypothesis_id", "hyp"),
    # The liveness pointer. Shown here for the same reason it is a field at
    # all: a reader picking up a detached probe should not have to find the
    # host and the session by reading three paragraphs of prose.
    ("screen_session", "screen"),
    ("remote_log", "remote log"),
    # The completion clause and the hold, shown for the same reason.
    ("result_glob", "results"),
    ("expect_results", "expect"),
    ("held_by", "held by"),
    ("branch", "branch"),
    ("commit", "commit"),
]


def clip(s, n):
    return s if len(s) <= n else s[: max(0, n - 1)] + "…"


if compact:
    # Size each column to the data rather than to a guess: a run id can be
    # wider than any fixed guess, and a fixed column pushes every later
    # column out of alignment.
    def col(key, label, cap):
        # Floor at the header's own width, or the header overflows its column
        # and every data row below it sits misaligned.
        return min(cap, max([len(label)] + [len(r.get(key) or "-") for r in rows]))

    w_rid = col("run_id", "RUN_ID", 28)
    w_var = col("variant", "VARIANT", 12)
    w_host = col("host", "HOST", 14)
    head = "%-20s  %-20s  %-*s  %-*s  %-*s  " % (
        "TS", "EVENT", w_rid, "RUN_ID", w_var, "VARIANT", w_host, "HOST")
    print(BOLD + head + "NOTE" + RESET)
    for o in rows:
        ev = o.get("event") or "-"
        line = "%-20s  %s%-20s%s  %-*s  %-*s  %-*s  " % (
            (o.get("ts") or "-")[:20],
            EVENT_COLOUR.get(ev, ""), clip(ev, 20), RESET,
            w_rid, clip(o.get("run_id") or "-", w_rid),
            w_var, clip(o.get("variant") or "-", w_var),
            w_host, clip(o.get("host") or "-", w_host))
        note = " ".join((o.get("note") or "").split())
        print(line + DIM + clip(note, max(12, width - len(head))) + RESET)
    sys.exit(0)


# A leading ALL-CAPS clause is a section heading by convention in these
# entries ("*** WHY THIS MATTERS: the body of the section"). Lift it onto its
# own line when the whole clause is upper case - a clause with any lower case
# in it is prose that merely starts loudly, and splitting it would read worse.
HEADING = re.compile(r"^([^.:]{4,60})([.:])\s+(.*)$", re.S)


def heading_of(para):
    m = HEADING.match(para)
    if not m:
        return None, para
    head, punct, rest = m.groups()
    head = head.strip()
    letters = [c for c in head if c.isalpha()]
    if not letters or not all(c.isupper() for c in letters):
        return None, para
    # One word is a sentence that merely starts loudly ("SHORT. one
    # sentence."), not a heading - unless a colon makes it unambiguous.
    if len(head.split()) < 2 and punct != ":":
        return None, para
    return head, rest.strip()


def paragraphs(note):
    # Entries mark their own sections with `***`. Honour that rather than
    # inventing a structure the writers did not use.
    return [p.strip() for p in note.split("***") if p.strip()]


for i, o in enumerate(rows):
    if i:
        print()
    ev = o.get("event") or "-"
    colour = EVENT_COLOUR.get(ev, BOLD)
    print("%s%s%s  %s%s%s" % (DIM, o.get("ts") or "-", RESET, colour, ev, RESET))

    # Packed by VISIBLE width - textwrap would count the escape sequences as
    # characters and wrap these lines far too early.
    meta = [(label, o.get(key)) for key, label in META if o.get(key)]
    line, plain = "", 0
    for label, value in meta:
        cell, seen = "%s%s%s %s" % (DIM, label, RESET, value), len(label) + 1 + len(str(value))
        if plain and plain + 3 + seen > width - 2:
            print("  " + line)
            line, plain = "", 0
        line, plain = (line + "   " + cell if line else cell), (plain + 3 + seen if plain else seen)
    if line:
        print("  " + line)

    note = o.get("note")
    if not note:
        continue
    for j, para in enumerate(paragraphs(note)):
        print()
        head, body = heading_of(para)
        if head:
            print("  %s%s%s" % (BOLD, head, RESET))
        if body:
            print(textwrap.fill(" ".join(body.split()), width=width,
                                initial_indent="  ", subsequent_indent="  ",
                                break_long_words=False, break_on_hyphens=False))
PY
}

cmd_last() {
    local event="" json=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --event)   event="$2"; shift 2 ;;
            -j|--json) json=1; shift ;;
            -h|--help) usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done

    if [[ -z "$event" ]]; then
        echo "--event is required" >&2
        usage 2
    fi
    if ! is_valid_event "$event"; then
        echo "unknown event '$event' - must be one of: ${EVENTS[*]}" >&2
        exit 2
    fi

    if [[ ! -f "$JOURNAL" ]]; then
        if [[ "$json" -eq 1 ]]; then echo "null"; else echo "no entries for event '$event'"; fi
        return 1
    fi

    local result rc
    result="$(python3 -c '
import json, sys
target = sys.argv[1]
path = sys.argv[2]
last = None
with open(path) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        if obj.get("event") == target:
            last = obj
if last is None:
    sys.exit(1)
print(json.dumps(last))
' "$event" "$JOURNAL")"
    rc=$?

    if [[ $rc -ne 0 ]]; then
        if [[ "$json" -eq 1 ]]; then echo "null"; else echo "no entries for event '$event'"; fi
        return 1
    fi

    if [[ "$json" -eq 1 ]]; then
        echo "$result"
    else
        # %-formatting rather than an f-string: this program is carried inside
        # a single-quoted shell string, so it cannot contain a `'`.
        echo "$result" | python3 -c '
import json, sys
o = json.load(sys.stdin)
for k, v in o.items():
    print("%s: %s" % (k, "-" if v is None else v))
'
    fi
}

[[ $# -eq 0 ]] && usage 2

sub="$1"; shift
case "$sub" in
    append)      cmd_append "$@" ;;
    tail)        cmd_tail "$@" ;;
    last)        cmd_last "$@" ;;
    active-runs) cmd_active_runs "$@" ;;
    -h|--help) usage 0 ;;
    *) echo "unknown subcommand: $sub" >&2; usage 2 ;;
esac
