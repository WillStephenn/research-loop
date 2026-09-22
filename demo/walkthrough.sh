#!/usr/bin/env bash
# A narrated pass through the whole lifecycle, against a scratch registry.
#
# Nothing here touches the repo's own registry: everything is built in a
# temporary directory and thrown away at the end, so the demo can be run as
# many times as you like and always starts from nothing.
#
# Run it with no arguments. Add --keep to leave the scratch directory behind
# so you can poke at the JSON records it built.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/research-loop-demo.XXXXXX")"
cleanup() { [[ $KEEP -eq 1 ]] || rm -rf "$SCRATCH"; }
trap cleanup EXIT

export RL_REGISTRY="$SCRATCH/registry"
export RL_JOURNAL="$SCRATCH/registry/journal.ndjson"
export RL_GOAL="$SCRATCH/NORTH_STAR.md"
export RL_CONFIG="$ROOT/config/loop.conf"
mkdir -p "$RL_REGISTRY" "$SCRATCH/evals"

HYP="$ROOT/bin/hypothesis.sh"
JOURNAL="$ROOT/bin/journal.sh"
GOAL="$ROOT/bin/north_star.sh"

if [[ ! -f "$ROOT/examples/NORTH_STAR.md" ]]; then
    echo "examples/NORTH_STAR.md is missing; the ratchet section cannot run" >&2
    exit 1
fi
cp "$ROOT/examples/NORTH_STAR.md" "$RL_GOAL"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
run() { printf '\n\033[2m$ %s\033[0m\n' "$*"; eval "$@"; }

# A command we EXPECT to be refused. The demo is not decoration: the refusals
# are the product, so each one is run for real and its exit code checked.
refused() {
    local want="$1"; shift
    printf '\n\033[2m$ %s\033[0m\n' "$*"
    local out rc=0
    out="$(eval "$@" 2>&1)" || rc=$?
    # Refusals print their usage after the reason. The reason is the point, so
    # only the first few lines are shown here.
    printf '%s\n' "$out" | head -4 | sed 's/^/   /'
    if [[ $rc -eq $want ]]; then
        printf '   \033[32mrefused with exit %d, as intended\033[0m\n' "$rc"
    else
        printf '   \033[31mexpected exit %d, got %d\033[0m\n' "$want" "$rc"
        exit 1
    fi
}

say "1. A hypothesis must carry a falsifier"
note "The registry refuses a conjecture that cannot be killed. This is the"
note "single most valuable constraint in the tool: without it, 'hypotheses'"
note "silently become a to-do list and nothing is ever ruled out."
refused 2 "'$HYP' new --family representation --test-cost probe \
    --targets median_error --claim 'a better estimator would help'"

say "2. Register two real hypotheses"
run "'$HYP' new --family representation --test-cost probe \
    --targets median_error,frac_improved \
    --provenance demo/evaluate.py:47 \
    --claim 'averaging the samples beats taking the first one' \
    --falsifier 'median_error under the mean variant is not below the baseline'"
run "'$HYP' new --family evaluation-methodology --test-cost probe \
    --targets frac_improved \
    --provenance demo/evaluate.py:72 \
    --claim 'a variant can improve median_error while improving fewer cases' \
    --falsifier 'no variant scores better on median_error and worse on frac_improved than the median variant'"

say "3. A dependency makes one hypothesis gate the other"
note "H2 asks whether the headline number can mislead. H1 asks whether the"
note "simplest change works at all. Ranking runs unmet dependencies first, so"
note "the lemma is settled before the thing that leans on it."
run "'$HYP' new --family optimisation --test-cost run \
    --targets median_error --depends-on H1 \
    --provenance demo/evaluate.py:47 \
    --claim 'trimming the extremes beats a plain average' \
    --falsifier 'the trimmed variant does not lower median_error against the mean variant'"
run "'$HYP' next"

say "4. Measure, then record the verdict"
run "python3 '$HERE/evaluate.py' --variant mean --seed 1 --out '$SCRATCH/evals/mean/final_eval.json'"
run "python3 '$HERE/evaluate.py' --variant overfit --seed 1 --out '$SCRATCH/evals/overfit/final_eval.json'"
note "A record enters testing before it can be settled. There is no path from"
note "open straight to a verdict: something has to have decided it."
run "'$HYP' set-state H1 testing --evidence 'mean variant probe dispatched, seed 1'"
run "'$HYP' set-state H2 testing --evidence 'overfit variant probe dispatched, seed 1'"
note "H1 confirmed: the mean variant lowers median error against the baseline."
run "'$HYP' set-state H1 confirmed \
    --evidence 'mean variant, seed 1, 400 cases: median_error 0.318 against a baseline of 0.855' \
    --metric-delta 'median_error: 0.855 -> 0.318'"
note "H2 confirmed too: the overfit variant is the counterexample it predicted."
run "'$HYP' set-state H2 confirmed \
    --evidence 'overfit variant improves 0.5525 of cases against the median variant 0.6675, at comparable median_error' \
    --metric-delta 'frac_improved: 0.6675 -> 0.5525'"

say "5. falsified is terminal"
note "A dead conjecture stays dead. A loop that can quietly revive one will"
note "cycle forever, so resurrection is refused by exit code rather than by an"
note "agent remembering the rule."
run "'$HYP' set-state H3 testing --evidence 'trimmed variant probe dispatched, seed 1'"
run "'$HYP' set-state H3 falsified \
    --evidence 'trimmed 0.3175 against mean 0.3181: inside the noise, no effect'"
refused 2 "'$HYP' set-state H3 open --evidence 'worth another look'"

say "6. The goal file, and whether it has been met"
note "Two evals of ONE run, in one directory, on one pinned eval set. The"
note "seed is the eval set and must match: two evals on different data are"
note "not consecutive evals of anything. Only the step differs."
run "'$GOAL' current"
E1="$SCRATCH/evals/trimmed/eval_step_0070.json"
E2="$SCRATCH/evals/trimmed/final_eval.json"
run "python3 '$HERE/evaluate.py' --variant trimmed --seed 1 --step 70 --out '$E1'"
run "python3 '$HERE/evaluate.py' --variant trimmed --seed 1 --step 100 --out '$E2'"
run "'$GOAL' check --eval '$E1' --eval '$E2'"

say "7. Met, so the loop may raise its own bar"
note "Every moved threshold cites the measurement that sized it, and may not"
note "be set past the worse of the two. Dry run first: the ratchet decides"
note "and prints, and touches nothing without --apply."
run "'$GOAL' ratchet --threshold median_error=0.45 --threshold frac_worsened=0.22 \
    --threshold frac_improved=0.75 \
    --sizing median_error='the worse of the two measured ratios was 0.4397, so 0.45 sits just above it' \
    --sizing frac_worsened='the worse of the two was 0.2125, so 0.22 sits just above it' \
    --sizing frac_improved='the worse of the two was 0.7875, so 0.75 sits just below it' \
    --eval '$E1' --eval '$E2'"

say "8. It refuses to run ahead of the evidence"
note "A threshold may not be set stricter than the worse of the two"
note "measurements that triggered it. Ask for a bar the evidence has not"
note "cleared twice and the tool refuses, rather than accepting an optimistic"
note "target no run will ever meet."
refused 9 "'$GOAL' ratchet --threshold median_error=0.01 \
    --sizing median_error='0.01 is well under both measurements' \
    --eval '$E1' --eval '$E2'"

say "9. And it refuses a bar that got easier"
note "This is the whole point. The loop cannot declare victory by lowering"
note "what victory means."
refused 6 "'$GOAL' ratchet --threshold median_error=9.0 \
    --sizing median_error='9.0 is a softer bar than the current one' \
    --eval '$E1' --eval '$E2'"

say "9. What the loop leaves behind"
run "'$HYP' list"
run "'$JOURNAL' tail --compact -n 20"

say "Done"
if [[ $KEEP -eq 1 ]]; then
    note "scratch kept at $SCRATCH"
else
    note "scratch discarded. Re-run with --keep to inspect the records."
fi
