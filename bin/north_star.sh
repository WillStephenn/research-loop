#!/usr/bin/env bash
#
# north_star.sh - the ratchet: read the active target from the goal file,
# decide mechanically whether it has been met, and raise it when it has.
#
# The goal file (NORTH_STAR.md by default) is the loop's only definition of
# success. Left immutable, a met target has nowhere to go: the loop either
# stops (so success behaves exactly like failure) or a human has to notice
# and hand-edit the file every time the bar is cleared. This script exists so
# a project can delegate exactly ONE change - the loop may RAISE its own
# target, never lower it - along a path narrow enough that "an agent which
# can redefine victory will eventually declare it" stays false.
#
# THIS SCRIPT IS THE ONLY WRITER. Hand-editing the goal file to achieve the
# same effect is what the rule forbids; every guard below is a refusal with
# its own exit code, so the guarantee is mechanical rather than remembered.
#
# GENERALISATION. Earlier versions of this idea hardcoded three named axes.
# This one does not: the set of axes the ratchet may move, and which
# direction is HARDER on each, are read from RATCHET_AXES in config/loop.conf
# (or $RL_CONFIG), as a list of `name:harder_is_lower` / `name:harder_is_higher`
# entries. The ratchet works with any number of axes - one, three, twelve -
# because nothing below branches on how many there are or what they are
# called; it only ever loops over whatever the config names. Adding an axis
# is a config change and a v1 written to match it, not a code change.
#
# WHAT MAY MOVE, AND WHAT MAY NOT
#
#   may move    the numeric threshold of each configured axis, and nothing
#               else about it
#   human-only  the condition SHAPE (metric, op, and reference if the axis is
#               a ratio) on every axis, the consecutive-evals count, any axis
#               not listed in RATCHET_AXES, the Definition of done, and the
#               file's own preamble
#
# THE FILE FORMAT. Versions live inside the goal file as fenced blocks with
# the info string `json north-star-target`, newest first, each under a
# `#### vN - active since ...` heading with a prose restatement. The FIRST
# such block is the active target. A new one is inserted immediately below
# the single-line `<!-- north-star-versions: ... -->` anchor, and nothing
# already in the file is ever rewritten - the write is re-read and compared
# before it is reported as done. The Definition of done has its own
# `json north-star-dod` block, which no path here writes: it exists so the
# ratchet can refuse to push a target past a bar the human set.
#
# THE SHAPE IS DEFINED BY V1, which a human wrote and no tool can write.
# Every later version must carry the same conditions, with the same metric,
# op and reference (if any) on each axis, and the same consecutive-evals
# count - which must also agree with the human-owned Definition of done
# block. Whether a given axis is a flat threshold or a ratio against another
# metric is read off v1's own JSON (a "reference" key present means ratio),
# not hardcoded per axis name: that is what lets an arbitrary set of axes
# share one mechanism. The only way to change shape is to hand-edit the file,
# and the next `ratchet` or `verify` refuses to build on it.
#
# THE EVIDENCE. "Met" is decided only against the REGISTERED EVAL INSTRUMENT:
# the process's own final_eval.json and eval_step_NNNN.json, with `mode`
# recorded as the configured registered value. A probe that re-scores the
# same artefact some other way is evidence about a hypothesis, never about
# this file. The two evals must be CONSECUTIVE in their own directory's
# series - adjacent after sorting, and separated by that series' modal
# stride, so deleting the eval in between cannot manufacture adjacency - and
# must carry the same pinned seed.
#
# THE REFUSAL LADDER (exit codes; each is a separate branch, and each should
# be pinned by a test):
#
#   0  met / accepted (dry run) / applied
#   1  not met - a clean negative, not an error
#   2  usage error, or a write that could not be completed
#   3  evidence inadmissible (not the registered instrument, wrong mode, not
#      consecutive, mismatched seed, missing summary keys), an unverifiable
#      north_star_met, or file drift that is not a shape change
#   4  the active target is NOT met at both evals
#   5  shape change - a condition added, removed or renamed, or its metric,
#      op or reference altered, or the consecutive-evals count moved
#   6  non-monotonic - some threshold got easier, or none got harder
#   7  past the Definition of done - a target may REACH the human-owned
#      floor, never overtake it
#   8  sizing evidence missing, over-long, or citing no measured quantity
#   9  stricter than demonstrated - a bar the evidence has not cleared twice
#
# 9 is what keeps the ratchet following the evidence instead of running
# ahead of it: a new threshold may sit anywhere between the worse of the two
# measurements and the old threshold, and nowhere else.
#
# REPORTING. `ratchet --apply` prints the old->new deltas and the sizing
# evidence to stdout and records a `north_star_updated` journal event with
# the same summary. There is no other channel: no email, no chat notification
# - if a project wants to be paged when its target moves, that is this
# script's stdout piped into whatever the project already uses for that.
#
# Usage:
#   ./north_star.sh current [--json]
#   ./north_star.sh versions [--json]
#   ./north_star.sh verify [--json]
#   ./north_star.sh check --eval <a.json> --eval <b.json> [--json]
#   ./north_star.sh met --eval <a.json> --eval <b.json> [--record] [--run-id ID]
#   ./north_star.sh pending [--json]
#   ./north_star.sh ratchet --threshold NAME=VALUE [--threshold NAME=VALUE ...] \
#       --eval <a.json> --eval <b.json> \
#       --sizing NAME="..." [--sizing NAME="..." ...] \
#       [--active-since YYYY-MM-DD] [--apply]
#
# Subcommands:
#   current   print the active target version (the first block in the file)
#   versions  every version, newest first, with its thresholds
#   verify    whole-file consistency: one active version, an unbroken supersedes
#             chain, unchanged shape, monotone history, the anchor and the DoD
#             block present. Non-zero on any violation - this is the drift check
#   check     score the named evals against the active target. Exit 0 met,
#             1 not met, 3 inadmissible evidence
#   met       `check`, and with --record append the north_star_met journal event
#             whose note carries the evidence in the form `pending` reads back
#   pending   is there an unconsumed north_star_met? Exit 0 yes, 1 no, 3 a
#             north_star_met exists whose evidence FAILS re-verification. The
#             claim is never trusted; it is re-scored from the artefacts it names
#   ratchet   validate a proposed next version, and with --apply write it and
#             journal it. Dry run by default
#
# Flags:
#   --eval PATH        a registered eval artefact; give it twice
#   --json             machine-readable output
#   --threshold N=V    proposed value for axis N, repeated once per axis that
#                       is to move. An axis named in RATCHET_AXES but not given
#                       here keeps its current value
#   --sizing N=TEXT     required for every axis named in a --threshold that
#                       actually moved the value; refused for one that did not.
#                       Must contain a number and stay under 300 characters
#   --active-since DATE the new version's date (default: today, UTC)
#   --apply             actually write. Without it, ratchet decides and
#                       prints, and touches nothing
#   --record            (met) append the journal event
#   --run-id ID         (met) tag that journal event with a run id
#
# Environment:
#   RL_GOAL      path to the goal file (default: NORTH_STAR.md at the repo
#                root). Tests point this at a scratch copy
#   RL_JOURNAL   path to journal.ndjson, as in journal.sh
#   RL_CONFIG    path to loop.conf (default: config/loop.conf at the repo
#                root), which is where RATCHET_AXES is read from

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

NS_FILE="${RL_GOAL:-$REPO_ROOT/NORTH_STAR.md}"
JOURNAL="${RL_JOURNAL:-$REPO_ROOT/registry/journal.ndjson}"
JOURNAL_SH="$HERE/journal.sh"

# Citations are refused past this length at input, so the bound is enforced
# where it is actionable: cite the measurement here and put the argument in
# the journal.
MAX_SIZING_CHARS=300

# Prints the file's leading comment block. Derived rather than a line range:
# a fixed `sed -n` range silently truncates the help text every time a flag is
# documented above the cut, and this file's header IS its documentation.
usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit "${1:-0}"
}

require_python() { command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 2; }; }

# Reads RATCHET_AXES out of config/loop.conf (or $RL_CONFIG), one
# "name:harder_is_lower" / "name:harder_is_higher" entry per line on stdout.
# Run in a subshell so sourcing the config's other arrays (HYPOTHESIS_FAMILIES
# and the rest) never leaks into this script's own variables.
load_axes() {
    local conf="${RL_CONFIG:-$REPO_ROOT/config/loop.conf}"
    if [[ ! -f "$conf" ]]; then
        echo "north_star: no such config file: $conf" >&2
        return 2
    fi
    (
        # shellcheck disable=SC1090
        source "$conf"
        if [[ -z "${RATCHET_AXES+x}" ]]; then
            echo "north_star: RATCHET_AXES is not defined in $conf" >&2
            exit 2
        fi
        if [[ ${#RATCHET_AXES[@]} -eq 0 ]]; then
            echo "north_star: RATCHET_AXES in $conf is empty - the ratchet needs at least one axis" >&2
            exit 2
        fi
        printf '%s\n' "${RATCHET_AXES[@]}"
    )
}

# ---------------------------------------------------------------------------
# The engine. One python program dispatched on NS_MODE, so the file parsing,
# the eval loading and the scoring exist exactly once: separate shell
# subcommands each with their own copy of "which block is active" is how the
# two halves of a rule drift apart.
#
# stdout is for a human (or JSON when asked). The machine-readable result is
# also written to $NS_RESULT when set, so the shell can build a journal note
# from the same numbers rather than re-parsing its own prose.
# ---------------------------------------------------------------------------
engine() {
    local axes
    axes="$(load_axes)" || exit $?
    NS_FILE="$NS_FILE" NS_JOURNAL="$JOURNAL" NS_REPO="$REPO_ROOT" \
    NS_MAX_SIZING="$MAX_SIZING_CHARS" NS_AXES="$axes" \
    python3 - <<'PY'
import json, os, re, sys
from datetime import datetime, timezone

MODE = os.environ.get("NS_MODE", "")
NS_FILE = os.environ["NS_FILE"]
JOURNAL = os.environ["NS_JOURNAL"]
REPO = os.environ["NS_REPO"]
AS_JSON = os.environ.get("NS_JSON", "0") == "1"
RESULT_PATH = os.environ.get("NS_RESULT", "")
MAX_SIZING = int(os.environ.get("NS_MAX_SIZING", "300"))

TARGET_FENCE = "```json north-star-target"
DOD_FENCE = "```json north-star-dod"
ANCHOR = "north-star-versions:"
APPLIES_TO = "loop_target"

out = []
result = {"mode": MODE, "ok": False}


def emit(line=""):
    out.append(line)


def finish(code, **extra):
    result.update(extra)
    result["exit"] = code
    if RESULT_PATH:
        with open(RESULT_PATH, "w") as fh:
            json.dump(result, fh)
    if AS_JSON:
        print(json.dumps(result, indent=2, default=str))
    else:
        print("\n".join(out))
    sys.exit(code)


def fail(code, msg, **extra):
    emit(f"refused ({code}): {msg}")
    finish(code, error=msg, **extra)


# --- axes, read from config rather than hardcoded ---------------------------
# Everything below loops over AXES; nothing branches on how many there are or
# what they are called. A fourth, fifth, twentieth axis is a config change and
# a v1 written to match it, never a code change.

AXES = []
HARDER_IS_LOWER = {}
for _line in os.environ.get("NS_AXES", "").splitlines():
    _line = _line.strip()
    if not _line:
        continue
    if ":" not in _line:
        fail(2, f"malformed RATCHET_AXES entry {_line!r} - expected "
                f"NAME:harder_is_lower or NAME:harder_is_higher")
    _name, _, _direction = _line.partition(":")
    _name = _name.strip()
    if _direction == "harder_is_lower":
        _harder_lower = True
    elif _direction == "harder_is_higher":
        _harder_lower = False
    else:
        fail(2, f"malformed RATCHET_AXES entry {_line!r} - direction must be "
                f"harder_is_lower or harder_is_higher, got {_direction!r}")
    if _name in HARDER_IS_LOWER:
        fail(2, f"RATCHET_AXES names {_name!r} twice")
    AXES.append(_name)
    HARDER_IS_LOWER[_name] = _harder_lower
AXES = tuple(AXES)

# The registered eval instrument, and nothing else, decides whether a target
# is met. final_eval.json is always last in its series; a step file's
# position is read off its own filename, never off its contents, so it cannot
# be spoofed by editing the artefact.
FINAL_EVAL = "final_eval.json"
STEP_EVAL_RE = re.compile(r"^eval_step_(\d+)\.json$")
REGISTERED_MODE = "deterministic"

# The token `met --record` writes into its journal note and `pending` reads
# back: a controlled format written and parsed by one tool, holding
# repo-relative paths, rather than prose parsed hopefully.
EVIDENCE_TOKEN = "north-star-evidence:"


# --- axis shape, read off the conditions themselves --------------------------

def axis_cond(version, axis):
    conds = version.get("conditions")
    if not isinstance(conds, dict):
        return None
    return conds.get(axis)


def is_ratio(cond):
    """A ratio axis compares its metric against another metric scaled by a
    multiplier (e.g. final <= 0.95 x initial); a flat axis compares it
    against a fixed threshold. Which one an axis is comes from whether v1's
    own condition carries a "reference" key - never from the axis's name -
    which is what lets this file stay silent on what any axis is called."""
    return isinstance(cond, dict) and "reference" in cond


def value_key(cond):
    return "multiplier" if is_ratio(cond) else "threshold"


def cond_value(version, axis):
    cond = axis_cond(version, axis)
    return float(cond[value_key(cond)])


def shape_keys(cond):
    return ("metric", "op", "reference") if is_ratio(cond) else ("metric", "op")


def shape_of(version):
    out = {}
    for axis in AXES:
        cond = axis_cond(version, axis) or {}
        out[axis] = tuple(cond.get(k) for k in shape_keys(cond))
    return out


def validate_shape(versions, dod):
    """The shape is whatever v1 says it is - a human wrote v1 and no tool can.
    Everything above it must match, and the consecutive-evals count must agree
    with the human-owned Definition of done. The only way to break any of this
    is to hand-edit the file, which is exactly the move being refused."""
    problems = []
    for v in versions:
        tag = f"v{v.get('version')}"
        conds = v.get("conditions")
        if not isinstance(conds, dict) or set(conds) != set(AXES):
            problems.append(f"{tag} has conditions {sorted(conds) if isinstance(conds, dict) else conds!r}, "
                            f"expected exactly {sorted(AXES)}")
            continue
        for axis in AXES:
            cond = conds[axis]
            for key in shape_keys(cond) + (value_key(cond),):
                if key not in cond:
                    problems.append(f"{tag} condition {axis} has no {key}")
        if v.get("applies_to") != APPLIES_TO:
            problems.append(f"{tag} applies_to={v.get('applies_to')!r}, expected {APPLIES_TO!r}")
    if problems:
        fail(5, "; ".join(problems))

    base = versions[-1]
    base_shape = shape_of(base)
    for v in versions[:-1]:
        for axis, sig in shape_of(v).items():
            if sig != base_shape[axis]:
                problems.append(f"v{v.get('version')} condition {axis} is "
                                f"{sig} against v{base.get('version')}'s {base_shape[axis]}")
    counts = {v.get("consecutive_evals") for v in versions}
    if len(counts) != 1:
        problems.append(f"versions disagree on consecutive_evals: {sorted(map(str, counts))}")
    elif counts != {dod.get("consecutive_evals")}:
        problems.append(f"consecutive_evals is {counts.pop()!r} against the human-owned "
                        f"Definition of done's {dod.get('consecutive_evals')!r}")
    if problems:
        fail(5, "; ".join(problems))


# --- the file ---------------------------------------------------------------

def read_file():
    try:
        with open(NS_FILE) as fh:
            return fh.read().split("\n")
    except OSError as exc:
        fail(2, f"cannot read {NS_FILE}: {exc}")


def parse_blocks(lines, fence):
    """Every fenced block carrying this info string, in file order, as
    (start, end, parsed). A malformed block is fatal rather than skipped:
    dropping one would silently change which version is active."""
    blocks = []
    i = 0
    while i < len(lines):
        if lines[i].strip() == fence:
            j = i + 1
            body = []
            while j < len(lines) and lines[j].strip() != "```":
                body.append(lines[j])
                j += 1
            if j >= len(lines):
                fail(3, f"unterminated `{fence}` block at line {i + 1} of {NS_FILE}")
            try:
                blocks.append((i, j, json.loads("\n".join(body))))
            except json.JSONDecodeError as exc:
                fail(3, f"malformed JSON in the block at line {i + 1} of {NS_FILE}: {exc}")
            i = j + 1
        else:
            i += 1
    return blocks


def load_targets():
    lines = read_file()
    blocks = parse_blocks(lines, TARGET_FENCE)
    if not blocks:
        fail(3, f"no `{TARGET_FENCE}` block found in {NS_FILE}")
    dod = parse_blocks(lines, DOD_FENCE)
    if len(dod) != 1:
        fail(3, f"expected exactly one `{DOD_FENCE}` block in {NS_FILE}, found {len(dod)}")
    versions = [b[2] for b in blocks]
    validate_shape(versions, dod[0][2])
    return lines, versions, dod[0][2]


def describe(version):
    parts = []
    for axis in AXES:
        cond = axis_cond(version, axis)
        val = cond_value(version, axis)
        if is_ratio(cond):
            parts.append(f"{axis} x{val:g}")
        else:
            symbol = cond.get("op", "<=")
            parts.append(f"{axis} {symbol} {val:g}")
    return (f"v{version.get('version')} (active since {version.get('active_since')}): "
            + ", ".join(parts)
            + f", at {version.get('consecutive_evals')} consecutive registered evals")


# --- the evidence -----------------------------------------------------------

def eval_order_key(name):
    name = os.path.basename(name)
    if name == FINAL_EVAL:
        return (1, 0)
    m = STEP_EVAL_RE.match(name)
    if m:
        return (0, int(m.group(1)))
    return None


def required_summary_keys(version):
    """The summary keys any eval artefact must carry to be scored against this
    version - collected from the version's own conditions rather than
    hardcoded, so an eval schema only needs to carry what the configured axes
    actually reference."""
    keys = set()
    for axis in AXES:
        cond = axis_cond(version, axis)
        if not cond:
            continue
        if cond.get("metric"):
            keys.add(cond["metric"])
        if is_ratio(cond) and cond.get("reference"):
            keys.add(cond["reference"])
    return tuple(sorted(keys))


def load_eval(path, required):
    if not os.path.exists(path):
        fail(3, f"no such eval artefact: {path}")
    key = eval_order_key(path)
    if key is None:
        fail(3, f"{os.path.basename(path)} is not the registered eval instrument - only "
                f"{FINAL_EVAL} and eval_step_NNNN.json decide whether the target is met, "
                f"never a probe re-scoring")
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        fail(3, f"cannot read {path}: {exc}")
    if doc.get("mode") != REGISTERED_MODE:
        fail(3, f"{path} records mode={doc.get('mode')!r}, not {REGISTERED_MODE!r} - the "
                f"target is defined on the registered evaluation mode only")
    summary = doc.get("summary") or {}
    missing = [k for k in required if k not in summary]
    if missing:
        fail(3, f"{path} has no {', '.join(missing)} under summary")
    try:
        rel = os.path.relpath(path, REPO)
    except ValueError:
        rel = path
    return {"path": path, "rel": rel, "key": key, "seed": doc.get("seed"),
            "cases": summary.get("n_cases"),
            "requested": doc.get("cases_requested"), "summary": summary}


def check_consecutive(evals):
    """Adjacent in the run directory's own series, and separated by that
    series' modal stride. Adjacency alone would let a deleted intermediate
    manufacture it."""
    dirs = {os.path.dirname(os.path.abspath(e["path"])) for e in evals}
    if len(dirs) != 1:
        fail(3, "the two evals are in different directories, so they cannot be "
                "consecutive evals of one run")
    directory = dirs.pop()
    series = sorted(k for k in (eval_order_key(n) for n in os.listdir(directory))
                    if k is not None)
    a, b = sorted(e["key"] for e in evals)
    if a == b:
        fail(3, "the same artefact was given twice - two DISTINCT consecutive evals "
                "are required")
    try:
        ia, ib = series.index(a), series.index(b)
    except ValueError:
        fail(3, "an eval is not part of its own directory's series")
    if ib - ia != 1:
        fail(3, f"those two evals are {ib - ia} apart in the series of {len(series)} in "
                f"{os.path.basename(directory)}, not consecutive")
    steps = [k[1] for k in series if k[0] == 0]
    if a[0] == 0 and b[0] == 0 and len(steps) >= 3:
        strides = [steps[i + 1] - steps[i] for i in range(len(steps) - 1)]
        modal = max(set(strides), key=strides.count)
        if b[1] - a[1] != modal:
            fail(3, f"the gap between those evals is {b[1] - a[1]} steps against a "
                    f"series stride of {modal} - an eval in between is missing, so they "
                    f"are adjacent in the directory but not consecutive in the run")
    seeds = {e["seed"] for e in evals}
    if len(seeds) != 1:
        fail(3, f"the two evals carry different seeds {sorted(map(str, seeds))} - they "
                f"are not the same pinned eval set")


def score(version, ev):
    s = ev["summary"]
    rows = []
    for axis in AXES:
        c = axis_cond(version, axis)
        got = float(s[c["metric"]])
        if is_ratio(c):
            ref = float(s[c["reference"]])
            bar = float(c["multiplier"]) * ref
            ratio = (got / ref) if ref > 0 else None
            passed = (got <= bar) if c["op"] == "<=" else (got >= bar)
            rows.append({"axis": axis, "metric": c["metric"], "got": got, "bar": bar,
                         "op": c["op"], "pass": passed, "reference_value": ref,
                         "ratio": ratio, "kind": "ratio"})
        else:
            bar = float(c["threshold"])
            passed = (got <= bar) if c["op"] == "<=" else (got >= bar)
            rows.append({"axis": axis, "metric": c["metric"], "got": got, "bar": bar,
                         "op": c["op"], "pass": passed, "reference_value": None,
                         "ratio": None, "kind": "flat"})
    return all(r["pass"] for r in rows), rows


def evaluate(version, evals):
    check_consecutive(evals)
    evals = sorted(evals, key=lambda e: e["key"])
    per = []
    for ev in evals:
        passed, rows = score(version, ev)
        per.append({"eval": ev["rel"], "n_cases": ev["cases"], "seed": ev["seed"],
                    "pass": passed, "conditions": rows})
    return all(p["pass"] for p in per), per, evals


def demonstrated_bounds(per, strict=True):
    """The tight end of the ratchet's band on each axis: the WORSE of the two
    measurements. Everything the sizing decision needs, computed in one place
    so `check` reports the same numbers `ratchet` will later enforce."""
    bounds = {}
    for p in per:
        for r in p["conditions"]:
            axis = r["axis"]
            if r["kind"] == "ratio":
                if r["ratio"] is None:
                    if strict:
                        fail(3, f"{p['eval']} has a zero reference for the {axis} "
                                f"condition, so the demonstrated multiplier is undefined "
                                f"and that axis cannot be sized")
                    bounds[axis] = None
                    continue
                val = r["ratio"]
            else:
                val = r["got"]
            prev = bounds.get(axis)
            if prev is None:
                bounds[axis] = val
            else:
                bounds[axis] = max(prev, val) if HARDER_IS_LOWER[axis] else min(prev, val)
    return bounds


def render(version, per):
    emit(f"active target  {describe(version)}")
    emit("")
    for p in per:
        emit(f"  {p['eval']}   n={p['n_cases']} seed={p['seed']}   "
             f"{'MET' if p['pass'] else 'NOT MET'}")
        for r in p["conditions"]:
            emit(f"    {'ok  ' if r['pass'] else 'FAIL'} {r['metric']} = "
                 f"{r['got']:.6g} {r['op']} {r['bar']:.6g}")
    emit("")


def evidence_paths():
    paths = [p for p in os.environ.get("NS_EVALS", "").split("\n") if p.strip()]
    if len(paths) != 2:
        fail(2, f"exactly two --eval artefacts are required (the target is defined at "
                f"two consecutive registered evals); got {len(paths)}")
    return paths


# --- modes ------------------------------------------------------------------

lines, versions, dod = load_targets()
active = versions[0]

if MODE == "current":
    emit(describe(active))
    finish(0, ok=True, active=active, dod=dod)

if MODE == "versions":
    emit(f"{len(versions)} version(s), newest first:")
    for v in versions:
        emit(f"  {describe(v)}  supersedes={v.get('supersedes')}")
    finish(0, ok=True, versions=versions)

if MODE == "verify":
    # Shape was already checked by load_targets(), which exits 5. What is left
    # is the ordering, the supersedes chain, monotonicity across the whole
    # history, and the anchor.
    problems = []
    nums = [v.get("version") for v in versions]
    if any(not isinstance(n, int) for n in nums):
        problems.append(f"a version number is not an integer: {nums}")
    else:
        if len(set(nums)) != len(nums):
            problems.append(f"duplicate version numbers: {nums}")
        if nums != sorted(nums, reverse=True):
            problems.append(f"versions are not newest-first: {nums}")
    for newer, older in zip(versions, versions[1:]):
        if newer.get("supersedes") != older.get("version"):
            problems.append(f"v{newer.get('version')} supersedes {newer.get('supersedes')!r} "
                            f"but sits directly above v{older.get('version')}")
        for axis in AXES:
            nv, ov = cond_value(newer, axis), cond_value(older, axis)
            if (nv > ov) if HARDER_IS_LOWER[axis] else (nv < ov):
                problems.append(f"v{newer.get('version')} loosened {axis} {ov:g} -> {nv:g}")
    if versions[-1].get("supersedes") is not None:
        problems.append(f"the oldest version supersedes {versions[-1].get('supersedes')!r}, "
                        f"expected null")
    if not any(ANCHOR in ln for ln in lines):
        problems.append(f"the `{ANCHOR}` insertion anchor is missing")
    if problems:
        for p in problems:
            emit(f"  DRIFT  {p}")
        finish(3, ok=False, problems=problems)
    emit(f"ok: {len(versions)} version(s), shape unchanged since v{versions[-1].get('version')}, "
         f"monotone, anchor present, Definition of done block present")
    finish(0, ok=True, versions=versions, dod=dod)

if MODE in ("check", "met"):
    required = required_summary_keys(active)
    evals = [load_eval(p, required) for p in evidence_paths()]
    met, per, evals = evaluate(active, evals)
    render(active, per)
    bounds = demonstrated_bounds(per, strict=False)
    emit("worst demonstrated across the two evals - the tight end of any ratchet's band:")
    for axis in AXES:
        val = bounds.get(axis)
        emit(f"    {axis:<18} {'undefined' if val is None else format(val, '.6g')}"
             f"   (active bar {cond_value(active, axis):g})")
    emit("")
    emit(f"{'MET' if met else 'NOT MET'} - v{active.get('version')} "
         f"{'holds' if met else 'does not hold'} at both evals")
    token = f"{EVIDENCE_TOKEN} {evals[0]['rel']} | {evals[1]['rel']}"
    if MODE == "met":
        emit(token)
    finish(0 if met else 1, ok=met, met=met, active_version=active.get("version"),
           per_eval=per, demonstrated=bounds, evidence=[e["rel"] for e in evals],
           evidence_token=token)

if MODE == "pending":
    met_line, consumed = None, False
    try:
        with open(JOURNAL) as fh:
            entries = [json.loads(ln) for ln in fh if ln.strip()]
    except (OSError, json.JSONDecodeError):
        entries = []
    for e in entries:
        if e.get("event") == "north_star_met":
            met_line, consumed = e, False
        elif e.get("event") == "north_star_updated" and met_line is not None:
            consumed = True
    if met_line is None:
        emit("no north_star_met in the journal - nothing due")
        finish(1, ok=False, pending=False, reason="none")
    if consumed:
        emit(f"the newest north_star_met ({met_line.get('ts')}) was already consumed by a "
             f"north_star_updated - nothing due")
        finish(1, ok=False, pending=False, reason="consumed")
    note = met_line.get("note") or ""
    if EVIDENCE_TOKEN not in note:
        fail(3, f"the north_star_met at {met_line.get('ts')} carries no "
                f"`{EVIDENCE_TOKEN}` - it was not written by `north_star.sh met --record`, "
                f"and a claim that cannot be re-verified is never trusted")
    tail = note.split(EVIDENCE_TOKEN, 1)[1].strip()
    paths = []
    for part in tail.split("|")[:2]:
        words = part.split()
        if words:
            paths.append(os.path.join(REPO, words[0]))
    if len(paths) != 2:
        fail(3, f"the north_star_met at {met_line.get('ts')} names {len(paths)} artefact(s), "
                f"not two")
    evals = [load_eval(p, required_summary_keys(active)) for p in paths]
    met, per, evals = evaluate(active, evals)
    render(active, per)
    if not met:
        fail(3, f"the north_star_met at {met_line.get('ts')} does NOT re-verify against "
                f"v{active.get('version')} - either it was never scored from its own "
                f"artefacts, or the active target has moved since it was written")
    emit(f"PENDING - v{active.get('version')} met at {met_line.get('ts')}, no "
         f"north_star_updated since.")
    finish(0, ok=True, pending=True, met_ts=met_line.get("ts"),
           active_version=active.get("version"), per_eval=per,
           evidence=[e["rel"] for e in evals])

if MODE == "ratchet":
    required = required_summary_keys(active)
    evals = [load_eval(p, required) for p in evidence_paths()]

    proposed = {}
    for raw in os.environ.get("NS_THRESHOLDS", "").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        if "=" not in raw:
            fail(2, f"malformed --threshold {raw!r} - expected NAME=VALUE")
        name, _, val = raw.partition("=")
        name = name.strip()
        if name not in AXES:
            fail(2, f"--threshold names {name!r}, not one of the configured axes {list(AXES)}")
        try:
            proposed[name] = float(val)
        except ValueError:
            fail(2, f"--threshold {name} must be a number, got {val!r}")
    for axis in AXES:
        proposed.setdefault(axis, cond_value(active, axis))

    sizing = {axis: "" for axis in AXES}
    for raw in os.environ.get("NS_SIZINGS", "").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        if "=" not in raw:
            fail(2, f"malformed --sizing {raw!r} - expected NAME=TEXT")
        name, _, text = raw.partition("=")
        name = name.strip()
        if name not in AXES:
            fail(2, f"--sizing names {name!r}, not one of the configured axes {list(AXES)}")
        sizing[name] = text

    # (4) met, before anything about the proposal: an unmet target cannot be
    # raised however well argued the new numbers are.
    met, per, evals = evaluate(active, evals)
    render(active, per)
    if not met:
        fail(4, f"v{active.get('version')} is not met at both evals - a target is raised "
                f"only from evidence that it has already been cleared")

    # (6) monotonic: no axis easier, at least one strictly harder.
    eased, harder, moved = [], [], set()
    for axis in AXES:
        old, new = cond_value(active, axis), proposed[axis]
        if old == new:
            continue
        moved.add(axis)
        (eased if ((new > old) if HARDER_IS_LOWER[axis] else (new < old)) else harder) \
            .append(f"{axis} {old:g} -> {new:g}")
    if eased:
        fail(6, "a ratchet may only tighten, and these loosen: " + "; ".join(eased))
    if not harder:
        fail(6, "no threshold moved - a new version must tighten at least one")

    # (7) the human-owned floor. Any axis the Definition of done itself
    # defines a condition for may be REACHED and never overtaken; an axis the
    # DoD says nothing about has no floor here.
    dod_conds = dod.get("conditions") or {}
    floor_problems = []
    for axis in AXES:
        if axis not in dod_conds:
            continue
        floor = cond_value(dod, axis)
        if (proposed[axis] < floor) if HARDER_IS_LOWER[axis] else (proposed[axis] > floor):
            floor_problems.append(f"{axis} {proposed[axis]:g} is stricter than the "
                                  f"Definition of done's {floor:g}, which is human-owned")
    if floor_problems:
        fail(7, "; ".join(floor_problems))

    # (9) demonstrated: a new bar must already have been cleared at BOTH evals.
    demonstrated = demonstrated_bounds(per)
    too_strict = []
    for axis in AXES:
        new, dem = proposed[axis], demonstrated[axis]
        if (new < dem) if HARDER_IS_LOWER[axis] else (new > dem):
            too_strict.append(f"{axis} {new:g} is past the worst demonstrated {dem:.6g}")
    if too_strict:
        fail(9, "a ratchet may not set a bar the evidence has not cleared twice: "
                + "; ".join(too_strict), demonstrated=demonstrated)

    # (8) sizing: required for every axis that moved, refused for one that did
    # not, and it must cite a measured quantity rather than assert one.
    sizing_problems = []
    for axis in AXES:
        text = sizing[axis]
        if axis not in moved:
            if text:
                sizing_problems.append(f"{axis} did not move but a citation was given for it")
            continue
        if not text:
            sizing_problems.append(f"{axis} moved with no sizing citation")
        elif not any(ch.isdigit() for ch in text):
            sizing_problems.append(f"the {axis} citation names no measured quantity "
                                   f"(it contains no number)")
        elif len(text) > MAX_SIZING:
            sizing_problems.append(f"the {axis} citation is {len(text)} characters, over the "
                                   f"{MAX_SIZING} limit - cite the measurement here and put "
                                   f"the argument in the journal")
    if sizing_problems:
        fail(8, "; ".join(sizing_problems))

    new_version = {
        "version": int(active["version"]) + 1,
        "applies_to": APPLIES_TO,
        "active_since": os.environ.get("NS_ACTIVE_SINCE", "").strip()
                        or datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "supersedes": int(active["version"]),
        "consecutive_evals": active["consecutive_evals"],
        "conditions": {
            axis: {**axis_cond(active, axis),
                   value_key(axis_cond(active, axis)): proposed[axis]}
            for axis in AXES
        },
        "sizing_evidence": {a: (sizing[a] or (active.get("sizing_evidence") or {}).get(a))
                            for a in AXES},
        "authorised_by": "autonomous loop, under the ratchet this project's operator enabled",
        "met_evidence": [e["rel"] for e in evals],
    }

    deltas = {a: {"old": cond_value(active, a), "new": proposed[a], "moved": a in moved}
              for a in AXES}
    result.update({"active_version": active.get("version"),
                   "new_version": new_version["version"], "deltas": deltas,
                   "demonstrated": demonstrated, "sizing": sizing,
                   "evidence": [e["rel"] for e in evals], "new_block": new_version})

    emit("accepted:")
    for a in AXES:
        d = deltas[a]
        emit(f"  {a:<18} {d['old']:g} -> {d['new']:g}"
             f"{'' if d['moved'] else '   (unchanged)'}"
             f"   worst demonstrated {demonstrated[a]:.6g}")
    emit("")

    if os.environ.get("NS_APPLY", "0") != "1":
        emit(f"dry run - nothing written. Re-run with --apply to create "
             f"v{new_version['version']}.")
        finish(0, ok=True, applied=False)

    try:
        anchor_idx = next(i for i, ln in enumerate(lines) if ANCHOR in ln)
    except StopIteration:
        fail(3, f"the `{ANCHOR}` insertion anchor is missing from {NS_FILE}")

    block = ["",
             f"#### v{new_version['version']} - active since {new_version['active_since']}, "
             f"supersedes v{new_version['supersedes']}",
             ""]
    for i, axis in enumerate(AXES, start=1):
        cond = new_version["conditions"][axis]
        if is_ratio(cond):
            op_symbol = "≤" if cond["op"] == "<=" else cond["op"]
            block.append(f"{i}. `{cond['metric']}` {op_symbol} "
                         f"{proposed[axis]:g} × `{cond['reference']}`")
        else:
            op_symbol = "≤" if cond["op"] == "<=" else "≥"
            block.append(f"{i}. `{cond['metric']}` {op_symbol} {proposed[axis]:g}")
    block.append(f"{len(AXES) + 1}. All of the above at "
                 f"**{new_version['consecutive_evals']} consecutive** registered evals")
    block += ["", TARGET_FENCE]
    block += json.dumps(new_version, indent=2, ensure_ascii=False).split("\n")
    block += ["```"]

    head, tail = lines[:anchor_idx + 1], lines[anchor_idx + 1:]
    try:
        with open(NS_FILE, "w") as fh:
            fh.write("\n".join(head + block + tail))
    except OSError as exc:
        fail(2, f"cannot write {NS_FILE}: {exc}")

    # Append-only, verified rather than intended: re-read and require every
    # pre-existing line to survive byte-identically, and the stack to read
    # back with the new version on top and the old ones unchanged beneath it.
    after = read_file()
    if after[:len(head)] != head or after[len(head) + len(block):] != tail:
        fail(2, f"the write was not append-only - {NS_FILE} is now modified outside the "
                f"inserted block. Revert it before doing anything else")
    reread = [b[2] for b in parse_blocks(after, TARGET_FENCE)]
    if reread[0].get("version") != new_version["version"] or reread[1:] != versions:
        fail(2, f"after writing, the version stack in {NS_FILE} does not read back as "
                f"expected. Revert it before doing anything else")

    emit(f"wrote v{new_version['version']} to {os.path.relpath(NS_FILE, REPO)}")
    finish(0, ok=True, applied=True)

fail(2, f"unknown mode {MODE!r}")
PY
}

# One-line delta summary for the journal note, built from the engine's own
# result file so the numbers there are the numbers that were written rather
# than a shell-side re-derivation.
describe_deltas() {
    # %-formatting rather than an f-string: this program is carried inside a
    # single-quoted shell string, so it cannot contain a literal `'`, and a
    # `\"` used to dodge that is a line-continuation to Python's tokeniser
    # rather than an escaped quote - the exact defect journal.sh's `last`
    # once had, worth avoiding rather than repeating.
    python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))
deltas = r["deltas"]
parts = []
for axis in deltas:
    d = deltas[axis]
    if d["moved"]:
        parts.append("%s %g -> %g" % (axis, d["old"], d["new"]))
print("; ".join(parts))
' "$1"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_simple() {  # current | versions | verify | pending
    local mode="$1"; shift
    local json=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json=1; shift ;;
            -h|--help) usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done
    NS_MODE="$mode" NS_JSON="$json" engine
}

cmd_check() {  # check | met
    local mode="$1"; shift
    local json=0 record=0 run_id=""
    local evals=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --eval)   evals+=("$2"); shift 2 ;;
            --json)   json=1; shift ;;
            --record) record=1; shift ;;
            --run-id) run_id="$2"; shift 2 ;;
            -h|--help) usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done
    if [[ "$mode" == "check" && ( "$record" -eq 1 || -n "$run_id" ) ]]; then
        echo "--record and --run-id belong to \`met\`, not \`check\` - check decides, met records" >&2
        usage 2
    fi

    local joined="" e
    for e in "${evals[@]:-}"; do [[ -n "$e" ]] && joined+="$e"$'\n'; done

    local result; result="$(mktemp "${TMPDIR:-/tmp}/north_star.XXXXXX")"
    local out rc
    out="$(NS_MODE="$mode" NS_JSON="$json" NS_EVALS="$joined" NS_RESULT="$result" engine)"; rc=$?
    printf '%s\n' "$out"

    if [[ "$mode" == "met" && "$record" -eq 1 ]]; then
        if [[ "$rc" -ne 0 ]]; then
            echo "not recorded: the target is not met, or the evidence was refused (exit $rc)" >&2
            rm -f "$result"
            return "$rc"
        fi
        local token version note
        token="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["evidence_token"])' "$result")"
        version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["active_version"])' "$result")"
        note="TARGET MET - every condition of target v${version} holds at two consecutive registered evals, scored by north_star.sh against the run's own artefacts rather than a probe re-scoring. Whatever ratchets the target re-verifies this claim from the artefacts named here (via \`north_star.sh pending\`) before acting on it. ${token}"
        local args=(append --event north_star_met --note "$note")
        [[ -n "$run_id" ]] && args+=(--run-id "$run_id")
        if ! "$JOURNAL_SH" "${args[@]}" >/dev/null; then
            echo "north_star: FAILED to append the north_star_met journal event" >&2
            rm -f "$result"
            return 2
        fi
        echo "recorded: north_star_met appended to the journal"
    fi
    rm -f "$result"
    return "$rc"
}

cmd_ratchet() {
    local apply=0 active_since="" json=0
    local evals=() thresholds=() sizings=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --threshold)    thresholds+=("$2"); shift 2 ;;
            --sizing)       sizings+=("$2"); shift 2 ;;
            --eval)         evals+=("$2"); shift 2 ;;
            --active-since) active_since="$2"; shift 2 ;;
            --apply)        apply=1; shift ;;
            --json)         json=1; shift ;;
            -h|--help) usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done

    local joined_evals="" e
    for e in "${evals[@]:-}"; do [[ -n "$e" ]] && joined_evals+="$e"$'\n'; done
    local joined_thresh="" t
    for t in "${thresholds[@]:-}"; do [[ -n "$t" ]] && joined_thresh+="$t"$'\n'; done
    local joined_sizing="" s
    for s in "${sizings[@]:-}"; do [[ -n "$s" ]] && joined_sizing+="$s"$'\n'; done

    local result; result="$(mktemp "${TMPDIR:-/tmp}/north_star.XXXXXX")"
    local out rc
    out="$(NS_MODE=ratchet NS_JSON="$json" NS_EVALS="$joined_evals" NS_RESULT="$result" \
        NS_THRESHOLDS="$joined_thresh" NS_SIZINGS="$joined_sizing" \
        NS_ACTIVE_SINCE="$active_since" NS_APPLY="$apply" engine)"; rc=$?
    printf '%s\n' "$out"

    if [[ "$rc" -eq 0 && "$apply" -eq 1 ]]; then
        local newv oldv summary
        newv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["new_version"])' "$result")"
        oldv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["active_version"])' "$result")"
        summary="$(describe_deltas "$result")"
        # Journal first. A note that fails to append must not cost the record
        # of what changed - the journal is the shared memory that matters.
        "$JOURNAL_SH" append --event north_star_updated \
            --note "TARGET RAISED - active target v${oldv} -> v${newv}, written by north_star.sh ratchet --apply. ${summary}. Earlier versions are untouched and still readable in the goal file; reverting this commit is how a human vetoes it." \
            >/dev/null || echo "north_star: FAILED to append the north_star_updated journal event" >&2
    fi
    rm -f "$result"
    return "$rc"
}

require_python

case "${1:-}" in
    current)  shift; cmd_simple current "$@" ;;
    versions) shift; cmd_simple versions "$@" ;;
    verify)   shift; cmd_simple verify "$@" ;;
    pending)  shift; cmd_simple pending "$@" ;;
    check)    shift; cmd_check check "$@" ;;
    met)      shift; cmd_check met "$@" ;;
    ratchet)  shift; cmd_ratchet "$@" ;;
    -h|--help) usage 0 ;;
    "") echo "a subcommand is required" >&2; usage 2 ;;
    *) echo "unknown subcommand: $1" >&2; usage 2 ;;
esac
