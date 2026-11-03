# quality-inspector

A black-box QA agent that tests **any product with a web UI**, running on the DAM agent
platform. For every issue of a target repository labelled `qa:ready`, it turns the
issue's **Done when** section into frozen acceptance criteria, brings the newest build of
the product up **inside its own VM**, tests the criteria **through the UI** with
[e2e](https://github.com/tester-army/e2e) (Playwright with an LLM fallback and a replay
cache) and the image's built-in Chromium, confirms each result red-green against the last
release, and publishes a per-criterion verdict with video evidence. It never reads the
product's source code.

Everything product-specific — how to run it, which builds exist, how to sign in, what is
off limits, what a tester should know — comes from a **product profile**, a skill installed
at onboarding ([docs/profile-contract.md](docs/profile-contract.md)). Reusable
**engines** (`engines/`, e.g. [`helm-k3s`](engines/helm-k3s/README.md) for a Helm chart in
k3s) do the running, so a profile is mostly data. The DAM profile, `qi-profile-dam`, lives in
the DAM repository under `.quality-inspector/`. The agent uses the platform's own primitives:
schedules with Prechecks, the artifact library for evidence, the skill catalog for profiles,
sub-agents for independent review.

## How it works

Scripts only detect, and the profile only sets up the nested product; every judgment and every
external write is the agent's, per `docs/`. [`CLAUDE.md`](CLAUDE.md) is the small always-loaded
core (run types, schedules, invariants); the definition is versioned (`VERSION` + `CHANGELOG.md`).

- **Issues run** (hourly; the Precheck declines idle hours before any model wakes) — an issue is
  due when it is new, its text changed, or it carries `qa:retest`; the agent freezes the
  criteria, brings the product up, writes one e2e test per criterion, runs it on the last release
  and on the candidate, and reports ([docs/issue-qa.md](docs/issue-qa.md)).
- **Regression run** (nightly, off by default) — replays the promoted tests against each new
  candidate, mostly without model calls ([docs/regression.md](docs/regression.md)); see
  **When the UI changes** below.
- **Security run** (weekly, off by default) — frozen black-box checks of each new candidate;
  findings go to a private artifact only ([docs/security.md](docs/security.md)).
- **Scenarios** — in a connected Slack channel anyone can ask "test that …"; an independent judge
  sub-agent checks the scenario and the evidence, and the answer is a video report in the thread.
  A weekly discovery run (off by default) proposes scenarios of its own
  ([docs/scenarios.md](docs/scenarios.md), [docs/judge.md](docs/judge.md)).
- **Testing modules** (nightly, each off by default, switched from the dashboard) — UI sweep,
  form validation, bounded stress, design checks, real-user UX signals, a deep test of one area
  ([docs/modules.md](docs/modules.md)).
- **Audit** (weekly), **benchmark** (monthly), **Change radar** (every 3 hours) — all off by
  default ([docs/audit.md](docs/audit.md), [docs/benchmark.md](docs/benchmark.md),
  [docs/radar.md](docs/radar.md)).
- **From Slack** (off by default) — "test #N", "test feature …" or a scenario, answered in the
  thread ([docs/slack.md](docs/slack.md)). In the direct session the operator can watch
  exploration live (`live_browser`), and the nested product can call the agent's own model
  (`lend_model`).
- **On its own** — a failure is diagnosed and what is the agent's is repaired; the rest goes to a
  register of blockers with its owner and the one repair, the pre-flight holds that work with a
  growing back-off, and the operator is told once and sees it first on the dashboard. A pre-flight
  that cannot build its worklist (a GitHub listing refused) is a blocker of its own, told at the
  second failure in a row. Every problem carries a severity, and what a run saw in passing feeds the
  next discovery ([docs/autonomy.md](docs/autonomy.md)).

## Setup

This repository is its own **Starter Kit** ([`kit.yaml`](kit.yaml)):

1. **Find it under Starter kits** and open its setup page.
2. **Grant the GitHub connection** (required) — reads the target's issues and removes
   the retest label after a test; with issue comments enabled it also posts verdicts, and on the
   operator's word it opens issues about the problems it found, so the account needs issue write
   access on the target. Use a dedicated bot account, and where the connection allows it (a
   GitHub App installation, a fine-grained token) only Issues on the target — no Contents, Pull
   requests or Actions. The egress, not the token, keeps forks and mirrors out of reach. With a
   work backup (`work_repo`), add Contents read & write on that one private repository, and
   protect its `main` so only this account pushes (a private repository needs a paid GitHub
   plan for that; without it, the next persist logs and reverts a foreign commit).
3. **The agent runs on the vm backend**: the kit says so, and is hidden on an install
   without virtualization. It asks for 8 CPU, 12 Gi and 80 Gi; the profile's README says
   what its product needs.
4. **Assign the product profile**: add its skill source (Skills → Sources) and assign the
   profile skill to the agent — for DAM, repository `https://github.com/dam-agents/dam`
   with path `.quality-inspector`, skill `qi-profile-dam`. A profile lives under
   `.quality-inspector/` of its repository, the one directory the kit's egress opens.
   A product without a profile gets one from its team with the
   [`qi-profile-creator`](skills/qi-profile-creator/SKILL.md) skill.
5. **Give the agent a model connection** (Anthropic API key, OAuth token, or a proxy such
   as LiteLLM). *Inject only into addressed requests* stays on (the kit sets it).
6. **Answer the onboarding dialog** ([`ONBOARDING.md`](ONBOARDING.md)): it lists the egress
   rules left to the operator in words, the profile's throwaway **sandbox accounts** when it
   declares them, and ends in a smoke test of the nested product. Schedules are held until it
   completes.
7. *Optional:* **connect a Slack channel** to the agent for scenario requests.

Not in a catalog yet? Add one entry to the catalog repository's `catalog.yaml`:

```yaml
kits:
  - url: https://github.com/<your-org>/quality-inspector
```

### Without the catalog

Create a vm-backend agent by hand, grant the GitHub connection, then send it:

> Here is a file — read it and set yourself up according to it:
> `https://github.com/<your-org>/quality-inspector/blob/main/ONBOARDING.md`

## Black-box boundary

The agent must not be able to read the target's source and has **no GitHub access of its
own**. The kit's egress makes it true for every target, whatever the connection's token may
read (the gateway injects it; the VM holds a placeholder): GitHub is deny-by-default, and only
the issues endpoints, the `.quality-inspector/` profile directory, a repository's metadata and
the read-only fetch of this definition open; every other code host is denied. Inside the VM, a
`PreToolUse` policy hook and a `permissions.deny` list refuse any road to GitHub but
`scripts/github.sh`. Before each day's work the pre-flight's **black-box gate** probes every
forbidden surface and stops every run while one answers or a hook is gone. What stays the
operator's — the profile's `egress`, the `work_repo` backup, a GitHub Enterprise target — is
listed by `bash scripts/egress-rules.sh` as host, method, path and why. Approve no held request
on the deny side. Details: [docs/black-box.md](docs/black-box.md) (**Egress rules**,
**Enforcement layers**, **The gate**).

## What a report looks like

Every tested issue gets one evidence page in the artifact library (and, with comments
enabled, a short verdict table on the issue linking to it). Per criterion it shows the frozen
Given/When/Then, then the candidate and the last release side by side: a **video of the whole
test run**, screenshots captioned by step, the step list, the assertion error and the trace — so
a reader can watch the feature fail on the release and work on the candidate. An **intent test**
checks the issue's stated goal beside the verdict, never in it ([docs/intent.md](docs/intent.md)).
Media add a few MB per criterion ([docs/reporting.md](docs/reporting.md)).

**The test catalog** is one more artifact — the dashboard: every test with its history,
coverage map, every run and its report, a clickable product map and a Test builder. It holds
test-related content only, so the operator may share it ([docs/catalog.md](docs/catalog.md)).

## When the UI changes

Promoted tests replay nightly against each new build, and a redesign must not fail them. The
agent builds what changed — never from code: the issues completed between the two builds and a
diff of the **UI map** it crawls on each build ([docs/change-awareness.md](docs/change-awareness.md)).
Every acceptance check carries a fallback that judges the criterion's own sentence on screen. A
triage sorts each non-trivial result into *re-learned*, *repaired*, *superseded*, *needs review*
or **regression** — the default when the evidence is unclear ([docs/triage.md](docs/triage.md)).
What the agent may not absorb alone becomes a **maintenance proposal** for the operator
([docs/maintenance.md](docs/maintenance.md)); the Change radar opens `predicted` proposals from
pull request text before a build carries the change ([docs/radar.md](docs/radar.md)). Recurring
tests are grouped by **feature**, runnable by name ([docs/features.md](docs/features.md)).

## Configuration

`work/CONFIG.md`, written at onboarding. Every key, its default and its meaning:
[`CLAUDE.md`](CLAUDE.md) → **Runtime configuration**; which keys onboarding asks for, offers or
defaults: [`ONBOARDING.md`](ONBOARDING.md) → Step 3. The testing modules' keys live in
`scripts/lib/modules.json` ([docs/modules.md](docs/modules.md)).

## Runtime requirements

- **Platform:** a DAM agent (vm backend when the profile requires root; Node ≥ 24.8 and
  Playwright with its Chromium baked in the image), `$HOME` on a persistent volume, the
  gateway for credentials, `mcp__platform-outbound__*` for schedules and the artifact
  tools. Its egress gateway denies paths with dot segments and matches GitHub denies in
  any letter case (dam-agents/dam#4909) — without that, a profile inside the target
  repository opens the whole repository.
- **Identity:** the GitHub connection's account — a dedicated bot; read access to the
  target's issues, plus issues write (the retest label removal, and comments when enabled).
- **External surfaces:** artifacts in the platform's artifact library (private by
  default); removal of the retest label after a test; with `issue_comments: enabled`,
  **public comments** on the target's issues; on the operator's "create issue for …" only, **new issues**
  on the target about found problems ([`skills/create-issue`](skills/create-issue/SKILL.md));
  optionally Slack posts — request threads, `scenario_channel`'s weekly digest,
  `regression_channel`'s nightly summary and breach alert (and the blocker notices with
  `blocker_alerts: enabled`), `slack_channel`'s ordered tests,
  `design_desk_findings` to the Design Desk; with `work_repo`, pushes of the `work/` backup. The
  platform runtime's session state (`PLATFORM_RUNTIME_URL`) frees a dead run's environment lock
  at once; without it the lock waits `lock_ttl_min`.
- **Cost:** idle hours wake no model. One issue costs up to three installs of the product
  (time, no tokens) plus authoring — expect a few hundred thousand tokens for the first
  run of an issue (explorations, on by default, add roughly 30–60 %); replays of promoted
  tests are mostly free, except `agent.assert` checks, which always call the model. A
  scenario costs about what an issue does; discovery adds tens of thousands of tokens a
  week (`propose`), or that plus one scenario per proposal (`run`).
- **Persistence:** with `work_repo` set, `work/` (never credentials or media) is backed up to
  that private repository after every turn; without it `work/` is local-only. Definition
  updates arrive as the platform's Kit Update and never touch `work/`
  ([docs/persistence.md](docs/persistence.md) → **Backup & restore**).

## Files

- [`kit.yaml`](kit.yaml) — the Starter Kit: seed, connection, schedules, size.
- [`CLAUDE.md`](CLAUDE.md) — the core manual loaded on every run.
- [`AGENTS.md`](AGENTS.md) — harness entry pointer to `CLAUDE.md`.
- [`ONBOARDING.md`](ONBOARDING.md) — first-run setup, ending in a nested smoke test and
  `scripts/verify-onboarding.sh --live`.
- [`docs/`](docs/) — procedures, read on demand.
- [`engines/`](engines/) — reusable runners of the profile's `bin/` contract.
- [`skills/qi-profile-creator/`](skills/qi-profile-creator/SKILL.md) — the skill a product
  team writes and checks its profile with; the agent never uses it.
- [`skills/qi-test-sync/`](skills/qi-test-sync/SKILL.md) — the skill a product team (or its
  code reviewer) runs on a product change: it updates the profile in the same change and writes
  the pull request's "QA impact" note; the agent never uses it.
- [`skills/create-issue/`](skills/create-issue/SKILL.md) — the agent's own: one GitHub issue
  about found problems on the operator's word.
- [`scripts/`](scripts/) — pre-flight and Precheck, the environment lock and profile
  dispatch (`env.sh`), the suite runner (`suite.sh`), the evidence page renderer
  (`render-report.mjs`), the work backup (`work-backup.sh`), the test catalog (`catalog.mjs`,
  `catalog/viewer.html`), the assertion guard, verification, offline tests.
- [`VERSION`](VERSION) + [`CHANGELOG.md`](CHANGELOG.md) — semver and upgrade steps.
- [`LICENSE`](LICENSE) — Apache-2.0.
