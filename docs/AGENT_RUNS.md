# Long agent runs on this project: cost and robustness

Lessons from running multi-agent work on DARIA step 7 (2026-10-09 to 10-11): an orchestrating session that starts workflows of subagents, each running builds, simulations and Quartus fits for hours. Read this before starting long agent work here. The machine and tool setup is in [ENVIRONMENT.md](ENVIRONMENT.md).

## 1. The prompt cache: never more than 4 minutes between a subagent's calls

**The two lifetimes.** The orchestrating session's prompt cache lasts 1 hour. Workflow subagents get a 5-minute cache. This was measured from the session's transcripts on 2026-10-10:
- every one of the orchestrating session's 21M cache-write tokens was a 1-hour write;
- every one of the subagents' 355M was a 5-minute write.

**Why it matters.** Writing a context into the cache costs 25 times as much as reading it back. Each new call either reads the agent's whole context from the cache or, if the cache has expired, writes it again. A subagent deep in a lane holds about 400k tokens of context, so letting its cache expire costs about 25 cache reads.

**What went wrong.** Agents that waited on a simulation or a fit used to check every 10 minutes. Each check found the cache expired and rewrote the whole context. Over the session to 2026-10-10 that was 37% of all spend: a median of 419k tokens rewritten per check.

**Measured on the self-hosted VM (2026-10-20).** The same two lifetimes hold there:
- the orchestrating session wrote only 1-hour cache entries (509,602 tokens, none at 5 minutes); every call after a gap under an hour read its context from the cache (7 of 7, four of them after 10-60 minutes), and both calls after a gap of more than an hour rewrote it;
- the workflow subagents wrote only 5-minute entries (1.97M tokens, none at 1 hour);
- one probe agent with a fixed context of about 32k tokens waited a set time between calls:

| Gap before the call | Read from the cache | Written to the cache | |
|---|---|---|---|
| 213 s | 31,475 | 181 | hit |
| 272 s | 31,656 | 181 | hit |
| 333 s | 0 | 32,018 | whole context rewritten |
| 424 s | 0 | 32,199 | whole context rewritten |

So a subagent's cache lasts 5 minutes, and the 4-minute rule leaves about a minute for the call itself.

**The rule:**
- While a subagent waits for a long job, it never lets more than 4 minutes pass between its own calls. "At most every 4 minutes" has been read as "no more often than every 4 minutes"; it means the opposite.
- It waits in bounded steps, for example `timeout 230 bash -c 'until <done-test>; do sleep 20; done'`, then checks, then waits again.
- No single tool call may run longer than about 4 minutes: no command timeout above 240 s, and anything longer runs detached (`setsid nohup ... &`) with the bounded waits above. On 2026-10-20 two agents waited with 10-minute calls; they were stopped and restarted with this wording. A plain foreground `sleep N` is refused by the agent's shell; wait on a condition, as above.
- Two 4-minute waits cost about one twenty-fifth of one 10-minute wait.
- When a wait is measured in hours, it is cheaper to end the subagent and let the orchestrating session (1-hour cache) do the waiting, then start a fresh agent for the next step. The agent returns what it waits on: each detached job, its log and an exact done-test.

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

**On the self-hosted VM** ([ENVIRONMENT.md](ENVIRONMENT.md) 11), this section mostly does not apply. The VM stays on: it does not stop when a session goes idle, and it has no 13-hour limit. So skip the precautions below that exist only for restarts: splitting runs into one-hour pieces, `WIP` snapshot commits, resumable worker scripts and progress files. Keep a short NOTES.md per lane. "Resuming a workflow" still applies when a workflow is stopped on purpose. The rest of this section records the cloud container (2026-10-09 to 10-16).

**How often.** Six restarts hit in about 65 hours (2026-10-09 to 10-12): one of the container, five of the session only. On 2026-10-13 and 14 the machine came up fresh at 23:01, 02:40, 04:40, 20:39 and 23:48 UTC.

**Why the machine stops.** Found on 2026-10-14 from the times of the campaign's last file writes, and added to since:
- The machine runs only while the session runs. A session ends about five minutes after it goes idle: no turn running, no tool call in progress, no agent working. Detached processes and background shell jobs do not count. On 10-14 the campaign's last writes were at 19:35:21 and 20:51:27 UTC, the moments the session ended, the second time four minutes after its last turn. Nothing ran again until the next session start (20:39 and 23:48, each a scheduled check-in). The "reboot" at 23:01 on 10-13 was the same: the session had been idle since 13:49.
- A session that is working also ends after about 13 hours (seen six times from 10-10 to 10-14). Each time the next one started within seconds; at 17:36 on 10-14 the machine stayed up through it.
- Five working sessions ended early, with an agent working: at 02:40 (after 3.7 hours) and 04:40 (after 2.0 hours) on 10-14, 18:50 and 22:39 on 10-15, and 02:40 on 10-16 (UTC), each 2-6 hours after the session started. The machine restarted with them. No cause was found.
- So keep one agent working for as long as detached runs must go on: a watcher that waits about 4 minutes per call (section 1's rule) and returns when something changes. Keep a scheduled check-in as well, to restart the runs after a stop.

**Split long runs.** A stop kills every job running at the time, whatever its checkpoints: a three-hour regression never finished in one piece.
- Split long runs into pieces of at most about an hour. Each piece writes its own results, and a rerun skips finished pieces. `wire.py run` takes scenario names, `s4/check.sh` takes `ONLY=`, and frame and mode-B runs go per image.
- Keep `progress.txt` current after every piece, so a successor agent resumes from it.
- dockerd can then fail with "containerd is still running", from a stale `/var/run/docker/containerd/containerd.pid`; delete it and start dockerd again (ENVIRONMENT.md). A session restart kills the agents but not the processes they started. A machine restart kills the processes as well, and dockerd with them (ENVIRONMENT.md 3.3, 8.1).

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

**The owner's rule:** on the self-hosted VM (2026-10-19), at most four simulations while no Quartus job runs, and three while one does. In the container (2026-10-09) it was three and two (`docs/daria_step7/plan.md` 4.2); the container-era helper below was built for that rule. Quartus runs one job at a time, under the lock of ENVIRONMENT.md 3.5.

**The container-era slot helper (2026-10).** The step-7 runs in the container used a small helper outside the repository that gives each call one slot. It is not the VM's helper (below):
- Slot A is always available. Slot C, the orchestrating session's own simulation slot, is lent to lanes while that session runs none; like A, it does not depend on Quartus.
- Slot B is used only while Quartus is idle. A job in slot B is stopped with `SIGSTOP` on its process group while a Quartus job runs, and continued afterwards.
- So three simulations run while no Quartus job runs (A, B, C), and two while one does (A, C).
- A job counts as Quartus while it holds the lock or a container runs.

That helper had to wait on slot A with a blocking `flock` (in short timeouts), not poll it with `flock -n`. Otherwise callers that used a plain blocking `flock` on the same file starved it: one caller waited over three hours.

**The VM's slot helper** (`~/daria_work/bin/simslot CMD...`, outside the repository) has three slots, the lock files `slot1` to `slot3` in its directory (`daria_simslots` in the temporary directory), and no Quartus awareness: three simulations fit both of the owner's limits. Callers take FIFO tickets (below). The oldest live ticket polls the slots with `flock -n` every second, and CMD holds the slot's lock until it exits. A plain blocking `flock` on one of its slot files bypasses the queue, and the helper's `flock -n` polls cannot stop it. Never take those files with `flock`, and never set `SIM_LOCK` to one of them: run the command under `simslot` instead.

**First come, first served (2026-10-23).** The VM's helper (outside the repository) polled its three slots with `flock -n` every 5 s. A worker that finished a job and called again within milliseconds could take the slot it had just freed, ahead of callers that had waited for minutes (found in 2.2.4's campaign). In a dummy-job test (three workers re-entering after each 2 s job, a fourth caller arriving at 1 s with a 1 s job) the caller finished after 21 s [measured: the old helper]. The helper now hands slots out in ticket order: each caller takes a ticket, only the oldest live ticket may claim a free slot, and a re-entering worker joins the back of the queue. The same test: 3 s [measured: the new helper], with the 3-slot cap and the exit status unchanged.
A killed waiter's ticket is dropped by the next caller that looks, once its process is gone or is a zombie. The first queued version missed zombies: a waiter killed under a parent that does not reap it (a Python `Popen` with no `wait()`) held the head of the queue, and every caller behind it waited with no message (found in review, 2026-10-23). It also wrote the ticket counter in place, so a caller killed during the write could reset it and put new tickets ahead of old ones. Both are fixed: zombies (state Z or X) count as gone, and the counter is written to a temporary file and renamed. A stopped waiter (`SIGSTOP`) still counts as live: while it is the head, the queue waits until it is continued or killed.

**Replacing the helper.** Replace it atomically (write a new file, then `mv`). Never edit it in place: bash reads a script while it runs, so callers already waiting would read the edit half-way. Callers already waiting keep running the old file, so a change only serves calls made after it. The earlier versions are kept beside it: `simslot.bak` (polling, no queue) and `simslot.v2.bak` (the first queued version).

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
| 2.2.4: a frame job ran in a WORK that shared another directory's `obj_frames` but had no `rtl/` link. Verilator only warns "$readmem file not found", so the bench ran on zeroed palettes; the black pictures surfaced hours later as a video difference. | `sim/run_frames.sh` now refuses such a WORK (exit 2) and fails a run whose log has that warning for one of those tables (exit 1). The warning for `rtl/mem0.hex` is expected in every `BUILD_TOP=tb_frames` WORK and does not count. Build into the WORK, or link its `rtl/` as well as its binary. |
| 2.2.4: a done-test used `pgrep -f PATTERN`, which also matches the shell that launched the job, or the one running the test, when PATTERN is in its command line: a finished job looked alive. | Done-tests read the job's own log for its final `^rc ` line, never `pgrep -f`; to look at processes, use `ps` and leave out your own shell. |
| 2.2.4: `PP_GUARD_FROM` must name the merge that brought 2.2.2 into the release tree; `git log -S` without `--first-parent` names 2.2.2's own POKEY commit instead (a ÷19 tree, where `--qsf release` cannot start). | An anchor that is a merge is found with `--first-parent`, on a branch that has that merge on its first-parent line, and passed as the full hash ([daria_step10/plan.md](daria_step10/plan.md) 3.1 says where the expression goes wrong). |
| 2.2.4: an `exit` inside an `until` condition (`until <test> \|\| exit 1; do ...`) ended the whole shell, a worker or a wait, not the loop, with that status. | Put only the test in the condition; leave the loop with `break` and decide after it. |
