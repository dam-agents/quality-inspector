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
**engines** (`engines/`, e.g. `helm-k3s` for a Helm chart in k3s) do the running, so a
profile is mostly data. The DAM profile, `qi-profile-dam`, lives in the DAM repository
under `qa/`.
The agent uses the platform's own primitives: schedules with Prechecks, the artifact
library for evidence, the skill catalog for profiles, sub-agents for independent review.

## How it works

- **Issues run** (hourly) — the pre-flight lists labelled issues in one call, hashes each
  issue's criteria text and asks the profile for the newest builds; an
  issue is due when it is new, its text changed, or it carries `qa:retest`. The schedule's
  Precheck declines idle hours before any model wakes. The agent then freezes the
  criteria, brings the product up, writes one e2e test per criterion, runs it on
  the last release and on the candidate, and reports (docs/issue-qa.md).
- **Regression run** (nightly, off by default) — replays the tests the operator promoted
  against each new candidate; recorded steps replay without model calls, the LLM steps in
  only where the UI changed; it also maps which pages no promoted test reaches (docs/regression.md).
- **Security run** (weekly, off by default) — frozen black-box checks of each new candidate:
  access without or with the wrong session, stored XSS, headers, leaks, the deployment;
  findings go to a private artifact only, never to an issue (docs/security.md).
- **Scenarios** — in a connected Slack channel anyone can ask "test that …" or write the
  steps and the expected outcome; the agent freezes it, has an independent judge sub-agent
  check the scenario, tests it on the newest build (and on the last release when it fails,
  to tell a regression from an old defect), lets the judge check the evidence, and answers
  in the thread with a video report. "save S-<k>" queues a passing scenario for the
  operator's "promote all pending". A weekly discovery run (off by default) proposes
  scenarios of its own from uncovered pages and completed issues, and can test them too
  (docs/scenarios.md, docs/judge.md).
- **Testing modules** (nightly, each off by default) — switchable from the dashboard: a UI
  sweep that walks every page at several screen sizes and lists layout, visual and
  accessibility defects for design; form validation; bounded stress of the local product;
  and a one-off deep test of a chosen area (docs/modules.md).
- **Weekly audit** (off by default) — health, the black-box boundary probes, assertion
  drift, cache efficiency, and the week's speed and cost per issue (docs/audit.md).
- **From Slack** (off by default) — a person in the bound channel asks "test #N", "test feature
  …" or for a scenario and gets the result in the thread, with one picture of the screenshots behind it
  and a link to the report or the dashboard where one opens; the run shows on the dashboard.
  One test at a time, `slack_tests_per_day` a day (docs/slack.md).
  In the direct session the operator can watch exploration live in the Browser Panel
  (`live_browser`), and the nested product can call the agent's own model by placeholder
  instead of a mock (`lend_model`).
- Scripts only detect, and the profile only sets up the nested product; every judgment and every
  external write is the agent's, per `docs/`. `CLAUDE.md` is the small always-loaded
  core; the definition is versioned (`VERSION` + `CHANGELOG.md`).

## Setup

This repository is its own **Starter Kit** ([`kit.yaml`](kit.yaml)):

1. **Find it under Starter kits** and open its setup page.
2. **Grant the GitHub connection** (required) — reads the target's issues and removes
   the retest label after a test; with issue comments enabled it also posts verdicts, and on the
   operator's word it opens issues about the problems it found (the dashboard's "Report it as
   a GitHub issue"), so the account needs issue write access on the target. Use a dedicated bot account, and where the
   connection allows it (a GitHub App installation, a fine-grained token) only Issues on
   the target — no Contents, Pull requests or Actions. The egress, not the token, keeps
   forks and mirrors out of reach: a public target's are readable by anyone. With a work
   backup (`work_repo`), add Contents read & write on that one private repository, and
   protect its `main` so only this account pushes (a private repository needs a paid GitHub
   plan for that; without it, the next persist logs and reverts a foreign commit).
3. **The agent runs on the vm backend**: the kit says so, and is hidden on an install
   without virtualization. It asks for 8 CPU, 12 Gi and 80 Gi; the profile's README says
   what its product needs.
4. **Assign the product profile**: add its skill source (Skills → Sources) and assign the
   profile skill to the agent — for DAM, repository `https://github.com/dam-agents/dam`
   with path `.quality-inspector`, skill `qi-profile-dam`. A profile lives under
   `.quality-inspector/` of its repository, the one directory the kit's egress opens.
   Onboarding checks it. A product without a profile gets one
   from its team with the [`qi-profile-creator`](skills/qi-profile-creator/SKILL.md) skill.
5. **Give the agent a model connection** (Anthropic API key, OAuth token, or a proxy such
   as LiteLLM). Agent steps send its placeholder, which the gateway swaps for the
   credential; *Inject only into addressed requests* stays on (the kit sets it). Onboarding
   checks it with one model call made the way the tests make it.
6. **Apply the profile's egress rules** (Black-box boundary below), then answer the onboarding
   dialog. A profile whose flows reach outside the product (Slack, GitHub) asks for
   throwaway **sandbox accounts** there — its guides say how to create them
   ([docs/profile-contract.md](docs/profile-contract.md) → `sandbox`). Schedules are held until onboarding completes, which includes a smoke test of
   the nested product.
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

The agent must not be able to read the target's source, and it has **no GitHub access of its
own** ([docs/black-box.md](docs/black-box.md)). The kit's egress makes it true for every
target, with no operator step and whatever the connection's token may read (the gateway
injects it; the VM holds a placeholder): GitHub is deny-by-default, and only the issues
endpoints (which also list the pull requests: the Change radar keeps their sanitized title and
description alone), the `.quality-inspector/` profile directory, a repository's metadata and the
read-only fetch of this definition open — for every repository alike, each allow fenced by
two longer denies against wildcard tricks. Every other code host is denied. What stays the
operator's, listed by `bash scripts/egress-rules.sh` as host, method, path and why — never as
commands: the profile's `egress`, the `work_repo` backup, a GitHub Enterprise target (`--kit`
adds the kit's rules for an agent created by hand or from a kit before 3.0.0 — a kit never
updates an existing agent's rules). A host no kit rule covers lands through its approval prompt
(`verify-onboarding.sh --egress` asks for each); a rule under a kit deny the operator adds by
hand, since no prompt ever appears for it. A rule counts only once a probe proves it: before each day's work
the pre-flight's **black-box gate** requests each forbidden surface — through `gh` (REST,
GraphQL), `git` (HTTPS, SSH) and `curl` — and stops every run while one answers, with an alert
to `regression_channel` (else `slack_channel`); `verify-onboarding.sh --live` and the weekly audit report the same probes.
Approve no held request on the deny side.

Inside the VM, a Claude Code `PreToolUse` hook and a `permissions.deny` list, merged into
`~/.claude/settings.json` at onboarding, refuse any road to GitHub but `scripts/github.sh`
(the target's issues only) — no `gh`, no `git clone|fetch|push`, no GitHub URL; the
platform's Kit Update `git fetch origin` excepted — plus `git clean`, container
filesystems, writes outside `work/` (the agent proposes changes to itself as patches in
`work/patches/`), commits from a scheduled run or a Slack turn, and any GitHub write from a
Slack turn except a Slack-ordered "test #N"'s comment and retest-label removal on that issue
([docs/black-box.md](docs/black-box.md) → Enforcement layers). The daily gate also stops every
run while a hook or the deny list is gone. A trace hook logs every turn's start and end and every failed
tool call to `work/logs/`, so the weekly audit sees crashed runs and repeating failures ([docs/logging.md](docs/logging.md) → Harness trace).

## What a report looks like

Every tested issue gets one evidence page in the artifact library (and, with comments
enabled, a short verdict table on the issue linking to it). Per acceptance criterion it
shows the frozen Given/When/Then, then the candidate build and the last release side by
side: a **video of the whole test run**, screenshots captioned by step — including the
exact screen the criterion is checked on — the step list, the assertion error when one
failed, and the trace. A reader can confirm a `verified` verdict by watching the feature
fail on the release and work on the candidate. When the issue states its purpose, the page also
shows an **intent test**: one user journey that checks the goal, not only the letter of the
criteria — reported beside the verdict, never in it ([docs/intent.md](docs/intent.md)). Media add a few MB per criterion.

## The test catalog

One more artifact shows the whole suite: every criterion, exploration and scenario test with
its Given/When/Then, steps, tier, verdict history per build, heals, flakiness and the still of
the screen it checks — filterable, sortable and groupable by tier, origin, verdict, area, page,
label, feature or the operator's own collections, with a gallery, a coverage map of the UI, a
build-by-test heatmap and the promotion funnel. It is also the way into every run — each night,
issue run and scenario run with its outcome and report — and a product map: the UI map's page
shots with each control clickable to the tests that use it, viewable as of any past build. Its
Test builder lets a person write a new test as steps — blocks or text, or clicked through on the
map's shots — play them on those shots, then ask for the test or, as the operator, have the agent
do the steps live in the Browser Panel. Every
issue, build, page and report on it is a link, and the browser's back (or its own ← Back) returns
step by step. It
holds test-related content only, so the operator may share it ([docs/catalog.md](docs/catalog.md)).

## When the UI changes

Promoted tests replay nightly against each new build, and a redesign must not fail them.
Before replaying, the agent builds a picture of what changed — never from code: the
**issues completed** between the two builds, and a **UI map** it crawls on each build
(pages, navigation, buttons, tabs, fields), diffed into what was added, removed, renamed
or moved. Tests are written to survive layout changes, and every acceptance check carries
a fallback that judges the criterion's own sentence on screen when its exact locator no
longer matches. A triage then sorts every non-trivial result into *re-learned* (steps
moved), *repaired* (a check followed a renamed or moved control — logged), *superseded*
(a completed issue changed the behaviour on purpose), *needs review*, or **regression** —
the only one that is a product defect, and the default when the evidence is unclear.
What the agent may not absorb alone becomes a **maintenance proposal** for the operator — what
changed, the evidence, and accept, rewrite, retire or keep ([docs/maintenance.md](docs/maintenance.md));
a page, control or interface gone or moved in the night's UI map opens one before the test even fails.
A **Change radar** (every 3 hours, off by default) reads the target's pull requests — their title and
description only, sanitized, through the issues listing; never a diff — and opens a `predicted`
proposal for each recurring test a change names, before a build carries it ([docs/radar.md](docs/radar.md)).
Recurring tests are also grouped by **feature** ("Model switching"), so anyone can ask for a
feature by name — "run feature …" in the chat, "test feature …" in Slack — and have its tests run
again ([docs/features.md](docs/features.md)).

## Configuration

`work/CONFIG.md`, filled at onboarding; per-key semantics in `CLAUDE.md` → Runtime
configuration.

| Key | Filled at onboarding by | Purpose |
| --- | --- | --- |
| `profile` | chosen and installed | The product profile skill, e.g. `qi-profile-dam`. |
| `profile.<key>` | asked or defaulted, per the profile | The profile's own settings ([docs/profile-contract.md](docs/profile-contract.md)). |
| `target_repo` | asked | Repository whose issues are tested. `QI_TARGET_REPO` overrides. |
| `github_login` | asked for a GitHub App connection, default empty | The agent's own login (`<slug>[bot]`) when the token cannot tell; it identifies the agent's own comments. |
| `work_repo` | asked, default unset (local-only) | A private repository the Stop hook backs `work/` up to after every turn; a fresh volume or another pod restores from it ([docs/persistence.md](docs/persistence.md) → Backup & restore). |
| `github_login` | asked for a GitHub App connection, default empty | The agent's own login (`<slug>[bot]`) when `gh api user` cannot answer; it identifies the agent's own comments. |
| `issue_comments` | asked, default `disabled` | Opt-in: post verdicts on the issue. |
| `spec_feedback` | asked, default `disabled` | Opt-in: suggest an observable "Done when" on issues with nothing testable. |
| `scenario_discovery`, `scenario_channel` | asked, default `disabled` / empty | Opt-in: weekly scenario proposals (`propose`), also tested (`run`); the Slack conversation for their digest. |
| `max_scenarios_per_run`, `max_scenarios_per_day` | defaults (`3`, `10`) | Proposals per discovery run, also profile scenarios adopted a night; scenario runs a day. |
| `profile_scenarios`, `regression_channel` | default `enabled`; asked when a channel is connected, default empty | The profile's `scenarios/` (the product team's flows) are adopted and replayed nightly; the Slack conversation for the nightly summary and a black-box breach alert (else `slack_channel`). |
| `auto_promote` | default `disabled` | `verified`: tests whose every criterion was verified join the nightly regression without the operator's "promote". |
| `marker_prefix` | default `quality-inspector` | Dedup marker; **immutable once a comment exists**. |
| `qa_label`, `retest_label` | defaults | The gates (`qa:ready`, `qa:retest`). |
| `candidate_channel`, `baseline_channel` | the profile's defaults | What is tested against what (`none` turns red-green off). |
| `test_catalog` | default `enabled` | One page to browse, describe, filter, group and categorize every test, published as an artifact after a run that changes it ([docs/catalog.md](docs/catalog.md)). |
| `artifact_reports`, `include_comments`, `max_issues_per_run`, `lock_ttl_min`, `display_name` | defaults | Reporting and pacing. |
| `e2e_version`, `e2e_web_version`, `e2e_model` | defaults | Test framework pins and the model for agent steps. |
| `confirm_regressions`, `bisect_max_steps` | defaults (off) | Opt-in: confirm a regression on the previous build, then narrow it over the builds in between — extra installs. |
| `audit_report`, `log_level`, `media_retention_days` | defaults | Audit, diagnostics, local evidence retention. |
| `explorations`, `max_explorations_per_ac` | defaults (`enabled`, `3`) | Agent-designed checks beyond the criteria, reported apart from the verdict ([docs/explorations.md](docs/explorations.md)). |
| `security_checks`, `security_failed_logins` | defaults (`enabled`, `10`) | The security run ([docs/security.md](docs/security.md)); its schedule ships off. |
| `max_wallclock_min_per_issue`, `max_model_steps_per_issue`, `min_free_disk_gi` | defaults | Per-issue budgets and the free disk an install needs. |
| `ui_sweep`, `validation_checks`, `stress_checks` and their tunables, `focus_max_checks`, `modules_max_wallclock_min` | offered, default `disabled` | The testing modules of the nightly modules run; registry `scripts/lib/modules.json` ([docs/modules.md](docs/modules.md)). |
| `dashboard_interactive` | offered, default `disabled` | The dashboard's buttons send their command to the agent's chat (needs the platform's Interactive artifacts). |
| `slack_channel`, `slack_tests_per_day` | asked (optional), default `3` | Slack test requests ([docs/slack.md](docs/slack.md)). |
| `report_visibility` | default `private` | `public`: every report but the security run's gets a link anyone holding it opens, and the dashboard opens it in one click ([docs/reporting.md](docs/reporting.md) → Delivery). |
| `slack_report_visibility` | default `private` | `public`: a report answered in a Slack thread gets a link anyone holding it opens, posted in that thread only ([docs/slack.md](docs/slack.md) → The answer in the thread). |
| `nested_target` | default `auto` | Where the nested product runs: a platform Environment when the profile declares one and the platform makes it, else this VM; `vm` keeps it here, `environment` refuses this VM ([docs/nested-env.md](docs/nested-env.md) → Where the product runs). |
| `lend_model`, `live_browser` | `lend_model` offered, default `disabled`; `live_browser` detected | The product calls the agent's model by placeholder; exploration in the browser the operator watches. |

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
  on the target about found problems, labelled `found_label` (and `fix_label` for the software
  architect) — [`skills/create-issue`](skills/create-issue/SKILL.md); optionally a Slack channel bound to the agent (replies
  in request threads; with `scenario_channel`, one weekly digest post; with `regression_channel`, one nightly summary post and a black-box breach alert; with `slack_channel`,
  issue tests people order there); with `work_repo`, pushes of the `work/` backup to that
  private repository. The platform runtime's session state (`PLATFORM_RUNTIME_URL`) frees a
  dead run's environment lock at once; without it the lock waits `lock_ttl_min`.
- **Cost:** idle hours wake no model. One issue costs up to three installs of the product
  (time, no tokens; an install of the build already up returns at once) plus authoring — expect a few hundred thousand tokens for the first
  run of an issue (explorations, on by default, add roughly 30–60 %); replays of promoted
  tests are mostly free, except `agent.assert` checks, which always call the model. A
  scenario costs about what an issue does; discovery adds tens of thousands of tokens a
  week (`propose`), or that plus one scenario per proposal (`run`).

## Persistence

With `work_repo` set, a Claude Code `Stop` hook pushes `work/` — the suite, its replay
cache, the frozen criteria, the state tables and the reports' text, never credentials or
media — to that **private** repository after every turn; a fresh volume or another pod
restores it at onboarding. The backup is never read back otherwise and refuses a public
repository, the target or its fork. Without it, `work/` is local-only and a lost volume
loses it. Definition updates arrive as the platform's Kit Update and never touch `work/`
([docs/persistence.md](docs/persistence.md) → Backup & restore).

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
  about found problems (failed tests, design, validation, stress findings) on the operator's word.
- [`scripts/`](scripts/) — pre-flight and Precheck, the environment lock and profile
  dispatch (`env.sh`),
  the suite runner (`suite.sh`), the evidence page renderer (`render-report.mjs`), the
  work backup (`work-backup.sh`), the test catalog (`catalog.mjs`, `catalog/viewer.html`), the
  assertion guard, verification, offline tests.
- [`VERSION`](VERSION) + [`CHANGELOG.md`](CHANGELOG.md) — semver and upgrade steps.
- [`LICENSE`](LICENSE) — Apache-2.0.
