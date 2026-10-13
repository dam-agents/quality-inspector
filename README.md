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
at onboarding ([docs/profile-contract.md](docs/profile-contract.md)). The first profile,
for DAM itself, is `qi-profile-dam` in
[quality-inspector-profiles](https://github.com/dam-agents/quality-inspector-profiles).
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
  only where the UI changed (docs/regression.md).
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
   needs issue write access on the target. Use a dedicated bot account.
3. **Create the agent on the vm backend** when the profile requires root (most nested
   products do). The kit asks for 8 CPU, 16 Gi and 80 Gi; the profile's README says what
   its product needs.
4. **Connect the skill source that holds the profile** (Skills → Sources), e.g.
   `https://github.com/dam-agents/quality-inspector-profiles`. Onboarding installs the
   profile from it.
5. **Make sure agent steps can reach Anthropic** through the gateway with an injected
   credential (the agent's provider connection). Onboarding checks it.
6. **Apply the egress rules** below, then answer the onboarding dialog. Schedules are
   held until onboarding completes, which includes a smoke test of the nested product.

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
([docs/black-box.md](docs/black-box.md)); the egress rules make it true. Apply them with
the CLI (`T` = the target, e.g. `acme/widgets`; `AGENT` = this agent's name):

```bash
dam network create "$AGENT" --host api.github.com --method GET  --path "/repos/$T/issues"            --yes
dam network create "$AGENT" --host api.github.com --method GET  --path "/repos/$T/issues/*"          --yes
dam network create "$AGENT" --host api.github.com --method GET  --path "/repos/$T/issues/*/comments" --yes
dam network create "$AGENT" --host api.github.com --method POST --path "/repos/$T/issues/*/comments" --yes
dam network create "$AGENT" --host api.github.com --method DELETE --path "/repos/$T/issues/*/labels/*" --yes
dam network create "$AGENT" --host api.github.com --path "/repos/$T/*" --verdict deny --yes
dam network create "$AGENT" --host raw.githubusercontent.com --verdict deny --yes
dam network create "$AGENT" --host codeload.github.com --verdict deny --yes
dam network create "$AGENT" --host github.com --path "/$T*" --verdict deny --yes
```

Allow `registry.npmjs.org` (`GET`) and `api.anthropic.com` (and `cdn.playwright.dev` only
if `e2e`'s Playwright ever differs from the image's), then **every entry of the profile's
`egress`** in its `profile.json` — the hosts its product needs to come up.

Rules are matched most-specific first, and a connection grant may already allow the
GitHub API host as a whole — **the deny rules are only proven by the probes**:
`verify-onboarding.sh --live` and the weekly audit request each forbidden surface and
fail when one answers. Approve no held request on the deny side.

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
| `marker_prefix` | default `quality-inspector` | Dedup marker; **immutable once a comment exists**. |
| `qa_label`, `retest_label` | defaults | The gates (`qa:ready`, `qa:retest`). |
| `candidate_channel`, `baseline_channel` | the profile's defaults | What is tested against what (`none` turns red-green off). |
| `artifact_reports`, `include_comments`, `max_issues_per_run`, `lock_ttl_min`, `display_name` | defaults | Reporting and pacing. |
| `e2e_version`, `e2e_web_version`, `e2e_model` | defaults | Test framework pins and the model for agent steps. |
| `audit_report`, `log_level`, `media_retention_days` | defaults | Audit, diagnostics, local evidence retention. |

## Runtime requirements

- **Platform:** a DAM agent (vm backend when the profile requires root; Node ≥ 24.8 and
  Playwright with its Chromium baked in the image), `$HOME` on a persistent volume, the
  gateway for credentials, `mcp__platform-outbound__*` for schedules and the artifact
  tools.
- **Identity:** the GitHub connection's account — a dedicated bot; read access to the
  target's issues, plus issues write when comments are enabled.
- **External surfaces:** artifacts in the platform's artifact library (private by
  default); with `issue_comments: enabled`, **public comments** on the target's issues,
  and removal of the retest label.
- **Cost:** idle hours wake no model. One issue costs three installs of the product (time,
  no tokens) plus authoring — expect a few hundred thousand tokens for the first
  run of an issue; replays of promoted tests are mostly free, except `agent.assert`
  checks, which always call the model.

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
