#!/usr/bin/env bash
#
# test_journal.sh - behavioural tests for journal.sh, the append-only
# event journal that is the loop's entire memory between ticks.
#
#   ./tests/test_journal.sh
#
# WHAT IS WORTH PINNING, and why these and not others:
#
#   APPEND-ONLY      the file's whole value is that nothing is ever rewritten.
#                    Asserted directly: an earlier line is byte-identical
#                    after later appends.
#   ONE LINE, ALWAYS a note containing quotes, backslashes and newlines must
#                    still be ONE parseable ndjson line. A note that broke the
#                    line format would corrupt every later read, and notes
#                    here can be long essays.
#   THE VOCABULARY   an unknown --event exits 2 rather than silently landing
#                    in the log, and every event the header documents is
#                    actually accepted. Documentation drifting from behaviour
#                    is a defect this test class exists to catch.
#   FIELD MERGING    active-runs merges fields across repeated run_started
#                    lines, latest non-null winning. A run journalled twice,
#                    the second time without --host, must not read as
#                    UNREACHABLE just because a reader took only the last line.
#   EXIT CODES       0 / 1 / 2 are a documented interface the orchestrator
#                    branches on, so every one of them gets a test.
#
# NO NETWORK, NO REPO WRITES. Every invocation runs against a scratch journal
# via RL_JOURNAL, under a mktemp dir removed on exit. The real journal.sh is
# invoked in place rather than copied - a copy goes stale silently - and the
# final assertion checks the real registry/journal.ndjson is untouched.
#
# Exit codes: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
J="$REPO/bin/journal.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/journal-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

REAL_JOURNAL="$REPO/registry/journal.ndjson"
REAL_JOURNAL_MD5="$(md5of "$REAL_JOURNAL" 2>/dev/null || echo absent)"

export RL_JOURNAL="$WORK/journal.ndjson"

# Read one field out of a JSON line. `null` for a null, `MISSING` for a key
# the schema should have had and does not.
field() {
    python3 -c '
import json, sys
o = json.loads(sys.argv[1])
v = o.get(sys.argv[2], "MISSING")
print("null" if v is None else v)' "$1" "$2"
}

reset_journal() { rm -f "$RL_JOURNAL"; }

# ---------------------------------------------------------------------------
# append
# ---------------------------------------------------------------------------
echo "== append writes one parseable line =="
reset_journal
out="$("$J" append --event note --note 'bootstrap' 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "exits 0"; else bad "exits 0 (got $rc: $out)"; fi
if [[ "$(wc -l < "$RL_JOURNAL" | tr -d ' ')" == "1" ]]; then ok "writes exactly one line"; else
    bad "writes exactly one line"; fi
line="$(tail -n 1 "$RL_JOURNAL")"
if [[ "$(field "$line" event)" == "note" ]]; then ok "round-trips --event"; else
    bad "round-trips --event"; fi
if [[ "$(field "$line" note)" == "bootstrap" ]]; then ok "round-trips --note"; else
    bad "round-trips --note"; fi

echo
echo "== the schema is a fixed key set, missing fields null =="
# THE ONE ASSERTION IN THIS FILE THAT IS ALLOWED TO MOVE BETWEEN GENERATIONS,
# and it must move: its subject IS the key set, so a task that adds a field
# necessarily changes it. The value of pinning it anyway is that a field
# added to build_json_line and forgotten in the header, or vice versa, is
# caught here rather than by a reader of a null column.
keys="$(python3 -c 'import json,sys; print(" ".join(sorted(json.loads(sys.argv[1]))))' "$line")"
expected_keys="branch commit event expect_results held_by host hypothesis_id note remote_log result_glob run_id screen_session ts variant"
if [[ "$keys" == "$expected_keys" ]]; then ok "every documented key is present"; else
    bad "every documented key is present (got: $keys)"; fi
if [[ "$(field "$line" run_id)" == "null" ]]; then ok "an unsupplied field is null, not absent"; else
    bad "an unsupplied field is null, not absent"; fi

echo
echo "== ts and commit are auto-filled =="
if [[ "$(field "$line" ts)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    ok "ts is UTC ISO8601"; else bad "ts is UTC ISO8601 (got $(field "$line" ts))"; fi
head_commit="$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null)"
# A brand-new repo with no commits yet has no HEAD to default to, and that is
# null rather than empty-string, so the comparison accounts for both.
want="${head_commit:-null}"
if [[ "$(field "$line" commit)" == "$want" ]]; then ok "commit defaults to HEAD"; else
    bad "commit defaults to HEAD (got $(field "$line" commit), want $want)"; fi
"$J" append --event note --commit deadbee --note x >/dev/null 2>&1
if [[ "$(field "$(tail -n 1 "$RL_JOURNAL")" commit)" == "deadbee" ]]; then
    ok "an explicit --commit is not overwritten"; else
    bad "an explicit --commit is not overwritten"; fi

echo
echo "== nothing already written is ever rewritten =="
reset_journal
"$J" append --event note --note 'first' >/dev/null 2>&1
first="$(head -n 1 "$RL_JOURNAL")"
for i in 1 2 3; do "$J" append --event note --note "later $i" >/dev/null 2>&1; done
if [[ "$(head -n 1 "$RL_JOURNAL")" == "$first" ]]; then
    ok "the first line is byte-identical after three more appends"; else
    bad "the first line is byte-identical after three more appends"; fi
if [[ "$(wc -l < "$RL_JOURNAL" | tr -d ' ')" == "4" ]]; then ok "appends accumulate"; else
    bad "appends accumulate"; fi

echo
echo "== a hostile note stays one parseable line =="
reset_journal
nasty='he said "quote" and \ backslash
and a newline, plus a tab	and *** a section marker'
"$J" append --event note --note "$nasty" >/dev/null 2>&1
if [[ "$(wc -l < "$RL_JOURNAL" | tr -d ' ')" == "1" ]]; then ok "a note with a newline is still one line"; else
    bad "a note with a newline is still one line"; fi
line="$(tail -n 1 "$RL_JOURNAL")"
if python3 -c 'import json,sys; json.loads(sys.argv[1])' "$line" 2>/dev/null; then
    ok "quotes and backslashes stay parseable"; else bad "quotes and backslashes stay parseable"; fi
if [[ "$(field "$line" note)" == *'he said "quote" and \ backslash'* ]]; then
    ok "the note survives verbatim up to the newline"; else
    bad "the note survives verbatim up to the newline"; fi

echo
echo "== the join key into the registry =="
reset_journal
"$J" append --event eval_completed --hypothesis-id H5 --run-id r1 >/dev/null 2>&1
if [[ "$(field "$(tail -n 1 "$RL_JOURNAL")" hypothesis_id)" == "H5" ]]; then
    ok "--hypothesis-id is stored"; else bad "--hypothesis-id is stored"; fi

# ---------------------------------------------------------------------------
# The liveness pointer. Three fields, written by the stage that dispatches a
# DETACHED remote probe, because that work outlives the tick that started it
# and `hypothesis.sh drift` otherwise reads it as an orphan.
#
# The assertions that matter are the REFUSALS. A half-written pointer is worse
# than none: drift would find a host with no session to ask about, or not find
# it at all and go on calling a live sweep dead. So all four travel together.
# ---------------------------------------------------------------------------
echo
echo "== the liveness pointer for a detached probe =="
reset_journal
"$J" append --event note --hypothesis-id H12 --host worker-3 \
    --screen-session h12probe --remote-log /tmp/rl/h12_probe/run.log \
    --note "phase 1 dispatched detached" >/dev/null 2>&1
line="$(tail -n 1 "$RL_JOURNAL")"
if [[ "$(field "$line" screen_session)" == "h12probe" ]]; then
    ok "--screen-session is stored"; else bad "--screen-session is stored"; fi
if [[ "$(field "$line" remote_log)" == "/tmp/rl/h12_probe/run.log" ]]; then
    ok "--remote-log is stored"; else bad "--remote-log is stored"; fi
if [[ "$(field "$line" host)" == "worker-3" && "$(field "$line" hypothesis_id)" == "H12" ]]; then
    ok "and it carries the host and the join key alongside them"; else
    bad "and it carries the host and the join key alongside them"; fi
# Each refusal names the ONE part that is missing, so a caller is not left
# guessing which of four it forgot.
n_before="$(wc -l < "$RL_JOURNAL" | tr -d ' ')"
out="$("$J" append --event note --hypothesis-id H12 --host worker-3 \
    --screen-session h12probe 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "a pointer with no --remote-log is a usage error"; else
    bad "a pointer with no --remote-log is a usage error (got rc=$rc)"; fi
if [[ "$out" == *"--remote-log"* ]]; then ok "and the refusal names the missing part"; else
    bad "and the refusal names the missing part (got: $out)"; fi
out="$("$J" append --event note --hypothesis-id H12 \
    --screen-session h12probe --remote-log /tmp/r.log 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "a pointer with no --host is a usage error"; else
    bad "a pointer with no --host is a usage error (got rc=$rc)"; fi
out="$("$J" append --event note --host worker-3 \
    --screen-session h12probe --remote-log /tmp/r.log 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "a pointer with no --hypothesis-id is a usage error"; else
    bad "a pointer with no --hypothesis-id is a usage error (got rc=$rc)"; fi
out="$("$J" append --event note --hypothesis-id H12 --host worker-3 \
    --remote-log /tmp/r.log 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "a --remote-log with no --screen-session is a usage error"; else
    bad "a --remote-log with no --screen-session is a usage error (got rc=$rc)"; fi
if [[ "$(wc -l < "$RL_JOURNAL" | tr -d ' ')" == "$n_before" ]]; then
    ok "and not one refused pointer reached the journal"; else
    bad "and not one refused pointer reached the journal"; fi
# THE CONTROL: an ordinary entry naming a host is not a pointer and must stay
# legal, or every run_started line in the journal becomes a usage error.
out="$("$J" append --event run_started --run-id r9 --host box-a 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "CONTROL: --host on its own is still an ordinary field"; else
    bad "CONTROL: --host on its own is still an ordinary field (got rc=$rc)"; fi
if [[ "$(field "$(tail -n 1 "$RL_JOURNAL")" screen_session)" == "null" ]]; then
    ok "CONTROL: and its pointer fields read null rather than absent"; else
    bad "CONTROL: and its pointer fields read null rather than absent"; fi

# ---------------------------------------------------------------------------
# The COMPLETION CLAUSE and the HOLD. Two fields and one field, sitting on top
# of the pointer, because a session listing alone cannot tell a detached probe
# that FINISHED from one whose agent died holding it - both leave no session -
# and because a tick's own wake line is newer than every record that tick
# dispatches a subagent into.
#
# The assertions that matter are again the REFUSALS, and there is one more
# reason for them here than there was for the pointer: the glob is SPLICED INTO
# A REMOTE COMMAND. A quote or a semicolon in it is not a bad journal entry, it
# is a broken payload on a shared machine.
# ---------------------------------------------------------------------------
echo
echo "== the completion clause on the pointer =="
reset_journal
"$J" append --event note --hypothesis-id H12 --host worker-3 \
    --screen-session h12probe --remote-log /tmp/rl/h12_probe/run.log \
    --result-glob '/tmp/rl/h12_probe/cells/*/manifest.json' \
    --expect-results 60 --note "phase 1, 54 cases" >/dev/null 2>&1
line="$(tail -n 1 "$RL_JOURNAL")"
if [[ "$(field "$line" result_glob)" == "/tmp/rl/h12_probe/cells/*/manifest.json" ]]; then
    ok "--result-glob is stored verbatim"; else bad "--result-glob is stored verbatim"; fi
if [[ "$(field "$line" expect_results)" == "60" ]]; then
    ok "--expect-results is stored"; else bad "--expect-results is stored"; fi
# An INTEGER in the json, not a string: drift compares it against a count the
# machine computed, and "9" > "60" is true of strings and false of numbers.
if python3 -c 'import json,sys; o=json.loads(sys.argv[1]); sys.exit(0 if isinstance(o["expect_results"], int) else 1)' "$line"; then
    ok "and it is a JSON number, not a string"; else
    bad "and it is a JSON number, not a string"; fi

n_before="$(wc -l < "$RL_JOURNAL" | tr -d ' ')"
# The message is left in a GLOBAL rather than printed: `x="$(helper ...)"` would
# run the helper in a subshell, swallow its own ok/FAIL line into the captured
# text and lose the PASS count it incremented - an assertion that reports
# nothing and, worse, one whose follow-up needle then matches its own label.
CLAUSE_OUT=""
clause_rc() {   # clause_rc <label> <args...> - expects rc 2; message in CLAUSE_OUT
    local label="$1"; shift
    local rc
    CLAUSE_OUT="$("$J" append "$@" 2>&1)"; rc=$?
    if [[ $rc -eq 2 ]]; then ok "$label"; else bad "$label (got rc=$rc)"; fi
}
clause_rc "a --result-glob with no --expect-results is a usage error" \
    --event note --hypothesis-id H12 --host worker-3 --screen-session s \
    --remote-log /tmp/r.log --result-glob '/tmp/x/*/m.json'
if [[ "$CLAUSE_OUT" == *"missing: --expect-results"* ]]; then
    ok "and the refusal names the missing half"; else
    bad "and the refusal names the missing half (got: $CLAUSE_OUT)"; fi
clause_rc "an --expect-results with no --result-glob is a usage error" \
    --event note --hypothesis-id H12 --host worker-3 --screen-session s \
    --remote-log /tmp/r.log --expect-results 60
# The clause sits ON a pointer. Half a pointer under it is the same defect one
# level down: drift reads the count in the same payload as the session list
# and cannot ask for one without the other.
clause_rc "a clause with no --screen-session is a usage error" \
    --event note --hypothesis-id H12 --host worker-3 --remote-log /tmp/r.log \
    --result-glob '/tmp/x/*/m.json' --expect-results 60
if [[ "$CLAUSE_OUT" == *"--screen-session"* ]]; then
    ok "and names the missing part of the pointer"; else
    bad "and names the missing part of the pointer (got: $CLAUSE_OUT)"; fi
clause_rc "a clause with no --host is a usage error" \
    --event note --hypothesis-id H12 --screen-session s --remote-log /tmp/r.log \
    --result-glob '/tmp/x/*/m.json' --expect-results 60
# A RELATIVE pattern would expand against the remote home directory and count
# the wrong thing without ever saying so.
clause_rc "a relative --result-glob is a usage error" \
    --event note --hypothesis-id H12 --host worker-3 --screen-session s \
    --remote-log /tmp/r.log --result-glob 'cells/*/manifest.json' --expect-results 60
if [[ "$CLAUSE_OUT" == *"absolute"* ]]; then ok "and says it must be absolute"; else
    bad "and says it must be absolute (got: $CLAUSE_OUT)"; fi
# THE INJECTION SURFACE. Each of these would end the single-quoted string the
# glob is spliced into, or break the word, or redirect.
for hostile in "/tmp/x'/*.json" '/tmp/x;rm -rf ~/*.json' '/tmp/x $(id)/*.json' \
               '/tmp/x`id`/*.json' '/tmp/two words/*.json' '/tmp/x>out/*.json'; do
    rc=0
    "$J" append --event note --hypothesis-id H12 --host worker-3 --screen-session s \
        --remote-log /tmp/r.log --result-glob "$hostile" --expect-results 60 \
        >/dev/null 2>&1 || rc=$?
    if [[ $rc -eq 2 ]]; then ok "a --result-glob carrying [${hostile:5:12}] is refused"; else
        bad "a --result-glob carrying [$hostile] is refused (got rc=$rc)"; fi
done
# 0 would make an empty result directory read as a finished sweep - the
# empty-match-reads-as-absent defect wearing the opposite sign.
clause_rc "--expect-results 0 is a usage error" \
    --event note --hypothesis-id H12 --host worker-3 --screen-session s \
    --remote-log /tmp/r.log --result-glob '/tmp/x/*/m.json' --expect-results 0
if [[ "$CLAUSE_OUT" == *"positive integer"* ]]; then ok "and says it must be positive"; else
    bad "and says it must be positive (got: $CLAUSE_OUT)"; fi
clause_rc "a negative --expect-results is a usage error" \
    --event note --hypothesis-id H12 --host worker-3 --screen-session s \
    --remote-log /tmp/r.log --result-glob '/tmp/x/*/m.json' --expect-results -3
clause_rc "a non-numeric --expect-results is a usage error" \
    --event note --hypothesis-id H12 --host worker-3 --screen-session s \
    --remote-log /tmp/r.log --result-glob '/tmp/x/*/m.json' --expect-results sixty
if [[ "$(wc -l < "$RL_JOURNAL" | tr -d ' ')" == "$n_before" ]]; then
    ok "and not one refused clause reached the journal"; else
    bad "and not one refused clause reached the journal"; fi
# THE CONTROL, and it is the whole reason the clause is OPTIONAL: work with no
# output artefacts has no completion evidence, and a compulsory glob would only
# invite a fabricated one. A four-field pointer with no clause must stay legal.
out="$("$J" append --event note --hypothesis-id H13 --host worker-4 \
    --screen-session h13probe --remote-log /tmp/r.log --note "no clause" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "CONTROL: a four-field pointer with no clause is still legal"; else
    bad "CONTROL: a four-field pointer with no clause is still legal (rc=$rc: $out)"; fi
line="$(tail -n 1 "$RL_JOURNAL")"
if [[ "$(field "$line" result_glob)" == "null" && "$(field "$line" expect_results)" == "null" ]]; then
    ok "CONTROL: and its clause fields read null rather than absent"; else
    bad "CONTROL: and its clause fields read null rather than absent"; fi

echo
echo "== the hold: an agent of the tick in progress owns this record =="
"$J" append --event note --hypothesis-id T7 --held-by do-task \
    --note "dispatched to discharge it" >/dev/null 2>&1
line="$(tail -n 1 "$RL_JOURNAL")"
if [[ "$(field "$line" held_by)" == "do-task" ]]; then
    ok "--held-by is stored"; else bad "--held-by is stored"; fi
# A hold naming no record protects nothing.
out="$("$J" append --event note --held-by do-task --note "who?" 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "--held-by with no --hypothesis-id is a usage error"; else
    bad "--held-by with no --hypothesis-id is a usage error (got rc=$rc)"; fi
if [[ "$out" == *"--hypothesis-id"* ]]; then ok "and the refusal names what is missing"; else
    bad "and the refusal names what is missing (got: $out)"; fi
out="$("$J" append --event note --hypothesis-id T7 --held-by '  ' --note "x" 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "a whitespace --held-by is a usage error"; else
    bad "a whitespace --held-by is a usage error (got rc=$rc)"; fi
# DELIBERATELY NOT a closed vocabulary, unlike --event: refusing an unfamiliar
# stage name would cost a live agent's record its protection, which is the exact
# damage the hold exists to prevent, reintroduced by the validator.
out="$("$J" append --event note --hypothesis-id T7 --held-by some-future-stage \
    --note "x" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "an unfamiliar stage name is accepted, not refused"; else
    bad "an unfamiliar stage name is accepted, not refused (rc=$rc: $out)"; fi
# A hold needs no pointer: the stage may be working entirely on this machine.
out="$("$J" append --event note --hypothesis-id T7 --held-by probe-hypothesis \
    --note "local probe" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "CONTROL: a hold needs no host, session or log"; else
    bad "CONTROL: a hold needs no host, session or log (rc=$rc: $out)"; fi

# ---------------------------------------------------------------------------
# The event vocabulary. Documented and implemented must be the same set: an
# event in EVENTS but absent from the header is invisible to every agent that
# reads --help to find one.
# ---------------------------------------------------------------------------
echo
echo "== the documented vocabulary is the implemented vocabulary =="
documented="$("$J" --help | awk '/^Event vocabulary/,/^Schema/' |
    grep -E '^  [a-z_]+ ' | awk '{print $1}' | sort | tr '\n' ' ')"
implemented="$(awk '/^EVENTS=\(/,/\)$/' "$J" |
    sed -e 's/^EVENTS=(//' -e 's/)$//' | tr -s ' \n' '\n' |
    grep -E '^[a-z_]+$' | sort | tr '\n' ' ')"
if [[ -n "$documented" && "$documented" == "$implemented" ]]; then
    ok "--help documents exactly the events the code accepts"
else
    bad "--help documents exactly the events the code accepts"
    printf '       documented: %s\n       implemented: %s\n' "$documented" "$implemented"
fi

reset_journal
rejected=""
for ev in $documented; do
    "$J" append --event "$ev" --note "vocab check" >/dev/null 2>&1 || rejected="$rejected $ev"
done
if [[ -z "$rejected" ]]; then ok "every documented event is accepted"; else
    bad "documented but rejected:$rejected"; fi

echo
echo "== append's error branches =="
reset_journal
out="$("$J" append --note 'no event' 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "a missing --event exits 2"; else bad "a missing --event exits 2 (got $rc)"; fi
if [[ "$out" == *"--event is required"* ]]; then ok "and says --event is required"; else
    bad "and says --event is required"; fi

out="$("$J" append --event run_exploded --note x 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "an unknown event exits 2"; else bad "an unknown event exits 2 (got $rc)"; fi
if [[ "$out" == *"unknown event 'run_exploded'"* ]]; then ok "and names the event it refused"; else
    bad "and names the event it refused"; fi
if [[ ! -s "$RL_JOURNAL" ]]; then ok "and writes nothing"; else bad "and writes nothing"; fi

out="$("$J" append --event note --wat x 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "an unknown flag exits 2"; else bad "an unknown flag exits 2 (got $rc)"; fi
if [[ "$out" == *"unknown argument: --wat"* ]]; then ok "and names the flag"; else
    bad "and names the flag"; fi

# ---------------------------------------------------------------------------
# last
# ---------------------------------------------------------------------------
echo
echo "== last returns the most recent matching entry =="
reset_journal
"$J" append --event run_started --run-id old --note first >/dev/null 2>&1
"$J" append --event note        --run-id noise           >/dev/null 2>&1
"$J" append --event run_started --run-id new  --note last >/dev/null 2>&1
out="$("$J" last --event run_started --json 2>/dev/null)"; rc=$?
if [[ $rc -eq 0 ]]; then ok "exits 0 on a match"; else bad "exits 0 on a match (got $rc)"; fi
if [[ "$(field "$out" run_id)" == "new" ]]; then ok "returns the newest, not the first"; else
    bad "returns the newest, not the first"; fi

human="$("$J" last --event run_started 2>/dev/null)"
if [[ "$human" == *"run_id: new"* ]]; then ok "the human format prints key: value"; else
    bad "the human format prints key: value"; fi
if [[ "$human" == *"variant: -"* ]]; then ok "and renders a null field as -"; else
    bad "and renders a null field as -"; fi

echo
echo "== last's error branches =="
out="$("$J" last --event run_died 2>&1)"; rc=$?
if [[ $rc -eq 1 ]]; then ok "no match exits 1"; else bad "no match exits 1 (got $rc)"; fi
if [[ "$out" == *"no entries for event 'run_died'"* ]]; then ok "and says so"; else
    bad "and says so"; fi
out="$("$J" last --event run_died --json 2>/dev/null)"; rc=$?
if [[ $rc -eq 1 && "$out" == "null" ]]; then ok "no match with --json prints null and exits 1"; else
    bad "no match with --json prints null and exits 1 (rc=$rc, out=$out)"; fi
out="$("$J" last --json 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "a missing --event exits 2"; else bad "a missing --event exits 2 (got $rc)"; fi
out="$("$J" last --event nonsense 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "an unknown event exits 2"; else bad "an unknown event exits 2 (got $rc)"; fi
reset_journal
out="$("$J" last --event note --json 2>/dev/null)"; rc=$?
if [[ $rc -eq 1 && "$out" == "null" ]]; then ok "an absent journal exits 1"; else
    bad "an absent journal exits 1 (rc=$rc)"; fi

# ---------------------------------------------------------------------------
# tail
# ---------------------------------------------------------------------------
echo
echo "== tail =="
reset_journal
for i in $(seq 1 15); do "$J" append --event note --note "entry $i" >/dev/null 2>&1; done
n="$("$J" tail --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
if [[ "$n" == "10" ]]; then ok "defaults to 10 entries"; else bad "defaults to 10 entries (got $n)"; fi
n="$("$J" tail -n 3 --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
if [[ "$n" == "3" ]]; then ok "-n limits the count"; else bad "-n limits the count (got $n)"; fi
newest="$("$J" tail -n 3 --json 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["note"])')"
if [[ "$newest" == "entry 15" ]]; then ok "--json puts the newest last"; else
    bad "--json puts the newest last (got $newest)"; fi
n="$("$J" tail -n 5 --compact 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$n" == "6" ]]; then ok "--compact is one line per entry plus a header"; else
    bad "--compact is one line per entry plus a header (got $n)"; fi
if "$J" tail -n 5 --compact 2>/dev/null | head -n 1 | grep -qE '^TS +EVENT'; then
    ok "--compact prints a column header"; else bad "--compact prints a column header"; fi

echo
echo "== tail's degenerate inputs =="
out="$("$J" tail -n 0 2>/dev/null)"; rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then ok "-n 0 prints nothing and exits 0"; else
    bad "-n 0 prints nothing and exits 0 (rc=$rc)"; fi
reset_journal
out="$("$J" tail 2>/dev/null)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"journal is empty"* ]]; then ok "an absent journal is empty, not an error"; else
    bad "an absent journal is empty, not an error (rc=$rc)"; fi
out="$("$J" tail --json 2>/dev/null)"
if [[ "$out" == "[]" ]]; then ok "an absent journal is [] in --json"; else
    bad "an absent journal is [] in --json (got $out)"; fi

echo
echo "== a malformed line is survivable, not fatal =="
reset_journal
"$J" append --event note --note 'good one' >/dev/null 2>&1
printf 'this is not json\n' >> "$RL_JOURNAL"
"$J" append --event note --note 'good two' >/dev/null 2>&1
out="$("$J" tail 2>/dev/null)"; rc=$?
err="$("$J" tail 2>&1 >/dev/null)"
if [[ $rc -eq 0 ]]; then ok "still exits 0"; else bad "still exits 0 (got $rc)"; fi
if [[ "$out" == *"good one"* && "$out" == *"good two"* ]]; then
    ok "the readable entries either side still render"; else
    bad "the readable entries either side still render"; fi
if [[ "$err" == *"skipped 1 unparseable line"* ]]; then
    ok "the skip is reported on stderr, not swallowed"; else
    bad "the skip is reported on stderr, not swallowed"; fi

echo
echo "== the stanza renderer =="
reset_journal
long="$(python3 -c 'print("filler words to make this note long. " * 90 + "TAILTOKEN")')"
"$J" append --event note --note "$long" >/dev/null 2>&1
if "$J" tail -n 1 2>/dev/null | grep -qF 'TAILTOKEN'; then
    ok "nothing is dropped: the end of a long note is printed"; else
    bad "nothing is dropped: the end of a long note is printed"; fi
if "$J" tail -n 1 --compact 2>/dev/null | grep -qF 'TAILTOKEN'; then
    bad "--compact truncates the note"; else ok "--compact truncates the note"; fi
widest="$("$J" tail -n 1 --width 60 2>/dev/null | awk '{ if (length($0) > m) m = length($0) } END { print m+0 }')"
if [[ "$widest" -le 60 ]]; then ok "--width bounds the wrapped output"; else
    bad "--width bounds the wrapped output (widest line $widest)"; fi

reset_journal
"$J" append --event note --note '*** WHY THIS MATTERS: the body of the section.' >/dev/null 2>&1
out="$("$J" tail -n 1 2>/dev/null)"
if grep -qx '  WHY THIS MATTERS' <<< "$out"; then
    ok "an ALL-CAPS clause is lifted onto its own line"; else
    bad "an ALL-CAPS clause is lifted onto its own line"; fi
reset_journal
"$J" append --event note --note '*** CROSS-CASE WARNING and it is the most important thing: body.' >/dev/null 2>&1
out="$("$J" tail -n 1 2>/dev/null)"
if grep -qE '^  CROSS-CASE WARNING and it is' <<< "$out"; then
    ok "a clause with lower case in it is left as prose"; else
    bad "a clause with lower case in it is left as prose"; fi

echo
echo "== piped output is plain text =="
reset_journal
"$J" append --event run_died --run-id r --note 'a red event' >/dev/null 2>&1
if "$J" tail 2>/dev/null | grep -q $'\033'; then
    bad "no ANSI escapes when stdout is not a terminal"; else
    ok "no ANSI escapes when stdout is not a terminal"; fi
if diff -q <("$J" tail --no-colour 2>/dev/null) <("$J" tail 2>/dev/null) >/dev/null 2>&1; then
    ok "--no-colour is accepted and changes nothing when piped"; else
    bad "--no-colour is accepted and changes nothing when piped"; fi

# ---------------------------------------------------------------------------
# active-runs
# ---------------------------------------------------------------------------
echo
echo "== active-runs =="
reset_journal
"$J" append --event run_started --run-id alpha --variant v1 --host box-a >/dev/null 2>&1
"$J" append --event run_started --run-id beta  --variant v2 --host box-b >/dev/null 2>&1
"$J" append --event run_completed --run-id alpha >/dev/null 2>&1
out="$("$J" active-runs --json 2>/dev/null)"; rc=$?
ids="$(python3 -c 'import json,sys; print(",".join(r["run_id"] for r in json.loads(sys.argv[1])))' "$out")"
if [[ $rc -eq 0 ]]; then ok "exits 0 while a run is active"; else bad "exits 0 while a run is active (got $rc)"; fi
if [[ "$ids" == "beta" ]]; then ok "a completed run drops out, an open one stays"; else
    bad "a completed run drops out, an open one stays (got '$ids')"; fi

for term in run_died run_stopped; do
    reset_journal
    "$J" append --event run_started --run-id gamma --host box-c >/dev/null 2>&1
    "$J" append --event "$term" --run-id gamma >/dev/null 2>&1
    out="$("$J" active-runs --json 2>/dev/null)"; rc=$?
    if [[ "$out" == "[]" && $rc -eq 1 ]]; then ok "$term is terminal too"; else
        bad "$term is terminal too (out=$out rc=$rc)"; fi
done

reset_journal
"$J" append --event run_started --run-id delta --host box-d >/dev/null 2>&1
"$J" append --event run_died --run-id someone_else >/dev/null 2>&1
out="$("$J" active-runs --json 2>/dev/null)"
if [[ "$out" == *'"delta"'* ]]; then
    ok "another run's terminal event does not terminate this one"; else
    bad "another run's terminal event does not terminate this one"; fi

echo
echo "== active-runs merges fields across repeated run_started lines =="
reset_journal
# The shape that motivated this: journalled once bare, then again with the
# metadata that was missing the first time.
"$J" append --event run_started --run-id run-042 >/dev/null 2>&1
"$J" append --event run_started --run-id run-042 --variant v9 --host box-e \
    --branch feature/loop-pass-1 --hypothesis-id H9 >/dev/null 2>&1
out="$("$J" active-runs --json 2>/dev/null)"
merged="$(python3 -c '
import json, sys
r = json.loads(sys.argv[1])[0]
print("%s|%s|%s|%s" % (r["host"], r["variant"], r["branch"], r["hypothesis_id"]))' "$out")"
if [[ "$merged" == "box-e|v9|feature/loop-pass-1|H9" ]]; then
    ok "a later non-null field wins over an earlier null"; else
    bad "a later non-null field wins over an earlier null (got $merged)"; fi
started="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0]["started"])' "$out")"
first_ts="$(field "$(head -n 1 "$RL_JOURNAL")" ts)"
if [[ "$started" == "$first_ts" ]]; then ok "started is the FIRST run_started, not the latest"; else
    bad "started is the FIRST run_started, not the latest"; fi

reset_journal
"$J" append --event run_started --run-id lonely >/dev/null 2>&1
out="$("$J" active-runs --json 2>/dev/null)"
nulls="$(python3 -c '
import json, sys
r = json.loads(sys.argv[1])[0]
print(all(r[k] is None for k in ("variant", "branch", "host", "hypothesis_id")))' "$out")"
if [[ "$nulls" == "True" ]]; then ok "unknown fields are present and null, not absent"; else
    bad "unknown fields are present and null, not absent"; fi
if "$J" active-runs 2>/dev/null | grep -qE '^lonely +- +- +- '; then
    ok "the human table renders a null field as -"; else
    bad "the human table renders a null field as -"; fi

echo
echo "== active-runs' empty cases =="
reset_journal
"$J" append --event note --note 'no runs here' >/dev/null 2>&1
out="$("$J" active-runs 2>/dev/null)"; rc=$?
if [[ $rc -eq 1 ]]; then ok "no active runs exits 1"; else bad "no active runs exits 1 (got $rc)"; fi
if [[ "$out" == *"(no active runs)"* ]]; then ok "and says so"; else bad "and says so"; fi
reset_journal
out="$("$J" active-runs --json 2>/dev/null)"; rc=$?
if [[ $rc -eq 1 && "$out" == "[]" ]]; then ok "an absent journal is [] and exits 1"; else
    bad "an absent journal is [] and exits 1 (rc=$rc, out=$out)"; fi

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
echo
echo "== the subcommand dispatcher =="
out="$("$J" 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "no arguments exits 2"; else bad "no arguments exits 2 (got $rc)"; fi
out="$("$J" frobnicate 2>&1)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "an unknown subcommand exits 2"; else
    bad "an unknown subcommand exits 2 (got $rc)"; fi
if [[ "$out" == *"unknown subcommand: frobnicate"* ]]; then ok "and names it"; else bad "and names it"; fi

# ---------------------------------------------------------------------------
# The guard on this whole file: none of the above touched the real journal.
# ---------------------------------------------------------------------------
echo
echo "== the real journal was never written to =="
now_md5="$(md5of "$REAL_JOURNAL" 2>/dev/null || echo absent)"
if [[ "$now_md5" == "$REAL_JOURNAL_MD5" ]]; then
    ok "registry/journal.ndjson is byte-identical to before the run"; else
    bad "registry/journal.ndjson CHANGED during the test run"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
