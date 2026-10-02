# Record a result

Used when a test has finished: by the orchestrator after a job ends, or by a
sub-agent that scored a probe. Your job is to turn evidence into records that a
successor with no memory can use.

```
hypothesis_id <the record whose test finished>
```

## 1. Score against the falsifier as stored

```bash
bin/hypothesis.sh show <hypothesis_id>    # claim, falsifier, linked jobs, journal lines
```

Read the job's own output files, not its log lines and not a sub-agent's summary of
them. Score the falsifier as written. A result that cannot be scored as written is a
finding about the criterion: say so, and do not substitute one you can evaluate.

## 2. Choose the state

| State | When | Needs |
|---|---|---|
| `confirmed` | the falsifier did not fire | `--evidence`, and `--metric-delta` if a target moved |
| `falsified` | the falsifier fired. Terminal | `--evidence` |
| `blocked` | the test was confounded, or cannot decide it yet | `--blocked-on`, naming what would settle it |
| `superseded` | another result made it moot, untested | `--superseded-by <id>` and `--evidence` |

`blocked` is not `falsified`: a confounded test leaves the claim untouched, and
blocking records what would settle it without spending the claim. Reaching for
`blocked` because a clean result was disappointing is how a loop avoids ever
concluding anything. Never use `falsified` to retire a moot record, because it
claims evidence that does not exist.

If the record is already `blocked` and the result kills it, go straight to
`falsified`. A methodology defect found in a test is fixed and the test re-run. A
second failure with no new defect retires the hypothesis: do not run it a third time
hoping for a cleaner read.

## 3. Write it down

```bash
bin/hypothesis.sh set-state <id> falsified \
    --evidence "trimmed 0.3175 against mean 0.3181: inside the noise, no effect" \
    --metric-delta 'median_error: 0.3181 -> 0.3175'
bin/journal.sh append --event note --hypothesis-id <id> \
    --note "<what was measured, against what, the number, what it changes>"
```

The evidence is the number that decided it. The journal note is for a reader with no
other context, so say what you would have to know to act on it.

## 4. Did it move the goal?

Only a registered evaluation can decide whether the goal is met, meaning the eval
files the goal file names. A probe that re-scores something another way is evidence
about a hypothesis, never about the goal. After a registered evaluation:

```bash
bin/north_star.sh check --eval <a.json> --eval <b.json>            # exit 0 met, 1 not met
bin/north_star.sh met --eval <a.json> --eval <b.json> --record     # only after a 0
```

`--record` journals a `north_star_met` event that the next wake's `pending` will
re-verify from the files it names, so the claim is never taken on trust.

## 5. Write the rivals while the result is fresh

Generating hypotheses is rarely the bottleneck. Keeping them is: an idea that is not
a record is one the loop will regenerate, half remembered, next week. Each result
suggests rivals, so register them now.

```bash
bin/hypothesis.sh similar "<claim>"        # has this been claimed before?
bin/hypothesis.sh new --family <f> --test-cost <probe|run> --targets <t> \
    --provenance <journal ts | path[:LINE]> --claim "..." --falsifier "..." [--depends-on <id>]
```

Each must cite the result that prompted it (`--provenance` is validated, so a
pointer that matches nothing is refused), name the metric it expects to move, and
carry a falsifier. With no falsifier `new` refuses it. It also screens for
near-duplicates and exits 2 naming what it thinks you re-drafted. If yours really
differs, add `--not-a-duplicate "<one sentence on what differs>"`, which is kept in
the record's history. The screen is lexical only: a heavy reword passes, so read
the neighbours yourself.

Do not register what no longer needs testing. Prefer the hypothesis whose outcome
changes what you do next. When this result makes another record moot, retire it:

```bash
bin/hypothesis.sh set-state <id> superseded --superseded-by <id> --evidence "<why it is moot>"
```

An obligation rather than a conjecture is a task: `new --kind task --done-when "..."`.
Keep tasks narrow: things that block the loop, or are owed to a shared resource.

## 6. When a sub-agent did the testing

Do not take its word. Run `bin/hypothesis.sh show <id>` after it returns and check
that the state moved, the evidence is a number, and a journal line exists. If it
returned without recording, record the result yourself, from the output files and
never from its summary.
