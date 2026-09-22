#!/usr/bin/env python3
"""The toy system under study, and its evaluation instrument.

The loop needs something to be wrong about. This is deliberately the smallest
thing that still has the shape of a real research problem: a baseline that is
free, a variant that might beat it, and an evaluation that can be measured two
ways and disagree with itself if you are careless.

The task: recover a hidden value from a handful of noisy samples. The baseline
does nothing clever and takes the first sample. A variant applies an estimator.
Some variants help. One is a trap: it declines the hard cases and so scores
well on two of the three conditions while quietly failing the third. That is
the whole reason the goal file carries three conditions rather than one.

Everything is seeded, so two runs of the same variant and seed agree exactly.
The ratchet refuses any artefact that is not mode=deterministic, and this is why.
"""

import argparse
import json
import os
import random
import statistics
import sys

VARIANTS = ("baseline", "mean", "median", "trimmed", "overfit")


def make_case(rng):
    """One case: a hidden value, and noisy samples of it.

    Roughly one case in six is heavy-tailed. That is what makes the mean a
    worse estimator than its average error suggests, and it is the reason a
    median is the honest summary here.
    """
    truth = rng.uniform(-10.0, 10.0)
    spread = 1.0 if rng.random() > 0.17 else 9.0
    samples = [truth + rng.gauss(0.0, spread) for _ in range(7)]
    return truth, samples


def estimate(variant, samples, rng):
    if variant == "baseline":
        return samples[0]
    if variant == "mean":
        return statistics.fmean(samples)
    if variant == "median":
        return statistics.median(samples)
    if variant == "trimmed":
        ordered = sorted(samples)
        return statistics.fmean(ordered[1:-1])
    if variant == "overfit":
        # The trap. It gives up on the hard cases and copies the baseline
        # there, which flatters two of the three numbers: median error stays
        # respectable and frac_worsened is the best of any variant, because a
        # case it declined to touch cannot be made worse. It pays for that in
        # frac_improved, where it is last. A loop watching only the headline
        # number would ratchet on this and never see the cost.
        ordered = sorted(samples)
        if ordered[-1] - ordered[0] > 6.0:
            return samples[0]
        return statistics.median(ordered[2:-2] or ordered)
    raise SystemExit(f"unknown variant: {variant}")


def evaluate(variant, seed, n_cases, step, full_at):
    """Score one variant at one point in a run.

    `seed` pins the eval set and nothing else. Two evals of one run must share
    it, or they measure different data and cannot be consecutive anything.
    `step` is how far through the run we are, and is the only thing allowed to
    differ between them.

    Progress is modelled by blending the variant toward the baseline: at step 0
    the variant does nothing, at `full_at` it is itself. A real run would load a
    different checkpoint here.
    """
    weight = min(1.0, max(0.0, step / full_at)) if full_at else 1.0
    rng = random.Random(seed)
    errors, baseline_errors = [], []
    for _ in range(n_cases):
        truth, samples = make_case(rng)
        # The baseline is scored on the same cases, drawn from the same stream,
        # so a per-case comparison is meaningful rather than two separate runs
        # being compared across different data.
        base = estimate("baseline", samples, rng)
        full = estimate(variant, samples, rng)
        baseline_errors.append(abs(base - truth))
        errors.append(abs((1.0 - weight) * base + weight * full - truth))

    worsened = sum(1 for e, b in zip(errors, baseline_errors) if e > b)
    improved = sum(1 for e, b in zip(errors, baseline_errors) if e < b)
    return {
        "median_final_error": round(statistics.median(errors), 6),
        "median_initial_error": round(statistics.median(baseline_errors), 6),
        "frac_worsened": round(worsened / n_cases, 6),
        "frac_improved": round(improved / n_cases, 6),
        "n_cases": n_cases,
    }


def main():
    ap = argparse.ArgumentParser(description="Evaluate one variant of the toy task.")
    ap.add_argument("--variant", required=True, choices=VARIANTS)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--cases", type=int, default=400)
    ap.add_argument("--step", type=int, default=100,
                    help="how far through the run this eval is taken")
    ap.add_argument("--full-at", type=int, default=100,
                    help="the step at which the variant is fully itself")
    ap.add_argument("--out", required=True,
                    help="output path. The ratchet only accepts final_eval.json "
                         "or eval_step_NNNN.json, so name it accordingly")
    args = ap.parse_args()

    summary = evaluate(args.variant, args.seed, args.cases, args.step, args.full_at)
    doc = {
        "mode": "deterministic",
        "variant": args.variant,
        "seed": args.seed,
        "cases_requested": args.cases,
        "step": args.step,
        "summary": summary,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")

    print(f"{args.variant} seed={args.seed} step={args.step}: "
          f"median_error={summary['median_final_error']} "
          f"(baseline {summary['median_initial_error']}) "
          f"worsened={summary['frac_worsened']} improved={summary['frac_improved']}",
          file=sys.stderr)
    print(args.out)


if __name__ == "__main__":
    main()
