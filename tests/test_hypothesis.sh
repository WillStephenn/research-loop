#!/usr/bin/env bash
#
# test_hypothesis.sh - the registry's state machine and its refusals.
#
# Self-contained: run it, read PASS/FAIL. It writes only to a scratch
# directory via RL_REGISTRY and RL_JOURNAL and never touches a real registry.
#
#   ./tests/test_hypothesis.sh
#
# Exit codes: 0 = all assertions passed, 1 = at least one failed.
#
# The refusals are the point of this file. A registry that merely documents
# its rules enforces nothing, so almost every assertion here is a command that
# MUST fail, paired with a control that must succeed. A guard with no control
# beside it is indistinguishable from a tool that refuses everything.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HS="$ROOT/bin/hypothesis.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/hypothesis-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
export RL_REGISTRY="$WORK/registry"
export RL_JOURNAL="$WORK/registry/journal.ndjson"
mkdir -p "$RL_REGISTRY"

PASS=0; FAIL=0

# A provenance value that always validates, so tests which are not ABOUT
# provenance do not have to care what a valid one looks like. It must exist
# under the repo root; the script under test certainly does.
PROV="bin/hypothesis.sh"

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

section() { printf '\n%s\n' "$1"; }

# expect_rc <expected> <label> -- <command...>
expect_rc() {
    local want="$1" label="$2"; shift 3
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [[ $rc -eq $want ]]; then ok "$label"
    else bad "$label (wanted rc=$want, got $rc)"; printf '       %s\n' "$out" | head -3
    fi
}

# expect_contains <needle> <label> -- <command...>
expect_contains() {
    local needle="$1" label="$2"; shift 3
    local out
    out="$("$@" 2>&1)"
    if [[ "$out" == *"$needle"* ]]; then ok "$label"
    else bad "$label (no '$needle' in output)"; printf '       %s\n' "$out" | head -3
    fi
}

# expect_not_contains <needle> <label> -- <command...>
expect_not_contains() {
    local needle="$1" label="$2"; shift 3
    local out
    out="$("$@" 2>&1)"
    if [[ "$out" != *"$needle"* ]]; then ok "$label"
    else bad "$label (unexpected '$needle' in output)"
    fi
}

# new_hyp <family> <claim> [extra args...] -> prints the created id
new_hyp() {
    local family="$1" claim="$2"; shift 2
    "$HS" new --family "$family" --test-cost probe --targets median_error \
        --provenance "$PROV" --claim "$claim" \
        --falsifier "the measurement does not move" "$@" 2>&1 |
        grep -oE '\bH[0-9]+\b' | head -1
}

# ---------------------------------------------------------------------------
section "Creation: what the registry refuses to admit"
# ---------------------------------------------------------------------------

expect_rc 2 "a hypothesis with no falsifier is refused" -- \
    "$HS" new --family representation --test-cost probe --targets median_error \
        --provenance "$PROV" --claim "something would help"

expect_rc 2 "a hypothesis with no targets is refused" -- \
    "$HS" new --family representation --test-cost probe \
        --provenance "$PROV" --claim "x" --falsifier "y"

expect_rc 2 "an unknown target is refused" -- \
    "$HS" new --family representation --test-cost probe --targets not_a_metric \
        --provenance "$PROV" --claim "x" --falsifier "y"

expect_rc 2 "an unknown family is refused" -- \
    "$HS" new --family astrology --test-cost probe --targets median_error \
        --provenance "$PROV" --claim "x" --falsifier "y"

expect_rc 2 "an unknown test cost is refused" -- \
    "$HS" new --family representation --test-cost free --targets median_error \
        --provenance "$PROV" --claim "x" --falsifier "y"

# Provenance is a pointer somebody has to be able to follow. A pointer nobody
# can follow is prose with extra syntax.
expect_rc 2 "a provenance path that does not exist is refused" -- \
    "$HS" new --family representation --test-cost probe --targets median_error \
        --provenance "no/such/file.py" --claim "x" --falsifier "y"

expect_rc 2 "an absolute provenance path is refused" -- \
    "$HS" new --family representation --test-cost probe --targets median_error \
        --provenance "/etc/hosts" --claim "x" --falsifier "y"

expect_contains "H1" "the control creates H1" -- \
    "$HS" new --family representation --test-cost probe --targets median_error \
        --provenance "$PROV" --claim "averaging beats taking the first sample" \
        --falsifier "median_final_error under the mean variant is not below the baseline"

expect_contains "H2" "a :LINE suffix on a real path is accepted" -- \
    "$HS" new --family optimisation --test-cost run --targets median_error \
        --provenance "$PROV:1" --claim "trimming the extremes beats a plain average" \
        --falsifier "the trimmed variant does not lower median_final_error"

# ---------------------------------------------------------------------------
section "Tasks are a different kind of record, not a family"
# ---------------------------------------------------------------------------

expect_rc 2 "a task with no done condition is refused" -- \
    "$HS" new --kind task --family infrastructure --test-cost probe \
        --priority good-citizen --claim "tidy the scratch directories"

expect_rc 2 "a task carrying targets is refused" -- \
    "$HS" new --kind task --family infrastructure --test-cost probe \
        --priority good-citizen --targets median_error \
        --claim "x" --done-when "y"

expect_rc 0 "the control creates a task" -- \
    "$HS" new --kind task --family infrastructure --test-cost probe \
        --priority good-citizen --claim "tidy the scratch directories" \
        --done-when "no scratch directory older than a week survives"

# ---------------------------------------------------------------------------
section "The state machine"
# ---------------------------------------------------------------------------

# There is no path from open straight to a verdict. Something has to have
# decided it, and `testing` is where that is recorded.
expect_rc 2 "open -> confirmed is illegal" -- \
    "$HS" set-state H1 confirmed --evidence "it looked right"

expect_rc 2 "open -> falsified is illegal" -- \
    "$HS" set-state H1 falsified --evidence "it looked wrong"

expect_rc 0 "open -> testing is legal" -- \
    "$HS" set-state H1 testing --evidence "mean variant probe dispatched"

expect_rc 0 "testing -> confirmed is legal" -- \
    "$HS" set-state H1 confirmed \
        --evidence "median_final_error 0.318 against a baseline of 0.855" \
        --metric-delta "median_error: 0.855 -> 0.318"

expect_rc 2 "a confirmed record cannot be reopened" -- \
    "$HS" set-state H1 open --evidence "second thoughts"

expect_rc 2 "a verdict with no evidence is refused" -- \
    "$HS" set-state H2 testing

# ---------------------------------------------------------------------------
section "falsified is terminal"
# ---------------------------------------------------------------------------

"$HS" set-state H2 testing --evidence "trimmed variant probe dispatched" >/dev/null 2>&1
expect_rc 0 "testing -> falsified is legal" -- \
    "$HS" set-state H2 falsified --evidence "inside the noise, no effect"

# A loop that can quietly resurrect a dead idea will cycle forever, so this is
# enforced by exit code rather than by an agent remembering the rule.
expect_rc 2 "falsified -> open is refused" -- \
    "$HS" set-state H2 open --evidence "worth another look"

expect_rc 2 "falsified -> testing is refused" -- \
    "$HS" set-state H2 testing --evidence "one more attempt"

expect_rc 2 "falsified -> confirmed is refused" -- \
    "$HS" set-state H2 confirmed --evidence "actually it was right"

expect_contains "terminal" "the refusal says why" -- \
    "$HS" set-state H2 open --evidence "worth another look"

# ---------------------------------------------------------------------------
section "blocked, and the new-mechanism gate"
# ---------------------------------------------------------------------------

H3="$(new_hyp capacity "a wider readout would carry the signal")"
"$HS" set-state "$H3" blocked --blocked-on "the sizing probe has not run" \
    --evidence "cannot be decided until the probe lands" >/dev/null 2>&1

# Renewed enthusiasm is not a new mechanism. Without this gate a blocked
# record cycles back to open every time somebody rereads it.
expect_rc 2 "blocked -> open without a new mechanism is refused" -- \
    "$HS" set-state "$H3" open --evidence "worth another look now"

expect_rc 0 "blocked -> open with a new mechanism is legal" -- \
    "$HS" set-state "$H3" open --new-mechanism "the sizing probe landed and reports a width" \
        --evidence "the dependency is discharged"

# A kill needs no resurrection gate: evidence that settles a blocked record
# against itself is still evidence.
H4="$(new_hyp capacity "depth matters more than width")"
"$HS" set-state "$H4" blocked --blocked-on "no measurement yet" \
    --evidence "waiting" >/dev/null 2>&1
expect_rc 0 "blocked -> falsified is legal" -- \
    "$HS" set-state "$H4" falsified --evidence "the width ladder rules it out"

# ---------------------------------------------------------------------------
section "superseded claims no evidence"
# ---------------------------------------------------------------------------

H5="$(new_hyp representation "the same mechanism, stated differently")"
expect_rc 2 "superseded without naming the superseder is refused" -- \
    "$HS" set-state "$H5" superseded --evidence "H1 covers it"

expect_rc 0 "superseded with --superseded-by is legal" -- \
    "$HS" set-state "$H5" superseded --superseded-by H1 \
        --evidence "H1 confirmed; the two cannot both be the mechanism"

# ---------------------------------------------------------------------------
section "The attempt cap"
# ---------------------------------------------------------------------------

H6="$(new_hyp optimisation "a different schedule would help")"
# An interrupted attempt is explicitly NOT a spent one, so cycling through
# --interrupted-by would never reach the cap. Going out via blocked does.
for i in 1 2 3; do
    "$HS" set-state "$H6" testing --evidence "attempt $i dispatched" >/dev/null 2>&1
    "$HS" set-state "$H6" blocked --blocked-on "the measurement was inconclusive" \
        --evidence "attempt $i settled nothing" >/dev/null 2>&1
    "$HS" set-state "$H6" open --new-mechanism "a different schedule shape, attempt $((i+1))" \
        --evidence "retrying on a new mechanism" >/dev/null 2>&1
done

# A conjecture that survives three honest attempts without a verdict is not
# being tested, it is being protected.
expect_rc 2 "a fourth attempt without --override-cap is refused" -- \
    "$HS" set-state "$H6" testing --evidence "one more go"

expect_contains "cap" "the refusal names the cap" -- \
    "$HS" set-state "$H6" testing --evidence "one more go"

expect_rc 0 "--override-cap lets it through deliberately" -- \
    "$HS" set-state "$H6" testing --override-cap "last attempt, then retire it" \
        --evidence "deliberate override, recorded"

# ---------------------------------------------------------------------------
section "Dependencies and ranking"
# ---------------------------------------------------------------------------

H7="$(new_hyp representation "the lemma everything else leans on")"
H8="$(new_hyp representation "the thing that leans on it" --depends-on "$H7")"

expect_contains "$H7" "show reports the dependency on the dependant" -- \
    "$HS" show "$H8"

# Unmet dependencies rank first: test the lemma before its dependants, or you
# reduce a hard problem to an equally hard one and learn nothing.
out="$("$HS" next 2>&1)"
pos7="$(printf '%s\n' "$out" | grep -n "^$H7 " | head -1 | cut -d: -f1)"
pos8="$(printf '%s\n' "$out" | grep -n "^$H8 " | head -1 | cut -d: -f1)"
if [[ -n "$pos7" && -n "$pos8" && $pos7 -lt $pos8 ]]; then
    ok "next ranks the blocker above its dependant"
else
    bad "next ranks the blocker above its dependant (got $pos7 vs $pos8)"
fi

expect_contains "$H8" "next flags what the dependant is waiting on" -- \
    "$HS" next

# ---------------------------------------------------------------------------
section "Listing and filtering"
# ---------------------------------------------------------------------------

expect_contains "H1" "list shows a confirmed record" -- "$HS" list --state confirmed
expect_not_contains "H1" "list --state open excludes it" -- "$HS" list --state open
expect_contains "$H7" "list --family narrows correctly" -- "$HS" list --family representation
expect_not_contains "$H7" "list --kind task excludes hypotheses" -- "$HS" list --kind task
expect_contains "nothing matches" "list on an unknown state returns empty, not an error" -- \
    "$HS" list --state pondering

# ---------------------------------------------------------------------------
section "Unknown records and malformed input"
# ---------------------------------------------------------------------------

expect_rc 1 "show on an unknown id is refused" -- "$HS" show H9999
expect_rc 1 "set-state on an unknown id is refused" -- \
    "$HS" set-state H9999 testing --evidence "x"
expect_rc 2 "an unknown subcommand is refused" -- "$HS" frobnicate

# ---------------------------------------------------------------------------
section "The vocabularies really do come from config"
# ---------------------------------------------------------------------------

# If the closed vocabularies were still hardcoded, this section would pass for
# the wrong reason. A config naming nothing the shipped one names proves the
# generalisation is real.
ALT="$WORK/alt.conf"
cat > "$ALT" <<'EOF'
HYPOTHESIS_FAMILIES=(thermal acoustic)
TASK_FAMILIES=(chores)
TARGETS=(settling_time overshoot)
RATCHET_AXES=(settling_time:harder_is_lower overshoot:harder_is_lower)
TEST_COSTS=(probe run)
ATTEMPT_CAP=3
EOF

ALT_WORK="$WORK/alt"; mkdir -p "$ALT_WORK/registry"
expect_rc 0 "a record in a wholly different vocabulary is accepted" -- \
    env RL_CONFIG="$ALT" RL_REGISTRY="$ALT_WORK/registry" \
        RL_JOURNAL="$ALT_WORK/registry/journal.ndjson" \
        "$HS" new --family thermal --test-cost probe --targets settling_time \
            --provenance "$PROV" --claim "a shorter duty cycle settles faster" \
            --falsifier "settling_time does not fall"

expect_rc 2 "a family from the shipped config is refused under the alternative" -- \
    env RL_CONFIG="$ALT" RL_REGISTRY="$ALT_WORK/registry" \
        RL_JOURNAL="$ALT_WORK/registry/journal.ndjson" \
        "$HS" new --family representation --test-cost probe --targets settling_time \
            --provenance "$PROV" --claim "x" --falsifier "y"

expect_rc 2 "a target from the shipped config is refused under the alternative" -- \
    env RL_CONFIG="$ALT" RL_REGISTRY="$ALT_WORK/registry" \
        RL_JOURNAL="$ALT_WORK/registry/journal.ndjson" \
        "$HS" new --family thermal --test-cost probe --targets median_error \
            --provenance "$PROV" --claim "x" --falsifier "y"

# ---------------------------------------------------------------------------
section "Isolation"
# ---------------------------------------------------------------------------

if [[ -e "$ROOT/registry" ]]; then
    bad "the suite wrote a registry into the repo root"
else
    ok "the repo's own registry was never created"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
