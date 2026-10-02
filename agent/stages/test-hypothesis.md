# Test a hypothesis

You settle one hypothesis: you run the cheapest test that could prove it wrong,
then record the result. You hold no fixed knowledge. The orchestrator gave you one
id, and everything else is in the registry and the journal.

```
hypothesis_id <the record to settle>
```

## 1. Read the claim before the data

```bash
bin/hypothesis.sh show <hypothesis_id>
```

The `falsifier` is the criterion. It was written before this data was looked at,
and that ordering is the only thing that makes the result worth anything. **Do not
restate it in your own words and score against the restatement:** that is how a
bound quietly moves. If it cannot be scored as written, that is a finding about the
criterion. Say so and stop. Do not invent a new one.

Confirm the record is `open` (or `blocked`, with a reason to retry in the journal)
and that it waits on nothing unsettled. If it is already `testing`, another stage
holds it: stop.

## 2. Pick the test by tier

`test_cost` on the record says which tier it is.

- **`probe`** decides it from artefacts that already exist: a results file, a
  metrics table, a saved output. Minutes, no exclusive resource, safe to run while
  a job is in flight. Prefer a probe that needs nothing expensive at all. Many
  claims are decidable from a table already on disk.
- **`run`** books the expensive resource for hours. Never book one for something a
  probe could settle. The orchestrator does this tier in its own session (section
  4), because a background process dies when the sub-agent that owns it stops.

## 3. Write the probe as a script, not a shell pipeline

Commit it with your project's other experiment scripts and have it write a JSON
artefact beside them. A result that exists only in a terminal cannot be re-read by
whatever cites it, and a probe nobody can re-run cannot be checked by anyone who
doubts it. Say in the artefact which input it scored: a result with no provenance
is not evidence. Give each probe its own file name. If `git status` shows an
already-tracked file as modified, you have overwritten somebody's evidence, so read
the diff before you commit.

## 4. Record: testing, then the result

```bash
bin/hypothesis.sh set-state <id> testing --evidence "probe started against <input>"
# once scored:
bin/hypothesis.sh set-state <id> <confirmed|falsified|blocked> --evidence "<the number that decided it>"
bin/journal.sh append --event note --hypothesis-id <id> \
    --note "PROBE: <what was measured, against what, the number>"
```

`agent/stages/record-result.md` has the detail. Three outcomes, and the third is real:

- **falsified**: the falsifier fired. Terminal. Say what it cost to learn.
- **confirmed**: it held. A probe that confirms a claim is usually weaker evidence
  than one that kills it, so a survivor normally still needs its `run`.
- **blocked**: the probe could not settle it. Say what would, with `--blocked-on`.
  That turns an unbounded question into a specific one, which is progress. It is
  not for a clean test with a disappointing answer.

If the record was already `blocked` and your probe settles it, go straight to
`falsified`: that edge is legal and spends no attempt. Do not launder a result
through `open`. If it is still blocked but on something else, revise the blocker in
place with `hypothesis.sh reblock <id> --blocked-on "<what it waits on now>" --reason "..."`.

Three attempts is the cap, and `set-state testing` past it exits 2 unless you pass
`--override-cap "<why this one is different>"`. Reaching for that flag usually
means the hypothesis should be retired.

## 5. A run: the job that outlives the tick

The orchestrator runs this tier itself. Fix the criteria before you launch, and
commit them: changing one after the first result exists is falsifying the result.
Start the job detached, give it a name, and once you have seen it make real
progress, record all three in the same breath. A launch that dies in setup should
not spend an attempt.

```bash
bin/journal.sh append --event run_started --run-id <name> --hypothesis-id <id> \
    --note "<what it tests, the expected duration, where its output lands>"
bin/hypothesis.sh link <id> --run-id <name>
bin/hypothesis.sh set-state <id> testing --evidence "job <name> making progress"
```

At each wake, check the job and journal one line against the id. When it ends,
journal `run_completed`, `run_died` or `run_stopped` with the same `--run-id`, and
score it with `record-result.md`. `run_stopped` means someone ended it on purpose
and is terminal: never resume it. A death is not a falsification, and a relaunch
that changes nothing will hit the same fault. Three failed launches of one thing
is a structural fault: diagnose it instead of trying a fourth.

## Out of scope

Do not edit the goal file, raise a target, or touch another record. Do not test a
record that is `testing` on a live job: you would score a mid-flight result against
a criterion written for the final one. If the probe shows the hypothesis needs a
real run, record what you found and hand it back.
