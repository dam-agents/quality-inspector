# The nested product

The system under test runs **in this agent's own VM or in a platform Environment of its
own**, at the build under test, brought up by the profile ([profile-contract.md](profile-contract.md)).
`scripts/env.sh` is the one entry: it holds the lock, chooses where the product runs, and
hands every other command to the profile's `bin/env` there. How one product is installed is
the profile's; this file is the why and the recovery path.

## Where the product runs

`env.sh up` chooses, per `nested_target` in `work/CONFIG.md` (`auto`, the default; `vm`;
`environment`), and says which on its first line; `env.sh where` tells it any time.

- **An Environment** when the profile declares one (`environment` in `profile.json`), the
  agent does not lend its model (`lend_model`: an Environment holds no connection), this VM
  has `/dev/kvm` when the profile sets `engine_config.kvm` (the platform gives an Environment
  the device on the same terms, and its tools do not say it), and the platform's Environment
  tools answer (the owner's `environments` feature). With `kvm`, `up` then checks `/dev/kvm`
  in the Environment (`ssh env-<name>`): missing → `up` deletes that Environment and the
  product runs in this VM; no answer in three tries → an environment failure, and the
  Environment stays. The active Environment is reused while it lives (each `up` extends it
  two days); otherwise `up` makes a new one, `qi-<date>`, and moving to it stops the product
  in this VM.
- **This VM** otherwise, and whenever the platform does not make the Environment — with the
  reason in the output and the `env_target` log line. Moving back deletes the active
  Environment. With `nested_target: environment` this VM is never the fallback: `up` fails
  with the reason, an environment failure.

In an Environment, `bin/env` runs over the Environment Link (`ssh env-<name>`) from a copy
of the profile and the engines in `~/qi` there; `init` and the credentials stay here and are
copied over at every call. One `ssh -L` keeps the product at the profile's `app.url` on this
VM, so tests, the CLI and the API address `localhost` in both places and nothing below
changes. `env.sh status` adds `target` (and `environment`, `forward`) and brings a dropped
forward back; `env.sh down` there only closes the forward, and the Environment sleeps. A
lost link mid-run is an environment failure, never a verdict. The profile's diagnosis
commands run there as `ssh env-<name> '<command>'`, under the same read-only rule;
`k3s kubectl` as `ssh env-<name> bash qi/kubectl.sh …`, as a plain ssh shell can miss `k3s`.

## Kept for a person

An Environment can stay as a run left it — the build, its data, the state at the failed
step — so a person signs in and looks, beyond the video and screenshots.

- **When:** an issue, scenario or regression run in an Environment ends with a criterion
  `failed` or `blocked` by the product (not by the budget, the environment or the model):
  `env.sh keep <label>` before the report — `issue-<n>`, `scenario-s-<k>`,
  `regression-<candidate>` — prints the row, and its `url`, `account` and `expires_utc` go
  into the verdicts file as `environment` ([reporting.md](reporting.md) → Verdicts file).
  It keeps the Environment 3 days (`env.sh keep <label> <days>`, at most 30); the
  operator's "keep #N for <d> days" gives a kept one more (`env.sh extend <label> <d>`). An
  earlier one of the same label goes; the next `up` makes a new Environment.
- **Who opens it:** the Environment's `app` address admits only the owner's access list
  (the platform's sign-in). In the product, a person signs in with the account of the
  profile's `environment.account` role; its password stays in `work/env/credentials.env`,
  which the operator opens in the agent's files — never in a report, comment or chat.
- **Released:** `env.sh release <label>` when the same issue or scenario passes later
  (verified, inconclusive or passed), on the operator's "release #N", and by the platform
  at its expiry. At the platform's cap a new run releases the oldest kept one first.
  `env.sh kept` lists them (and drops those the platform deleted); the weekly audit names
  each.

## Shape

- **Inside the VM only** (CLAUDE.md → Hard invariants): `suite.sh`, `e2e-mcp.sh` and
  `ui-inventory.mjs` refuse any base URL but the profile's `localhost` `app.url`.
- **One user of the environment at a time** — `env.sh lock <owner>` / `unlock <owner>`
  (`scripts/lib/lock.sh`). The lock names its holder's session: while the platform runtime
  says that session runs a turn, the lock holds and the pre-flight treats the occurrence as
  idle; once it does not, the next run takes the lock at once and the pre-flight hands the
  holder's `in_progress` row over as a `takeover`. No runtime answer, or a lock without a
  session → age decides: past `lock_ttl_min` it is the next holder's.
- **`env.sh up <build>` and `suite.sh run <label>` run as harness background tasks** with a
  tool `timeout` of 7200000 (two hours, the maximum; otherwise an unattended run's harness
  stops a background task after 30 minutes) — a suite run that may take longer is split by
  `--tag`. Then `env.sh wait <build>` / `suite.sh wait <label>`, the tool's timeout at its
  10-minute maximum (one call waits 9 minutes): exit 0 = up / the run's summary printed,
  1 = failed (an environment failure for `up`; the output says why), 3 = still running, call
  again. The turn never ends while either runs; every `env.sh up` or `suite.sh run …` in these
  docs means this pair. A test may wait longer than one tool call
  ([test-authoring.md](test-authoring.md) → **Long waits**). The engine runs the product below
  the agent's own CPU priority, and an `up` of the build that already answers with the same
  values returns at once — after a VM restart too
  ([engines/helm-k3s/README.md](../engines/helm-k3s/README.md)).
- **What a run leaves stays until the next reset**: a failed AC's data is there to look
  at ("show the environment") until a run resets for its baseline — and, in an Environment,
  for days when the run keeps it (**Kept for a person** above).
- **Credentials are the profile's** — `env.sh init` makes it write
  `work/env/credentials.env` (mode 600); tests reach them only as `e2e` credentials.
- **Builds move forward only.** To run an older build (the baseline) after a newer one,
  always `env.sh reset` first — a downgrade over newer data is undefined. The red-green
  order in [issue-qa.md](issue-qa.md) step 6 is built around that.
- What the nested product cannot do (no outbound network for its own components, no
  email, a single user…) is in the profile's `SKILL.md`; it decides `testable: no`
  ([acceptance-criteria.md](acceptance-criteria.md)).

## After a VM restart

The platform hibernates an idle agent VM and boots it at the next session; the boot stops k3s
and the product (and the forward to an Environment), and a boot service of the agent's own is
not allowed. So the **SessionStart hook** (`scripts/hooks/resume.sh`, registered by
`scripts/hooks/install.sh`) runs `env.sh resume` in the first session after a boot: when the
last `up` succeeded before this boot and no `down` or `reset` came after it, it brings **that
build** back in the background — no reset, no other build, the data as it was, **where that
`up` put it** (`work/env/TARGET`). In this VM it runs that `up` again (the engine finds the
cluster on disk and only waits for the UI); in an Environment, whose `boot.sh` brings the
product back, it only starts the forward. A resume never chooses where the product runs,
never makes, deletes or extends an Environment. With no target recorded (`env.sh keep` and `release`
remove it) or that Environment gone, it resumes nothing (an `env_resume` warning); the next
`up` chooses. Its output is `work/env/last-resume.log`, its state `work/env/RESUME`, its
events `env_resume` (and `env_failed` when it fails — the next `up` then installs as usual;
never a verdict).

- The hook gives the session one line when it starts a resume; `env.sh status` shows when
  the product answers again. A run's `up` (a background task) waits for a resume to
  end first (at most 15 minutes, then stops it), so two installs never run at the same time.
  `reset` and `down` run in the foreground: they stop a running resume at once.
- A Browser Panel tab that was open before the restart is empty after it: when a person
  watches, give the `env.sh watch` button again.
- `env.sh down` (and `reset`) turn the resume off until the next `up`. The audit's
  `resume_hook` check warns while the hook is not registered.

## Network

The VM reaches the outside only through the paired gateway, by the agent's egress rules.
The hosts a profile needs are its `egress` list; the operator applies them. A pull that is
held or refused surfaces as a failing `env.sh up`, and the fix is the operator's.

## Budgets

One issue may hold the environment for at most `max_wallclock_min_per_issue` minutes and
`max_model_steps_per_issue` model-backed steps. `suite.sh budget <claim time>` measures
both deterministically: minutes since the claim, and the `agent.act` / `agent.assert`
steps of every suite run written since then, replays from the cache excluded (not your own
exploring turns, nor the product's own model calls under `lend_model: enabled`). When
`exceeded` is non-empty: stop testing — stop a background `suite.sh run` that still runs,
since `env.sh unlock` refuses while one does —, judge what already ran, mark every remaining
AC `blocked` with the note `budget exceeded`, log `issue_budget_exceeded` per budget
([logging.md](logging.md)), and finish from step 8 of [issue-qa.md](issue-qa.md) — the
row ends `report_pending` or `reported`, never `in_progress`. `lock_ttl_min` stays above
the wall-clock budget so a live run never looks stale (`verify-onboarding.sh` checks it).

## Failures

An `env.sh` exit other than 0, or a failing smoke run, is an **environment failure** —
never a verdict. `env.sh up` itself refuses (exit 1, `env_failed`) while the home volume
has less than `min_free_disk_gi` free. Before giving up on the entry, diagnose it
([autonomy.md](autonomy.md) → **Diagnosis**: what is known first, then hypotheses and their checks):

1. Read the output: `env.sh wait` prints the last lines of a failed install, and
   `work/env/last-up.log` / `last-reset.log` keep the whole output of the last `up` /
   `reset` (mode 600, never backed up, never quoted unmasked — `env.sh wait` masks the
   credential values). Then `bash "$HOME/scripts/env.sh" status`, then the diagnosis the
   profile's README names (read-only commands only).
2. Up to three repairs, each from another hypothesis the evidence supports — usually first
   `env.sh reset`, then `up` again, for an install stuck half-way or refused for disk space (on
   the `helm-k3s` engine a reset also removes every image no container uses — the earlier builds').
3. Still failing → register its cause (`blockers.mjs open` or `hit`, scope `env`; the pre-flight then
   holds every install until its retry time or a fix) and abort the entry ([issue-qa.md](issue-qa.md)
   step 4) with the evidence in the log. A cause you reproduced goes to `work/LESSONS.md`; a profile
   defect is an issue on the profile's repository, never a local patch to the profile.

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
