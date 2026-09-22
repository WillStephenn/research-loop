#!/usr/bin/env bash
#
# hypothesis.sh - the hypothesis registry: what the loop currently believes,
# what it has ruled out, and what it should test next.
#
# The journal (registry/journal.ndjson) records what HAPPENED. This records
# what is BELIEVED, which is a different shape of data: a hypothesis has
# mutable state that changes as evidence arrives, so it cannot be an
# append-only line. One JSON file per hypothesis under registry/,
# version-controlled, so `git diff` shows exactly what a tick changed and why.
#
# The two are joined by `hypothesis_id`, which journal.sh accepts on every
# append. `hypothesis.sh show <id>` returns the record AND every journal line
# tagged to it, which is the whole handoff primitive: an agent given nothing
# but an id can recover the full context of what it is working on.
#
# WHY THIS EXISTS. Before a registry like this, hypotheses tend to live only
# as prose inside journal notes. A note recording an evaluation names two or
# three rival explanations in one paragraph; one gets tested and the others
# are unrecoverable by any query a later tick could run. Generation is rarely
# the bottleneck in a working research loop - it tends to produce more
# candidate hypotheses than it can afford to test. RETENTION is the
# bottleneck: an idea that is not written down as a record with its own state
# is an idea the loop will regenerate, half-remembered, next week.
#
# TWO KINDS OF RECORD, and the split is load-bearing.
#
#   hypothesis  a conjecture that gets SPENT. Requires --falsifier. Capped at
#               ATTEMPT_CAP attempts (config/loop.conf), then retire it.
#   task        an obligation that gets DISCHARGED. Requires --done-when. No
#               cap: you do not stop fixing a broken build because you have
#               tried three times.
#
# Tasks are a `kind`, not a family, because the required-field rule is the
# most valuable constraint in this file - a hypothesis with no falsifier is
# refused. Admitting tasks as a family would have forced either fake
# falsifiers or an optional --falsifier, and both wreck the discipline for
# real hypotheses.
#
# What belongs here as a task is deliberately narrow, or this becomes a
# second and worse issue tracker: (i) it blocks or distorts the loop's
# ability to run experiments, or (ii) it is a good-citizen obligation to a
# shared resource. General product and feature work belongs in a normal
# issue tracker, not here.
#
# States (a transition not in this table exits 2):
#
#   hypothesis:
#     open ──► testing ──► confirmed
#      ▲ │        │
#      │ │        ├──► falsified ◄── blocked   (a kill needs no resurrection gate)
#      │ │        ├──► open                    (requires --interrupted-by)
#      │ └────────┴──► blocked ──► open        (requires --new-mechanism)
#      └──────────────────────────┘
#
#   task:
#     open ──► doing ──► done       terminal
#      ▲ │        │
#      │ │        ├──► dropped      terminal, and must say why
#      │ │        └──► open         (requires --interrupted-by)
#      │ └───────────► blocked ──► open   (requires --new-mechanism)
#      └──────────────────────────┘
#
#   open       a candidate nobody has tested
#   testing    a run or probe is currently deciding it
#   confirmed  its falsifier did not fire and its gate passed
#   falsified  its falsifier fired. TERMINAL - reopening means deleting the
#              file by hand, deliberately awkward, because a loop that can
#              quietly resurrect a dead idea will cycle forever
#   blocked    cannot be decided yet (needs a dependency settled, or a
#              confound removed). Reopening requires naming a NEW MECHANISM,
#              not just renewed enthusiasm
#
# A BLOCKED RECORD IS NOT FROZEN, and treating it as one is how the registry
# goes stale in exactly the way `drift` exists to catch. Two things happen to
# a blocker that the state table alone cannot express:
#
#   THE BLOCKER IS DISCHARGED AND REPLACED. A record waits on "dependency X
#   landing". X lands, so a tick reading the record sees a satisfied
#   dependency and may dispatch the record as ready - while the record is in
#   fact still blocked, for a different reason it had itself pre-registered.
#   `set-state` accepts --blocked-on only on a transition INTO blocked, and
#   blocked -> blocked exits 2 as a no-op, so there was no way to say so.
#   `reblock` is that way, and it appends the old text to history[] rather
#   than overwriting it.
#
#   THE EVIDENCE ARRIVES AND THE FALSIFIER FIRES. Consider a record blocked
#   solely on a budget confound, where the run that removes the confound also
#   causes the record's own pre-registered falsifier to fire under the larger
#   budget. Before this edge existed, the only legal route to that verdict was
#   blocked -> open (spending the --new-mechanism gate) -> testing (spending
#   an ATTEMPT, and claiming a probe was deciding something already decided)
#   -> falsified: three transitions and a spent attempt to record one result,
#   which is exactly the kind of machinery an agent under time pressure
#   skips. So `blocked -> falsified` is direct.
#
# THE ASYMMETRY IS DELIBERATE and is the whole reason this does not weaken the
# table. --new-mechanism guards blocked -> open because that edge RESURRECTS
# an idea, and a loop that can quietly revive a dead conjecture will cycle
# forever. Nothing about that argues for forcing a KILL through open:
# falsified is terminal, has no edge out, and already requires --evidence.
# blocked -> confirmed stays illegal for the opposite reason - confirming
# claims a gate passed, which means a test ran, which means `testing`.
#
# AN INTERRUPTED ATTEMPT IS NOT A VERDICT. Without an edge out of `testing` or
# `doing` meaning "the agent working this died", the edges that already exist
# all say something false: `dropped` and the terminal pair claim a decision
# nobody made, and `blocked` claims a dependency or a confound that may not
# exist. So the only route back was `blocked -> open`, which SPENDS
# --new-mechanism - the gate that exists to stop a loop resurrecting
# conjectures killed on evidence - on a record nothing had decided. Two
# transitions and a spent gate is exactly the kind of machinery an agent under
# time pressure routes around, which is not hypothetical: an agent whose
# process dies mid-attempt because a usage limit or a hung call killed it is a
# routine event in a loop that runs unattended on a schedule.
#
#   ./hypothesis.sh set-state T27 open \
#       --interrupted-by "the agent's process was killed mid-edit" \
#       --evidence "partial work verified inert and discarded"
#
# One transition, no --new-mechanism, no terminal state, and --interrupted-by
# is required on it - a recovery that does not say what interrupted it is
# indistinguishable from an agent quietly un-testing something it did not
# like. The flag is refused on every other transition, so it cannot become
# decoration. The old entry stays in history[]; nothing is overwritten.
#
# ATTEMPTS ARE HELD, NOT RESTORED, and that is the choice this file makes. A
# hypothesis interrupted in `testing` has already incremented `attempts` on
# the way in. Recovery does NOT decrement it - the attempt really was spent,
# a resource really was booked, and a counter that walks backwards in a git
# diff looks tampered with. Instead the record carries `attempt_carried:
# true`, and the NEXT entry to `testing` resumes that attempt rather than
# spending a second one for the same never-completed test: no increment, and
# the cap does not bind, because nothing new is being spent.
# `resumed_attempt` in the history entry says why the counter did not move.
# The invariant either way is that ONE never-completed attempt costs EXACTLY
# ONE attempt. Tasks have no attempts to hold, so a recovered task stays at 0.
#
# `next` MAKES MID-ATTEMPT RECORDS VISIBLE, which is the half that actually
# bites in practice. The candidate list is still `open` records only - a
# record a stage is holding is not something to dispatch - but a lane with a
# record in `testing` (or a task in `doing`) prints an IN FLIGHT block naming
# it, and a line like "TASKS - none open. (Good.)" is suppressed whenever
# that would be false. A genuinely empty lane still prints it. The risk with
# "(Good.)" is not that it is wrong when the lane truly is empty; it is that
# it actively reassures the reader when the lane is not empty at all, which
# is worse than saying nothing.
#
# HAS THIS BEEN CLAIMED BEFORE? The registry can answer that, and only at the
# moment a rival is written, which is the only moment the answer can be acted
# on. A parameter re-tuned repeatedly without its underlying form ever
# changing, or a duplicate experiment that reaches an expensive shared
# resource, costs real time - and the answer is decidable from records
# already on disk.
#
#   ./hypothesis.sh similar "<claim>" [--falsifier "<f>"] [-n 3]
#
# prints the nearest existing records with their state, their falsifier
# VERBATIM and the sentence that matched. `new` runs the SAME function as a
# screen and REFUSES above the bar (exit 2), naming what it thinks you have
# re-drafted. It is a screen and not a veto - the drafter may be right:
#
#   ./hypothesis.sh new ... --not-a-duplicate "<one sentence on what differs>"
#
# proceeds, and that sentence is written into history[] where a reviewer of
# the git diff will see it. Nothing else is: no neighbour id, no score and no
# link is stored, in either caller. Similarity is a function of the text AND
# of the corpus's document frequencies, both of which move as the registry
# grows, so a cached neighbour is a stale assertion no later read could tell
# from a fresh one. It is recomputed every time.
#
# WHAT IT PRINTS IS CONSTRAINED AS MUCH AS WHAT IT COMPUTES. No similarity
# score, no in-degree, no citation count, and the ordering is on the
# similarity and the id and NOTHING derived from how often a record is
# referenced. A record several others depend on is more IMPORTANT, which is a
# different question from whether it is the same idea as this draft; letting
# importance leak into that ordering would quietly turn a duplicate check
# into a popularity list. The measure and its calibration are documented at
# the similarity core, above cmd_similar.
#
# IT IS A LEXICAL SCREEN AND NOTHING MORE. A heavy reword of an existing
# record - same mechanism, no shared phrasing - scores inside the
# true-negative band and passes. Do not describe it as a semantic duplicate
# detector.
#
# WHAT ELSE IS EMPTY? `next` prints the family x TARGET matrix (both closed
# vocabularies come from config/loop.conf) and names every cell with nothing
# OPEN aimed at it. `families` already shows concentration, but only to a
# reader who goes looking; this is the same fact where the choice of what to
# test next is actually made.
#
# test_cost decides which stage tests a record, and it is the cheapest thing
# in this file to get right:
#   probe   scores an existing artefact already on disk. Minutes, no
#           exclusive resource, runs concurrently with live work.
#   run     needs the expensive shared resource, for hours, contended.
# NEVER book a run for something a probe could settle.
#
# attempts increments on entry to `testing`. At ATTEMPT_CAP the transition
# refuses without --override-cap, which turns a documented rule of thumb
# ("no more than N honest attempts") into something enforced rather than
# merely aspirational.
#
# PROVENANCE. A hypothesis must name the result it came from, and `new`
# refuses one that does not. Without this, upstream evidence exists only as
# prose inside the claim field: a hypothesis created moments after some other
# event, whose evidence is entirely real, is otherwise indistinguishable from
# an idea invented on the spot in that same moment - no field holds it, no
# query returns it.
#
#   --provenance <journal-ts | repo-relative-path[:LINE]>
#
# Both forms are real sources - an evaluation report, a probe result, a task
# finding, a file and line of code - so both are accepted, and both are
# VALIDATED. A timestamp must match the `ts` of an actual line in
# journal.ndjson; a path must exist under the repo root. An unvalidated
# pointer is prose with extra syntax, so a ts matching no line exits 2.
#
# ONE FIELD, and --source-ts feeds it. `--source-ts` predates general
# provenance and recorded where a BACKFILLED record's prose was reconstructed
# from. That meaning reconciles with provenance directly - for a record
# rebuilt from a journal note, the note is both the text's source and the
# evidence - so there is no second field: --source-ts populates `provenance`
# (kind journal_ts, marked backfilled) whenever --provenance is absent.
#
# TASKS ARE EXEMPT, deliberately. A good-citizen obligation can arise from a
# standing fact rather than from a result - reading a maintenance note or a
# status script can generate a task with nothing to cite as provenance - and
# the hypothesis/task asymmetry on required fields is already this file's
# central design. `--provenance` is accepted on a task and validated the same
# way when given; it is simply not required. `show` prints the exemption
# rather than an empty field, so a reader is never left guessing whether it
# was skipped.
#
# When provenance genuinely cannot be recovered, say so instead of leaving
# the field null-and-ambiguous:
#
#   --provenance 'unrecoverable: <why>'
#
# This is refused on `new` unless --backfilled is also given, because on a
# fresh record it would be a hole straight through the requirement.
#
# DRIFT. Registry state is written by an agent remembering to write it, and
# `drift` is what notices when one did not. Three known ways it goes stale: a
# tick dies mid-stage between doing the work and calling set-state; a
# subagent returns without recording; a run ends and nobody walks the link
# back. All three matter more than they look, because `attempts` increments
# on the open->testing edge, and `attempts` is what the attempt cap and the
# family diversity column are computed from - a missed transition is a cap
# that silently does not bind and a families base rate on too small a
# denominator.
#
#   ./hypothesis.sh drift        # exits 3 if any record disagrees with reality
#
# It REPORTS and never repairs. The correct transition needs judgement about
# what actually happened, and a tool that silently set a state would
# manufacture exactly the false confidence this check exists to remove.
#
# WHAT IT DELIBERATELY DOES NOT FIRE ON is the half that decides whether the
# check survives. `open` with attempts=0 after a launch that never produced
# any real progress is CORRECT: the stage that starts a run links and
# transitions to `testing` only once the run is seen making progress,
# precisely so a launch that dies in setup does not spend an attempt. So the
# check keys on a TERMINAL journal event or on a STALE record, never on the
# mere existence of a launch attempt - and the `open` check reads the
# record's own `tested_by` link rather than scanning the journal for a
# hypothesis id. A checker that flags a correct state is ignored within a
# few ticks, which is worse than no checker at all.
#
# ORPHANED MID-ATTEMPT WORK IS CAUGHT ON THE SAME TICK, not after a long
# staleness window. A staleness threshold of many hours is a floor on false
# positives for a record that is merely WAITING; it is many ticks too late
# for one whose agent is dead. The discriminator is a TICK BOUNDARY in the
# journal: an "orchestrator woke" line is written during a tick's
# orientation, before any stage runs, and the scheduler will not start a
# second instance of a running tick - so a boundary line NEWER than a
# record's last activity proves the tick that left it mid-attempt is over.
# That is decidable from the journal alone, needs no clock, and fires the
# first time `drift` runs after the death. Shapes `doing_orphaned` and
# `testing_orphaned`.
#
# THE RESIDUAL IS NAMED RATHER THAN PAPERED OVER. One shape stays undecidable
# from the journal: a STAGE dying inside a tick that SURVIVES and has not yet
# journalled the abort. Nothing is written when a stage starts or returns, so
# at that moment a task in `doing` for over an hour is byte-for-byte identical
# to a task-working stage that is simply taking a long time on real work, and
# elapsed time alone cannot separate them. Stages legitimately run for hours,
# so a short deadline is not the fix - a low fixed ceiling would eventually
# shoot a healthy tick mid-probe. So the staleness path is KEPT, deliberately,
# as the backstop for that residual and for any journal with no boundary
# lines at all. Closing it properly would take a stage-lifecycle event in the
# journal, which is a change to journal.sh and to every stage script, not to
# this file.
#
# THE DISPATCHING STAGE MAY SAY SO. The tick-boundary heuristic above is
# unsound for work the CURRENT tick itself dispatches: the wake line is
# written at the TOP of a tick, so every record that tick then hands to a
# subagent is, by construction, older than the newest boundary for the rest
# of that tick - and a naive check would call that subagent's record
# orphaned roughly the instant it is dispatched. The fix is not to compare
# against an older boundary (that just moves the same failure back one tick
# and defeats same-tick detection outright); it is for the dispatching stage
# to say so:
#
#   ./journal.sh append --hypothesis-id <id> --held-by <stage>
#
# records that an agent of the tick in progress is working that record, and
# a hold is honoured only while it is at or newer than the newest
# orchestrator-woke line - the same tick-boundary argument, applied at the
# level (tick against tick) where it is actually valid. A HOLD IS NOT
# ACTIVITY: it suppresses the orphan verdict for the tick that placed it and
# nothing else. It does not reset the staleness clock, so a stage that dies
# instantly on every tick cannot keep its record permanently invisible, and
# it never overrides a finding backed by positive evidence (a linked run
# that has actually ended, for instance), because it is the tick-boundary
# INFERENCE that is unsound there, not those findings. A record with no hold
# behaves exactly as one written before this feature existed.
#
# A RESUMED RUN IS NOT A TERMINAL ONE, AND tested_by IS A LIST. A run killed
# partway through is sometimes resumed under a FRESH run id, and `link`
# APPENDS, so the record carries both. Scoring the record the moment the
# FIRST linked id reaches a terminal event, while a second, later id for the
# same attempt is still running, invents a verdict against work that has not
# finished - and it recurs every tick until the new run ends, training the
# loop to ignore the exit code this check relies on.
#
# ANY ACTIVE LINK SUPPRESSES the "linked run has ended" finding, and it is
# the only thing suppressed. The active set comes from journal.sh's own
# active-runs authority, so this check and the orphan check can never
# disagree about what "in flight" means. It DEFERS rather than drops: when
# the last live link reaches a terminal event the finding fires again,
# naming the NEWEST terminal event rather than the first link written,
# because an attempt that spanned two ids ended at the second, and a reader
# sent to the first would look for artefacts on the wrong host. It is
# reported under RESUMED ATTEMPTS rather than being silent, for the same
# reason a hold is reported: a record that quietly stops being flagged is
# indistinguishable from one nobody looked at.
#
# WHAT THIS PORT DROPS. An earlier design point additionally verified a
# detached background job's liveness directly - opening a connection to
# wherever the work was dispatched and asking whether the process was still
# there before ever calling a record orphaned. That closed a real gap: work
# deliberately dispatched to outlive a single tick invocation is, from the
# journal alone, byte-for-byte identical to a stage that died holding it.
# This port drops that check: it depended on a retry/probe library this tool
# does not bundle, and reproducing it honestly is a substantial feature in
# its own right, independent of the state machine this file is actually
# about. A record dispatched to genuinely detached work therefore falls back
# to the plain staleness backstop above, which is a real regression from a
# positive-evidence check to an elapsed-time one - worth knowing if this tool
# is ever extended to dispatch long-running detached jobs of its own.
#
# Exit codes:  0 = success
#              1 = not found / no candidates
#              2 = usage error, unknown family/state/tier, illegal transition,
#                  attempt cap reached without override, or unvalidatable
#                  provenance
#              3 = `drift` found at least one disagreement (distinct from 2 so
#                  a caller can tell drift from its own bad arguments)
#
# Usage:
#   ./hypothesis.sh new --family optimisation --test-cost run \
#       --targets frac_improved,median_error \
#       --provenance 2026-01-09T19:09:02Z \
#       --claim "..." --falsifier "..." [--depends-on H1]
#   ./hypothesis.sh new --family capacity --test-cost probe --targets median_error \
#       --provenance src/model/decoder.py:369 \
#       --claim "..." --falsifier "..."
#   ./hypothesis.sh similar "<claim>" [--falsifier "<f>"] [-n 3]
#   ./hypothesis.sh new ... --not-a-duplicate "<what differs from what it matched>"
#   ./hypothesis.sh provenance H9 --source 2026-01-09T19:09:02Z \
#       --reason "the probe result named in the claim but held in no field"
#   ./hypothesis.sh drift [--json] [--stale-hours N]
#   ./hypothesis.sh retarget H5 --targets frac_improved --reason "..."
#   ./hypothesis.sh reblock H1 --blocked-on "<what it waits on NOW>" \
#       --reason "the old dependency landed; it is blocked on something else now"
#   ./hypothesis.sh set-state H6 superseded --superseded-by H5 \
#       --evidence "H5 confirmed; the two cannot both be the mechanism"
#   ./hypothesis.sh set-state H5 confirmed --evidence "..." \
#       --metric-delta 'median_error: 8.21 -> 8.03'
#   ./hypothesis.sh new --kind task --priority good-citizen --family infrastructure \
#       --test-cost probe --claim "..." --done-when "..."
#   ./hypothesis.sh show H5 [--json]
#   ./hypothesis.sh list [--state open] [--family representation] [--kind task]
#   ./hypothesis.sh families [--json]
#   ./hypothesis.sh next [--tier probe] [--exclude-family optimisation] [--json]
#   ./hypothesis.sh next --kind task        # the separate task lane
#   ./hypothesis.sh set-state H5 falsified --evidence "..."
#   ./hypothesis.sh set-state T1 doing --evidence "..."
#   ./hypothesis.sh set-state T27 open --interrupted-by "the agent's process died" \
#       --evidence "partial work verified inert and discarded"
#   ./hypothesis.sh link H5 --run-id run-2024-08-a1b2c3

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# The closed vocabularies live in config, not in this script, so the loop can
# be pointed at a new problem by editing one file. See config/loop.conf's own
# header for why each list exists.
# RL_CONFIG overrides the path, which is how the tests point the tool at a
# scratch vocabulary without touching the shipped one. north_star.sh reads the
# same variable, and the two must agree: a record admitted under one vocabulary
# and scored under another is worse than either refusing it or accepting it.
# shellcheck source=config/loop.conf
. "${RL_CONFIG:-$REPO_ROOT/config/loop.conf}"

# RL_REGISTRY / RL_JOURNAL exist so the state machine can be tested against a
# scratch registry without writing fake hypotheses into the real one. Mirrors
# journal.sh's own RL_JOURNAL exactly.
REGISTRY="${RL_REGISTRY:-$REPO_ROOT/registry}"
JOURNAL="${RL_JOURNAL:-$REPO_ROOT/registry/journal.ndjson}"

# HYPOTHESIS_FAMILIES, TASK_FAMILIES, TARGETS and ATTEMPT_CAP come from
# config/loop.conf: they are the closed vocabulary for the PROBLEM the loop
# is pointed at, and that changes per project. STATES, KINDS and PRIORITIES
# stay hardcoded below: they are the state machine itself, not a fact about
# any one problem, and letting them be edited from config would let a project
# quietly invent a new state with no transition table to govern it.
HYP_FAMILIES=("${HYPOTHESIS_FAMILIES[@]}")
FAMILIES=("${HYP_FAMILIES[@]}" "${TASK_FAMILIES[@]}")
STATES=(open testing confirmed falsified blocked superseded doing "done" dropped)
TIERS=("${TEST_COSTS[@]}")
KINDS=(hypothesis task)
PRIORITIES=(blocking good-citizen chore)

# How long a record may sit in `testing`/`doing` with no activity before
# `drift` calls it stale. A floor on false positives, not an SLA - a stage
# that leaves a record open this long has already failed, and this only
# guarantees the failure is eventually seen even without a tick-boundary line
# to catch it sooner. 13 is an illustrative default: derive your own from the
# longest gap between consecutive wake lines in your own journal, rounded up
# to the next whole hour, and recompute it if the wake cadence changes.
DRIFT_STALE_HOURS="${RL_DRIFT_STALE_HOURS:-13}"

# Prints the file's leading comment block. Derived rather than a line range:
# a fixed `sed -n` range silently truncates or over-runs the moment the header
# grows, and this file's header IS its documentation.
usage() {
    awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit "${1:-0}"
}

in_list() {
    local needle="$1"; shift
    local c
    for c in "$@"; do [[ "$c" == "$needle" ]] && return 0; done
    return 1
}

require_python() { command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 2; }; }

# ---------------------------------------------------------------------------
# resolve_provenance - the single validator, shared by `new` and `provenance`
#
# Echoes "<kind>\t<source>" on success; writes the refusal to stderr and
# returns 2 otherwise. Kinds: journal_ts | path | unrecoverable.
#
# The validation IS the feature. A pointer nobody checked is prose with extra
# syntax, and the failure it invites is the expensive one: a reader who
# trusts the field, follows it, finds nothing, and cannot tell whether the
# evidence never existed or merely moved.
# ---------------------------------------------------------------------------
resolve_provenance() {
    require_python
    HY_PROV="$1" HY_JOURNAL="$JOURNAL" HY_REPO="$REPO_ROOT" python3 - <<'PY'
import os, re, sys

raw = os.environ["HY_PROV"].strip()
if not raw:
    sys.stderr.write("--provenance was given an empty value\n")
    sys.exit(2)

# 1. The explicit "I looked and it is not there" form.
if raw.lower().startswith("unrecoverable"):
    reason = raw.split(":", 1)[1].strip() if ":" in raw else ""
    if not reason:
        sys.stderr.write(
            "'unrecoverable' needs a reason: --provenance 'unrecoverable: <why>'.\n"
            "An unexplained hole is what leaving the field null already achieves.\n")
        sys.exit(2)
    print("unrecoverable\tunrecoverable: %s" % reason)
    sys.exit(0)

# 2. A journal timestamp, validated against the journal itself.
if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", raw):
    jpath = os.environ["HY_JOURNAL"]
    if not os.path.exists(jpath):
        sys.stderr.write("--provenance looks like a journal ts but %s does not exist\n" % jpath)
        sys.exit(2)
    import json
    with open(jpath) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("ts") == raw:
                print("journal_ts\t%s" % raw)
                sys.exit(0)
    sys.stderr.write(
        "--provenance %s matches no line in the journal.\n"
        "A pointer nobody can follow is prose with extra syntax. Check the ts with\n"
        "`journal.sh tail --json`, or pass a repo-relative path instead.\n" % raw)
    sys.exit(2)

# 3. Otherwise a repo-relative source or artefact path, optionally :LINE.
if raw.startswith("/"):
    sys.stderr.write(
        "--provenance paths are repo-relative, got the absolute path %r.\n"
        "An absolute path stops resolving the moment the repo is cloned\n"
        "somewhere else, which will happen sooner than you expect.\n" % raw)
    sys.exit(2)

repo = os.environ["HY_REPO"]
candidate = raw
if not os.path.exists(os.path.join(repo, candidate)):
    # Only strip a :LINE suffix if the literal path did not already exist -
    # a filename may legitimately contain a colon.
    stripped = re.sub(r":\d+(?:-\d+)?$", "", raw)
    if stripped != raw and os.path.exists(os.path.join(repo, stripped)):
        print("path\t%s" % raw)
        sys.exit(0)
    sys.stderr.write(
        "--provenance %r is neither a journal ts (YYYY-MM-DDTHH:MM:SSZ) nor a path\n"
        "that exists under %s.\n" % (raw, repo))
    sys.exit(2)
print("path\t%s" % raw)
PY
}

# ---------------------------------------------------------------------------
# THE SIMILARITY CORE - one implementation, two callers.
#
# `similar` reports the nearest existing records to a draft; `new` runs the
# SAME function as a screen and refuses above the bar. They must be one piece
# of code, not two: a screen that scores differently from the report is a
# tool that lies about what it is going to do, and the whole value of the
# report is that you can predict the refusal from it.
#
# HOW IT SCORES. The numbers below are illustrative - measured once against a
# real corpus of a few dozen records to show the argument has teeth, not
# guaranteed for yours. Recompute them against your own registry.
#
#   TOKENS are /[a-z_][a-z0-9_]*/ over the lowercased text. Alpha-initial, so
#   bare numbers drop out entirely. That is deliberate: a registry like this
#   is dense with measurements ("0.4991", "18.7 ms", "run-42"), and two
#   records citing DIFFERENT numbers about the same mechanism are still the
#   same idea, while two records that merely both say "0" are not.
#   Identifiers survive whole - a parameter name, a run id, a path fragment.
#
#   THE DOCUMENT IS claim + operative-field, and the operative field is
#   weighted 2x. For a hypothesis that field is the falsifier; for a task it
#   is done_when. The falsifier is the experiment; the claim is the story
#   told about it. Two records with the same falsifier are the same booking
#   of a resource however differently the prose reads. This is not
#   decorative: for illustration, at EQUAL weights the loudest true negative
#   in a full creation-order replay of a real corpus sat right at a naive
#   0.60 bar; weighting the falsifier 2x pushed it down to a clearly
#   separated figure in the mid-0.50s.
#
#   THE STOPLIST IS DERIVED FROM THE CORPUS, not written by hand: any token
#   appearing in >= 30% of records is dropped. It has to be derived, because
#   the words that carry no information here are THIS project's own
#   vocabulary - whatever nouns and identifiers recur across most records -
#   and a hand-written English stoplist would leave every record looking
#   like every other. The exact fraction barely matters in practice: swept
#   across a reasonable range, the loudest true negative and the least
#   similar seeded near-duplicate both move only slightly.
#
#   COSINE over those weights, L2-normalised, so a long claim and a short
#   claim are comparable. Without it every long record would look similar to
#   every other long record.
#
# THE BAR defaults to 0.60, and it is a screen rather than a judgement. In a
# real replay of a real corpus: nothing genuinely different scored much above
# 0.5, a reworded near-duplicate scored in the high 0.70s to low 0.80s, and
# an unrelated claim scored around 0.15. So the bar sits in a wide gap with
# margin on both sides - recompute this against your own corpus rather than
# trusting the illustrative figures here.
#
# WHAT IT WILL MISS, stated because a screen that oversells itself is worse
# than none: a HEAVY reword of an existing record - same mechanism, no shared
# phrasing - can still land inside the true-negative band and pass. That is
# not fixable by moving the bar without refusing real work. This is a cheap
# lexical screen against re-drafting an idea in different words. It is not a
# semantic duplicate detector and must not be described as one.
#
# THE FLOOR: a draft with fewer than 10 distinct content tokens after
# stoplisting is not compared at all, and says so on stderr. Short strings
# hit high cosine by accident - "c"/"f" against "c"/"f" is 1.0.
#
# NOTHING MINED IS EVER WRITTEN DOWN. No neighbour id, no score and no link
# enters a record from this path, in either caller. The similarity of two
# records is a function of their text and of the corpus's document
# frequencies, both of which move as the registry grows; a cached neighbour
# would be a stale assertion that no later read could tell from a fresh one.
# It is recomputed at read time, every time.
# ---------------------------------------------------------------------------
SIM_THRESHOLD="${RL_SIM_THRESHOLD:-0.60}"
SIM_DF_FRACTION="${RL_SIM_DF_FRACTION:-0.30}"
SIM_FALSIFIER_WEIGHT="${RL_SIM_FALSIFIER_WEIGHT:-2.0}"
SIM_MIN_CONTENT_TOKENS="${RL_SIM_MIN_TOKENS:-10}"

# run_similarity <mode> <claim> <operative-text> <top-n>
#   mode=report  print the nearest records to stdout; exit 0 if any, 1 if none
#   mode=screen  print nothing unless the bar is crossed, in which case print
#                the same report to stderr and exit 2
run_similarity() {
    require_python
    HY_DIR="$REGISTRY" HY_MODE="$1" HY_CLAIM="$2" HY_OPERATIVE="$3" HY_TOP="$4" \
    HY_THRESH="$SIM_THRESHOLD" HY_DF_FRAC="$SIM_DF_FRACTION" \
    HY_WF="$SIM_FALSIFIER_WEIGHT" HY_MIN_TOK="$SIM_MIN_CONTENT_TOKENS" \
    python3 - <<'PY'
import json, math, os, re, sys

d = os.environ["HY_DIR"]
mode = os.environ["HY_MODE"]
thresh = float(os.environ["HY_THRESH"])
df_frac = float(os.environ["HY_DF_FRAC"])
wf = float(os.environ["HY_WF"])
min_tok = int(os.environ["HY_MIN_TOK"])
top_n = int(os.environ["HY_TOP"] or 3)
out = sys.stderr if mode == "screen" else sys.stdout

TOKEN_RE = re.compile(r"[a-z_][a-z0-9_]*")
SENT_RE = re.compile(r"(?<=[.!?])\s+")

def toks(t):
    return TOKEN_RE.findall((t or "").lower())

def operative(r):
    """The field that says what would settle it: falsifier, or done_when for a
    task. One slot, because the two kinds answer the same question with
    different words and a record has exactly one of them."""
    return r.get("falsifier") or r.get("done_when") or ""

recs = []
if os.path.isdir(d):
    for fn in sorted(os.listdir(d)):
        if fn.endswith(".json"):
            try:
                with open(os.path.join(d, fn)) as fh:
                    recs.append(json.load(fh))
            except ValueError:
                continue

def doc(claim, op):
    v = {}
    for t in toks(claim):
        v[t] = v.get(t, 0.0) + 1.0
    for t in toks(op):
        v[t] = v.get(t, 0.0) + wf
    return v

# Document frequency over the corpus in scope. Recomputed on every call: the
# stoplist is a property of the registry as it stands, and the registry grows.
n = len(recs)
df = {}
for r in recs:
    for t in set(toks(r.get("claim")) + toks(operative(r))):
        df[t] = df.get(t, 0) + 1
stop = {t for t, c in df.items() if c >= df_frac * n} if n else set()

def strip(v):
    return {t: w for t, w in v.items() if t not in stop}

def cosine(a, b):
    common = set(a) & set(b)
    if not common:
        return 0.0
    na = math.sqrt(sum(w * w for w in a.values()))
    nb = math.sqrt(sum(w * w for w in b.values()))
    if na == 0.0 or nb == 0.0:
        return 0.0
    return sum(a[t] * b[t] for t in common) / (na * nb)

query = strip(doc(os.environ.get("HY_CLAIM", ""), os.environ.get("HY_OPERATIVE", "")))
if len(query) < min_tok:
    sys.stderr.write(
        "note: duplicate screen skipped - the draft has %d distinct content tokens\n"
        "after stoplisting, below the floor of %d. Short strings collide by accident.\n"
        % (len(query), min_tok))
    sys.exit(1 if mode == "report" else 0)

def matched_sentence(r, qtoks):
    """The sentence of the record that overlaps the draft most. Reported so a
    reader can see WHERE the two texts meet, rather than being told a number
    and asked to trust it."""
    best, best_n, best_field = "", 0, ""
    for field, text in (("claim", r.get("claim") or ""), ("falsifier", operative(r))):
        for s in SENT_RE.split(text):
            s = s.strip()
            st = set(toks(s)) - stop
            if len(toks(s)) < 4:
                continue
            hit = len(st & qtoks)
            if hit > best_n:
                best, best_n, best_field = s, hit, field
    return best, best_field

qtoks = set(query)
scored = []
for r in recs:
    v = strip(doc(r.get("claim"), operative(r)))
    if len(v) < min_tok:
        continue
    scored.append((cosine(query, v), r))
# Sorted on the similarity and on the id, and on NOTHING ELSE. Explicitly not
# on in-degree, dependant count or how often a record is cited: a record that
# many others depend on is more IMPORTANT, which is a different question from
# whether it is the same idea as this draft, and letting importance leak into
# this ordering would quietly turn a duplicate check into a popularity list.
scored.sort(key=lambda p: (-p[0], p[1]["id"][0], int(p[1]["id"][1:])))

fired = bool(scored) and scored[0][0] >= thresh
# A REPORT shows the nearest few whatever their distance -- that is what it is
# for. A REFUSAL shows only what it is actually refusing over: padding the
# refusal out to three would put records the screen has no complaint about
# under a heading that says it does, which is how a reader learns to skim it.
hits = [p for p in scored if p[0] >= thresh][:top_n] if mode == "screen" \
    else scored[:top_n]
if mode == "screen" and not fired:
    sys.exit(0)
if mode == "report" and not hits:
    out.write("no comparable records in the registry (%d present).\n" % n)
    sys.exit(1)

if mode == "screen":
    near = [r["id"] for s, r in scored if s >= thresh]
    out.write(
        "refusing: this draft reads as a duplicate of %s.\n"
        % ", ".join(near))
    out.write(
        "A duplicate booking costs real time on a contended shared resource,\n"
        "and some parameters get retuned repeatedly without their underlying\n"
        "form ever changing -- exactly what this screen exists to catch before\n"
        "the booking happens.\n\n")
else:
    out.write("%d nearest of %d records. Read the FALSIFIER, not the claim:\n"
              % (len(hits), n))
    out.write("two records with the same falsifier are the same experiment,\n"
              "however differently the claim is written.\n\n")

for s, r in hits:
    kind = r.get("kind", "hypothesis")
    tg = ",".join(r.get("targets") or []) or "-"
    out.write("%s  [%s]  %s  %s\n"
              % (r["id"], r.get("state"), r.get("family"),
                 ("targets: " + tg) if kind != "task" else ("priority: %s" % r.get("priority"))))
    sent, field = matched_sentence(r, qtoks)
    if sent:
        out.write("  matched sentence (from its %s):\n" % field)
        out.write("    %s\n" % sent)
    label = "falsifier" if kind != "task" else "done_when"
    out.write("  %s, VERBATIM:\n" % label)
    for line in (operative(r) or "(none)").splitlines() or ["(none)"]:
        out.write("    %s\n" % line)
    out.write("\n")

if mode == "screen":
    out.write("If it is genuinely a different claim, say what differs and proceed:\n")
    out.write("  new ... --not-a-duplicate \"<one sentence on what differs>\"\n")
    out.write("That sentence is written into history[] and is reviewable in git diff.\n")
    sys.exit(2)
sys.exit(0)
PY
}

# ---------------------------------------------------------------------------
# similar - what has been claimed before?
# ---------------------------------------------------------------------------
cmd_similar() {
    local claim="" falsifier="" top=3
    if [[ $# -gt 0 && "$1" != -* ]]; then claim="$1"; shift; fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --claim)      claim="$2"; shift 2 ;;
            --falsifier)  falsifier="$2"; shift 2 ;;
            --done-when)  falsifier="$2"; shift 2 ;;
            -n|--limit)   top="$2"; shift 2 ;;
            -h|--help)    usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done
    [[ -z "$claim" ]] && { echo "usage: similar \"<claim>\" [--falsifier \"...\"] [-n N]" >&2; usage 2; }
    run_similarity report "$claim" "$falsifier" "$top"
}

# ---------------------------------------------------------------------------
# new
# ---------------------------------------------------------------------------
cmd_new() {
    local family="" claim="" falsifier="" test_cost="" depends_on="" id=""
    local state="open" blocked_on="" attempts="" tested_by="" backfilled=0 source_ts=""
    local kind="hypothesis" done_when="" priority="" targets="" provenance=""
    local not_a_duplicate=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --family)      family="$2"; shift 2 ;;
            --claim)       claim="$2"; shift 2 ;;
            --falsifier)   falsifier="$2"; shift 2 ;;
            --targets)     targets="$2"; shift 2 ;;
            --provenance)  provenance="$2"; shift 2 ;;
            --test-cost)   test_cost="$2"; shift 2 ;;
            --depends-on)  depends_on="$2"; shift 2 ;;
            --id)          id="$2"; shift 2 ;;
            --kind)        kind="$2"; shift 2 ;;
            --done-when)   done_when="$2"; shift 2 ;;
            --priority)    priority="$2"; shift 2 ;;
            # The five below are BACKFILL ONLY: they let a record be created
            # already in a non-open state, reconstructed from journal prose.
            # Normal creation never uses them - a new hypothesis is `open`.
            --state)       state="$2"; shift 2 ;;
            --blocked-on)  blocked_on="$2"; shift 2 ;;
            --attempts)    attempts="$2"; shift 2 ;;
            --tested-by)   tested_by="$2"; shift 2 ;;
            --backfilled)  backfilled=1; shift ;;
            --source-ts)   source_ts="$2"; shift 2 ;;
            # The override for the duplicate screen. One sentence on what
            # differs, written into history[] so the judgement is reviewable
            # in `git diff` rather than made silently.
            --not-a-duplicate) not_a_duplicate="$2"; shift 2 ;;
            -h|--help)     usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done

    in_list "$kind" "${KINDS[@]}" || {
        echo "unknown kind '$kind' - must be one of: ${KINDS[*]}" >&2; exit 2; }

    # --source-ts is the pre-existing backfill flag, and for a record rebuilt
    # from a journal note that note IS the evidence - so it feeds the same
    # single field rather than justifying a second one. Applied for both kinds,
    # before the kind branch, so backfill behaves the same either side of it.
    if [[ -z "$provenance" && -n "$source_ts" ]]; then
        provenance="$source_ts"
    fi

    [[ -z "$family"    ]] && { echo "--family is required" >&2; usage 2; }
    [[ -z "$claim"     ]] && { echo "--claim is required" >&2; usage 2; }
    [[ -z "$test_cost" ]] && { echo "--test-cost is required (probe|run)" >&2; usage 2; }

    # The required-field split is the whole reason tasks are a separate kind
    # rather than a family. A hypothesis is refused without a falsifier - that
    # is the most valuable constraint in this file. A task has no falsifier; it
    # has a definition of done. Letting tasks in as a family would have forced
    # either fake falsifiers or an optional --falsifier, and both destroy the
    # discipline for actual hypotheses.
    if [[ "$kind" == "hypothesis" ]]; then
        [[ -z "$falsifier" ]] && {
            echo "--falsifier is required - a hypothesis with no falsifier is not a hypothesis" >&2; usage 2; }
        # Required for the same reason --falsifier is. A hypothesis that cannot
        # name which of your TARGETS it bears on is not obviously worth the
        # expensive resource, and without this the ranking has no goal-facing
        # signal at all.
        [[ -z "$targets" ]] && {
            echo "--targets is required - name which condition(s) this bears on: ${TARGETS[*]}" >&2; usage 2; }
        local t
        for t in ${targets//,/ }; do
            in_list "$t" "${TARGETS[@]}" || {
                echo "unknown target '$t' - must be one of: ${TARGETS[*]}" >&2; exit 2; }
        done
        [[ -n "$done_when" ]] && {
            echo "--done-when is for tasks; a hypothesis takes --falsifier" >&2; usage 2; }
        [[ -n "$priority" ]] && {
            echo "--priority is for tasks; hypotheses are ordered by 'next'" >&2; usage 2; }
        # Required for the same reason --falsifier and --targets are. A
        # hypothesis that cannot name the result it came from is
        # indistinguishable from one invented on the spot.
        [[ -z "$provenance" ]] && {
            echo "--provenance is required - name the result this came from: a journal ts" >&2
            echo "(validated against journal.ndjson) or a repo-relative path to the report," >&2
            echo "artefact or source line that generated it. Prose in the claim is not a field." >&2
            usage 2; }
    else
        [[ -n "$targets" ]] && {
            echo "--targets is for hypotheses; a task is not aimed at one of your TARGETS" >&2; usage 2; }
        [[ -z "$done_when" ]] && {
            echo "--done-when is required for a task - say what finishing looks like" >&2; usage 2; }
        [[ -n "$falsifier" ]] && {
            echo "--falsifier is for hypotheses; a task takes --done-when" >&2; usage 2; }
        [[ -z "$priority" ]] && priority=chore
        in_list "$priority" "${PRIORITIES[@]}" || {
            echo "unknown priority '$priority' - must be one of: ${PRIORITIES[*]}" >&2; exit 2; }
    fi

    in_list "$family" "${FAMILIES[@]}" || {
        echo "unknown family '$family' - must be one of: ${FAMILIES[*]}" >&2; exit 2; }
    in_list "$test_cost" "${TIERS[@]}" || {
        echo "unknown test-cost '$test_cost' - must be one of: ${TIERS[*]}" >&2; exit 2; }
    in_list "$state" "${STATES[@]}" || {
        echo "unknown state '$state' - must be one of: ${STATES[*]}" >&2; exit 2; }
    if [[ "$state" == "blocked" && -z "$blocked_on" ]]; then
        echo "state 'blocked' requires --blocked-on" >&2; exit 2
    fi

    # Tasks are exempt from NEEDING provenance, but if one is offered it is held
    # to the same standard - an optional field that is not validated is worse
    # than no field, because it looks checked.
    local prov_kind="" prov_source="" resolved=""
    if [[ -n "$provenance" ]]; then
        resolved="$(resolve_provenance "$provenance")" || exit 2
        prov_kind="${resolved%%$'\t'*}"
        prov_source="${resolved#*$'\t'}"
        if [[ "$prov_kind" == "unrecoverable" && "$backfilled" != "1" ]]; then
            echo "'unrecoverable' provenance is only accepted with --backfilled." >&2
            echo "On a record being written now, the source is whatever you are looking at;" >&2
            echo "allowing the sentinel here would be a hole straight through the rule." >&2
            exit 2
        fi
    fi

    # -----------------------------------------------------------------------
    # THE DUPLICATE SCREEN. This is the call site: the measure can exist and
    # be documented at length and still do nothing if `new` never calls it.
    #
    # It runs LAST, after every field has been validated, so a usage error is
    # never reported as a duplicate - and it runs BEFORE anything is written,
    # so a refusal leaves no file behind.
    #
    # It applies to both kinds and to backfills. A task can be a duplicate as
    # easily as a hypothesis, and a backfilled record that duplicates a live
    # one is exactly the confusion the registry exists to prevent; there is no
    # exemption because an exemption is a hole and the override is one flag.
    # -----------------------------------------------------------------------
    if [[ -z "$not_a_duplicate" ]]; then
        run_similarity screen "$claim" "${falsifier:-$done_when}" 3
        [[ $? -eq 2 ]] && exit 2
    fi

    mkdir -p "$REGISTRY"
    local commit
    commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"

    require_python
    HY_DIR="$REGISTRY" HY_ID="$id" HY_FAMILY="$family" HY_CLAIM="$claim" \
    HY_FALSIFIER="$falsifier" HY_TEST_COST="$test_cost" HY_DEPENDS="$depends_on" \
    HY_STATE="$state" HY_BLOCKED_ON="$blocked_on" HY_ATTEMPTS="$attempts" \
    HY_TESTED_BY="$tested_by" HY_BACKFILLED="$backfilled" HY_COMMIT="$commit" \
    HY_SOURCE_TS="$source_ts" HY_KIND="$kind" HY_DONE_WHEN="$done_when" \
    HY_PRIORITY="$priority" HY_TARGETS="$targets" \
    HY_PROV_KIND="$prov_kind" HY_PROV_SOURCE="$prov_source" \
    HY_NOT_DUP="$not_a_duplicate" \
    python3 - <<'PY'
import json, os, re, sys, datetime

d = os.environ["HY_DIR"]
def g(k):
    v = os.environ.get(k, "")
    return v if v != "" else None

def csv(k):
    v = g(k)
    return [x.strip() for x in v.split(",") if x.strip()] if v else []

kind = g("HY_KIND") or "hypothesis"
prefix = "T" if kind == "task" else "H"

hid = g("HY_ID")
if hid is None:
    # Auto-allocate the next number in this kind's series. Scans existing files
    # rather than keeping a counter, so a hand-written record cannot collide
    # with a generated one. Tasks are T1, T2...; hypotheses H1, H2...
    nums = []
    for fn in os.listdir(d) if os.path.isdir(d) else []:
        m = re.fullmatch(re.escape(prefix) + r"(\d+)\.json", fn)
        if m:
            nums.append(int(m.group(1)))
    hid = "%s%d" % (prefix, max(nums) + 1 if nums else 1)

if not re.fullmatch(r"[A-Z]{1,2}\d+", hid):
    sys.stderr.write("id must look like H5, T1 or L1, got %r\n" % hid)
    sys.exit(2)

path = os.path.join(d, hid + ".json")
if os.path.exists(path):
    sys.stderr.write("%s already exists - hypotheses are never overwritten\n" % path)
    sys.exit(2)

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
state = g("HY_STATE") or "open"
backfilled = os.environ.get("HY_BACKFILLED") == "1"
attempts = int(g("HY_ATTEMPTS") or 0)

prov = None
if g("HY_PROV_KIND"):
    prov = {
        "source": g("HY_PROV_SOURCE"),
        "kind": g("HY_PROV_KIND"),
        # Marked the way `backfilled` already is, so a reconstruction is never
        # mistaken for a pointer written at the moment the idea arrived.
        "backfilled": backfilled,
        "recorded_ts": now,
    }

rec = {
    "id": hid,
    "kind": kind,
    "family": g("HY_FAMILY"),
    "claim": g("HY_CLAIM"),
    "falsifier": g("HY_FALSIFIER"),
    "provenance": prov,
    "done_when": g("HY_DONE_WHEN"),
    "priority": g("HY_PRIORITY"),
    "targets": csv("HY_TARGETS"),
    "metric_deltas": [],
    "superseded_by": None,
    "test_cost": g("HY_TEST_COST"),
    "state": state,
    "depends_on": csv("HY_DEPENDS"),
    "blocked_on": g("HY_BLOCKED_ON"),
    "attempts": attempts,
    # True when `attempts` includes one attempt that was interrupted and
    # never completed; the next entry to `testing` resumes it rather than
    # spending a second one. Written explicitly rather than left absent, so a
    # reader of the JSON never has to know that a missing key means false.
    "attempt_carried": False,
    "tested_by": csv("HY_TESTED_BY"),
    "backfilled": backfilled,
    "created_ts": now,
    "updated_ts": now,
    "history": [{
        "ts": now,
        "from": None,
        "to": state,
        # A backfilled record says so in its own history, so nobody later
        # mistakes a reconstruction for a contemporaneous record.
        "evidence": ("backfilled from journal prose"
                     + (" at " + g("HY_SOURCE_TS") if g("HY_SOURCE_TS") else "")
                     if backfilled else "created"),
        "commit": g("HY_COMMIT"),
    }],
}

# The override, and ONLY the override. The screen's own finding -- which
# records it matched, and how closely -- is deliberately NOT written here: a
# mined link is a function of the text AND of the corpus's document
# frequencies, both of which move as the registry grows, so a cached neighbour
# would be a stale assertion that no later read could distinguish from a fresh
# one. What is durable is the human sentence saying what differs, and that is
# what a reviewer of the git diff needs.
if g("HY_NOT_DUP"):
    rec["history"][0]["not_a_duplicate"] = g("HY_NOT_DUP")

tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(rec, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
print("created %s (%s, %s, %s)" % (hid, rec["family"], rec["test_cost"], state))
PY
}

# ---------------------------------------------------------------------------
# set-state
# ---------------------------------------------------------------------------
cmd_set_state() {
    [[ $# -lt 2 ]] && { echo "usage: set-state <id> <state> --evidence \"...\"" >&2; usage 2; }
    local id="$1" to="$2"; shift 2
    local evidence="" run_id="" blocked_on="" new_mechanism="" override_cap=""
    local superseded_by="" interrupted_by="" metric_deltas=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --evidence)       evidence="$2"; shift 2 ;;
            --run-id)         run_id="$2"; shift 2 ;;
            --blocked-on)     blocked_on="$2"; shift 2 ;;
            --new-mechanism)  new_mechanism="$2"; shift 2 ;;
            --override-cap)   override_cap="$2"; shift 2 ;;
            --superseded-by)  superseded_by="$2"; shift 2 ;;
            # The recovery edge testing/doing -> open. Says what killed the
            # agent, and is refused anywhere else so it cannot become decoration.
            --interrupted-by) interrupted_by="$2"; shift 2 ;;
            # Repeatable: --metric-delta 'median_error: 8.21 -> 8.03'
            --metric-delta)   metric_deltas+=("$2"); shift 2 ;;
            -h|--help)        usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done

    in_list "$to" "${STATES[@]}" || {
        echo "unknown state '$to' - must be one of: ${STATES[*]}" >&2; exit 2; }
    [[ -z "$evidence" ]] && {
        echo "--evidence is required: a state change with no stated reason is unreviewable" >&2; usage 2; }

    local commit
    commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"

    require_python
    HY_DIR="$REGISTRY" HY_ID="$id" HY_TO="$to" HY_EVIDENCE="$evidence" \
    HY_RUN_ID="$run_id" HY_BLOCKED_ON="$blocked_on" HY_NEW_MECH="$new_mechanism" \
    HY_OVERRIDE="$override_cap" HY_COMMIT="$commit" HY_CAP="$ATTEMPT_CAP" \
    HY_SUPERSEDED_BY="$superseded_by" HY_TARGETS="${TARGETS[*]}" \
    HY_INTERRUPTED_BY="$interrupted_by" \
    HY_DELTAS="$(printf '%s\n' ${metric_deltas+"${metric_deltas[@]}"})" \
    python3 - <<'PY'
import json, os, re, sys, datetime

# One transition table per kind. Absent key or absent target = illegal.
#
# They differ because the objects differ. A hypothesis is a conjecture that
# gets spent: it is tested, and terminal means confirmed or falsified. A task
# is an obligation that gets discharged: it is worked, and terminal means done
# or explicitly dropped. Sharing one table would have meant a task could be
# "falsified", which is meaningless, or a hypothesis "done", which hides
# whether it was answered.
LEGAL_BY_KIND = {
    "hypothesis": {
        # `superseded` is reachable from every non-terminal state: a hypothesis
        # can be made moot by another result before it is ever tested, and
        # without this edge the only ways to record that were to leave it open
        # forever (where `next` keeps offering it) or to mark it falsified,
        # which would claim evidence that does not exist.
        "open":       {"testing", "blocked", "superseded"},
        # `open` direct from `testing`: the agent deciding it died, so nothing
        # was decided. Guarded by --interrupted-by rather than --new-mechanism,
        # because this resurrects nothing -- no evidence ever arrived. The
        # attempt is HELD, not restored; see the header.
        "testing":    {"confirmed", "falsified", "blocked", "superseded", "open"},
        # `falsified` direct from `blocked`: the evidence that unblocks a
        # record often IS the evidence that kills it, and routing that verdict
        # through open -> testing spends the resurrection gate and an attempt
        # to record a result nobody is still deciding. Safe because falsified
        # is terminal. `confirmed` is deliberately NOT here: it claims a gate
        # passed, which means a test ran, which means `testing`.
        "blocked":    {"open", "falsified", "superseded"},
        "confirmed":  set(),
        "falsified":  set(),
        "superseded": set(),
    },
    "task": {
        "open":    {"doing", "blocked", "dropped"},
        # `open` direct from `doing`, the same edge and the same guard as the
        # hypothesis table's testing -> open. A task has no attempts, so there
        # is nothing to hold: it comes back at 0, exactly as it left.
        "doing":   {"done", "blocked", "dropped", "open"},
        "blocked": {"open"},
        "done":    set(),
        "dropped": set(),
    },
}

def g(k):
    v = os.environ.get(k, "")
    return v if v != "" else None

d, hid, to = os.environ["HY_DIR"], os.environ["HY_ID"], os.environ["HY_TO"]
cap = int(os.environ["HY_CAP"])
path = os.path.join(d, hid + ".json")
if not os.path.exists(path):
    sys.stderr.write("no such hypothesis: %s\n" % hid)
    sys.exit(1)

with open(path) as fh:
    rec = json.load(fh)
frm = rec["state"]
kind = rec.get("kind", "hypothesis")
LEGAL = LEGAL_BY_KIND[kind]

if to == frm:
    sys.stderr.write("%s is already %s - no transition to record\n" % (hid, frm))
    sys.exit(2)
if to not in LEGAL.get(frm, set()):
    extra = ""
    if frm in ("falsified", "done", "dropped", "superseded"):
        extra = (" %s is terminal by design: delete the file by hand if it must"
                 " genuinely be revived." % frm)
    elif to not in LEGAL_BY_KIND["task" if kind == "hypothesis" else "hypothesis"].get(frm, set()):
        pass
    else:
        extra = (" '%s' belongs to the other kind; %s is a %s." % (to, hid, kind))
    sys.stderr.write("illegal transition %s -> %s for %s.%s\n" % (frm, to, hid, extra))
    sys.exit(2)

# Guards on specific edges.
if to == "blocked" and not g("HY_BLOCKED_ON"):
    sys.stderr.write("--blocked-on is required when blocking: say what it waits on\n")
    sys.exit(2)
if frm == "blocked" and to == "open" and not g("HY_NEW_MECH"):
    sys.stderr.write(
        "reopening a blocked hypothesis requires --new-mechanism: name what is\n"
        "materially new. Renewed enthusiasm is not a mechanism.\n")
    sys.exit(2)

# The recovery edge, and the only edge --interrupted-by belongs on. It is
# REQUIRED here for the same reason --blocked-on is required when blocking: a
# record that walks backwards out of an attempt with no stated cause is
# indistinguishable from an agent quietly un-testing something it did not like.
# It is REFUSED elsewhere for the reason --superseded-by is: an optional flag
# that lands on any transition is decoration, and decoration in history[] is
# noise in the one place that has to stay readable.
RECOVERY_EDGE = (frm in ("testing", "doing") and to == "open")
if RECOVERY_EDGE and not g("HY_INTERRUPTED_BY"):
    sys.stderr.write(
        "recovering an interrupted attempt requires --interrupted-by: name what\n"
        "stopped the agent (a usage limit, a hung call, a killed tick). This edge\n"
        "exists because nothing DECIDED the record -- if something did, the honest\n"
        "transition is confirmed/falsified/done/dropped, or blocked with a cause.\n")
    sys.exit(2)
if g("HY_INTERRUPTED_BY") and not RECOVERY_EDGE:
    sys.stderr.write(
        "--interrupted-by only applies to the recovery edge (testing -> open for a\n"
        "hypothesis, doing -> open for a task), got %s -> %s\n" % (frm, to))
    sys.exit(2)

# Nullifying a hypothesis is legitimate - the loop may revise which hypothesis
# it tests - but it has to name the result that made this one moot, so that a
# future reader can check the reasoning rather than take it on trust.
if to == "superseded":
    sup = g("HY_SUPERSEDED_BY")
    if not sup:
        sys.stderr.write(
            "--superseded-by <id> is required: name the record that made this moot.\n"
            "Nullifying without a cause is indistinguishable from losing interest.\n")
        sys.exit(2)
    if not os.path.exists(os.path.join(d, sup + ".json")):
        sys.stderr.write("--superseded-by names %s, which does not exist\n" % sup)
        sys.exit(2)
    if sup == hid:
        sys.stderr.write("%s cannot supersede itself\n" % hid)
        sys.exit(2)
elif g("HY_SUPERSEDED_BY"):
    sys.stderr.write("--superseded-by only applies when moving to 'superseded'\n")
    sys.exit(2)

# Structured outcome: "median_error: 8.21 -> 8.03". Parsed rather than kept as
# prose so that "which families have ever moved a target metric" becomes a
# query instead of an act of memory.
VALID_TARGETS = set(os.environ["HY_TARGETS"].split())
deltas = []
for line in (os.environ.get("HY_DELTAS") or "").splitlines():
    line = line.strip()
    if not line:
        continue
    m = re.match(r"^\s*([a-z_]+)\s*:\s*(-?[\d.]+)\s*->\s*(-?[\d.]+)\s*$", line)
    if not m:
        sys.stderr.write(
            "cannot parse --metric-delta %r\n"
            "expected: '<metric>: <before> -> <after>', e.g. 'median_error: 8.21 -> 8.03'\n"
            % line)
        sys.exit(2)
    name, before, after = m.group(1), float(m.group(2)), float(m.group(3))
    if name not in VALID_TARGETS:
        sys.stderr.write("unknown metric %r - must be one of: %s\n"
                         % (name, " ".join(sorted(VALID_TARGETS))))
        sys.exit(2)
    deltas.append({"metric": name, "before": before, "after": after})

TERMINAL_STATES = {"confirmed", "falsified", "superseded", "done", "dropped"}
if deltas and to not in TERMINAL_STATES:
    sys.stderr.write("--metric-delta belongs on a terminal transition, not on '%s'\n" % to)
    sys.exit(2)
# The attempt cap is a hypothesis concept: a conjecture that has survived
# ATTEMPT_CAP clean tests should be retired. A task is an obligation - you do
# not stop fixing a broken build because you have tried three times - so
# `doing` neither counts nor caps.
#
# ATTEMPTS ARE HELD, NOT RESTORED. Recovery does not decrement: the attempt
# really was spent. The record carries the fact instead, and the next entry
# to `testing` RESUMES that attempt rather than spending a second one for the
# same never-completed test. The cap does not bind on a resume, because
# nothing new is being spent -- refusing there would put the --override-cap
# machinery in front of a record that was interrupted rather than exhausted,
# which is precisely the friction an agent under time pressure routes around.
resumed_attempt = None
if to == "testing":
    if rec.get("attempt_carried"):
        resumed_attempt = rec["attempts"]
        rec["attempt_carried"] = False
    else:
        if rec["attempts"] >= cap and not g("HY_OVERRIDE"):
            sys.stderr.write(
                "%s has had %d attempts and the cap is %d. Retire it, or pass\n"
                "--override-cap \"<why this one is different>\".\n" % (hid, rec["attempts"], cap))
            sys.exit(2)
        rec["attempts"] += 1
if RECOVERY_EDGE and rec["attempts"] > 0:
    # A task never gets here with attempts > 0 -- `doing` neither counts nor
    # caps -- so this is the hypothesis case, and it is keyed on the counter
    # rather than on the kind so a backfilled record behaves the same way.
    rec["attempt_carried"] = True

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rec["state"] = to
rec["updated_ts"] = now
# Captured before the field is nulled: leaving `blocked` clears blocked_on, so
# the text either goes into history on the way out or is lost from the record
# entirely (recoverable only from a git diff). That matters most on the kill
# edge - a blocked -> falsified verdict should still say what the record had
# been waiting for when the evidence arrived.
was_blocked_on = rec.get("blocked_on") if frm == "blocked" else None
rec["blocked_on"] = g("HY_BLOCKED_ON") if to == "blocked" else None
if to == "superseded":
    rec["superseded_by"] = g("HY_SUPERSEDED_BY")
if deltas:
    rec.setdefault("metric_deltas", []).extend(deltas)
run_id = g("HY_RUN_ID")
if run_id and run_id not in rec["tested_by"]:
    rec["tested_by"].append(run_id)

entry = {"ts": now, "from": frm, "to": to,
         "evidence": g("HY_EVIDENCE"), "commit": g("HY_COMMIT")}
if was_blocked_on:
    entry["blocked_on_cleared"] = was_blocked_on
if g("HY_NEW_MECH"):
    entry["new_mechanism"] = g("HY_NEW_MECH")
if g("HY_OVERRIDE"):
    entry["override_cap"] = g("HY_OVERRIDE")
if g("HY_INTERRUPTED_BY"):
    entry["interrupted_by"] = g("HY_INTERRUPTED_BY")
# Why the counter did not move. Without it a resume reads in `git diff` as a
# transition into `testing` that forgot to increment.
if resumed_attempt is not None:
    entry["resumed_attempt"] = resumed_attempt
if to == "superseded":
    entry["superseded_by"] = g("HY_SUPERSEDED_BY")
if deltas:
    entry["metric_deltas"] = deltas
# History is append-only INSIDE the mutable file: the record's current state is
# a field, but how it got there is never rewritten.
rec["history"].append(entry)

tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(rec, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
carried = " [1 held for the interrupted attempt]" if rec.get("attempt_carried") else ""
if resumed_attempt is not None:
    carried = " [resumed the interrupted attempt; none spent]"
print("%s: %s -> %s (attempts %d)%s" % (hid, frm, to, rec["attempts"], carried))
PY
}

# ---------------------------------------------------------------------------
# retarget - correct which of your TARGETS a hypothesis bears on
# ---------------------------------------------------------------------------
cmd_retarget() {
    [[ $# -lt 1 ]] && { echo "usage: retarget <id> --targets a,b --reason \"...\"" >&2; usage 2; }
    local id="$1"; shift
    local targets="" reason=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --targets) targets="$2"; shift 2 ;;
            --reason)  reason="$2"; shift 2 ;;
            -h|--help) usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done
    [[ -z "$targets" ]] && { echo "--targets is required" >&2; usage 2; }
    [[ -z "$reason"  ]] && { echo "--reason is required: changing what a hypothesis is aimed at is a substantive edit" >&2; usage 2; }
    local t
    for t in ${targets//,/ }; do
        in_list "$t" "${TARGETS[@]}" || {
            echo "unknown target '$t' - must be one of: ${TARGETS[*]}" >&2; exit 2; }
    done

    local commit
    commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"

    require_python
    HY_DIR="$REGISTRY" HY_ID="$id" HY_TARGETS="$targets" HY_REASON="$reason" \
    HY_COMMIT="$commit" python3 - <<'PY'
import json, os, sys, datetime
d, hid = os.environ["HY_DIR"], os.environ["HY_ID"]
path = os.path.join(d, hid + ".json")
if not os.path.exists(path):
    sys.stderr.write("no such hypothesis: %s\n" % hid)
    sys.exit(1)
with open(path) as fh:
    rec = json.load(fh)
if rec.get("kind", "hypothesis") == "task":
    sys.stderr.write("%s is a task; targets are a hypothesis concept\n" % hid)
    sys.exit(2)

new = [x.strip() for x in os.environ["HY_TARGETS"].split(",") if x.strip()]
old = rec.get("targets") or []
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rec["targets"] = new
rec["updated_ts"] = now
# Recorded in history like a state change: what a hypothesis claims to bear on
# is part of its argument, and silently editing it after a result would be the
# same class of move as editing a falsifier.
rec["history"].append({
    "ts": now, "from": rec["state"], "to": rec["state"],
    "evidence": "retargeted %s -> %s: %s" % (old or ["-"], new, os.environ["HY_REASON"]),
    "commit": os.environ.get("HY_COMMIT") or None,
})
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(rec, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
print("%s targets: %s -> %s" % (hid, ",".join(old) or "-", ",".join(new)))
PY
}

# ---------------------------------------------------------------------------
# provenance - attach or correct the source of an existing record
#
# `new` refuses to overwrite a record, so this is the only way an already-written
# hypothesis gains the field, and the only way a wrong pointer is corrected. It
# exists rather than a hand edit of the JSON because a record written by anything
# other than this script is exactly what the `????` sentinel in `list` is there
# to catch.
#
# Provenance set here is ALWAYS marked backfilled: the record already existed, so
# the pointer is a reconstruction by definition, however confident.
# ---------------------------------------------------------------------------
cmd_provenance() {
    [[ $# -lt 1 ]] && { echo "usage: provenance <id> --source <ts|path> --reason \"...\"" >&2; usage 2; }
    local id="$1"; shift
    local source="" reason=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source)  source="$2"; shift 2 ;;
            --reason)  reason="$2"; shift 2 ;;
            -h|--help) usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done
    [[ -z "$source" ]] && { echo "--source is required (a journal ts or a repo-relative path)" >&2; usage 2; }
    [[ -z "$reason" ]] && {
        echo "--reason is required: attaching evidence after the fact is a substantive edit," >&2
        echo "and the reasoning is what a later reader has to be able to check." >&2; usage 2; }

    local resolved prov_kind prov_source
    resolved="$(resolve_provenance "$source")" || exit 2
    prov_kind="${resolved%%$'\t'*}"
    prov_source="${resolved#*$'\t'}"

    local commit
    commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"

    require_python
    HY_DIR="$REGISTRY" HY_ID="$id" HY_PROV_KIND="$prov_kind" \
    HY_PROV_SOURCE="$prov_source" HY_REASON="$reason" HY_COMMIT="$commit" \
    python3 - <<'PY'
import json, os, sys, datetime
d, hid = os.environ["HY_DIR"], os.environ["HY_ID"]
path = os.path.join(d, hid + ".json")
if not os.path.exists(path):
    sys.stderr.write("no such hypothesis: %s\n" % hid)
    sys.exit(1)
with open(path) as fh:
    rec = json.load(fh)

old = rec.get("provenance") or {}
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rec["provenance"] = {
    "source": os.environ["HY_PROV_SOURCE"],
    "kind": os.environ["HY_PROV_KIND"],
    "backfilled": True,
    "recorded_ts": now,
}
rec["updated_ts"] = now
# Recorded in history like a retarget: what a hypothesis claims to rest on is
# part of its argument, and silently swapping it after a result would be the
# same class of move as silently editing a falsifier.
rec["history"].append({
    "ts": now, "from": rec["state"], "to": rec["state"],
    "evidence": "provenance %s -> %s: %s" % (old.get("source") or "-",
                                             rec["provenance"]["source"],
                                             os.environ["HY_REASON"]),
    "commit": os.environ.get("HY_COMMIT") or None,
})
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(rec, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
print("%s provenance: %s -> %s (%s, backfilled)"
      % (hid, old.get("source") or "-", rec["provenance"]["source"],
         rec["provenance"]["kind"]))
PY
}

# ---------------------------------------------------------------------------
# reblock - revise WHAT an already-blocked record is waiting for
#
# A blocker is not a fact about the record, it is a fact about the world, and
# the world moves while the record sits. `set-state` accepts --blocked-on only
# on the transition INTO blocked, and blocked -> blocked exits 2 as a no-op, so
# before this the only way to correct a discharged blocker was to launder the
# record through open - which needs --new-mechanism, a gate that exists to stop
# a loop RESURRECTING dead ideas and means something quite different from "the
# thing it was waiting for happened".
#
# The failure this prevents is not cosmetic. A record's blocker reads
# "dependency X reaching some milestone"; X reaches it and the record stays
# correctly blocked for an entirely different reason it had itself
# pre-registered. A tick reading the record sees a satisfied dependency and
# dispatches a hypothesis that nothing on disk can decide.
#
# THE OLD TEXT GOES INTO history[], not into the bin. blocked_on is a mutable
# field, so a bare overwrite would leave the record asserting the new blocker as
# if it had always been the blocker - the same class of move as silently editing
# a falsifier. Both kinds may be blocked, so both may be reblocked.
# ---------------------------------------------------------------------------
cmd_reblock() {
    [[ $# -lt 1 ]] && { echo "usage: reblock <id> --blocked-on \"...\" --reason \"...\"" >&2; usage 2; }
    local id="$1"; shift
    local blocked_on="" reason=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --blocked-on) blocked_on="$2"; shift 2 ;;
            --reason)     reason="$2"; shift 2 ;;
            -h|--help)    usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done
    [[ -z "$blocked_on" ]] && {
        echo "--blocked-on is required: say what the record is waiting on NOW" >&2; usage 2; }
    [[ -z "$reason" ]] && {
        echo "--reason is required: say what discharged or changed the old blocker." >&2
        echo "A blocker swapped silently is indistinguishable from one that was never right." >&2
        usage 2; }

    local commit
    commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"

    require_python
    HY_DIR="$REGISTRY" HY_ID="$id" HY_BLOCKED_ON="$blocked_on" HY_REASON="$reason" \
    HY_COMMIT="$commit" python3 - <<'PY'
import json, os, sys, datetime
d, hid = os.environ["HY_DIR"], os.environ["HY_ID"]
path = os.path.join(d, hid + ".json")
if not os.path.exists(path):
    sys.stderr.write("no such hypothesis: %s\n" % hid)
    sys.exit(1)
with open(path) as fh:
    rec = json.load(fh)

# Only a live blocker can be revised. Writing blocked_on onto an open or
# terminal record would produce a record whose state and blocker disagree,
# which is worse than the stale text this command exists to fix.
if rec["state"] != "blocked":
    sys.stderr.write(
        "%s is '%s', not blocked - reblock revises a LIVE blocker.\n"
        "To block it, use: set-state %s blocked --blocked-on \"...\" --evidence \"...\"\n"
        % (hid, rec["state"], hid))
    sys.exit(2)

new = os.environ["HY_BLOCKED_ON"].strip()
old = rec.get("blocked_on") or ""
if new == old:
    sys.stderr.write(
        "%s blocked_on is already exactly that - nothing to record.\n"
        "A history entry that changes nothing is noise in the one place that must stay readable.\n"
        % hid)
    sys.exit(2)

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rec["blocked_on"] = new
rec["updated_ts"] = now
# Same shape as retarget and provenance: a same-state history entry carrying the
# reason. The full old and new texts are kept as their own keys rather than
# interpolated into `evidence`, because a blocker runs to a paragraph and the
# history line is read by eye.
rec["history"].append({
    "ts": now, "from": rec["state"], "to": rec["state"],
    "evidence": "blocked_on revised: %s" % os.environ["HY_REASON"],
    "blocked_on_from": old or None,
    "blocked_on_to": new,
    "commit": os.environ.get("HY_COMMIT") or None,
})
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(rec, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
def brief(s, n=140):
    s = " ".join((s or "-").split())
    return s if len(s) <= n else s[:n] + "..."
print("%s blocked_on revised (still blocked)\n  was: %s\n  now: %s" % (hid, brief(old), brief(new)))
PY
}

# ---------------------------------------------------------------------------
# link
# ---------------------------------------------------------------------------
cmd_link() {
    [[ $# -lt 1 ]] && { echo "usage: link <id> --run-id <run>" >&2; usage 2; }
    local id="$1"; shift
    local run_id=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-id)  run_id="$2"; shift 2 ;;
            -h|--help) usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done
    [[ -z "$run_id" ]] && { echo "--run-id is required" >&2; usage 2; }

    require_python
    HY_DIR="$REGISTRY" HY_ID="$id" HY_RUN_ID="$run_id" python3 - <<'PY'
import json, os, sys, datetime
d, hid, run_id = os.environ["HY_DIR"], os.environ["HY_ID"], os.environ["HY_RUN_ID"]
path = os.path.join(d, hid + ".json")
if not os.path.exists(path):
    sys.stderr.write("no such hypothesis: %s\n" % hid)
    sys.exit(1)
with open(path) as fh:
    rec = json.load(fh)
if run_id in rec["tested_by"]:
    print("%s already linked to %s" % (hid, run_id))
    sys.exit(0)
rec["tested_by"].append(run_id)
rec["updated_ts"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
tmp = path + ".tmp"
with open(tmp, "w") as fh:
    json.dump(rec, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
print("%s linked to %s" % (hid, run_id))
PY
}

# ---------------------------------------------------------------------------
# show - the handoff primitive: record + every journal line tagged to it
# ---------------------------------------------------------------------------
cmd_show() {
    [[ $# -lt 1 ]] && { echo "usage: show <id> [--json]" >&2; usage 2; }
    local id="$1"; shift
    local json=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -j|--json) json=1; shift ;;
            -h|--help) usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done

    require_python
    HY_DIR="$REGISTRY" HY_ID="$id" HY_JOURNAL="$JOURNAL" HY_JSON="$json" \
    python3 - <<'PY'
import json, os, sys
d, hid = os.environ["HY_DIR"], os.environ["HY_ID"]
path = os.path.join(d, hid + ".json")
if not os.path.exists(path):
    sys.stderr.write("no such hypothesis: %s\n" % hid)
    sys.exit(1)
with open(path) as fh:
    rec = json.load(fh)

entries = []
prov_line = None
prov = rec.get("provenance") or {}
jpath = os.environ["HY_JOURNAL"]
if os.path.exists(jpath):
    with open(jpath) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if o.get("hypothesis_id") == hid:
                entries.append(o)
            # Resolve the provenance pointer here rather than making the reader
            # do it: an id that hands back only a timestamp still dead-ends.
            if prov.get("kind") == "journal_ts" and o.get("ts") == prov.get("source"):
                prov_line = o

if os.environ["HY_JSON"] == "1":
    print(json.dumps({"hypothesis": rec, "journal": entries,
                      "provenance_line": prov_line}, indent=2))
    sys.exit(0)

# Two variables on purpose: `kind` drives the branches below and keeps the
# established default so a pre-`kind` record still reads as a hypothesis, while
# `kind_shown` refuses to launder a missing field into a confident answer. When
# they disagree the record needs backfilling, not interpreting.
kind = rec.get("kind") or "hypothesis"
kind_shown = rec.get("kind") or "???? (field MISSING - treated as hypothesis)"
print("%s  [%s]  kind=%s  family=%s  test_cost=%s%s"
      % (rec["id"], rec["state"], kind_shown, rec["family"], rec["test_cost"],
         ("  priority=%s" % rec["priority"]) if rec.get("priority")
         else ("  attempts=%d" % rec["attempts"])))
if rec.get("backfilled"):
    print("  (backfilled from journal prose - not a contemporaneous record)")
# Otherwise the held attempt is invisible: the counter reads 1 with the
# record open, which looks like an attempt that ran and was never scored.
if rec.get("attempt_carried"):
    print("  (1 of those attempts was INTERRUPTED and never completed - it is held,")
    print("   not restored; the next entry to testing resumes it and spends none)")
print("  claim     : %s" % rec["claim"])
if kind == "task":
    print("  done_when : %s" % rec.get("done_when"))
else:
    print("  falsifier : %s" % rec["falsifier"])
    print("  targets   : %s" % (", ".join(rec.get("targets") or []) or "- (none - no goal link)"))

# The handoff primitive is only complete if an agent handed an id can walk BACK
# to the evidence. Printed for both kinds: absent on a task is the documented
# exemption, absent on a hypothesis means the record predates the requirement.
if prov:
    mark = " (backfilled)" if prov.get("backfilled") else ""
    print("  provenance: %s %s%s" % (prov.get("kind"), prov.get("source"), mark))
    if prov_line is not None:
        print("              -> %s  %s" % (prov_line.get("event"),
                                           (prov_line.get("note") or "")[:88]))
    elif prov.get("kind") == "journal_ts":
        print("              -> NOT FOUND in the journal now; it was validated when written")
elif kind == "task":
    print("  provenance: - (tasks are exempt - an obligation can arise from a standing fact)")
else:
    print("  provenance: ???? (field MISSING - record predates the requirement)")
if rec.get("superseded_by"):
    print("  superseded_by: %s" % rec["superseded_by"])
for delta in (rec.get("metric_deltas") or []):
    print("  measured  : %s %s -> %s" % (delta["metric"], delta["before"], delta["after"]))
if rec["depends_on"]:
    print("  depends_on: %s" % ", ".join(rec["depends_on"]))
if rec.get("blocked_on"):
    print("  blocked_on: %s" % rec["blocked_on"])
if rec["tested_by"]:
    print("  tested_by : %s" % ", ".join(rec["tested_by"]))
print("  history   :")
for h in rec["history"]:
    print("    %s  %s -> %s  %s" % (h["ts"], h.get("from") or "-", h["to"], h.get("evidence") or ""))
    # The recovery's cause is the whole content of that transition - the
    # evidence field says what was done with the partial work, not what killed
    # the agent - so it gets its own line rather than being readable only in
    # the JSON.
    if h.get("interrupted_by"):
        print("      ^ interrupted by: %s" % h["interrupted_by"])
    if h.get("resumed_attempt") is not None:
        print("      ^ resumed attempt %d; no new attempt spent"
              % h["resumed_attempt"])
print("  journal   : %d entr%s" % (len(entries), "y" if len(entries) == 1 else "ies"))
for o in entries:
    note = (o.get("note") or "")
    print("    %s  %-20s %s" % (o.get("ts"), o.get("event"), note[:100]))
PY
}

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
cmd_list() {
    local state="" family="" tier="" json=0 kind=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --state)     state="$2"; shift 2 ;;
            --family)    family="$2"; shift 2 ;;
            --tier)      tier="$2"; shift 2 ;;
            --kind)      kind="$2"; shift 2 ;;
            -j|--json)   json=1; shift ;;
            -h|--help)   usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done

    require_python
    HY_DIR="$REGISTRY" HY_STATE="$state" HY_FAMILY="$family" HY_TIER="$tier" \
    HY_KIND="$kind" HY_JSON="$json" python3 - <<'PY'
import json, os, sys
d = os.environ["HY_DIR"]
def g(k):
    v = os.environ.get(k, "")
    return v if v != "" else None

recs = []
if os.path.isdir(d):
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".json"):
            continue
        with open(os.path.join(d, fn)) as fh:
            recs.append(json.load(fh))

for key, env in (("state", "HY_STATE"), ("family", "HY_FAMILY"),
                 ("test_cost", "HY_TIER"), ("kind", "HY_KIND")):
    want = g(env)
    if want:
        recs = [r for r in recs if (r.get(key) or "hypothesis" if key == "kind"
                                    else r.get(key)) == want]

recs.sort(key=lambda r: (r.get("kind", "hypothesis"), r["id"][0], int(r["id"][1:])))

if os.environ["HY_JSON"] == "1":
    print(json.dumps(recs, indent=2))
    sys.exit(0)

if not recs:
    print("(nothing matches)")
    sys.exit(0)
print("%-5s %-5s %-10s %-22s %-6s %-4s %s"
      % ("ID", "KIND", "STATE", "FAMILY", "COST", "ATT", "CLAIM"))
print("-" * 116)
for r in recs:
    # `????` when the field is absent or null, NEVER a silent default. Every
    # other read site defaults a missing kind to "hypothesis" so the tool keeps
    # working, and that is right - but a DISPLAY that hides the gap is exactly
    # how this column could come to report record age instead of record kind.
    # If you see `????`, the record predates the field or was written by
    # something other than this script.
    print("%-5s %-5s %-10s %-22s %-6s %-4d %s"
          % (r["id"], (r.get("kind") or "????")[:4], r["state"], r["family"],
             r["test_cost"], r["attempts"], r["claim"][:50]))
PY
}

# ---------------------------------------------------------------------------
# families - the concentration table
# ---------------------------------------------------------------------------
cmd_families() {
    local json=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -j|--json) json=1; shift ;;
            -h|--help) usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done

    require_python
    HY_DIR="$REGISTRY" HY_JSON="$json" HY_FAMILIES="${HYP_FAMILIES[*]}" \
    HY_RATCHET_AXES="${RATCHET_AXES[*]}" \
    HY_DISCRIMINATOR="${RL_MOVED_DISCRIMINATOR:-frac_improved}" python3 - <<'PY'
import json, os, sys
d = os.environ["HY_DIR"]
recs = []
if os.path.isdir(d):
    for fn in sorted(os.listdir(d)):
        if fn.endswith(".json"):
            with open(os.path.join(d, fn)) as fh:
                recs.append(json.load(fh))

# Hypotheses only. This table exists to expose a family being re-skinned rather
# than tested, which is a claim about conjectures; tasks have no attempts to
# concentrate and would only dilute it. The task lane is `next --kind task`.
recs = [r for r in recs if r.get("kind", "hypothesis") == "hypothesis"]

STATE_KEYS = ("open", "testing", "falsified", "confirmed", "blocked", "superseded")

# Which way is good for each of your TARGETS, read out of RATCHET_AXES in
# config/loop.conf rather than hardcoded: "name:harder_is_lower" means a lower
# number is the harder (better) bar. Without this a delta is just two numbers;
# with it, "did this family ever move the needle" is computable.
LOWER_IS_BETTER = {}
for entry in os.environ["HY_RATCHET_AXES"].split():
    name, _, direction = entry.partition(":")
    LOWER_IS_BETTER[name] = (direction == "harder_is_lower")

# MOVED must not fire on ANY metric improving from ANY record, or the column
# becomes anti-informative in the one situation it exists for.
#
# SOME OF YOUR TARGETS MAY BE SATISFIABLE BY A NULL POLICY. If a target only
# ever improves when the system does LESS -- abstains, defers, produces
# nothing -- then a delta set showing it moving the right way is exactly what
# an abstention shift looks like, not evidence of skill. HY_DISCRIMINATOR
# names the one target (default frac_improved, matching config/loop.conf's
# example) that specifically requires the system to have helped in a case
# that needed it, which a null policy cannot satisfy. If you change TARGETS,
# recheck which of them this argument still applies to.
DISCRIMINATOR = os.environ["HY_DISCRIMINATOR"]

# A claim that LOST cannot have a win attributed to it. A record can be
# falsified while still carrying deltas that all point the "right" way, which
# is what prices a dead family at 100% if this exclusion is missing.
NOT_A_WIN = {"falsified", "superseded"}

def improved(delta):
    lower = LOWER_IS_BETTER.get(delta["metric"])
    if lower is None:
        return False
    return (delta["after"] < delta["before"]) if lower else (delta["after"] > delta["before"])

def moved(rec, deltas):
    if rec["state"] in NOT_A_WIN:
        return False
    disc = [d for d in deltas if d["metric"] == DISCRIMINATOR]
    # No discriminator value recorded means the abstention reading cannot be
    # excluded. Undecidable is scored as "not a win" on purpose: this number
    # prices a contended resource, so the conservative direction is the
    # honest one.
    return bool(disc) and all(improved(d) for d in disc)

def blank(f):
    row = {"family": f, "n": 0, "attempts": 0, "measured": 0, "moved": 0}
    row.update({k: 0 for k in STATE_KEYS})
    return row

fams = {f: blank(f) for f in os.environ["HY_FAMILIES"].split()}
for r in recs:
    f = fams.setdefault(r["family"], blank(r["family"]))
    f["n"] += 1
    f["attempts"] += r["attempts"]
    if r["state"] in f:
        f[r["state"]] += 1
    ds = r.get("metric_deltas") or []
    if ds:
        # A falsified record still counts in MEAS: it is a settled result that
        # recorded a delta, and it genuinely did not move the needle. Dropping
        # it from the denominator would discard a real negative.
        f["measured"] += 1
        if moved(r, ds):
            f["moved"] += 1

rows = sorted(fams.values(), key=lambda x: (-x["attempts"], -x["n"], x["family"]))
if os.environ["HY_JSON"] == "1":
    print(json.dumps(rows, indent=2))
    sys.exit(0)

print("%-22s %4s %5s %5s %8s %10s %6s %8s %6s"
      % ("FAMILY", "N", "ATT", "OPEN", "FALSIFIED", "SUPERSEDED", "MEAS", "MOVED", "RATE"))
print("-" * 88)
for r in rows:
    rate = ("%.0f%%" % (100.0 * r["moved"] / r["measured"])) if r["measured"] else "-"
    print("%-22s %4d %5d %5d %8d %10d %6d %8d %6s"
          % (r["family"], r["n"], r["attempts"], r["open"], r["falsified"],
             r["superseded"], r["measured"], r["moved"], rate))
print("\nA family with many attempts and nothing falsified is a family being")
print("re-skinned rather than tested. A family with zero attempts is unexplored.")
print("MEAS/MOVED/RATE are the measured base rate: of the settled hypotheses in")
print("this family that recorded a --metric-delta, how many actually moved a")
print("target metric in the right direction. It is the only honest input to")
print("'is this family worth another go' - and it stays '-' until enough")
print("results exist to have one, which is the point.")
print("")
print("MOVED REQUIRES BOTH, and the second is the one that matters:")
print("  - the record is not falsified or superseded - a claim that lost cannot")
print("    have a win attributed to it; and")
print("  - it recorded %s AND %s moved the right way." % (DISCRIMINATOR, DISCRIMINATOR))
print("%s is the discriminator because it is the one target (by default) that a" % DISCRIMINATOR)
print("policy cannot satisfy merely by doing less. A record with deltas but no")
print("%s counts in MEAS and not in MOVED: undecidable is scored" % DISCRIMINATOR)
print("conservatively on purpose.")
PY
}

# ---------------------------------------------------------------------------
# drift - does the registry still agree with what the journal says happened?
#
# Every stage skill already carries the instruction to call set-state. The gap
# was never the reminder; it was that NOTHING noticed when one did not fire.
# This is the detector. It reports and exits 3; it never repairs.
# ---------------------------------------------------------------------------
cmd_drift() {
    local json=0 stale_hours="$DRIFT_STALE_HOURS"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stale-hours) stale_hours="$2"; shift 2 ;;
            -j|--json)     json=1; shift ;;
            -h|--help)     usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done

    # The active-run set comes from journal.sh rather than being re-derived here,
    # so the two can never disagree about what "in flight" means. It exits 1 when
    # there are none, which is not an error for us.
    local active_json
    active_json="$(RL_JOURNAL="$JOURNAL" "$HERE/journal.sh" active-runs --json 2>/dev/null)"
    [[ -z "$active_json" ]] && active_json="[]"

    require_python
    HY_DIR="$REGISTRY" HY_JOURNAL="$JOURNAL" HY_STALE_HOURS="$stale_hours" \
    HY_ACTIVE="$active_json" HY_JSON="$json" python3 - <<'PY'
import json, os, sys, datetime

d = os.environ["HY_DIR"]
stale_h = float(os.environ["HY_STALE_HOURS"])
now = datetime.datetime.now(datetime.timezone.utc)

def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc)
    except ValueError:
        return None

recs = []
if os.path.isdir(d):
    for fn in sorted(os.listdir(d)):
        if fn.endswith(".json"):
            with open(os.path.join(d, fn)) as fh:
                recs.append(json.load(fh))

# A run is over when the journal says so. run_degraded is NOT terminal: a
# degraded run is still in flight, `testing` is the correct state for it, and
# firing there would be exactly the false positive that gets a checker ignored.
TERMINAL_RUN = {"run_completed", "run_died", "run_stopped"}
LIFECYCLE = TERMINAL_RUN | {"run_started", "run_healthy", "run_degraded"}
# Registry states that are finished. A record here is nobody's problem.
TERMINAL_STATE = {"confirmed", "falsified", "superseded", "done", "dropped"}
# Both are written during a tick's ORIENTATION, before any stage runs, and the
# scheduler will not start a second instance of a running tick. So a line here
# that is NEWER than a record's last activity proves the tick that left the
# record mid-attempt is over -- no clock, no threshold, decidable from the
# journal alone.
TICK_BOUNDARY = {"orchestrator_woke", "tick_aborted"}
# A tick STARTS at its own orchestrator_woke and nowhere else. tick_aborted is
# written BY a tick ABOUT a previous one, so it is a boundary without being
# the start of anything -- which is what lets a hold placed by THIS tick
# survive a tick_aborted this same tick writes moments later.
TICK_START = "orchestrator_woke"

last_hyp_line = {}      # hypothesis_id -> newest ts of a journal line carrying it
run_terminal = {}       # run_id -> (event, ts) of the first terminal event seen
run_last_life = {}      # run_id -> (event, ts) of its newest lifecycle event
last_boundary = ""      # newest ts of any tick-boundary line, "" if none exist
last_wake = ""          # newest ts of an orchestrator_woke line, "" if none
holds = {}              # hypothesis_id -> the NEWEST hold for it

jpath = os.environ["HY_JOURNAL"]
if os.path.exists(jpath):
    with open(jpath) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            ts, ev, rid = o.get("ts"), o.get("event"), o.get("run_id")
            hid = o.get("hypothesis_id")
            if hid and ts:
                # A HOLD IS NOT ACTIVITY. A dispatch is a claim that an agent
                # exists, never evidence that anything happened TO the record --
                # so a hold line does not advance the clock the staleness
                # backstop reads. Were it to, a stage that died instantly on
                # every tick would keep its record permanently fresh AND
                # permanently held, i.e. invisible to both detectors. Anything a
                # stage has to SAY about a record goes on its own line, which
                # does count.
                if not o.get("held_by") and ts > last_hyp_line.get(hid, ""):
                    last_hyp_line[hid] = ts
                # A claim that an agent of the tick in progress is working this
                # record. Newest wins; whether it is still LIVE is decided
                # against the newest tick start, not here.
                if o.get("held_by"):
                    prev = holds.get(hid)
                    if prev is None or ts > prev["ts"]:
                        holds[hid] = {"ts": ts, "stage": o["held_by"]}
            if ev in TICK_BOUNDARY and ts and ts > last_boundary:
                last_boundary = ts
            if ev == TICK_START and ts and ts > last_wake:
                last_wake = ts
            if rid and ev in LIFECYCLE:
                if ev in TERMINAL_RUN and rid not in run_terminal:
                    run_terminal[rid] = (ev, ts)
                prev = run_last_life.get(rid)
                if prev is None or (ts or "") >= prev[1]:
                    run_last_life[rid] = (ev, ts or "")

active_ids = {r.get("run_id") for r in json.loads(os.environ["HY_ACTIVE"])}

def hours_idle(rec):
    """Time since anything at all happened to this record.

    max(its own updated_ts, the newest journal line tagged to it) - a record
    with no journal lines is still being worked if set-state touched it, and a
    record nobody has touched is still alive if a stage journalled against it.
    """
    stamps = [parse_ts(rec.get("updated_ts")), parse_ts(last_hyp_line.get(rec["id"]))]
    stamps = [s for s in stamps if s is not None]
    if not stamps:
        return None
    return (now - max(stamps)).total_seconds() / 3600.0

def last_activity_ts(rec):
    """The same quantity as hours_idle, as a comparable ISO string."""
    stamps = [s for s in (rec.get("updated_ts"), last_hyp_line.get(rec["id"])) if s]
    return max(stamps) if stamps else None

def held(rec):
    """Is an agent of THE TICK IN PROGRESS working this record?

    A hold is honoured only while it is at or newer than the newest
    orchestrator_woke, which is what makes it a claim about the live tick
    rather than a permanent exemption: the tick that placed it is over the
    moment a later tick wakes, and the same tick-boundary argument used for
    orphan detection is exactly what licenses that, at the level (tick against
    tick) where it is valid.

    A journal with no wake line at all has no tick in progress to belong to,
    so no hold is honoured in one. That is the safe direction; drift still
    reports.
    """
    h = holds.get(rec["id"])
    if not h or not last_wake or h["ts"] < last_wake:
        return None
    return h


def orphaned(rec, linked):
    """Has a tick boundary been crossed since anything happened to this record?

    Returns the boundary ts when the agent that left it mid-attempt is
    provably gone, and None when that is not decidable -- either because the
    journal carries no boundary lines at all, or because the record was
    touched after the newest one, which is what a LIVE stage in the current
    tick looks like.

    A record whose linked run is still in flight is never orphaned: a run can
    outlive ticks by design, and `testing` is the correct state for it.

    Nor is one the CURRENT TICK has dispatched a stage against: the wake line
    is written at the top of a tick, so every record it then hands to a
    subagent is older than the newest boundary for the rest of that tick. The
    hold suppresses this inference and nothing else -- a finding backed by
    positive evidence does not consult it, and the staleness clock is not
    reset, so a stage that dies instantly on every tick cannot hide a record.
    """
    if not last_boundary or any(rid in active_ids for rid in linked):
        return None
    if held(rec) is not None:
        return None
    act = last_activity_ts(rec)
    if act is None or last_boundary <= act:
        return None
    return last_boundary

findings = []
held_records = []       # what the tick in progress says it is working
resumed = []             # an attempt spanning several run ids, one of them live
def flag(rec, shape, detail, action):
    findings.append({"id": rec["id"], "state": rec["state"],
                     "kind": rec.get("kind", "hypothesis"),
                     "shape": shape, "detail": detail, "action": action})

for rec in recs:
    state = rec["state"]
    kind = rec.get("kind", "hypothesis")
    if state in TERMINAL_STATE:
        continue
    linked = rec.get("tested_by") or []
    idle = hours_idle(rec)

    # A live hold is REPORTED even where it changed nothing, because a record
    # that quietly stopped being flagged is indistinguishable from one nobody
    # looked at. Only in the two states that have an orphan verdict to suppress.
    if state in ("testing", "doing"):
        hold = held(rec)
        if hold is not None:
            held_records.append({"id": rec["id"], "state": state, "kind": kind,
                                 "stage": hold["stage"], "held_ts": hold["ts"],
                                 "tick_start": last_wake})

    if state == "testing":
        # (1) The run that was deciding it has ended and nobody walked the link
        # back. This is the shape with teeth: `attempts` already counted the
        # experiment, so leaving it here hides a spent conjecture in the open
        # set.
        #
        # tested_by IS A LIST, and ANY ACTIVE LINK SUPPRESSES THIS. A run
        # killed partway through is sometimes resumed under a FRESH run id,
        # `link` appends, and the record then carries both -- so a terminal
        # event on the superseded id is true and says nothing about whether
        # the attempt is over. Reporting it is not a nuisance but damage: the
        # action text below sends the reader to score a record whose
        # experiment is still running, and there is no artefact to score. The
        # suppression is narrow on purpose -- it removes ONLY the claim that
        # the run is over, which is false while any linked run is in flight,
        # and it DEFERS rather than drops: the moment the last live link
        # reaches a terminal event this fires again, naming that event.
        #
        # The active set is journal.sh active-runs, the same authority
        # `orphaned` already consults for the same reason, so the two can
        # never disagree about what in flight means. A run with a terminal
        # event is never in it, so an active link is necessarily a DIFFERENT
        # id from every ended one.
        ended = [(rid,) + run_terminal[rid] for rid in linked if rid in run_terminal]
        live_links = [rid for rid in linked if rid in active_ids]
        if ended and live_links:
            # Reported, never silent: a record that quietly stops being
            # flagged is indistinguishable from one nobody looked at.
            ended.sort(key=lambda e: e[2] or "")
            srid, sev, sts = ended[-1]
            resumed.append({"id": rec["id"], "state": state, "kind": kind,
                            "live_run": live_links[-1], "live_runs": live_links,
                            "terminal_run": srid, "terminal_event": sev,
                            "terminal_ts": sts,
                            "would_have_been": "testing_run_terminal"})
            # NO continue: only the terminal claim is suppressed. The
            # degradation check below is about a DIFFERENT question and still
            # applies.
        elif ended:
            # The NEWEST terminal event, not the first link written. An
            # attempt that spanned two ids ends at the second, and naming the
            # first would point a reader at a superseded run whose artefacts
            # are elsewhere.
            ended.sort(key=lambda e: e[2] or "")
            rid, ev, ts = ended[-1]
            flag(rec, "testing_run_terminal",
                 "linked run %s reached %s at %s" % (rid, ev, ts),
                 "the run is over; score it against the stored falsifier and set "
                 "confirmed/falsified/blocked")
            continue
        # (1b) Degradation that nobody ever followed up. A fresh run_degraded
        # is NOT drift - the run monitor flags it and the run continues - so
        # this fires only when the degradation is the run's latest word and
        # has gone stale.
        degraded = [rid for rid in linked
                    if run_last_life.get(rid, ("", ""))[0] == "run_degraded"]
        if degraded and idle is not None and idle > stale_h:
            flag(rec, "testing_run_degraded_stale",
                 "linked run %s has read run_degraded for %.1f h with no follow-up "
                 "(threshold %.0f h)" % (degraded[0], idle, stale_h),
                 "assess the degraded run; dispatch it or explain the wait")
            continue
        if not linked:
            # This must come BEFORE the staleness check: an orphaned probe is
            # decidable now, and hours of silence on work nobody is doing is
            # hours of a lane reading as empty.
            orph = orphaned(rec, linked)
            if rec["test_cost"] == "probe" and orph:
                flag(rec, "testing_orphaned",
                     "probe-tier, left in testing at %s; the loop has since crossed a "
                     "tick boundary at %s, so no agent is deciding it"
                     % (last_activity_ts(rec) or "?", orph),
                     "recover it in ONE transition: set-state %s open "
                     "--interrupted-by \"<what stopped it>\" --evidence \"...\". The "
                     "attempt is HELD, not restored -- re-entering testing resumes it "
                     "and spends none" % rec["id"])
                continue
            if rec["test_cost"] == "run":
                # (2) The stage that launches a run calls `link` and
                # `set-state testing` in the same breath, after real progress
                # is seen. A run-tier record in `testing` with no link means
                # one of those two writes was lost.
                flag(rec, "testing_no_run",
                     "run-tier and in testing, but no run is linked",
                     "find the run this belongs to and `link` it, or set the state "
                     "back to what actually happened")
            elif idle is not None and idle > stale_h:
                # (3) A probe takes minutes. Hours in `testing` means the tick
                # that started it died before recording the verdict.
                flag(rec, "testing_probe_stale",
                     "probe-tier, in testing, nothing recorded for %.1f h "
                     "(threshold %.0f h)" % (idle, stale_h),
                     "the probe either finished unrecorded or never ran; check "
                     "for its artefacts before re-spending an attempt")
            continue

    if kind == "task" and state == "doing":
        # (4) A task in `doing` is a stage that started and never closed. It
        # has no attempts to spend, so nothing else in the tool will ever
        # notice.
        #
        # Tick-boundary check first: the tick that was holding it is over,
        # same-tick, and it precedes the staleness path because a blocking
        # task invisible for many hours is many ticks of a lane reading
        # "TASKS - none open. (Good.)" while the obligation sits unfinished.
        orph = orphaned(rec, linked)
        if orph:
            flag(rec, "doing_orphaned",
                 "left in doing at %s; the loop has since crossed a tick boundary "
                 "at %s, so the stage that was working it is gone"
                 % (last_activity_ts(rec) or "?", orph),
                 "read the working tree and any log first -- the work may be done "
                 "and unrecorded. Otherwise recover it in ONE transition: set-state "
                 "%s open --interrupted-by \"<what stopped it>\" --evidence \"...\""
                 % rec["id"])
            continue
        if idle is not None and idle > stale_h:
            flag(rec, "doing_stale",
                 "in doing with nothing recorded for %.1f h (threshold %.0f h)"
                 % (idle, stale_h),
                 "read the working tree and any log before deciding: the work may "
                 "be done and unrecorded, which is the usual case")
        continue

    if state == "open" and linked:
        # (5) Something called `link` and never moved the state. Keyed on the
        # record's OWN link, never on a run_started line carrying a hypothesis_id:
        # a launch that dies before any real progress correctly leaves the record
        # open at attempts=0, and flagging that would make this check noise.
        live = [rid for rid in linked if rid in active_ids]
        if live:
            flag(rec, "open_run_active",
                 "linked run %s is in flight while the record still reads open" % live[0],
                 "if that run is testing this record, set it to testing - the "
                 "attempt is being spent either way")
        continue

if os.environ["HY_JSON"] == "1":
    print(json.dumps({"checked": len(recs), "stale_hours": stale_h,
                      "drift": findings, "held": held_records,
                      "resumed_attempts": resumed}, indent=2))
    sys.exit(3 if findings else 0)


def print_resumed():
    """An attempt spanning several run ids, one of which is still in flight.

    Reported even though it changed nothing: a record that quietly stops
    being flagged is indistinguishable from one nobody looked at.
    """
    if not resumed:
        return
    print()
    print("RESUMED ATTEMPTS (%d): a linked run of these is STILL IN FLIGHT, so a "
          "terminal" % len(resumed))
    print("event on an older linked id is not drift.")
    for r in resumed:
        print("  %-4s %-8s %s is in flight; the superseded id %s reached %s at %s"
              % (r["id"], r["state"], r["live_run"], r["terminal_run"],
                 r["terminal_event"], r["terminal_ts"]))
        print("       NOT %s: tested_by is a LIST and this attempt spans both ids. "
              "Do NOT" % r["would_have_been"])
        print("       score it or set confirmed/falsified/blocked -- the experiment "
              "is still")
        print("       running, and the transition would move the record out from "
              "under it.")


def print_held():
    if not held_records:
        return
    print()
    print("HELD BY THIS TICK (%d): a stage of the tick in progress is working "
          "these." % len(held_records))
    for h in held_records:
        print("  %-4s %-8s held by %s at %s (this tick woke %s)"
              % (h["id"], h["state"], h["stage"], h["held_ts"], h["tick_start"]))
    print("       NOT orphaned: the wake line is written at the TOP of a tick, so")
    print("       every record it dispatches a subagent into is older than it. Do")
    print("       NOT `set-state ... open --interrupted-by` on these - the agent is")
    print("       alive and the transition would move the record out from under it.")


if not findings:
    print("registry agrees with the journal (%d records checked, 0 drifted, "
          "stale threshold %.0f h)" % (len(recs), stale_h))
    print_resumed()
    print_held()
    sys.exit(0)

print("DRIFT: %d record%s disagree%s with the journal (of %d checked)."
      % (len(findings), "" if len(findings) == 1 else "s",
         "s" if len(findings) == 1 else "", len(recs)))
print()
for f in findings:
    print("  %-4s %-8s %s" % (f["id"], f["state"], f["detail"]))
    print("       -> %s" % f["action"])
print_resumed()
print_held()
print()
print("NOTHING HAS BEEN CHANGED. This reports only: the correct transition needs")
print("judgement about what actually happened, and a tool that set it for you")
print("would manufacture the same false confidence the check exists to remove.")
sys.exit(3)
PY
}

# ---------------------------------------------------------------------------
# next - the SELECT step, as an ordering
# ---------------------------------------------------------------------------
cmd_next() {
    # No kind filter by default. `next` shows BOTH lanes in one view, because a
    # lane you have to remember to ask for is a lane that gets forgotten, which
    # is precisely how a good-citizen task rots. --kind narrows it when you
    # genuinely want one.
    local tier="" json=0 limit=0 exclude_family="" kind=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tier)            tier="$2"; shift 2 ;;
            --kind)            kind="$2"; shift 2 ;;
            --exclude-family)  exclude_family="$2"; shift 2 ;;
            -n|--limit)        limit="$2"; shift 2 ;;
            -j|--json)         json=1; shift ;;
            -h|--help)         usage 0 ;;
            *) echo "unknown argument: $1" >&2; usage 2 ;;
        esac
    done
    if [[ -n "$tier" ]]; then
        in_list "$tier" "${TIERS[@]}" || {
            echo "unknown tier '$tier' - must be one of: ${TIERS[*]}" >&2; exit 2; }
    fi
    if [[ -n "$kind" ]]; then
        in_list "$kind" "${KINDS[@]}" || {
            echo "unknown kind '$kind' - must be one of: ${KINDS[*]}" >&2; exit 2; }
    fi

    require_python
    HY_DIR="$REGISTRY" HY_TIER="$tier" HY_JSON="$json" HY_LIMIT="$limit" \
    HY_EXCLUDE_FAMILY="$exclude_family" HY_KIND="$kind" \
    HY_HYP_FAMILIES="${HYP_FAMILIES[*]}" HY_ALL_TARGETS="${TARGETS[*]}" \
    HY_CAP="$ATTEMPT_CAP" python3 - <<'PY'
import json, os, sys
d = os.environ["HY_DIR"]
cap = int(os.environ["HY_CAP"])
recs = {}
if os.path.isdir(d):
    for fn in sorted(os.listdir(d)):
        if fn.endswith(".json"):
            with open(os.path.join(d, fn)) as fh:
                r = json.load(fh)
                recs[r["id"]] = r

TERMINAL = {"confirmed", "falsified", "superseded", "done", "dropped"}
only_kind = os.environ.get("HY_KIND") or None   # None = show both lanes

def unmet_deps(r):
    return [x for x in r["depends_on"]
            if x in recs and recs[x]["state"] not in TERMINAL]

# A record that some OTHER live record depends on is a blocker: settling it
# unblocks work. This is the "do not reduce to an equally-hard lemma" check -
# if three hypotheses hang off one record, test that record, not the three.
blocks = {hid: 0 for hid in recs}
for r in recs.values():
    if r["state"] in TERMINAL:
        continue
    for dep in r["depends_on"]:
        if dep in blocks:
            blocks[dep] += 1

fam_attempts = {}
for r in recs.values():
    fam_attempts[r["family"]] = fam_attempts.get(r["family"], 0) + r["attempts"]

want_tier = os.environ.get("HY_TIER") or None
skip_family = os.environ.get("HY_EXCLUDE_FAMILY") or None
PRIO_RANK = {"blocking": 0, "good-citizen": 1, "chore": 2}
cands = []
for r in recs.values():
    kind = r.get("kind", "hypothesis")
    if only_kind and kind != only_kind:
        continue
    if r["state"] != "open":
        continue
    # The cap is a hypothesis concept; tasks are obligations, not conjectures.
    if kind == "hypothesis" and r["attempts"] >= cap:
        continue
    if want_tier and r["test_cost"] != want_tier:
        continue
    if skip_family and r["family"] == skip_family:
        continue
    um = unmet_deps(r)
    cands.append({
        "id": r["id"],
        "kind": r.get("kind", "hypothesis"),
        "family": r["family"],
        "targets": r.get("targets") or [],
        "priority": r.get("priority"),
        "test_cost": r["test_cost"],
        "attempts": r["attempts"],
        "claim": r["claim"],
        "unmet_deps": um,
        "blocks_n": blocks.get(r["id"], 0),
        "family_attempts": fam_attempts.get(r["family"], 0),
    })

# Selection order, applied in sequence:
#   1. no unmet dependencies          (test the lemma before its dependants)
#   2. unblocks the most other work   (blockers first)
#   3. probe tier before run tier     (never book the expensive resource for
#                                       what a probe could kill)
#   4. least-attempted family first   (portfolio diversity)
#   5. fewest attempts, then id       (deterministic tiebreak)
# The two lanes are ranked separately because they are not comparable. A task
# and a hypothesis do not compete for the same slot: the standing rule reserves
# the expensive resource for an experiment, and tasks are cheap-lane work.
# Interleaving them into one order would imply a tradeoff that does not exist.
#
# Tasks order by PRIORITY first - a good-citizen obligation to a shared
# resource is not something to schedule around convenience. Then cheap before
# expensive.
tasks = [c for c in cands if c["kind"] == "task"]
hyps = [c for c in cands if c["kind"] != "task"]

tasks.sort(key=lambda c: (len(c["unmet_deps"]),
                          PRIO_RANK.get(c["priority"], 9),
                          0 if c["test_cost"] == "probe" else 1,
                          c["id"][0], int(c["id"][1:])))
hyps.sort(key=lambda c: (len(c["unmet_deps"]), -c["blocks_n"],
                         0 if c["test_cost"] == "probe" else 1,
                         c["family_attempts"], c["attempts"],
                         c["id"][0], int(c["id"][1:])))

# MID-ATTEMPT RECORDS ARE NOT CANDIDATES, BUT THEY ARE NOT INVISIBLE.
# `next` selects on state == open, so a record a stage is holding drops out of
# the listing entirely -- and with the last one gone the tasks lane could print
# "TASKS - none open. (Good.)". That line does not merely omit outstanding
# work, it actively tells the reader there is none, which is exactly how a
# blocking task can sit unfinished through a tick that had oriented correctly.
#
# They stay OUT of the candidate lists: dispatching a record another stage is
# holding is exactly the double-booking the loop must not do. They go in their
# own bucket, named, so the lane can never read as empty while one exists.
#
# --kind and --tier narrow this too: both select WHICH lane is being asked
# about, so a record outside the requested lane was never in scope.
# --exclude-family deliberately does NOT: that flag is a ranking preference
# ("drop the incumbent family"), and letting a preference hide in-flight work
# would rebuild the hole this closes.
IN_FLIGHT_STATE = {"task": "doing", "hypothesis": "testing"}
in_flight = []
for r in recs.values():
    kind = r.get("kind", "hypothesis")
    if kind != "task":
        kind = "hypothesis"
    if only_kind and kind != only_kind:
        continue
    if r["state"] != IN_FLIGHT_STATE[kind]:
        continue
    if want_tier and r["test_cost"] != want_tier:
        continue
    in_flight.append({
        "id": r["id"], "kind": kind, "state": r["state"],
        "family": r["family"], "priority": r.get("priority"),
        "test_cost": r["test_cost"], "attempts": r["attempts"],
        "attempt_carried": bool(r.get("attempt_carried")),
        "since": r.get("updated_ts"), "claim": r["claim"],
    })
in_flight.sort(key=lambda c: (c["kind"] != "task", c["id"][0], int(c["id"][1:])))
if_tasks = [c for c in in_flight if c["kind"] == "task"]
if_hyps = [c for c in in_flight if c["kind"] != "task"]

ALL_TARGETS = os.environ["HY_ALL_TARGETS"].split()
# A display nicety keyed on this project's own TARGETS (config/loop.conf), so
# it needs updating if you change what TARGETS holds. Falls back to the first
# four characters of anything not listed explicitly.
SHORT_MAP = {"median_error": "err", "frac_worsened": "wors", "frac_improved": "impr"}
SHORT = {t: SHORT_MAP.get(t, t[:4]) for t in ALL_TARGETS}

# WHERE IS THE SEARCH NOT LOOKING?
#
# `families` has always been able to answer this and nobody is required to
# read it, which is the whole complaint: concentration is only visible to an
# agent who goes looking for it, and `next` is where the choice is actually
# made.
#
# THE MATRIX IS THE HYPOTHESIS FAMILIES ONLY, and that is forced rather than
# chosen: a `task` cannot carry --targets at all -- `new` refuses the flag on
# one -- so a task-family cell can never be occupied by anything. Including
# them would add permanently unfillable cells to a block whose entire job is
# to make real gaps legible, and would make "names none against a registry
# whose cells are all occupied" impossible to satisfy by construction. The
# block says so in its own footer rather than leaving the reader to notice.
#
# OCCUPIED MEANS AT LEAST ONE `open` RECORD aimed there. A cell held only by a
# record in `testing` reads EMPTY, deliberately: `next` answers "what should I
# pick up", and a record another stage is holding is not something to pick
# up. That is the same rule the IN FLIGHT block above runs on, and for the
# same reason -- but the reader is told, because the two readings differ.
#
# IT IGNORES --tier AND --exclude-family. Both narrow what you are willing to
# dispatch right now; neither changes where the portfolio is aimed. A map that
# moved when you filtered the list would not be a map. --kind task does
# suppress it, because there the hypothesis lane is out of scope entirely.
FAM_ROWS = os.environ["HY_HYP_FAMILIES"].split()
cell_open = {(f, t): 0 for f in FAM_ROWS for t in ALL_TARGETS}
for r in recs.values():
    if r.get("kind", "hypothesis") == "task" or r["state"] != "open":
        continue
    for t in (r.get("targets") or []):
        if (r["family"], t) in cell_open:
            cell_open[(r["family"], t)] += 1
empty_cells = [(f, t) for f in FAM_ROWS for t in ALL_TARGETS if not cell_open[(f, t)]]

def print_empty_cells():
    if only_kind == "task":
        return
    total = len(FAM_ROWS) * len(ALL_TARGETS)
    print("EMPTY CELLS - %d of %d in the family x target matrix have no"
          % (len(empty_cells), total))
    print("OPEN record aimed at them. `families` says where the effort went; this")
    print("says where it has not gone. It is a map, not a to-do list - a cell is")
    print("sometimes empty because the family is settled, and sometimes because")
    print("nobody has looked. The tool cannot tell those apart; you can.")
    print(("%-24s %s" % ("FAMILY", " ".join("%-5s" % SHORT[t]
                                            for t in ALL_TARGETS))).rstrip())
    for f in FAM_ROWS:
        cells = " ".join("%-5s" % (cell_open[(f, t)] or ".") for t in ALL_TARGETS)
        print(("%-24s %s" % (f[:24], cells)).rstrip())
    if empty_cells:
        by_fam = {}
        for f, t in empty_cells:
            by_fam.setdefault(f, []).append(SHORT[t])
        line = "  EMPTY:"
        for f in FAM_ROWS:
            if f not in by_fam:
                continue
            piece = " %s x {%s}" % (f, ",".join(by_fam[f]))
            if len(line) + len(piece) > 96:
                print(line)
                line = "        "
            line += piece
        print(line)
    else:
        print("  NO EMPTY CELLS: every family has an open record aimed at every")
        print("  target. That is unusual; check it is not overfitting to the")
        print("  matrix rather than to the problem.")
    print("A cell held only by a record in testing reads empty: nothing in it is")
    print("dispatchable. Task families carry no targets by construction (`new`")
    print("refuses --targets on a task), so they are not cells. Unaffected by")
    print("--tier and --exclude-family, which narrow dispatch, not the search.")

limit = int(os.environ.get("HY_LIMIT") or 0)
if limit > 0:
    tasks, hyps = tasks[:limit], hyps[:limit]

if os.environ["HY_JSON"] == "1":
    # Always the same shape, filtered or not, so a caller never has to branch
    # on which flags it passed.
    print(json.dumps({"tasks": tasks, "hypotheses": hyps,
                      "in_flight": in_flight}, indent=2))
    sys.exit(0 if (tasks or hyps) else 1)

def flight_block(rows, lane):
    print("%s - %d MID-ATTEMPT. Not candidates: a stage is holding %s, or one died"
          % (lane, len(rows), "these" if len(rows) != 1 else "it"))
    print("holding %s. Nothing here is dispatchable until it is closed or recovered."
          % ("them" if len(rows) != 1 else "it"))
    print("%-5s %-8s %-20s %-22s %s" % ("ID", "STATE", "SINCE", "FAMILY", "WHAT"))
    print("-" * 112)
    for c in rows:
        print("%-5s %-8s %-20s %-22s %s"
              % (c["id"], c["state"], c["since"] or "-", c["family"][:22],
                 c["claim"][:44]))
    print("If no agent is working %s, `drift` names %s; recover in one transition:"
          % ("them" if len(rows) != 1 else "it", "them" if len(rows) != 1 else "it"))
    print("  set-state %s open --interrupted-by \"<what stopped it>\" --evidence \"...\""
          % rows[0]["id"])
    print()

if not tasks and not hyps and not in_flight:
    print("(nothing open%s)" % (" at tier %s" % want_tier if want_tier else ""))
    if only_kind != "task":
        print("An empty open set means either the project is out of ideas or the")
        print("evaluation stage stopped registering rivals. Check the latter first.")
        print()
        # Printed HERE too, and this is the path where it says the most: with
        # nothing open, every cell is empty, and the grid is the shortest
        # statement of what a successor would have to rebuild.
        print_empty_cells()
    sys.exit(1)

# Tasks print FIRST and unconditionally. They are obligations, they are cheap,
# and they are the thing a loop will otherwise defer forever because it is
# never the interesting choice.
if tasks:
    print("TASKS - cheap lane, and these are DUE. Work before probe hypotheses.")
    print("%-5s %-14s %-6s %-16s %s" % ("ID", "PRIORITY", "COST", "FAMILY", "WHAT"))
    print("-" * 112)
    for c in tasks:
        print("%-5s %-14s %-6s %-16s %s"
              % (c["id"], c["priority"] or "-", c["test_cost"],
                 c["family"], c["claim"][:56]))
        if c["unmet_deps"]:
            print("      ^ waits on %s" % ", ".join(c["unmet_deps"]))
    print()
if if_tasks:
    flight_block(if_tasks, "TASKS")
# The control for everything above: a lane that is GENUINELY empty must still
# say so. "(Good.)" is only true when nothing is open AND nothing is in flight.
if not tasks and not if_tasks and only_kind != "task":
    print("TASKS - none open. (Good.)\n")

if hyps:
    print("HYPOTHESES - the science lane. The expensive resource should always be on one.")
    print("%-5s %-6s %-20s %-4s %-7s %-8s %-18s %s"
          % ("ID", "COST", "FAMILY", "ATT", "BLOCKS", "FAM_ATT", "TARGETS", "CLAIM"))
    print("-" * 126)
    for c in hyps:
        tg = ",".join(SHORT.get(t, t) for t in c["targets"]) or "-"
        print("%-5s %-6s %-20s %-4d %-7d %-8d %-18s %s"
              % (c["id"], c["test_cost"], c["family"][:20], c["attempts"],
                 c["blocks_n"], c["family_attempts"], tg, c["claim"][:32]))
        if c["unmet_deps"]:
            print("      ^ waits on %s - test that first" % ", ".join(c["unmet_deps"]))

    # Goal coverage. The point of --targets is that this question becomes
    # answerable: is the open portfolio actually aimed at the thing that
    # defines winning? A target with nothing pointed at it is a blind spot
    # nobody would otherwise notice.
    covered = set()
    for c in hyps:
        covered.update(c["targets"])
    missing = [t for t in ALL_TARGETS if t not in covered]
    if missing:
        print("\n  ! NO OPEN HYPOTHESIS TARGETS: %s" % ", ".join(missing))
        print("    Your goal file judges on all %d. Nothing in the portfolio is" % len(ALL_TARGETS))
        print("    currently aimed at the ones above - that is a gap in the")
        print("    search, not a fact about the problem.")

if if_hyps:
    if hyps:
        print()
    flight_block(if_hyps, "HYPOTHESES")

if hyps and not if_hyps:
    print()
print_empty_cells()

# This is a ranking, not an instruction. Said out loud because a ranked list is
# the easiest thing in this system to follow off a cliff: taking rank 1 every
# time turns a portfolio into a queue, and a queue explores one family until it
# is exhausted rather than testing the idea most likely to be wrong.
print("\nThe two lanes do not compete: a task never takes the expensive-resource")
print("slot, and a hypothesis never jumps the queue on an obligation to a shared")
print("resource. Within the hypothesis lane this is a RANKING, not an")
print("instruction - take rank 1 only if you can say why it beats the")
print("alternatives.")
print("  TARGETS  which of your TARGETS this bears on - the goal link.")
print("  BLOCKS   how many live records depend on it. A result that changes")
print("           several downstream decisions is worth more than one that")
print("           changes none, whatever the claim's intrinsic interest.")
print("  FAM_ATT  attempts already spent on this family - the diversity signal.")
print("           High, with nothing falsified, is a family being re-skinned")
print("           rather than tested. `families` adds the measured base rate.")
print("--exclude-family <f> drops the incumbent when the last result was null.")
# No candidate to dispatch is still exit 1, even when a mid-attempt record was
# named above: `next` answers "what should I pick up", and there the answer is
# genuinely nothing. What changed is that the reader now sees WHY it is nothing.
sys.exit(0 if (tasks or hyps) else 1)
PY
}

[[ $# -eq 0 ]] && usage 2

sub="$1"; shift
case "$sub" in
    new)        cmd_new "$@" ;;
    similar)    cmd_similar "$@" ;;
    show)       cmd_show "$@" ;;
    list)       cmd_list "$@" ;;
    families)   cmd_families "$@" ;;
    set-state)  cmd_set_state "$@" ;;
    retarget)   cmd_retarget "$@" ;;
    provenance) cmd_provenance "$@" ;;
    reblock)    cmd_reblock "$@" ;;
    link)       cmd_link "$@" ;;
    next)       cmd_next "$@" ;;
    drift)      cmd_drift "$@" ;;
    -h|--help)  usage 0 ;;
    *) echo "unknown subcommand: $sub" >&2; usage 2 ;;
esac
