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
- **Weekly audit** (off by default) — health, the black-box boundary probes, assertion
  drift, cache efficiency (docs/audit.md).
- Scripts only detect, and the profile only sets up the nested product; every judgment and every
  external write is the agent's, per `docs/`. `CLAUDE.md` is the small always-loaded
  core; the definition is versioned (`VERSION` + `CHANGELOG.md`).

## Setup

This repository is its own **Starter Kit** ([`kit.yaml`](kit.yaml)):

1. **Find it under Starter kits** and open its setup page.
2. **Grant the GitHub connection** (required) — reads the target's issues; with issue
   comments enabled it also posts verdicts and removes the retest label, so the account
   needs issue write access on the target. Use a dedicated bot account, and where the
   connection allows it (a GitHub App installation, a fine-grained token) only Issues on
   the target — no Contents, Pull requests or Actions — so a fork or mirror of the source
   stays out of reach too.
3. **Create the agent on the vm backend** when the profile requires root (most nested
   products do). The kit asks for 8 CPU, 16 Gi and 80 Gi; the profile's README says what
   its product needs.
4. **Assign the product profile**: add its skill source (Skills → Sources) and assign the
   profile skill to the agent — for DAM, repository `https://github.com/dam-agents/dam`
   with path `qa`, skill `qi-profile-dam`. Onboarding checks it.
5. **Make sure agent steps can reach Anthropic** through the gateway with an injected
   credential (the agent's provider connection). Onboarding checks it.
6. **Apply the egress rules** (Black-box boundary below), then answer the onboarding
   dialog. Schedules are held until onboarding completes, which includes a smoke test of
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

The agent must not be able to read the target's source. Its rules say so
([docs/black-box.md](docs/black-box.md)); the egress rules make it true. The kit seeds
the ones every deployment shares: denies for GraphQL, code search and every code host
the agent never needs (raw.githubusercontent.com, GitLab, Bitbucket, …). The target's
rules depend on the instance, so onboarding prints them — `bash scripts/egress-rules.sh`
— as `dam network create` commands, with the profile's `egress`; set `AGENT` to the
agent's name and run them (`--kit` adds the kit's rules for an agent created by hand or
from a kit before 2.11.0). A rule counts only once a probe proves it:
`verify-onboarding.sh --live` and the weekly audit request each forbidden surface and
fail when one answers. Approve no held request on the deny side.

Inside the VM, a Claude Code `PreToolUse` hook and a `permissions.deny` list, merged into
`~/.claude/settings.json` at onboarding, refuse the same surfaces before a tool call runs —
plus `git clean`, container filesystems, writes outside `work/`, commits or definition
edits from a scheduled run or a Slack turn, and any GitHub write from a Slack turn
([docs/black-box.md](docs/black-box.md) → Enforcement layers).

## What a report looks like

Every tested issue gets one evidence page in the artifact library (and, with comments
enabled, a short verdict table on the issue linking to it). Per acceptance criterion it
shows the frozen Given/When/Then, then the candidate build and the last release side by
side: a **video of the whole test run**, screenshots captioned by step — including the
exact screen the criterion is checked on — the step list, the assertion error when one
failed, and the trace. A reader can confirm a `verified` verdict by watching the feature
fail on the release and work on the candidate. Media add a few MB per criterion.

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

## Configuration

`work/CONFIG.md`, filled at onboarding; per-key semantics in `CLAUDE.md` → Runtime
configuration.

| Key | Filled at onboarding by | Purpose |
| --- | --- | --- |
| `profile` | chosen and installed | The product profile skill, e.g. `qi-profile-dam`. |
| `profile.<key>` | asked or defaulted, per the profile | The profile's own settings ([docs/profile-contract.md](docs/profile-contract.md)). |
| `target_repo` | asked | Repository whose issues are tested. `QI_TARGET_REPO` overrides. |
| `issue_comments` | asked, default `disabled` | Opt-in: post verdicts on the issue. |
| `spec_feedback` | asked, default `disabled` | Opt-in: suggest an observable "Done when" on issues with nothing testable. |
| `scenario_discovery`, `scenario_channel` | asked, default `disabled` / empty | Opt-in: weekly scenario proposals (`propose`), also tested (`run`); the Slack conversation for their digest. |
| `max_scenarios_per_run`, `max_scenarios_per_day` | defaults (`3`, `10`) | Proposals per discovery run; scenario runs a day. |
| `auto_promote` | default `disabled` | `verified`: tests whose every criterion was verified join the nightly regression without the operator's "promote". |
| `marker_prefix` | default `quality-inspector` | Dedup marker; **immutable once a comment exists**. |
| `qa_label`, `retest_label` | defaults | The gates (`qa:ready`, `qa:retest`). |
| `candidate_channel`, `baseline_channel` | the profile's defaults | What is tested against what (`none` turns red-green off). |
| `artifact_reports`, `include_comments`, `max_issues_per_run`, `lock_ttl_min`, `display_name` | defaults | Reporting and pacing. |
| `e2e_version`, `e2e_web_version`, `e2e_model` | defaults | Test framework pins and the model for agent steps. |
| `confirm_regressions`, `bisect_max_steps` | defaults (off) | Opt-in: confirm a regression on the previous build, then narrow it over the builds in between — extra installs. |
| `audit_report`, `log_level`, `media_retention_days` | defaults | Audit, diagnostics, local evidence retention. |
| `explorations`, `max_explorations_per_ac` | defaults (`enabled`, `3`) | Agent-designed checks beyond the criteria, reported apart from the verdict ([docs/explorations.md](docs/explorations.md)). |
| `security_checks`, `security_failed_logins` | defaults (`enabled`, `10`) | The security run ([docs/security.md](docs/security.md)); its schedule ships off. |
| `max_wallclock_min_per_issue`, `max_model_steps_per_issue`, `min_free_disk_gi` | defaults | Per-issue budgets and the free disk an install needs. |

## Runtime requirements

- **Platform:** a DAM agent (vm backend when the profile requires root; Node ≥ 24.8 and
  Playwright with its Chromium baked in the image), `$HOME` on a persistent volume, the
  gateway for credentials, `mcp__platform-outbound__*` for schedules and the artifact
  tools.
- **Identity:** the GitHub connection's account — a dedicated bot; read access to the
  target's issues, plus issues write when comments are enabled.
- **External surfaces:** artifacts in the platform's artifact library (private by
  default); with `issue_comments: enabled`, **public comments** on the target's issues,
  and removal of the retest label; optionally a Slack channel bound to the agent (replies
  in request threads; with `scenario_channel`, one weekly digest post).
- **Cost:** idle hours wake no model. One issue costs three installs of the product (time,
  no tokens) plus authoring — expect a few hundred thousand tokens for the first
  run of an issue (explorations, on by default, add roughly 30–60 %); replays of promoted
  tests are mostly free, except `agent.assert` checks, which always call the model. A
  scenario costs about what an issue does; discovery adds tens of thousands of tokens a
  week (`propose`), or that plus one scenario per proposal (`run`).

## Persistence

`work/` is **local-only** by choice: the suite, its replay cache, the frozen criteria and
the reports live only on the agent's volume. A lost volume loses them; verdict rows can be
rebuilt from issue comments when comments were enabled. Definition updates arrive as the
platform's Kit Update and never touch `work/` ([docs/persistence.md](docs/persistence.md)).

## Files

- [`kit.yaml`](kit.yaml) — the Starter Kit: seed, connection, schedules, size.
- [`CLAUDE.md`](CLAUDE.md) — the core manual loaded on every run.
- [`AGENTS.md`](AGENTS.md) — harness entry pointer to `CLAUDE.md`.
- [`ONBOARDING.md`](ONBOARDING.md) — first-run setup, ending in a nested smoke test and
  `scripts/verify-onboarding.sh --live`.
- [`docs/`](docs/) — procedures, read on demand.
- [`scripts/`](scripts/) — pre-flight and Precheck, the environment lock and profile
  dispatch (`env.sh`),
  the suite runner (`suite.sh`), the evidence page renderer (`render-report.mjs`), the
  assertion guard, verification, offline tests.
- [`VERSION`](VERSION) + [`CHANGELOG.md`](CHANGELOG.md) — semver and upgrade steps.
- [`LICENSE`](LICENSE) — Apache-2.0.
