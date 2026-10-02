# agent/: the orchestrator, and the heartbeat that wakes it

```
cron, launchd or a loop, every few minutes, calls bin/tick.sh   (not due: exits at once)
  due: takes a lock, runs AGENT_CMD from config/loop.conf
  v
the agent reads agent/orchestrate.md: wake, reconcile, orient, choose one unit
  |--> a sub-agent reads agent/stages/<stage>.md, given an id only
  v    record, commit, report
bin/schedule_next.sh --in-minutes 120 --reason "..."     sets the next due time
```

A dead tick leaves a breadcrumb in `state/` that the next wake reconciles from. A
tick that forgets to schedule gets the default.

## Small on purpose

Instructions loaded on every wake cost tokens on every wake. So `orchestrate.md` holds
only the loop, a stage file is read when that step is dispatched, and tools explain
themselves through `--help`. Tokens are bytes divided by four.

| File | Lines | Tokens | Read |
|---|---|---|---|
| `orchestrate.md` | 198 | 2,547 | every wake |
| `stages/reconcile.md` | 106 | 1,184 | after a death, or when `drift` fires |
| `stages/test-hypothesis.md` | 104 | 1,264 | a probe or run is dispatched |
| `stages/record-result.md` | 103 | 1,152 | a test has finished |
| `stages/raise-goal.md` | 108 | 1,276 | the target was met |
| `stages/work-task.md` | 54 | 520 | a task is dispatched |
| `agents/*.md` (four) | 19 to 26 each | 214 to 338 | by platforms with named sub-agents |

A typical wake reads `orchestrate.md` plus one stage: about 3,700 tokens, against
about 16,000 for the file this was extracted from.

## Wiring it up

1. Edit `config/loop.conf` (the vocabularies, then `AGENT_CMD`) and write your goal file.
2. Check with `bin/tick.sh --dry-run`. The first real call runs a tick at once.
3. Call `bin/tick.sh` every few minutes: `examples/crontab.txt` or
   `examples/com.example.research-loop.plist`. Keep `SCHEDULE_MIN_MINUTES` at or above that.

**Claude Code.** The default `AGENT_CMD` is `claude -p "Read agent/orchestrate.md and
follow it"`. Add the permission flags you are comfortable with, and
`--session-id "$RL_SESSION_ID"` so a death records its session. Set `AGENT_RESUME_CMD`
to resume it after a usage limit. Copy `agent/agents/*.md` into `.claude/agents/` so
the orchestrator can dispatch each stage by name.

**Another agent.** Anything that runs shell commands from the repo root will do: put
it in `AGENT_CMD`. Without sub-agents, the orchestrator reads each stage file and
does the stage itself.

## State

`state/` is machine state, gitignored, and moved with `RL_STATE`: `next-wake`,
`next-wake-request`, `tick-aborted` (the breadcrumb), `last-tick-stdout.log`,
`tick.lock/` and `aborted-archive/`. The journal and registry hold the research.
This repository ignores `registry/`; in your own project drop that line, so a
commit carries the journal.
