# North Star

**This file defines what winning is.** Everything else in this project, the
model, the correction procedure, thresholds, pre-registered gate criteria,
which hypothesis is being tested, is an *instrument*, and the loop may revise
any of it freely. This file is the *target*.

**No agent may hand-edit this file.** An agent that can redefine victory will
eventually declare it, so the loop writes here through exactly one tool, on
exactly one path, under conditions it cannot satisfy by choosing to.

## The one delegated change: the ratchet

Left alone, this file would need a human every time the target is cleared: a
met target has nowhere to go, so the loop either stops (success behaving
exactly like failure) or waits for someone to notice and raise the bar by
hand. A project that wants otherwise can delegate exactly one change to
`bin/north_star.sh`, and only that one.

The loop may **raise** the active target. It may never lower it. Concretely:

- **Only the numeric threshold of each configured axis moves.** The set of
  axes, `median_error`, `frac_worsened`, `frac_improved`, and which
  direction is harder on each, come from `RATCHET_AXES` in
  `config/loop.conf`. The *shape* of each condition (its metric, its
  comparison, and its reference metric if it has one), the
  two-consecutive-evals count, and this preamble are **human-owned**, and no
  tool writes them.
- **Only when the active target has been met** on every condition at **two
  consecutive registered evals**, the process's own `final_eval.json` /
  `eval_step_*.json`, never a probe re-scoring.
- **Only to a bar already cleared twice.** A new threshold may not be
  stricter than the worse of the two measurements that triggered it, so the
  ratchet follows the evidence and cannot run ahead of it.
- **Only by appending.** A new version is prepended to the stack below;
  earlier versions are never edited, so what the target was on any past date
  stays readable.
- **Every moved threshold cites the measurement that sized it**, and the
  citation is stored with the version.

`bin/north_star.sh` is the only writer, and every one of those conditions is
enforced by exit code rather than by an agent remembering it, see
`north_star.sh --help` for the refusal ladder. Hand-editing this file to
achieve the same effect is precisely what the rule forbids.

**A human holds a veto, not an approval.** The loop does not wait: the
moment a version is created it continues against it. `ratchet --apply`
prints the old to new deltas and the sizing evidence to stdout and records
them in the journal. To veto, revert the commit that added the version, a
human editing this file is not what any of the above constrains.

Wanting to change anything *else* here is still a genuine stop condition.

---

## What this demo is trying to do

A simple estimator predicts a single number for each case in a stream of
test cases. Its raw prediction has some error against the true value. A
correction step adjusts that prediction, and **error** is how far the
corrected value sits from the truth. It is the only number that matters
here: smaller is always better, and the units are whatever the estimator's
own native scale is.

## The bar is doing nothing

Leaving the raw prediction uncorrected already has some error. That is the
**do-nothing baseline**, and it is the floor any correction step must clear,
a correction that cannot beat it is worse than useless, because skipping it
gives a better result.

The baseline is **set-specific**. Read it from the run's own artefact
(`median_initial_error`), never from a remembered constant.

## Where things stand

| | median error | improved | worsened |
|---|---|---|---|
| Do nothing | 10.0 | , | , |
| Best correction so far | 9.4 | 0.22 | 0.30 |

No correction procedure in this demo's history has yet beaten doing nothing
by much, which is exactly why the active target below asks for so little:
clearing v1 means the correction step has started working at all, not that
it is finished.

---

## Active target

On the pinned held-out eval set, evaluated deterministically, a run must
satisfy **every** condition of the **active version** below, at **two
consecutive** registered evals.

The `frac_improved` condition is not decoration. A correction step that
never touches the prediction passes the median and worsened conditions
perfectly while fixing nothing, so the null policy must fail. Worsened and
improved together are the actual problem in one line: **act when it helps,
hold when it does not.**

### Versions, newest first, append-only

The **first** `north-star-target` block below is the active target. Earlier
versions are kept verbatim, so any past result can still be read against the
bar it was actually judged by.

<!-- north-star-versions: newest first; new versions are inserted immediately below this line by bin/north_star.sh ratchet --apply, which is the only writer. Never insert one by hand. -->

#### v1 - active since project start

1. `median_final_error` ≤ 1.0 × `median_initial_error`
2. `frac_worsened` ≤ 0.25
3. `frac_improved` ≥ 0.25
4. All of the above at **2 consecutive** registered evals

```json north-star-target
{
  "version": 1,
  "applies_to": "loop_target",
  "active_since": "2026-01-01",
  "supersedes": null,
  "consecutive_evals": 2,
  "conditions": {
    "median_error": {
      "metric": "median_final_error",
      "op": "<=",
      "reference": "median_initial_error",
      "multiplier": 1.0
    },
    "frac_worsened": {
      "metric": "frac_worsened",
      "op": "<=",
      "threshold": 0.25
    },
    "frac_improved": {
      "metric": "frac_improved",
      "op": ">=",
      "threshold": 0.25
    }
  },
  "sizing_evidence": {
    "median_error": "human-set at project start. Multiplier 1.0 IS the do-nothing baseline, and no correction procedure in the project's history had ever beaten it.",
    "frac_worsened": "human-set at project start. The best correction so far worsened 0.30 of cases; 0.25 is a little under that.",
    "frac_improved": "human-set at project start. The best correction so far improved 0.22 of cases; 0.25 sits just above it."
  },
  "authorised_by": "human, at project setup",
  "met_evidence": null
}
```

## Definition of done

1. `frac_worsened` ≤ 0.05
2. Holds at two consecutive registered evals

**Human-owned and outside the ratchet.** The block below is a
machine-readable transcription of those two lines and nothing more: no tool
writes it, and it exists so the ratchet can *refuse* to push the active
target past a bar the human set. It defines a floor only for the axes it
lists; an axis it says nothing about has no floor here.

```json north-star-dod
{
  "applies_to": "definition_of_done",
  "human_owned": true,
  "consecutive_evals": 2,
  "conditions": {
    "frac_worsened": {
      "metric": "frac_worsened",
      "op": "<=",
      "threshold": 0.05
    }
  }
}
```

## Reading the result

Every term above comes straight out of `final_eval.json` (or
`eval_step_*.json`) under `summary`. No interpretation, no judgement call.

Those files are the **registered eval instrument**, and they are the only
thing that may decide whether a target is met. A probe that re-scores a run
some other way is evidence about a hypothesis, never about this file:
`north_star.sh` refuses any artefact that is not one of them, with `mode`
recorded as `deterministic`.

Two structural facts about an eval set like this that any criterion must
respect:

- **Some fraction of cases already have zero initial error**, already
  perfect. They can be held or worsened, never improved. A
  `frac_improved` bar set too high can therefore silently mean "win nearly
  all of the winnable ones" against a ceiling below 1.0.
- **A small eval set is too few cases to estimate a median reliably.**
  Whatever the eval set size caps at, raising it should keep the original
  cases as a subset, so older results stay comparable and the estimate
  simply tightens.

Judge on medians and counts, never on means: skewed error distributions let
one large outlier make a small run look better or worse than a fair,
case-by-case reading would say.

## When the goal itself is the problem

If the evidence says this target is unreachable as specified, for instance
if the eval set is too thin to support it, **that is a result, and
reporting it is success, not failure.** Say so plainly, with the measurement
that shows it, and stop. Do not grind against a wall to avoid delivering bad
news.
