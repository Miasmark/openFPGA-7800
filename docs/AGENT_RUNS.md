# Long agent runs on this project: cost and robustness

Lessons from running multi-agent work on DARIA step 7 (2026-10-09 to 10-11): an orchestrating session that starts workflows of subagents, each running builds, simulations and Quartus fits for hours. Read this before starting long agent work here. The machine and tool setup is in [ENVIRONMENT.md](ENVIRONMENT.md).

## 1. The prompt cache: poll at most every 4 minutes

**The two lifetimes.** The orchestrating session's prompt cache lasts 1 hour. Workflow subagents get a 5-minute cache. This was measured from the session's transcripts on 2026-10-10:
- every one of the orchestrating session's 21M cache-write tokens was a 1-hour write;
- every one of the subagents' 355M was a 5-minute write.

**Why it matters.** Writing a context into the cache costs 25 times as much as reading it back. Each new call either reads the agent's whole context from the cache or, if the cache has expired, writes it again. A subagent deep in a lane holds about 400k tokens of context, so letting its cache expire costs about 25 cache reads.

**What went wrong.** Agents that waited on a simulation or a fit used to check every 10 minutes. Each check found the cache expired and rewrote the whole context. Over the session to 2026-10-10 that was 37% of all spend: a median of 419k tokens rewritten per check.

**The rule:**
- While a subagent waits for a long job, it never lets more than 4 minutes pass between its own calls.
- It waits in bounded steps, for example `timeout 230 bash -c 'until <done-test>; do sleep 20; done'`, then checks, then waits again.
- Two 4-minute waits cost about one twenty-fifth of one 10-minute wait.
- When a wait is measured in hours, it is cheaper to end the subagent and let the orchestrating session (1-hour cache) do the waiting, then start a fresh agent for the next step.

**Measured effect.** Calls by the gap since the same agent's previous call:

| Workflow | Calls | Gaps under 4 min | 4-5 min | 5 min or more | Tokens rewritten after a gap of 5 min or more |
|---|---|---|---|---|---|
| Benches + Fix B, before the rule | 481 | 87.7% | 0 | 59 | 21.4M |
| Same, resumed, before the rule | 720 | 85.8% | 2 | 100 | 45.2M |
| Phase 1 finish, before the rule | 649 | 88.1% | 3 | 74 | 27.6M |
| Phase 1b, rule in every prompt | 538 | 99.4% | 3 | 0 | 0 |
| Phase 1b resumed, rule in every prompt | 349 | 97.7% | 8 | 0 | 0 |

**How to check a run.** For each subagent transcript:
1. Take the assistant messages, one per message id.
2. Sort them by timestamp.
3. For each consecutive pair, record the gap and the second call's `usage.cache_creation_input_tokens`.

A call that follows a gap of 5 minutes or more and has a large cache write is a rewrite. Put the rule in every subagent prompt; the agents follow it when it is stated with the reason.

## 2. Restarts

**How often.** Three session restarts hit in two days. A session restart kills the agents but not the processes they started. A machine restart kills the processes as well, and dockerd with them (ENVIRONMENT.md 3.3, 8.1).

**Commit and log early:**
- Commit verified work early on the lane branch. `WIP: ...` commits are fine there.
- Keep run scripts and logs under the lane's `sim/work/`.
- Never leave a mutant applied to a tracked file: apply mutants in scratch worktrees.

**Make long batches resumable.** The R1 reference runs used a worker script that:
- skips a run whose report exists;
- claims each run with a `mkdir` lock, so two workers can share the list.

After a restart, delete the claims (no worker is alive) and start the workers again.

**After a restart:**
1. Find orphaned processes by PID and decide, per process, whether its result is still wanted.
2. Restart dockerd.
3. Check disk space.
4. Read the dead workflow's journal: it records every finished agent's result.

**Resuming a workflow.** Resuming replays only agents whose prompt is byte-identical to the first run. A prompt that embeds an earlier agent's result does not stay identical: the replayed result re-serialises differently, the cache key changes, and that agent runs again from the start. That re-ran two finished reviews once.

Instead, write a short continuation script:
- Pass the finished results in, read from the journal.
- Start only the agents that were cut off.
- Give each a preamble saying what survived: the branch commits, uncommitted changes, logs and running processes.
- Tell it to reconstruct what is done and verified before it continues.

## 3. Simulation slots and the Quartus lock

**The owner's rule (2026-10-09):** at most three simulations while no Quartus job runs, and two while one does (`docs/daria_step7/plan.md` 4.2). Quartus runs one job at a time, under the lock of ENVIRONMENT.md 3.5.

**The slot helper.** The step-7 runs used a small helper outside the repository that gives each call one slot:
- Slot A is always available. Slot C, the orchestrating session's own simulation slot, is lent to lanes while that session runs none; like A, it does not depend on Quartus.
- Slot B is used only while Quartus is idle. A job in slot B is stopped with `SIGSTOP` on its process group while a Quartus job runs, and continued afterwards.
- So three simulations run while no Quartus job runs (A, B, C), and two while one does (A, C).
- A job counts as Quartus while it holds the lock or a container runs.

The helper must wait on slot A with a blocking `flock` (in short timeouts), not poll it with `flock -n`. Otherwise callers that use a plain blocking `flock` on the same file starve it: one caller waited over three hours.

**Replacing the helper.** Replace it atomically (write a new file, then `mv`). Callers already waiting keep running the old file, so a new slot only serves calls made after the change.

**Jobs that need two simulations.** A gate that runs two simulations at once (`sim/bupchip/s4/check.sh` with `JOBS=2`; its default is 3) was wrapped by its agent in scripts that took two slots:
- One version needed both slots free within seconds of each other. It was still waiting after more than 13 hours.
- The other two held slot A idle while they waited for B, including the version written to fix that.

Run such a job one simulation at a time inside a single slot call (for this gate, `S4_JOBS=1`).

**Expect queues.** On 2026-10-11 slot A had about eight waiters and one job waited 7.5 hours; it was queued before slot C existed, so it could never use C. The nine-fit ladder stopped slot B for about 3.5 hours. When the queue is that long, start fewer simulation batches, or let a lane finish before starting the next.

## 4. Disk

**How it fills.** Lane worktrees each build their own Verilator object directories (`obj_*`, 50-170 MB each) and keep fit run directories. During step 7 free space fell from 5.8 GB to 1.8 GB in a day.

**Housekeeping:**
- Check `df -h /` before every build, run or fit, and start none below 2 GB.
- Delete object directories when a run is done; they rebuild in seconds to minutes.
- Delete Quartus databases after their checks; keep the reports and `.rbf`.
- Never copy game images into a worktree's tracked paths. Read them from the main checkout's `sim/work` by path.

## 5. Things subagents got wrong, and the prompt line that prevents them

| Seen | Prevented by |
|---|---|
| A benchmark agent cloned an external repository into the main checkout's root. | "Never create files or clones inside the main checkout"; check `git status` before stopping. |
| Agents wrapped a two-simulation gate in their own scripts that held two slots; it starved for hours or held a slot idle. | "Run one simulation per slot; a job that runs two at once runs them one at a time." |
| A cleanup deleted a still-running agent's scratch worktree. | Before deleting a directory, check that no process uses it (`lsof +D`) and no workflow is active. |
| A first explanation of a timing change blamed the wrong path. | An independent skeptic agent re-checks every conclusion against the data; here it found the error. |
| A cost attribution double-counted 72 calls at a snapshot boundary. | An independent recount with its own parser. |
| Line references in a plan pointed at assignments, not declarations. | The reviewer brief asks for declarations and exact names as synthesis will see them. |
