#!/usr/bin/env bash
#
# test_north_star.sh - the ratchet's refusal ladder.
#
#   ./tests/test_north_star.sh
#
# WHY THIS EXISTS. north_star.sh is the only thing in this project allowed to
# write the goal file, and the whole safety argument for delegating that is
# "an agent cannot loosen the target, cannot raise it without evidence, and
# cannot change its shape". Those are claims about EXIT CODES, so they are
# worth exactly as much as the tests that fire them. Every refusal below is
# driven through the CLI against scratch fixtures, and each has a CONTROL:
# the same call with the defect removed must be ACCEPTED, or a script that
# refused everything would pass this file.
#
# The refusals pinned here: unmet-target updates (4), shape changes (5),
# non-monotonic updates (6), the human-owned floor (7), missing or unmeasured
# sizing (8), and a bar the evidence has not cleared twice (9). Inadmissible
# evidence (3) is pinned throughout the evidence section.
#
# NO NETWORK, NO REAL STATE. RL_GOAL and RL_JOURNAL point at a scratch tree
# for every call; the last assertion re-checks that the shipped example goal
# file and the real journal are byte-identical to how the run found them.
#
# THE FIXTURE'S THRESHOLDS ARE PINNED HERE, NOT INHERITED. Every ratchet
# fixture is derived from the shipped examples/NORTH_STAR.md so that the
# format the tool parses stays under test: the preamble, the anchor, the
# human-owned Definition of done block and the condition SHAPE all come from
# the real file, but its numeric thresholds are set by NS_BASE_* below and
# every version block the source carries is dropped. A fixture that instead
# read whichever version the shipped file has ratcheted to could only ever
# be tested against once: the day someone raises the example past NS_BASE_*,
# every proposal below written against those numbers would suddenly loosen
# the target, the monotonicity guard would fire before the guard actually
# under test was ever reached, and the whole file would read red for a
# reason unrelated to any of it. The "a future ratchet cannot re-red this
# suite" section below is what keeps that from happening: it builds the file
# a future ratchet would write and asserts the derived fixture is
# byte-identical regardless.
#
# GENERICITY. north_star.sh is not supposed to know how many axes there are
# or what they are called; everything it does is meant to come from
# RATCHET_AXES in config/loop.conf. Most of this file exercises the shipped
# three-axis config because that is what ships with the demo, but one
# section near the end runs the whole tool against a scratch two-axis config
# with different names to prove that claim rather than assume it.
#
# Exit codes: 0 = all assertions passed, 1 = at least one failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SUT="$REPO/bin/north_star.sh"
CONF="$REPO/config/loop.conf"
REAL_NS="$REPO/examples/NORTH_STAR.md"
REAL_JOURNAL="$REPO/registry/journal.ndjson"

# The file the fixtures are derived from, and the one the first section
# verifies. It is the shipped example unless RL_NS_TEST_SOURCE names another,
# which exists so the whole suite can be run end to end against a
# hypothetical future version of the file without anything touching the real
# one. Either way the real example is checksummed at the end and never
# written.
SRC_NS="${RL_NS_TEST_SOURCE:-$REAL_NS}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/northstar-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

expect_rc() {  # <want> <got> <label>
    if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (wanted exit $1, got $2)"; fi
}
expect_contains() {
    if [[ "$2" == *"$1"* ]]; then ok "$3"; else
        bad "$3 (missing '$1')"; printf '       %s\n' "${2//$'\n'/$'\n'       }"; fi
}
expect_not_contains() {
    if [[ "$2" != *"$1"* ]]; then ok "$3"; else bad "$3 (unexpectedly found '$1')"; fi
}

md5of() { md5 -q "$1" 2>/dev/null || md5sum "$1" | cut -d' ' -f1; }

REAL_NS_MD5_BEFORE="$(md5of "$REAL_NS")"
REAL_JOURNAL_MD5_BEFORE="$(md5of "$REAL_JOURNAL" 2>/dev/null || echo absent)"
SRC_NS_MD5_BEFORE="$(md5of "$SRC_NS")"

# --- Fixtures ----------------------------------------------------------------
# One registered eval artefact. Only the fields the tool reads are set;
# everything else a real run might write is left out deliberately, so a
# schema addition upstream cannot break this file.
make_eval() {  # <path> <median_initial> <median_final> <worsened> <improved> [mode] [seed]
    NS_T_PATH="$1" NS_T_MI="$2" NS_T_MF="$3" NS_T_W="$4" NS_T_I="$5" \
    NS_T_MODE="${6:-deterministic}" NS_T_SEED="${7:-42}" python3 - <<'PY'
import json, os
doc = {
    "mode": os.environ["NS_T_MODE"],
    "seed": int(os.environ["NS_T_SEED"]),
    "cases_requested": 256,
    "summary": {
        "n_cases": 256,
        "median_initial_error": float(os.environ["NS_T_MI"]),
        "median_final_error": float(os.environ["NS_T_MF"]),
        "frac_worsened": float(os.environ["NS_T_W"]),
        "frac_improved": float(os.environ["NS_T_I"]),
    },
}
with open(os.environ["NS_T_PATH"], "w") as fh:
    json.dump(doc, fh)
PY
}

drop_summary_key() {  # <path> <key>
    NS_T_PATH="$1" NS_T_KEY="$2" python3 - <<'PY'
import json, os
p = os.environ["NS_T_PATH"]
doc = json.load(open(p))
doc["summary"].pop(os.environ["NS_T_KEY"], None)
json.dump(doc, open(p, "w"))
PY
}

# The pinned baseline every ratchet fixture runs against. These match the
# shipped example's own v1, and they live HERE rather than being read out of
# whichever version the example has ratcheted to (see the header).
NS_BASE_MEDIAN=1.0
NS_BASE_WORSENED=0.25
NS_BASE_IMPROVED=0.25
NS_BASE_SINCE=2026-01-01
# The tool prints thresholds with %g, so expected strings are built the same
# way rather than transcribed: 1.0 renders as "x1", not "x1.0".
g() { printf '%g' "$1"; }

# One field of the active (first) target block of any goal file, so
# assertions about the shipped file name what that file actually says
# instead of what it said on the day they were written.
ns_active_field() {  # <file> <key>
    NS_T_SRC="$1" NS_T_KEY="$2" python3 - <<'PY'
import json, os
src = open(os.environ["NS_T_SRC"]).read().split("\n")
fence = "```json north-star-target"
i = next(k for k, ln in enumerate(src) if ln.strip() == fence)
j = next(k for k in range(i + 1, len(src)) if src[k].strip() == "```")
print(json.loads("\n".join(src[i + 1:j]))[os.environ["NS_T_KEY"]])
PY
}

# A scratch goal file: the source file's structure, the source file's
# condition SHAPE, this file's THRESHOLDS, and exactly one version.
# Optionally a doctored version is stacked on top of it. Injection is how a
# SHAPE CHANGE actually arrives: the tool builds a new version from the
# active one and so cannot change shape itself, only a hand-edit of the file
# can, and the next ratchet must refuse to build on it.
#
# Dropping the source's own versions is what makes this ratchet-proof. The
# versions region is exactly what lies between the insertion anchor and the
# next `## ` heading, which is where north_star.sh itself writes, so however
# many versions the real file accumulates, the fixture is the same one every
# time.
scratch_ns() {  # <dest> [python-dict-expression mutating a copy of the pinned v1] [source]
    NS_T_SRC="${3:-$SRC_NS}" NS_T_DEST="$1" NS_T_MUT="${2:-}" \
    NS_T_MED="$NS_BASE_MEDIAN" NS_T_W="$NS_BASE_WORSENED" \
    NS_T_I="$NS_BASE_IMPROVED" NS_T_SINCE="$NS_BASE_SINCE" python3 - <<'PY'
import json, os
src = open(os.environ["NS_T_SRC"]).read().split("\n")
fence = "```json north-star-target"

# The active block, for its SHAPE and its human-owned consecutive-evals count.
i = next(k for k, ln in enumerate(src) if ln.strip() == fence)
j = next(k for k in range(i + 1, len(src)) if src[k].strip() == "```")
active = json.loads("\n".join(src[i + 1:j]))
cond = active["conditions"]

v1 = {
    "version": 1,
    "applies_to": "loop_target",
    "active_since": os.environ["NS_T_SINCE"],
    "supersedes": None,
    "consecutive_evals": active["consecutive_evals"],
    "conditions": {
        "median_error": dict(cond["median_error"], multiplier=float(os.environ["NS_T_MED"])),
        "frac_worsened": dict(cond["frac_worsened"], threshold=float(os.environ["NS_T_W"])),
        "frac_improved": dict(cond["frac_improved"], threshold=float(os.environ["NS_T_I"])),
    },
    "sizing_evidence": {
        "median_error": "test fixture baseline, pinned in test_north_star.sh",
        "frac_worsened": "test fixture baseline, pinned in test_north_star.sh",
        "frac_improved": "test fixture baseline, pinned in test_north_star.sh",
    },
    "authorised_by": "test fixture",
    "met_evidence": None,
}

stack = [v1]
mut = os.environ["NS_T_MUT"]
if mut:
    v2 = json.loads(json.dumps(v1))
    v2["version"] = 2
    v2["supersedes"] = 1
    v2["active_since"] = "2026-01-15"
    exec(mut, {"v2": v2})
    stack.insert(0, v2)


def render(v):
    sup = "v%d" % v["supersedes"] if v["supersedes"] else "nothing"
    return ["", "#### v%d - active since %s, supersedes %s" % (v["version"], v["active_since"], sup),
            "", fence] + json.dumps(v, indent=2, ensure_ascii=False).split("\n") + ["```"]


anchor = next(k for k, ln in enumerate(src) if "north-star-versions:" in ln)
rest = next(k for k in range(anchor + 1, len(src)) if src[k].startswith("## "))
body = src[:anchor + 1] + [ln for v in stack for ln in render(v)] + [""] + src[rest:]
open(os.environ["NS_T_DEST"], "w").write("\n".join(body))
PY
}

# The file a future ratchet would leave behind: <src> plus one more version,
# strictly tighter on every axis. Proportional rather than a fixed step, so
# it stays a legal tightening whatever the source's numbers have become.
future_ns() {  # <src> <dest>
    NS_T_SRC="$1" NS_T_DEST="$2" python3 - <<'PY'
import json, os
src = open(os.environ["NS_T_SRC"]).read().split("\n")
fence = "```json north-star-target"
i = next(k for k, ln in enumerate(src) if ln.strip() == fence)
j = next(k for k in range(i + 1, len(src)) if src[k].strip() == "```")
active = json.loads("\n".join(src[i + 1:j]))

nxt = json.loads(json.dumps(active))
nxt["version"] = int(active["version"]) + 1
nxt["supersedes"] = int(active["version"])
nxt["active_since"] = "2026-12-25"
cond = nxt["conditions"]
cond["median_error"]["multiplier"] = round(float(cond["median_error"]["multiplier"]) / 2, 6)
cond["frac_worsened"]["threshold"] = round(float(cond["frac_worsened"]["threshold"]) / 2, 6)
imp = float(cond["frac_improved"]["threshold"])
cond["frac_improved"]["threshold"] = round(imp + (1.0 - imp) / 2, 6)

anchor = next(k for k, ln in enumerate(src) if "north-star-versions:" in ln)
block = ["", "#### v%d - active since %s, supersedes v%d" %
              (nxt["version"], nxt["active_since"], nxt["supersedes"]), "", fence]
block += json.dumps(nxt, indent=2, ensure_ascii=False).split("\n") + ["```"]
open(os.environ["NS_T_DEST"], "w").write("\n".join(src[:anchor + 1] + block + src[anchor + 1:]))
PY
}

# The met pair. The fixture's v1 is NS_BASE_*: median x1.0, worsened <= 0.25,
# improved >= 0.25, so both of these clear it; the WORST of the two is what
# any ratchet is bounded by.
#   demonstrated  median ratio 0.9   worsened 0.22   improved 0.28
MET_DIR="$WORK/met"; mkdir -p "$MET_DIR"
make_eval "$MET_DIR/eval_step_0050.json" 10.0 8.0 0.20 0.30
make_eval "$MET_DIR/eval_step_0100.json" 10.0 9.0 0.22 0.28
MET_A="$MET_DIR/eval_step_0050.json"
MET_B="$MET_DIR/eval_step_0100.json"

# An unmet pair: the second eval worsens too many cases.
UNMET_DIR="$WORK/unmet"; mkdir -p "$UNMET_DIR"
make_eval "$UNMET_DIR/eval_step_0050.json" 10.0 8.0 0.20 0.30
make_eval "$UNMET_DIR/eval_step_0100.json" 10.0 9.0 0.40 0.28
UNMET_A="$UNMET_DIR/eval_step_0050.json"
UNMET_B="$UNMET_DIR/eval_step_0100.json"

# A pair good enough that the Definition of done becomes the binding
# constraint rather than the demonstrated bound, otherwise exit 7 could never
# be reached without exit 9 firing first, and the test would not distinguish
# them.
#   demonstrated  median ratio 0.5   worsened 0.03   improved 0.6
GREAT_DIR="$WORK/great"; mkdir -p "$GREAT_DIR"
make_eval "$GREAT_DIR/eval_step_0050.json" 10.0 4.0 0.02 0.65
make_eval "$GREAT_DIR/eval_step_0100.json" 10.0 5.0 0.03 0.60
GREAT_A="$GREAT_DIR/eval_step_0050.json"
GREAT_B="$GREAT_DIR/eval_step_0100.json"

NS="$WORK/ns.md"
JOURNAL="$WORK/journal.ndjson"
: > "$JOURNAL"
export RL_JOURNAL="$JOURNAL"
export RL_CONFIG="$CONF"

run() {  # sets OUT and RC
    OUT="$(RL_GOAL="$NS" bash "$SUT" "$@" 2>&1)"; RC=$?
}

# ============================================================================
echo "== the shipped example goal file parses and verifies =="
# Not a scratch fixture: the file the demo actually ships must be well
# formed, or every assertion below is about a format nothing uses.
OUT="$(RL_GOAL="$SRC_NS" RL_CONFIG="$CONF" bash "$SUT" verify 2>&1)"; RC=$?
expect_rc 0 "$RC" "verify accepts the shipped example goal file"
expect_contains "shape unchanged" "$OUT" "and says what it checked"

# What `current` must report is the FIRST target block in the file, whichever
# version that has become, read out of the file rather than transcribed from
# whichever version was active the day this line was written.
ACTIVE_V="$(ns_active_field "$SRC_NS" version)"
ACTIVE_SINCE="$(ns_active_field "$SRC_NS" active_since)"
ACTIVE_CONSEC="$(ns_active_field "$SRC_NS" consecutive_evals)"
OUT="$(RL_GOAL="$SRC_NS" RL_CONFIG="$CONF" bash "$SUT" current 2>&1)"; RC=$?
expect_rc 0 "$RC" "current reads the active version"
expect_contains "v$ACTIVE_V (active since $ACTIVE_SINCE)" "$OUT" \
    "naming whichever version the file's FIRST block declares"
expect_contains "$ACTIVE_CONSEC consecutive" "$OUT" "and carries the human-owned eval count"

scratch_ns "$NS"

echo
echo "== a future ratchet cannot re-red this suite =="
# The fixtures below are derived from the shipped file, and if this section
# did not exist they would inherit its ACTIVE THRESHOLDS too: the day the
# example is ratcheted forward, every proposal here written against
# NS_BASE_* would suddenly loosen the target, the monotonicity guard would
# fire on a proposal shadowed by an unrelated change, and this file would go
# red for a reason having nothing to do with north_star.sh. Build the file a
# future ratchet would leave behind, and require the derived fixture to be
# unmoved by it.
FUTURE_NS="$WORK/ns_future.md"
future_ns "$SRC_NS" "$FUTURE_NS"
OUT="$(RL_GOAL="$FUTURE_NS" RL_CONFIG="$CONF" bash "$SUT" verify 2>&1)"; RC=$?
expect_rc 0 "$RC" "a synthetic tighter next version is itself a legal file"
OUT="$(RL_GOAL="$FUTURE_NS" RL_CONFIG="$CONF" bash "$SUT" current 2>&1)"; RC=$?
expect_contains "v$((ACTIVE_V + 1)) (active since 2026-12-25)" "$OUT" \
    "and it is what the tool would then read as active"

scratch_ns "$WORK/ns_from_shipped.md"
scratch_ns "$WORK/ns_from_future.md" "" "$FUTURE_NS"
if [[ "$(md5of "$WORK/ns_from_shipped.md")" == "$(md5of "$WORK/ns_from_future.md")" ]]; then
    ok "yet the scratch fixture derived from it is byte-identical"
else bad "yet the scratch fixture derived from it is byte-identical"; fi

OUT="$(RL_GOAL="$WORK/ns_from_future.md" RL_CONFIG="$CONF" bash "$SUT" current 2>&1)"; RC=$?
expect_rc 0 "$RC" "and still verifies"
expect_contains "median_error x$(g "$NS_BASE_MEDIAN"), frac_worsened <= $(g "$NS_BASE_WORSENED"), frac_improved >= $(g "$NS_BASE_IMPROVED")" \
    "$OUT" "at the thresholds this file pins, not the ones it was built from"

echo
echo "== the evidence must be the registered eval instrument =="
cp "$MET_A" "$WORK/met/probe_rescored.json"
run check --eval "$WORK/met/probe_rescored.json" --eval "$MET_B"
expect_rc 3 "$RC" "a probe artefact is refused"
expect_contains "never a probe re-scoring" "$OUT" "and the message says why"
rm -f "$WORK/met/probe_rescored.json"

STOCH_DIR="$WORK/stochastic"; mkdir -p "$STOCH_DIR"
make_eval "$STOCH_DIR/eval_step_0050.json" 10.0 8.0 0.20 0.30 stochastic
make_eval "$STOCH_DIR/eval_step_0100.json" 10.0 9.0 0.22 0.28 stochastic
run check --eval "$STOCH_DIR/eval_step_0050.json" \
          --eval "$STOCH_DIR/eval_step_0100.json"
expect_rc 3 "$RC" "an artefact recording a non-registered mode is refused"
expect_contains "registered evaluation mode only" "$OUT" "and names the reason"

MISS_DIR="$WORK/missing"; mkdir -p "$MISS_DIR"
make_eval "$MISS_DIR/eval_step_0050.json" 10.0 8.0 0.20 0.30
make_eval "$MISS_DIR/eval_step_0100.json" 10.0 9.0 0.22 0.28
drop_summary_key "$MISS_DIR/eval_step_0100.json" frac_improved
run check --eval "$MISS_DIR/eval_step_0050.json" \
          --eval "$MISS_DIR/eval_step_0100.json"
expect_rc 3 "$RC" "an artefact missing a scored summary key is refused"
expect_contains "frac_improved" "$OUT" "and names the key"

run check --eval "$MET_A"
expect_rc 2 "$RC" "one eval is a usage error, the target is defined at two"

run check --eval "$MET_A" --eval "$MET_A"
expect_rc 3 "$RC" "the same artefact twice is refused"
expect_contains "DISTINCT" "$OUT" "and says two distinct evals are required"

SEED_DIR="$WORK/seed"; mkdir -p "$SEED_DIR"
make_eval "$SEED_DIR/eval_step_0050.json" 10.0 8.0 0.20 0.30 deterministic 42
make_eval "$SEED_DIR/eval_step_0100.json" 10.0 9.0 0.22 0.28 deterministic 99999
run check --eval "$SEED_DIR/eval_step_0050.json" \
          --eval "$SEED_DIR/eval_step_0100.json"
expect_rc 3 "$RC" "two evals on different pinned seeds are refused"

CROSS_DIR="$WORK/cross"; mkdir -p "$CROSS_DIR"
make_eval "$CROSS_DIR/eval_step_0100.json" 10.0 9.0 0.22 0.28
run check --eval "$MET_A" --eval "$CROSS_DIR/eval_step_0100.json"
expect_rc 3 "$RC" "two evals from different runs are refused"

echo
echo "== the target is read off 'summary', never off an alternate variant =="
# An artefact may carry other scoring variants alongside the registered one;
# only one of them is the mode the run configured, and only that one may
# decide a target, an eval that could be graded on whichever variant scored
# best would make the goal a choice rather than a bar. The alternate below is
# doctored to pass every condition outright, so if it were ever consulted the
# verdict would move.
VARIANT_DIR="$WORK/variants"; mkdir -p "$VARIANT_DIR"
for ep in 0050 0100; do
    make_eval "$VARIANT_DIR/eval_step_${ep}.json" 10.0 9.5 0.40 0.05
    NS_T_PATH="$VARIANT_DIR/eval_step_${ep}.json" python3 - <<'PY'
import json, os
p = os.environ["NS_T_PATH"]
doc = json.load(open(p))
doc["variants"] = {
    "primary": {"is_registered": True, "summary": doc["summary"]},
    "alternate": {"is_registered": False,
                  "summary": {"n_cases": 256,
                              "median_initial_error": 10.0,
                              "median_final_error": 0.001,
                              "frac_worsened": 0.0,
                              "frac_improved": 1.0}},
}
json.dump(doc, open(p, "w"))
PY
done
run check --eval "$VARIANT_DIR/eval_step_0050.json" \
          --eval "$VARIANT_DIR/eval_step_0100.json"
expect_rc 1 "$RC" "an eval whose OTHER variant passes everything is still NOT MET"
expect_contains "NOT MET" "$OUT" "and says so"
expect_not_contains "0.001" "$OUT" "and never reports the alternate's median"

# The control, same shape: with the primary variant's own numbers met, the
# verdict flips, so the refusal above is about WHICH summary was read and not
# about the presence of a variants object at all.
CTRL_DIR="$WORK/variants_control"; mkdir -p "$CTRL_DIR"
cp "$MET_A" "$CTRL_DIR/eval_step_0050.json"
cp "$MET_B" "$CTRL_DIR/eval_step_0100.json"
run check --eval "$CTRL_DIR/eval_step_0050.json" \
          --eval "$CTRL_DIR/eval_step_0100.json"
CTRL_RC="$RC"; CTRL_OUT="$OUT"
for ep in 0050 0100; do
    NS_T_PATH="$CTRL_DIR/eval_step_${ep}.json" python3 - <<'PY'
import json, os
p = os.environ["NS_T_PATH"]
doc = json.load(open(p))
doc["variants"] = {"primary": {"is_registered": True, "summary": doc["summary"]}}
json.dump(doc, open(p, "w"))
PY
done
run check --eval "$CTRL_DIR/eval_step_0050.json" \
          --eval "$CTRL_DIR/eval_step_0100.json"
expect_rc "$CTRL_RC" "$RC" "adding a variants object does not change a verdict"
if [[ "$OUT" == "$CTRL_OUT" ]]; then
    ok "and the report is byte-identical with and without it"
else bad "and the report is byte-identical with and without it"; fi

echo
echo "== consecutive means consecutive in the run, not adjacent in the directory =="
GAP_DIR="$WORK/gap"; mkdir -p "$GAP_DIR"
for ep in 0050 0100 0150 0200; do
    make_eval "$GAP_DIR/eval_step_${ep}.json" 10.0 8.0 0.20 0.30
done
run check --eval "$GAP_DIR/eval_step_0050.json" \
          --eval "$GAP_DIR/eval_step_0150.json"
expect_rc 3 "$RC" "two evals two apart in the series are refused"

# The interesting one: delete the eval in between, and the survivors become
# ADJACENT in the directory listing. Only the stride check catches it.
rm -f "$GAP_DIR/eval_step_0150.json"
run check --eval "$GAP_DIR/eval_step_0100.json" \
          --eval "$GAP_DIR/eval_step_0200.json"
expect_rc 3 "$RC" "deleting the eval in between does not manufacture adjacency"
expect_contains "stride" "$OUT" "and the message names the stride it expected"

echo
echo "== check: met and not met =="
run check --eval "$MET_A" --eval "$MET_B"
expect_rc 0 "$RC" "a pair that clears every condition twice is MET"
expect_contains "MET - v1 holds at both evals" "$OUT" "and says so"

run check --eval "$UNMET_A" --eval "$UNMET_B"
expect_rc 1 "$RC" "a pair failing one condition at one eval is NOT MET"
expect_contains "NOT MET" "$OUT" "and says so"
expect_contains "FAIL frac_worsened" "$OUT" "naming the condition that failed"

run check --eval "$MET_A" --eval "$MET_B" --record
expect_rc 2 "$RC" "check refuses --record: check decides, met records"

# check reports the tight end of the band, because that is what the sizing
# decision needs and recomputing it by hand is where an off-by-one arrives.
run check --eval "$MET_A" --eval "$MET_B"
expect_contains "worst demonstrated" "$OUT" "check reports the demonstrated bound"
expect_contains "frac_worsened      0.22" "$OUT" "taking the WORSE of the two on a downward axis"
expect_contains "frac_improved      0.28" "$OUT" "and the worse of the two on an upward one"
expect_contains "median_error       0.9" "$OUT" "and the worse median ratio, not the raw value"

echo
echo "== met --record, and pending's re-verification =="
run pending
expect_rc 1 "$RC" "with no north_star_met, nothing is pending"

run met --eval "$MET_A" --eval "$MET_B" --record
expect_rc 0 "$RC" "met --record succeeds on a met pair"
expect_contains "recorded" "$OUT" "and says it recorded"
if grep -q '"event": "north_star_met"' "$JOURNAL"; then
    ok "a north_star_met line is in the journal"
else bad "a north_star_met line is in the journal"; fi
if grep -q 'north-star-evidence:' "$JOURNAL"; then
    ok "carrying the evidence token pending reads back"
else bad "carrying the evidence token pending reads back"; fi

run pending
expect_rc 0 "$RC" "pending re-verifies the claim from its own artefacts"
expect_contains "PENDING" "$OUT" "and reports it as due"

run met --eval "$UNMET_A" --eval "$UNMET_B" --record
expect_rc 1 "$RC" "met --record on an unmet pair does not record"
if [[ "$(grep -c '"event": "north_star_met"' "$JOURNAL")" == "1" ]]; then
    ok "and the journal still holds exactly one north_star_met"
else bad "and the journal still holds exactly one north_star_met"; fi

# A hand-written claim carries no token, so it cannot be re-verified, and an
# unverifiable claim is refused rather than believed.
HAND_JOURNAL="$WORK/hand.ndjson"
RL_JOURNAL="$HAND_JOURNAL" bash "$REPO/bin/journal.sh" append --event north_star_met \
    --note "trust me, the target is met" >/dev/null
OUT="$(RL_GOAL="$NS" RL_JOURNAL="$HAND_JOURNAL" RL_CONFIG="$CONF" bash "$SUT" pending 2>&1)"; RC=$?
expect_rc 3 "$RC" "a hand-written north_star_met with no evidence token is refused"
expect_contains "never trusted" "$OUT" "and says the claim is not taken on trust"

echo
echo "== ratchet: the three refusals the contract names =="

# (4) unmet target. The proposal itself is impeccable; the evidence is not.
run ratchet --eval "$UNMET_A" --eval "$UNMET_B" \
    --threshold frac_worsened=0.24 --sizing frac_worsened="worst of the two evals was 0.22"
expect_rc 4 "$RC" "an unmet target refuses the update (4)"
expect_contains "already been cleared" "$OUT" "and says a target is raised only from evidence"

# (6) non-monotonic, both ways round.
run ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold frac_worsened=0.30 --sizing frac_worsened="worst of the two evals was 0.22"
expect_rc 6 "$RC" "loosening a threshold is refused (6)"
expect_contains "may only tighten" "$OUT" "and says only tightening is allowed"

run ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold median_error="$NS_BASE_MEDIAN" --threshold frac_worsened="$NS_BASE_WORSENED" \
    --threshold frac_improved="$NS_BASE_IMPROVED"
expect_rc 6 "$RC" "a version that moves nothing is refused (6)"
expect_contains "no threshold moved" "$OUT" "and says at least one must tighten"

# (5) shape. The tool builds a new version from the active one and so cannot
# change shape itself; a shape change arrives by hand-editing the file, and
# the refusal is the tool declining to build on top of it.
SHAPE_NS="$WORK/ns_shape_ref.md"
scratch_ns "$SHAPE_NS" 'v2["conditions"]["median_error"]["reference"] = "median_baseline_error"'
OUT="$(RL_GOAL="$SHAPE_NS" RL_CONFIG="$CONF" bash "$SUT" ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold frac_worsened=0.24 --sizing frac_worsened="worst of the two evals was 0.22" 2>&1)"; RC=$?
expect_rc 5 "$RC" "a changed condition reference is refused (5)"
expect_contains "median_error" "$OUT" "and names the condition"

SHAPE_NS2="$WORK/ns_shape_extra.md"
scratch_ns "$SHAPE_NS2" 'v2["conditions"]["extra_metric"] = {"metric": "extra_metric", "op": ">=", "threshold": 0.1}'
OUT="$(RL_GOAL="$SHAPE_NS2" RL_CONFIG="$CONF" bash "$SUT" ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold frac_worsened=0.24 --sizing frac_worsened="worst of the two evals was 0.22" 2>&1)"; RC=$?
expect_rc 5 "$RC" "an added extra_metric condition is refused (5)"
expect_contains "expected exactly" "$OUT" "and says the condition set is closed"

SHAPE_NS3="$WORK/ns_shape_count.md"
scratch_ns "$SHAPE_NS3" 'v2["consecutive_evals"] = 1'
OUT="$(RL_GOAL="$SHAPE_NS3" RL_CONFIG="$CONF" bash "$SUT" ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold frac_worsened=0.24 --sizing frac_worsened="worst of the two evals was 0.22" 2>&1)"; RC=$?
expect_rc 5 "$RC" "moving the two-consecutive-evals count is refused (5)"
expect_contains "consecutive_evals" "$OUT" "and names the count"

SHAPE_NS4="$WORK/ns_shape_op.md"
scratch_ns "$SHAPE_NS4" 'v2["conditions"]["frac_improved"]["op"] = "<="'
OUT="$(RL_GOAL="$SHAPE_NS4" RL_CONFIG="$CONF" bash "$SUT" verify 2>&1)"; RC=$?
expect_rc 5 "$RC" "verify catches a flipped comparison operator too (5)"

echo
echo "== ratchet: the refusals the contract implies =="

# (7) the human-owned floor. 0.05 is the Definition of done's frac_worsened,
# and it is deliberately transcribed rather than read from the file: unlike
# the active target's thresholds, which the loop itself moves, the DoD
# changes only when a human edits it, and a human moving the floor SHOULD
# have to look at the two assertions that sit on it, along with the GREAT_*
# pair sized to reach it.
run ratchet --eval "$GREAT_A" --eval "$GREAT_B" \
    --threshold frac_worsened=0.03 --sizing frac_worsened="worst of the two evals was 0.03"
expect_rc 7 "$RC" "pushing the active target past the Definition of done is refused (7)"
expect_contains "human-owned" "$OUT" "and says whose bar it is"

# The boundary: reaching the DoD exactly is allowed. Without this the refusal
# above would be indistinguishable from an off-by-one.
run ratchet --eval "$GREAT_A" --eval "$GREAT_B" \
    --threshold frac_worsened=0.05 --sizing frac_worsened="worst of the two evals was 0.03"
expect_rc 0 "$RC" "reaching the Definition of done exactly is allowed"

# (9) a bar the evidence has not cleared twice.
run ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold frac_worsened=0.21 --sizing frac_worsened="worst of the two evals was 0.22"
expect_rc 9 "$RC" "a threshold stricter than the worst demonstrated is refused (9)"
expect_contains "cleared twice" "$OUT" "and says the bar must have been cleared twice"

run ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold median_error=0.85 --sizing median_error="worst demonstrated ratio was 0.9"
expect_rc 9 "$RC" "the same bound applies to the median multiplier (9)"

run ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold frac_improved=0.29 --sizing frac_improved="worst of the two evals was 0.28"
expect_rc 9 "$RC" "and to frac_improved, whose harder direction is upward (9)"

# (8) sizing evidence.
run ratchet --eval "$MET_A" --eval "$MET_B" --threshold frac_worsened=0.24
expect_rc 8 "$RC" "a moved threshold with no sizing citation is refused (8)"
expect_contains "no sizing citation" "$OUT" "and says which one"

run ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold frac_worsened=0.24 --sizing frac_worsened="it feels about right"
expect_rc 8 "$RC" "a citation containing no number is refused (8)"
expect_contains "no measured quantity" "$OUT" "and says it cites no measurement"

LONG="$(python3 -c 'print("worst of the two evals was 0.22 " * 20)')"
run ratchet --eval "$MET_A" --eval "$MET_B" --threshold frac_worsened=0.24 --sizing frac_worsened="$LONG"
expect_rc 8 "$RC" "an over-long citation is refused (8)"
expect_contains "over the 300 limit" "$OUT" "and names the limit"

run ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold frac_worsened=0.24 --sizing frac_worsened="worst of the two evals was 0.22" \
    --sizing frac_improved="0.28 was demonstrated"
expect_rc 8 "$RC" "a citation for a threshold that did not move is refused (8)"
expect_contains "did not move" "$OUT" "and says so"

echo
echo "== the control: a proposal with no defect is accepted =="
run ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold median_error=0.95 --threshold frac_worsened=0.24 --threshold frac_improved=0.26 \
    --sizing median_error="worst demonstrated ratio across the two evals was 0.9" \
    --sizing frac_worsened="worst of the two evals was 0.22 against a 0.25 bar" \
    --sizing frac_improved="worst of the two evals was 0.28 against a 0.25 bar"
expect_rc 0 "$RC" "a met, monotone, sized, demonstrated proposal is accepted"
expect_contains "dry run - nothing written" "$OUT" "and a ratchet without --apply writes nothing"
if [[ "$(md5of "$NS")" == "$(md5of <(scratch_ns /dev/stdout))" ]]; then
    ok "the scratch goal file is untouched by a dry run"
else bad "the scratch goal file is untouched by a dry run"; fi

echo
echo "== ratchet --apply: append-only and journalled =="
BEFORE="$WORK/ns_before.md"; cp "$NS" "$BEFORE"
run ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold median_error=0.95 --threshold frac_worsened=0.24 --threshold frac_improved=0.26 \
    --sizing median_error="worst demonstrated ratio across the two evals was 0.9" \
    --sizing frac_worsened="worst of the two evals was 0.22 against a 0.25 bar" \
    --sizing frac_improved="worst of the two evals was 0.28 against a 0.25 bar" \
    --active-since 2026-02-01 --apply
expect_rc 0 "$RC" "--apply succeeds"
expect_contains "wrote v2" "$OUT" "and says what it wrote"

run current
expect_contains "v2 (active since 2026-02-01)" "$OUT" "current now reads v2"
expect_contains "median_error x0.95" "$OUT" "with the new multiplier"

run versions
expect_contains "v1 (active since $NS_BASE_SINCE)" "$OUT" "versions still lists v1"

run verify
expect_rc 0 "$RC" "verify accepts the two-version file"

# Append-only, checked against the before-image rather than trusted: every
# line of the old file must still be present, in order, in the new one.
if python3 - "$BEFORE" "$NS" <<'PY'
import sys
before = open(sys.argv[1]).read().split("\n")
after = open(sys.argv[2]).read().split("\n")
i = 0
for line in before:
    while i < len(after) and after[i] != line:
        i += 1
    if i >= len(after):
        sys.exit(1)
    i += 1
sys.exit(0)
PY
then ok "every line of the previous file survives, in order"
else bad "every line of the previous file survives, in order"; fi

FENCES="$(grep -cxF '```json north-star-target' "$NS")"
if [[ "$FENCES" == "2" ]]; then
    ok "the file now holds exactly two target blocks"
else bad "the file now holds exactly two target blocks (found $FENCES)"; fi

if grep -q '"event": "north_star_updated"' "$JOURNAL"; then
    ok "a north_star_updated line is in the journal"
else bad "a north_star_updated line is in the journal"; fi
if grep -q "median_error 1 -> 0.95" "$JOURNAL"; then
    ok "and its note carries the delta"
else bad "and its note carries the delta"; fi

run pending
expect_rc 1 "$RC" "the north_star_met is now consumed, so nothing is pending"
expect_contains "consumed" "$OUT" "and says why"

echo
echo "== ratchet reports to stdout, not a side channel =="
# There is no notification transport in this tool: --apply's report is the
# accepted-deltas block already printed, and that is the only place a
# caller can learn what changed.
NS2="$WORK/ns_report.md"; scratch_ns "$NS2"
JOURNAL2="$WORK/journal2.ndjson"; : > "$JOURNAL2"
OUT="$(RL_GOAL="$NS2" RL_JOURNAL="$JOURNAL2" RL_CONFIG="$CONF" bash "$SUT" ratchet \
    --eval "$MET_A" --eval "$MET_B" --threshold frac_worsened=0.24 \
    --sizing frac_worsened="worst of the two evals was 0.22" --apply 2>&1)"; RC=$?
expect_rc 0 "$RC" "a ratchet with one moved axis applies"
expect_contains "accepted:" "$OUT" "and the accepted deltas are printed"
expect_contains "wrote v2" "$OUT" "and the write is confirmed on the same stream"

echo
echo "== the ladder composes: v2 cannot be loosened back toward v1 =="
OUT="$(RL_GOAL="$NS" RL_CONFIG="$CONF" bash "$SUT" ratchet --eval "$MET_A" --eval "$MET_B" \
    --threshold frac_worsened="$NS_BASE_WORSENED" \
    --sizing frac_worsened="$(g "$NS_BASE_WORSENED") was v1's bar" 2>&1)"; RC=$?
expect_rc 6 "$RC" "restoring v1's looser threshold on top of v2 is refused"

echo
echo "== usage =="
run
expect_rc 2 "$RC" "no subcommand exits 2"
run frobnicate
expect_rc 2 "$RC" "an unknown subcommand exits 2"
expect_contains "unknown subcommand" "$OUT" "and names it"
run current --nonsense
expect_rc 2 "$RC" "an unknown flag exits 2"

# ============================================================================
echo
echo "== genericity: the tool does not know how many axes there are =="
# Everything above exercises the shipped three-axis config because that is
# what the demo ships with. This section proves the claim in the header
# rather than assume it: a scratch config with a DIFFERENT NUMBER of axes and
# DIFFERENT NAMES, none of them "median_error", "frac_worsened" or
# "frac_improved", run through the exact same tool.
GCONF="$WORK/generic_loop.conf"
cat > "$GCONF" <<'EOF'
RATCHET_AXES=(
    accuracy:harder_is_higher
    latency_ms:harder_is_lower
)
EOF
GNS="$WORK/generic_ns.md"
cat > "$GNS" <<'EOF'
# Generic goal file

<!-- north-star-versions: newest first; new versions are inserted immediately below this line by bin/north_star.sh ratchet --apply, which is the only writer. Never insert one by hand. -->

#### v1 - active since 2026-01-01

```json north-star-target
{
  "version": 1,
  "applies_to": "loop_target",
  "active_since": "2026-01-01",
  "supersedes": null,
  "consecutive_evals": 2,
  "conditions": {
    "accuracy": {
      "metric": "accuracy",
      "op": ">=",
      "threshold": 0.5
    },
    "latency_ms": {
      "metric": "latency_ms",
      "op": "<=",
      "threshold": 100.0
    }
  },
  "sizing_evidence": {
    "accuracy": "human-set",
    "latency_ms": "human-set"
  },
  "authorised_by": "human, at project setup",
  "met_evidence": null
}
```

## Definition of done

```json north-star-dod
{
  "applies_to": "definition_of_done",
  "human_owned": true,
  "consecutive_evals": 2,
  "conditions": {}
}
```
EOF
GDIR="$WORK/generic_evals"; mkdir -p "$GDIR"
cat > "$GDIR/eval_step_0010.json" <<'EOF'
{"mode":"deterministic","seed":7,"cases_requested":50,"summary":{"n_cases":50,"accuracy":0.6,"latency_ms":80}}
EOF
cat > "$GDIR/eval_step_0020.json" <<'EOF'
{"mode":"deterministic","seed":7,"cases_requested":50,"summary":{"n_cases":50,"accuracy":0.55,"latency_ms":90}}
EOF
GJOURNAL="$WORK/generic_journal.ndjson"; : > "$GJOURNAL"

OUT="$(RL_GOAL="$GNS" RL_CONFIG="$GCONF" bash "$SUT" current 2>&1)"; RC=$?
expect_rc 0 "$RC" "current reads a two-axis config with unrelated names"
expect_contains "accuracy >= 0.5" "$OUT" "naming the first configured axis"
expect_contains "latency_ms <= 100" "$OUT" "and the second, in the order the config gave them"

OUT="$(RL_GOAL="$GNS" RL_CONFIG="$GCONF" bash "$SUT" check \
    --eval "$GDIR/eval_step_0010.json" --eval "$GDIR/eval_step_0020.json" 2>&1)"; RC=$?
expect_rc 0 "$RC" "a pair clearing both axes is MET, regardless of axis count"

OUT="$(RL_GOAL="$GNS" RL_JOURNAL="$GJOURNAL" RL_CONFIG="$GCONF" bash "$SUT" ratchet \
    --eval "$GDIR/eval_step_0010.json" --eval "$GDIR/eval_step_0020.json" \
    --threshold accuracy=0.55 --sizing accuracy="worst demonstrated was 0.55" \
    --apply 2>&1)"; RC=$?
expect_rc 0 "$RC" "a legal tighten applies against a config nothing above this section used"
expect_contains "wrote v2" "$OUT" "and writes a v2 exactly as the three-axis config does"

OUT="$(RL_GOAL="$GNS" RL_JOURNAL="$GJOURNAL" RL_CONFIG="$GCONF" bash "$SUT" ratchet \
    --eval "$GDIR/eval_step_0010.json" --eval "$GDIR/eval_step_0020.json" \
    --threshold accuracy=0.5 --sizing accuracy="loosen test" 2>&1)"; RC=$?
expect_rc 6 "$RC" "and the same monotonicity guard fires on this config too"

# --- one axis, to be sure "any number" is not secretly "two or three" -------
SCONF="$WORK/single_loop.conf"
cat > "$SCONF" <<'EOF'
RATCHET_AXES=(
    score:harder_is_higher
)
EOF
SNS="$WORK/single_ns.md"
cat > "$SNS" <<'EOF'
# Single-axis goal file

<!-- north-star-versions: newest first; new versions are inserted immediately below this line by bin/north_star.sh ratchet --apply, which is the only writer. Never insert one by hand. -->

#### v1 - active since 2026-01-01

```json north-star-target
{
  "version": 1,
  "applies_to": "loop_target",
  "active_since": "2026-01-01",
  "supersedes": null,
  "consecutive_evals": 2,
  "conditions": {
    "score": {
      "metric": "score",
      "op": ">=",
      "threshold": 0.5
    }
  },
  "sizing_evidence": {
    "score": "human-set"
  },
  "authorised_by": "human, at project setup",
  "met_evidence": null
}
```

## Definition of done

```json north-star-dod
{
  "applies_to": "definition_of_done",
  "human_owned": true,
  "consecutive_evals": 2,
  "conditions": {}
}
```
EOF
SDIR="$WORK/single_evals"; mkdir -p "$SDIR"
cat > "$SDIR/eval_step_0010.json" <<'EOF'
{"mode":"deterministic","seed":3,"cases_requested":20,"summary":{"n_cases":20,"score":0.7}}
EOF
cat > "$SDIR/eval_step_0020.json" <<'EOF'
{"mode":"deterministic","seed":3,"cases_requested":20,"summary":{"n_cases":20,"score":0.65}}
EOF
OUT="$(RL_GOAL="$SNS" RL_CONFIG="$SCONF" bash "$SUT" check \
    --eval "$SDIR/eval_step_0010.json" --eval "$SDIR/eval_step_0020.json" 2>&1)"; RC=$?
expect_rc 0 "$RC" "a single-axis config is met too, not just two or three"
expect_contains "MET - v1 holds at both evals" "$OUT" "and reports it the same way"

echo
echo "== the real files were never written to =="
if [[ "$(md5of "$REAL_NS")" == "$REAL_NS_MD5_BEFORE" ]]; then
    ok "examples/NORTH_STAR.md is byte-identical to before the run"
else bad "examples/NORTH_STAR.md is byte-identical to before the run"; fi
if [[ "$(md5of "$REAL_JOURNAL" 2>/dev/null || echo absent)" == "$REAL_JOURNAL_MD5_BEFORE" ]]; then
    ok "registry/journal.ndjson is byte-identical to before the run"
else bad "registry/journal.ndjson CHANGED during the test run"; fi
# RL_NS_TEST_SOURCE points the fixture derivation somewhere else; it must not
# turn this suite into a writer of that file either.
if [[ "$SRC_NS" != "$REAL_NS" ]]; then
    if [[ "$(md5of "$SRC_NS")" == "$SRC_NS_MD5_BEFORE" ]]; then
        ok "the RL_NS_TEST_SOURCE file is byte-identical to before the run"
    else bad "the RL_NS_TEST_SOURCE file is byte-identical to before the run"; fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
