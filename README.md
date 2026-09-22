# research-loop

A falsification-disciplined harness for running a research programme unattended.

An agent driving a long research programme has one characteristic failure mode:
it confirms itself. It proposes an idea, runs something, reads the result
generously, records a success, and moves on. Do that for a month and you have a
hundred confirmed hypotheses and no progress.

This is the machinery built to stop that. It holds hypotheses in a registry as a
dependency graph, refuses any conjecture that does not say in advance what would
kill it, and treats a falsified idea as permanently dead. It ranks what to test
next by what is cheapest to settle and what unblocks the most other work. It
lets the loop raise its own definition of success, but only upward, only on
evidence it has already cleared twice, and only through one tool that enforces
every condition by exit code.

The design principle throughout: an agent that can redefine victory will
eventually declare it, so the guard has to be mechanical rather than a rule
written down and remembered.

## Provenance

This is an extract. The original is a private research system I built to run an
unattended machine learning programme: it proposed hypotheses, selected the
cheapest experiment that could falsify one, dispatched GPU work across around 30
shared university lab machines, and recorded its verdicts in an append-only
journal. Over four weeks it settled 85 registered hypotheses, confirming 27 and
falsifying 32, including defects it found in its own evaluation harness.

That system stays private. The extraction was carried out by Claude Opus 5,
working from the original repository, to separate the reusable core from the
research it was pointed at. Every domain specific detail has been removed: the
problem being studied, the measurements, the findings, the infrastructure. What
is left is the part that was never about the research problem in the first
place.

Two honest caveats. The original ran for four weeks and earned its scars; this
generalised version has a test suite and a working demo but no production
history of its own. And the layer that dispatched work across a machine fleet is
not here, because it was specific to one university network and useless without
it.

## How it works

Three tools over two stores.

**`bin/hypothesis.sh`** is the registry. One JSON file per record, version
controlled, so `git diff` shows what a tick changed and why. It holds two kinds
of record. A *hypothesis* is a conjecture that gets spent: it requires a
falsifier, and it is capped at three attempts. A *task* is an obligation that
gets discharged: it requires a done condition instead, and has no cap. Admitting
both as one family would have forced fake falsifiers onto things that are not
conjectures.

States are `open`, `testing`, `confirmed`, `falsified`, `blocked` and
`superseded`. `falsified` is terminal. `blocked` back to `open` requires a new
mechanism, not a change of mind. `superseded` exists so a hypothesis can be
retired untested when another result makes it moot, because using `falsified`
for that would claim evidence that does not exist.

There is deliberately no field for predicted impact. A guess that becomes a sort
key launders itself into evidence.

**`bin/north_star.sh`** is the ratchet over the goal file. The goal file is the
loop's only definition of success; everything else, every threshold and preset
and gate criterion, is an instrument the loop may revise freely. Left immutable,
a met target has nowhere to go and success behaves exactly like failure. So the
loop is delegated exactly one change: it may raise the bar, never lower it, only
when the current bar has been met at two consecutive registered evaluations, and
only to a value the evidence has already cleared twice. The shape of the
conditions stays human owned. Nine numbered exit codes carry the refusals.

**`bin/journal.sh`** is an append-only ndjson event log. Nothing rewrites a
line. The registry records what is *believed* and changes as evidence arrives;
the journal records what *happened* and never changes. They join on a hypothesis
id, which is the whole handoff primitive: an agent given nothing but an id can
recover the full context of what it was doing.

## Try it

```bash
./demo/walkthrough.sh
```

A narrated pass through the lifecycle against a scratch registry, built in a
temporary directory and discarded at the end. It registers hypotheses, ranks
them, records verdicts, and then deliberately attempts four things that should
not be allowed: a hypothesis with no falsifier, resurrecting a falsified one,
ratcheting to a bar the evidence has not cleared, and ratcheting to an easier
one. Each refusal is run for real and its exit code checked. The refusals are
the product.

Pass `--keep` to leave the scratch directory behind and read the records it
built.

## Pointing it at your own problem

Edit `config/loop.conf`. It holds the closed vocabularies: the families a
hypothesis may belong to, the metrics it may claim to move, the axes the ratchet
may raise and which direction is harder on each, the cost tiers, and the attempt
cap. Nothing else needs to change. The vocabularies are closed on purpose: a
free text family field becomes a pile of near synonyms within a fortnight, and a
free text target field lets a hypothesis claim it moved something nobody agreed
to measure.

Then write a goal file. `examples/NORTH_STAR.md` is a worked one for the demo's
toy task.

## Tests

```bash
./tests/test_hypothesis.sh
./tests/test_journal.sh
./tests/test_north_star.sh
```

No network, no fixtures outside the repo.

## Licence

MIT. See `LICENSE`.
