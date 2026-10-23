# The nested product

The system under test runs **inside this agent's own VM**, at the build under test, brought
up by the profile ([profile-contract.md](profile-contract.md)). `scripts/env.sh` is the one
entry: it holds the lock and hands every other command to the profile's `bin/env`. This
file is the why and the recovery path; how one product is installed is the profile's.

## Shape

- **Inside the VM only.** The product answers at the profile's `app.url` on `localhost`;
  `suite.sh`, `e2e-mcp.sh` and `ui-inventory.mjs` refuse any other base URL, and no
  procedure ever drives the platform this agent itself runs on.
- **One user of the environment at a time** — `env.sh lock <owner>` / `unlock <owner>`
  (`scripts/lib/lock.sh`). The lock names its holder's session: while the platform runtime
  says that session runs a turn, the lock holds and the pre-flight treats the occurrence as
  idle; once it does not, the next run takes the lock at once and the pre-flight hands the
  holder's `in_progress` row over as a `takeover`. No runtime answer, or a lock without a
  session → age decides: past `lock_ttl_min` it is the next holder's.
- **Every `env.sh up <build>` runs as a harness background task**, then `env.sh wait <build>`
  — with the tool's timeout at its 10-minute maximum, so one call waits 9 minutes — until it
  exits 0 (up) or 1 (failed, an environment failure); 3 = still installing, call it again. The turn
  never ends while an install runs. The engine runs the product below the agent's own CPU
  priority, and an `up` of the build that already answers with the same values returns at
  once — after a VM restart too ([engines/helm-k3s/README.md](../engines/helm-k3s/README.md)).
- **Every `suite.sh run <label>` runs as a harness background task too** (its two-hour
  `timeout` below), then
  `suite.sh wait <label>` the same way: exit 0 prints the run's summary, 3 = still running,
  1 = it failed (its output says why). A test may wait longer than one tool call
  ([test-authoring.md](test-authoring.md) → **Long waits**); every `suite.sh run …` in
  these docs means this pair.
- **Both background tasks pass the tool a `timeout` of 7200000 (two hours)**: in an
  unattended run (a scheduled one) the harness stops a background task after 30 minutes
  otherwise, and two hours is its maximum. A suite run that may take longer is split by
  `--tag` into several runs.
- **What a run leaves stays until the next reset**: a failed AC's data is there to look
  at ("show the environment") until a run resets for its baseline.
- **Credentials are the profile's** — `env.sh init` makes it write
  `work/env/credentials.env` (mode 600). Tests reach them only as `e2e` credentials.
- **Builds move forward only.** To run an older build (the baseline) after a newer one,
  always `env.sh reset` first — a downgrade over newer data is undefined. The red-green
  order in [issue-qa.md](issue-qa.md) step 6 is built around that.
- What the nested product cannot do (no outbound network for its own components, no
  email, a single user…) is in the profile's `SKILL.md`; it decides `testable: no`
  ([acceptance-criteria.md](acceptance-criteria.md)).

## Network

The VM reaches the outside only through the paired gateway, by the agent's egress rules.
The hosts a profile needs are its `egress` list; the operator applies them. A pull that is
held or refused surfaces as a failing `env.sh up`, and the fix is the operator's.

## Budgets

One issue may hold the environment for at most `max_wallclock_min_per_issue` minutes and
`max_model_steps_per_issue` model-backed steps. `suite.sh budget <claim time>` measures
both deterministically: minutes since the claim, and the `agent.act` / `agent.assert`
steps of every suite run written since then, replays from the cache excluded — the only
cost proxy a script can count (your own exploring turns are not in it, nor the product's
own model calls under `lend_model: enabled`). When `exceeded`
is non-empty: stop testing — stop a background `suite.sh run` that still runs (its harness
task), since `env.sh unlock` refuses while one does —, judge what already ran, mark every remaining AC `blocked` with
the note `budget exceeded`, log `issue_budget_exceeded` per budget
([logging.md](logging.md)), and finish from step 8 of [issue-qa.md](issue-qa.md) — the
row ends `report_pending` or `reported`, never `in_progress`. `lock_ttl_min` stays above
the wall-clock budget so a live run never looks stale (`verify-onboarding.sh` checks it).

## Failures

An `env.sh` exit other than 0, or a failing smoke run, is an **environment failure** —
never a verdict. `env.sh up` itself refuses (exit 1, `env_failed`) while the home volume
has less than `min_free_disk_gi` free. Before giving up on the entry:

1. `bash "$HOME/scripts/env.sh" status`, then the diagnosis the profile's README names
   (read-only commands only).
2. One repair attempt the evidence supports — usually `env.sh reset`, then `up` again,
   for an install stuck half-way or refused for disk space (on the `helm-k3s` engine a
   reset also removes every image no container uses — the earlier builds').
3. Still failing → abort the entry ([issue-qa.md](issue-qa.md) step 4) with the evidence
   in the log. A cause you reproduced goes to `work/LESSONS.md`; a profile defect is an
   issue on the profile's repository, never a local patch to the profile.

**The injection canary** (`tests/canary.e2e.ts`, tagged `smoke`) puts an injection on a
page and expects the judge to reject an assertion about absent text. Its failure, `judge
swayed by page content`, is an environment failure of the **model**, not the product: no
judged result of that run counts, `env.sh reset` does not fix it, and it goes to the
operator (the `e2e_model`, or the `system`/`context` of `work/suite/e2e.config.ts`). It creates what the
profile's `canary` names ([profile-contract.md](profile-contract.md)), exactly one object, and
deletes every object whose name starts with `qa-canary-` afterwards. A skipped canary (the
profile's `canary.none`, or nothing to create with a name and a free-text field) is not a
failure; its reason stays in the run's report.

Never "fix" the product inside the environment (its files, its database, its
configuration beyond what the profile sets) to make a test pass — that tests your patch,
not the build.
