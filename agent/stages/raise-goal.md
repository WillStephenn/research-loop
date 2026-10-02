# Raise the goal

You are the one stage that writes the file defining what winning is. A human
delegated that in terms narrow enough that it cannot be abused: you may raise the
target and never lower it, only after the current target was met at two
consecutive registered evals, only to a bar the evidence has already cleared twice,
and only by appending a new version. `bin/north_star.sh` enforces each of those by
exit code, and it is the only writer.

The stage exists because a met target used to park the loop, so success behaved
exactly like failure. Read the goal file's preamble first (`$RL_GOAL`, default
`NORTH_STAR.md`): it states the delegation in the human's own terms, and this stage
is downstream of it.

You are given no context. Everything you need is recoverable from the tool, and
deriving the thresholds from the evidence is the whole job, so do not accept them
from anyone.

## 1. Confirm the trigger from the artefacts, not the claim

```bash
bin/north_star.sh pending --json
```

Exit 0 means a `north_star_met` is unconsumed and it re-verified: the tool re-read
the two eval files the event names and re-scored them against the active version.
Exit 1 means nothing is due: say so, change nothing, stop. Exit 3 means a claim
exists that does not re-verify. That is a finding: journal it, leave the goal file
alone, and hand it back. The output names the two evals, which are the only
evidence you may size from.

## 2. Size each threshold from that evidence

```bash
bin/north_star.sh check --eval <a.json> --eval <b.json>
```

It prints the worst measurement across the two evals beside each active bar. Those
are the two ends of the band, and both are hard: the loose end is the active
threshold, and the tight end is the worse of the two measurements. The tight end is
the point of the whole design. A new bar must already have been cleared twice,
because a target set to a number nobody has demonstrated is a prediction, not a
ratchet (exit 9).

**Default to halfway** between the old bar and the demonstrated value. It banks half
the gain and leaves headroom, so the next run is not failing a bar it has only just
touched. Go further when the two evals agree closely and the earlier evals in the
same series show a steady trend, which you can read from disk. Go less far when they
disagree or were taken on different numbers of cases. Say which you did.

**Move every axis that has room.** A ratchet that tightens one axis and leaves two
demonstrated gains unclaimed under-uses its evidence. Leave an axis alone when the
demonstrated value has not cleared its bar with room to spare.

## 3. Cite the measurement that sized each move

`--sizing NAME="..."` is required for every threshold that moves and refused for one
that does not. It must contain a number (exit 8) and stay under 300 characters: cite
the measurement here and argue in the journal. Name values, not intentions:

```
worst of the two evals was frac_worsened 0.2125 against the 0.25 bar; halfway is
0.231, taken as 0.23
```

not "tightened because it is improving".

## 4. Dry run, then apply

```bash
bin/north_star.sh ratchet --eval <a.json> --eval <b.json> \
    --threshold <axis>=<value> [--threshold ...] --sizing <axis>="..." [--sizing ...]
```

It decides and prints, and touches nothing. Read the exit code. A non-zero exit is a
constraint with a reason attached, never a hurdle:

- **3, 4**: the trigger was wrong (inadmissible evidence, or the target is not met). Stop.
- **5**: the file's condition shape was altered. Someone hand-edited it. Journal it and stop.
- **6**: a threshold loosened, or none tightened. Re-size, and never by loosening.
- **7**: past the Definition of done. Clamp that axis to its value. The human owns beyond it.
- **8, 9**: write the citation properly, or move the bar back inside the band.

Then repeat the same command with `--apply`. It writes the new version, journals a
`north_star_updated` event with the old to new deltas and the sizing, and prints the
same. That output is the human's veto signal and not an approval request: the loop
carries on against the new version at once. Do not wait, and do not stop to ask.

## 5. Journal and commit

```bash
bin/journal.sh append --event note \
    --note "<what moved, the measured values it was sized from, what was left alone and why>"
bin/north_star.sh verify        # must exit 0 before you commit
```

`--apply` already wrote the `north_star_updated` event, so the note is for the
reasoning it cannot carry. In a git repository, commit the goal file and the
journal by name, off the default branch, and never amend.

## What this stage may not do

- Change a condition's shape, the consecutive-evals count, an axis the config does
  not list, the Definition of done, or the preamble. All human-owned.
- Lower any threshold, for any reason. If the new target proves unreachable, that
  is a stop-list item and a result worth reporting, not a licence to walk it back.
- Edit an earlier version, or hand-edit the goal file at all.
- Start, stop or evaluate a job. You read files already on disk and write one file.
