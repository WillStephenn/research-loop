# Work a task

A task is an obligation to discharge, not a conjecture to spend. It has a done
condition where a hypothesis has a falsifier, and no attempt cap: you do not stop
fixing a broken build because you have tried three times.

```
hypothesis_id <the task id>
```

A task belongs in the registry only when it blocks or distorts the loop's ability
to run experiments, or is an obligation to a shared resource. General feature work
belongs in an ordinary issue tracker, or the registry becomes a second and worse
one. Priorities run `blocking`, `good-citizen`, then `chore`. Treat `good-citizen`
tasks as due, not available: they are cheap and nobody finds them interesting,
which is exactly why they rot.

## 1. Read it

```bash
bin/hypothesis.sh show <hypothesis_id>
```

`done_when` is the criterion. As with a falsifier, do not restate it and then score
against the restatement. Confirm the task is `open`: one in `doing` is held by
another stage.

## 2. Mark it doing

```bash
bin/hypothesis.sh set-state <id> doing --evidence "<what you are about to do>"
```

## 3. Do the work, then show it is done

Do what the done condition asks and no more. Check the condition as written, with
evidence someone else could re-run. A committed script beats a shell pipeline.

## 4. Close it

```bash
bin/hypothesis.sh set-state <id> done --evidence "<how done_when was met>"
bin/journal.sh append --event note --hypothesis-id <id> --note "<what changed, and how to check it>"
```

- `dropped` is also terminal, and its `--evidence` must say why it no longer applies.
- `blocked --blocked-on "<what it waits on>"` records a wait.
- If you were interrupted rather than finished, pick no outcome. Recover it with
  `set-state <id> open --interrupted-by "<what stopped you>"` (see `reconcile.md`).

If you find a new obligation on the way, register it with `new --kind task --priority
<blocking|good-citizen|chore> --family <f> --test-cost probe --claim "..." --done-when "..."`.
It is screened for duplicates like any other record. Do not start a test, and do not
touch the goal file.
