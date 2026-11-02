# Working on its own — blockers, diagnosis, telling the operator, initiative

Read when a run meets a failure it cannot pass (an install, a delivery, a test that stops before its
block), when the worklist carries `blockers` with anything in it or an `error`, and before the summary
of every run that tested something.

You are the product's tester and the operator's partner, not a job runner. A run ends when every
problem it met is repaired, or registered with its owner and the one action that repairs it — never
with the same failure handed unexplained to the next run. What never moves: the black box
([black-box.md](black-box.md)), the trust boundary and the invariants (CLAUDE.md,
[self-modification.md](self-modification.md) §10), the budgets ([nested-env.md](nested-env.md) → **Budgets**).

## The register — `work/BLOCKERS.md`

One row per **cause** that stops work, written only through `scripts/blockers.mjs` (its header holds the
contract); what you found about it in `work/blockers/B-<k>.md`, written by you.

| scope | When | What it holds |
| --- | --- | --- |
| `env` | `env.sh up`, `reset` or `wait`, the smoke run or the canary still fails after **Diagnosis** | every mode that installs: the new tests and queued scenarios of the issues run, the regression, discovery, security and modules runs |
| `delivery` | the platform refuses a report's publication or its media (a served type, a refusal, an error) | `reports_due` and the scenarios' report retries |
| `tests` (one `--test` each) | a recurring test stops before its frozen block for a cause outside the product — a capability the install lacks, a surface no test drives, a sandbox account —, triage cannot rework it, and the next build would stop it the same way | its nightly replay and its adoption retries |
| `preflight` (stage: the mode) | a mode's pre-flight cannot build its worklist (`error`: a listing GitHub refused, a build the profile cannot name, a scan that broke) — **written by `scripts/preflight.sh` itself**, never by you; one row per mode, each failing occurrence a hit, the newest error its signature | nothing: the pre-flight tries at every occurrence, and resolves the row once that mode's worklist builds again |

- **Owner** — whose action repairs it: `agent` (**Repair what is yours** below), `operator` (a setting,
  egress, disk, an account, the model), `profile` (its values, scripts or `SKILL.md`), `product` (a defect
  of the build), `platform` (the VM, the gateway, the artifact service), `unknown` (the diagnosis is open).
  `hit --owner` corrects it when the diagnosis learns more.
- **Signature** — the line that names the cause ("helm: virtualization.runner.resources.limits.memory
  is required"), never a symptom many causes share ("context deadline exceeded" alone).
- **The same cause is a `hit`**: read `blockers` in the worklist (or `blockers.mjs list --open`) before
  you `open`; a failure with an open row's cause is `hit B-<k>`, in other words too.
- **`resolve B-<k>`** once the stage it stopped passes again: the install and smoke run for `env`, the
  publication for `delivery`, the frozen block reached for `tests`. A row released for a retry that fails
  again is a `hit`, never a new row.
- `told` after its notice (**Telling the operator**); `retry` and `close` are the operator's words
  ([on-demand.md](on-demand.md)).

**Hold and release.** The pre-flight holds a standing row's scope — `issues_waiting[].reason`,
`held_tests[]`, a `skip=held` line in the mode's log — until its retry time (2^(hits−1) hours after the
last hit, a day at most, a week for `profile`) or until the kit, `work/CONFIG.md`, the profile or
`work/env/credentials.env` changes. A released row arrives in `blockers.released[]` with its reason: this
run is its retry. With `env` held, a takeover ends its row as an abort, with no install. A `preflight`
row is never held or released: it is the pre-flight's own.

**A pre-flight error.** The worklist carries `error` and `blockers`: the error is the mode's `preflight`
row. One failed occurrence wakes no one — the Precheck declines it, the row and the mode's log
(`work/<RUNTYPE>.log`, its `ERROR:` line) keep it. The second in a row makes the `opened` notice due, and
that wakes the run: give it (**Telling the operator**), with the owner the evidence names — read-only:
the mode's log, `work/LESSONS.md`, `bash "$HOME/scripts/verify-onboarding.sh" --config` for a
configuration cause; `hit B-<k> --owner <owner> --build none` when it is not `unknown` —, write its notes
file, then end the run: nothing of the mode runs without its worklist. A worklist with `error` and no
`blockers` (the register did not take it) is the old contract: log the error in one line and end.

## Diagnosis — before you give up on a failure

1. **Known first.** `blockers` in the worklist, then `grep -i` of the error's key words in
   `work/LESSONS.md` and `work/blockers/*.md`. A known cause with a known repair: apply it. One without:
   `hit` it and go to step 6.
2. **Read the evidence** ([nested-env.md](nested-env.md) → **Failures** step 1): the failed stage's
   output, `env.sh status`, the profile's diagnosis commands — read-only.
3. **Hypotheses, not a story.** Name two or more causes the evidence allows and, for each, the cheapest
   check that tells them apart — a file, a process, a port, a log line, the timing. Run it; write what it
   showed in the notes. A hypothesis that two hits did not confirm is dropped: the third hit needs a new
   one, or the owner becomes `unknown` and the notice says what you ruled out.
4. **Repair what is yours** — at most three attempts per failure, each from a different hypothesis the
   evidence supports:
   - `env.sh reset`, then `up`: a stale helm operation, an install stuck half-way, disk held by old images;
   - a repair that `work/LESSONS.md` or the profile's README names for this signature (a runtime
     directory, a service restart) — the command it names, never a new one on the product;
   - a test's steps, by the heal and rework rules of [triage.md](triage.md) alone;
   - your own state: a cache, a stale port in a file of `work/`, a lock past its TTL.

   Never the product, the profile's files, the platform, the configuration, or a frozen block
   ([nested-env.md](nested-env.md) → **Failures**; [triage.md](triage.md) → **What never happens**).
5. **What you proved** goes to `work/LESSONS.md`, one dated line with its evidence; a defect of the
   profile or the engine also as an issue draft for its repository in the chat summary, never a local
   patch ([self-modification.md](self-modification.md) §5a).
6. **Register**: `open` or `hit`, with the owner the evidence supports, then write
   `work/blockers/B-<k>.md` — the signature, up to 30 lines of evidence (credential values masked),
   each hypothesis with its check and result, each repair and what it did, the owner's one action.
7. Then the procedure's own failure path — [issue-qa.md](issue-qa.md) step 4,
   [regression.md](regression.md) step 2, [reporting.md](reporting.md) → **Delivery**: an environment
   failure never becomes a verdict.

## Telling the operator

`blockers.notices[]` in the worklist: `opened` — a cause that is not yours, or one of yours that struck
twice, or a `preflight` row that struck twice in a row; `resolved` — a cause the operator was told of
that works again (the next issues run carries the one of a `preflight` row). Each notice once:

- **First in the run's chat summary**, always.
- With `blocker_alerts: enabled` (default `disabled`), also one `send_channel_message` to
  `regression_channel`, else `slack_channel`; ledgered as surface `slack` with key
  `blocker@B-<k>:<kind>` ([logging.md](logging.md) → **Ledger of external writes**). A refused post is
  logged and never retried.
- Then `blockers.mjs told B-<k>`.

In ASD-STE100 ([reporting.md](reporting.md) → **Artifact text is ASD-STE100**), never a credential:

```
🟠 B-3 blocks <scope: what it stops> since <date> · owner: <owner>
Cause: <the signature>. <one sentence: why, as the evidence shows it>
Tried: <each repair and what it did>
Needed: <the one action, and who does it>
Until then: the agent holds <scope> and tries again at <retry_utc>, or at once after a change of the <kit|configuration|profile|credentials>.
```

`✅ B-3 is resolved: <scope> works again on <build> (<hits> hits since <date>).` The nightly summary
names the open rows (id, owner, days open) after its own results; the weekly audit warns about a row
open over 7 days and a notice not given ([audit.md](audit.md)).

## Initiative — what each run leaves for the next one

Before the summary of a run that tested something, inside its own budget — never a new run, schedule
or external write:

- **Severity on every problem** of the analysis ([reporting.md](reporting.md) → **The agent's
  analysis**), most severe first.
- **Leads.** Each `noticed` item and each `major` observation is a lead the next discovery run takes as
  its basis ([scenarios.md](scenarios.md) → **Discovery**) — so what you saw in passing is chased, not dropped.
- **Defects proposed, never filed.** A product defect the evidence confirms — a `failed` AC with
  `cause: product` and `certainty: high`, a confirmed `regression`, a `major` observation that
  reproduced — gets its severity and the operator's words that file it ("create issue for #42 AC-2",
  [skills/create-issue](../skills/create-issue/SKILL.md)) in the chat summary. Filing stays the operator's.
- **The suite grows.** Name each `promotable` file with its words ("promote #N"); a recurring test that
  fails for its own sake (`cause: test`) is a proposal ([maintenance.md](maintenance.md)), never a silent skip.
- **The next question.** One line: the most useful check this run did not make, and why — the budget,
  the environment, a role the profile does not give. The operator, or the next discovery run, takes it.

## Self-check

- Every failure that stopped work is repaired, or a row of its cause with its notes file; every row in
  `blockers.released[]` is resolved or hit again; no second open row for a cause one already holds; no
  `preflight` row opened, hit or resolved by you but for an owner's correction.
- Every notice due was given and `told`; no row owned by `agent` struck twice without one.
- Every problem of the analysis has its `severity`; every confirmed product defect is proposed with its words.
