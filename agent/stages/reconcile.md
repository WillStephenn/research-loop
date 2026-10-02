# Reconcile a dead predecessor

You are the orchestrator, and either `bin/tick.sh --breadcrumb` exited 0 or
`bin/hypothesis.sh drift` exited 3. Your predecessor was cut off mid-stage.

A tick killed mid-stage never reaches its commit or its journal write, so the
loop's own records show it as never having happened while its edits sit in the
working tree. Usage limits arrive without warning, and a machine can sleep or shut
down under a tick. Your job is to find out what was lost, keep what is complete,
discard what is partial, and put the gap in the journal.

## 1. Read the breadcrumb

```bash
bin/tick.sh --breadcrumb
```

`reason` says how it died. It is a fact for you to weigh, not an instruction.

| reason | What it usually means |
|---|---|
| `usage_limit` | the stage was fine and the work stopped |
| `killed` | the machine or the process was stopped from outside. Read what happened before you blame the stage |
| `error` | the dead conversation may itself be the problem, so do not trust its conclusions |
| `lost` | the heartbeat died with the tick, so there is no output to read |

`capture` names the dead tick's output. `tail -c 40000` of it is plenty. Treat it
as a lead, not a finding: it is truncated, and dates especially cannot be trusted.
Verify every claim against the repository before you act on any of it.

If you were resumed after a pause, you hold your own context. Re-verify anything
volatile (the journal tail, `active-runs`) before acting on conclusions you formed
before you stopped.

## 2. See what it left

```bash
git status --short         # what the dead tick left behind
git log @{u}..             # committed but never pushed
git log --oneline -5
```

Outside a git repository, list the files changed since `tick_started_at`.

## 3. Reconcile, in this order

1. **Push anything committed but unpushed.** No judgement needed: the work already
   passed its author's bar.
2. **Judge the working tree yourself.** Complete, correct work: commit it, crediting
   the tick that did it. Half-finished work: discard it. A partial script or a
   half-written config is more dangerous than an empty tree, because your
   successor cannot tell it is partial. Do not keep it "just in case".
3. **Journal what happened**, whichever way you went:

   ```bash
   bin/journal.sh append --event tick_aborted \
       --note "<when it died, at what stage, what was recovered, what was discarded>"
   ```

   Write it even when there was nothing to recover. "Died while testing H4, tree
   clean, nothing lost" is a useful line, and its absence is what makes a dead tick
   look like a tick that never ran.
4. **Check the registry against reality**, below.

## 4. The registry

```bash
bin/hypothesis.sh drift
```

Exit 3 means at least one record disagrees with the journal. Each finding names the
id, the shape of the disagreement and what to do. It reports and never repairs,
deliberately: the right transition needs judgement about what actually happened.
Read the record's own artefacts first, and score against the falsifier as stored.
It matters more than it looks, because `attempts` counts on the way into `testing`,
and a missed transition is a cap that silently does not bind.

**`testing_orphaned` and `doing_orphaned`** are the shapes a dead tick leaves. The
agent working them died, so nothing decided them. `done`, `dropped`, `confirmed`
and `falsified` would claim a result that does not exist, and `blocked` would
claim a dependency that does not. Use the one transition made for this:

```bash
bin/hypothesis.sh set-state <id> open \
    --interrupted-by "<what stopped the agent>" --evidence "<what you did with the partial work>"
```

No `--new-mechanism`: that guards against reviving a conjecture killed on evidence,
and nothing was killed. The spent attempt is held, not restored: the next entry to
`testing` resumes it and spends none. Look at the working tree and the journal
first, though. The usual case is that the work finished and was never recorded,
and then the honest transition is the real one, with the evidence from its output.

**`testing_run_terminal`** means a linked job ended and nobody scored it. Score it
with `agent/stages/record-result.md`.

A job still in flight is not orphaned: `bin/journal.sh active-runs` is the
authority. And do not hunt for drift the check does not report. An `open` record at
`attempts` 0 after a launch that never made progress is correct, because a launch
that dies in setup should not spend an attempt.

## 5. Then orient

Go back to section 3 of `agent/orchestrate.md`. Do not skip orientation because
the dead tick's output told you what it was doing: it died, so its conclusions are
stale by definition and the world has moved on since.
