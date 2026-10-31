# Changelog

**Migration instructions, not a change log.** Per version, the idempotent **Upgrade**
steps a deployed instance applies when crossing it — what to run, update, or change
(schedules, config keys, state formats). Most versions need nothing. What changed and
why lives in the PR and commit history, not here. Consumed by the version check
([docs/persistence.md](docs/persistence.md) → **Definition version & upgrade**);
authoring rules: [docs/self-modification.md](docs/self-modification.md) §12.

## 3.52.0 — 2026-10-31

**Upgrade:**
1. Nothing to run — docs are re-read per run; off by default, both cost nothing. Two testing modules
   join the modules run ([docs/design-checks.md](docs/design-checks.md)): the inconsistency radar
   (`consistency_radar`; `weekly` is enough) and the design check of each open pull request that
   carries `design_label` (default `qa:design`), on that pull request's own build (`design_checks`).
   Offer them to the operator (`module consistency set consistency_radar=weekly`, `module design-check
   set design_checks=enabled`); never switch them on yourself. The design check needs the profile to
   name a pull request's build (`bin/versions --prs`; the helm-k3s engine reads
   `engine_config.pull_requests`, [docs/profile-contract.md](docs/profile-contract.md)) and the product's
   repository to label its UI pull requests; until then the pull requests wait, and the pre-flight says
   why. Cost when on: a pull request is one install (15–25 min) and about a minute per screen, the radar
   a few seconds per screen — no model step in either.
2. Opt-in, off: `design_desk_findings: enabled` with `design_desk_channel` (the Slack conversation the
   Design Desk agent listens in) and `design_desk_bot` (its bot's `U…` id) sends each design finding
   once, as an automated test finding, at most `design_desk_max_per_run` (5) a run at or above
   `design_desk_min_severity` (`medium`). Offer it only where a Design Desk agent runs; then
   `bash "$HOME/scripts/verify-onboarding.sh" --config`. Up to 5 screenshots a run to look at (≈ 3–5k
   tokens each).

## 3.51.0 — 2026-10-30

**Upgrade:**
1. Nothing to run — docs are re-read per run and the policy hook runs from the checkout. A
   person the operator shared the interactive dashboard with may now use every control of the
   page: a scenario request runs in their turn, as before; every other command of the page goes
   to a fresh session by the viewer's handoff, where each confirmation waits for the operator
   ([docs/persistence.md](docs/persistence.md) → **Handoff**). Tell the operator once: share the
   dashboard only with people trusted to open issues, switch modules and promote tests
   ([docs/modules.md](docs/modules.md) → **Control**).

## 3.50.0 — 2026-10-30

**Upgrade:**
1. Run `bash "$HOME/scripts/hooks/install.sh"` once in the direct session: it registers the
   SessionStart hook `scripts/hooks/resume.sh`. From the next session after a VM restart (the
   platform hibernates an idle VM), the product comes back at the build it ran, in the background
   ([docs/nested-env.md](docs/nested-env.md) → **After a VM restart**). Do not install a boot
   service for this. The audit's `resume_hook` check warns until the hook is registered.

## 3.49.0 — 2026-10-30

**Upgrade:**
1. Nothing to run — docs are re-read per run, the dashboard is rebuilt by the next catalog
   publish. Its new "Run it again" buttons send `run <ref>, <ref>…` (up to 20 test cases),
   `recheck VAL-<k>` and `test scenario <slug>` ([docs/on-demand.md](docs/on-demand.md),
   [docs/validation.md](docs/validation.md) → **Recheck**); "Repair this test" now shows.

## 3.48.0 — 2026-10-30

**Upgrade:**
1. Nothing to run for an instance whose profile declares no `operator_credentials` — the key is
   optional and a profile without it behaves as before. When the profile declares one, run
   `bash "$HOME/scripts/env.sh" init` once (it only adds missing lines and never touches a
   value; with the file already there the engine's init does nothing else), then
   `bash "$HOME/scripts/verify-onboarding.sh" --config`. Each value then has an `E2E_<NAME>`
   line in `work/env/credentials.env`, reported as set, missing (required) or missing
   (optional) ([docs/profile-contract.md](docs/profile-contract.md) → `operator_credentials`).
   The operator fills it in the agent's files, never in chat. A name needs a `PASSWORD`,
   `TOKEN`, `SECRET` or `KEY` segment, so its value is masked; one without is not seeded.
2. Nothing to run — `scripts/lib/secrets.mjs` masks a value whose name ends in `KEY` too, in
   every run artefact and in the `work_repo` snapshot, so a line an operator filled as
   `..._KEY` no longer has to be renamed to `..._TOKEN` to stay out of them.

## 3.47.0 — 2026-10-30

**Upgrade:**
1. Nothing to run. Under `nested_target: auto` a profile that sets `engine_config.kvm` now runs
   in a platform Environment too, when this VM has `/dev/kvm` and the new Environment has it as
   well; an Environment without the device is deleted and the product runs in this VM, as before
   ([docs/nested-env.md](docs/nested-env.md) → **Where the product runs**). To keep it in this
   VM, set `- nested_target: vm` in `work/CONFIG.md`.

## 3.46.0 — 2026-10-30

**Upgrade:**
1. Nothing to run — docs are re-read per run. The deploy gate is on by default: an issue carrying
   `qa_label` is tested only once the candidate build was published after its change merged — the
   issue closed as completed, or a pull request with `qa_label` that closes it merged
   ([docs/issue-qa.md](docs/issue-qa.md) → **The deploy gate**). An open issue with no such pull
   request now waits; the logs and `issues_waiting[]` say why. Put the label on the fixing pull
   request too, or add `- deploy_gate: disabled` to `work/CONFIG.md` for the old behavior.

## 3.45.0 — 2026-10-30

**Upgrade:**
1. Nothing to run. From the next `env.sh up` the product runs in a platform Environment of this
   agent's own when the profile declares `environment`, `lend_model` is off, the profile does not
   set `engine_config.kvm` and the owner has the platform's `environments` feature; else in this VM as before, with the reason in the output
   ([docs/nested-env.md](docs/nested-env.md) → **Where the product runs**). To keep it in this
   VM, set `- nested_target: vm` in `work/CONFIG.md`.
2. A run in an Environment that fails keeps it 3 days for a person (`env.sh keep`), listed in
   `work/ENVIRONMENTS.json` (**Kept for a person**); "keep #N for <d> days" and "release #N" in the
   direct session change that.

## 3.44.0 — 2026-10-30

**Upgrade:**
1. Nothing — the engine is re-read per run. A helm-k3s profile that sets `kvm: true` (and
   `host_dirs`) gets VMs in its nested product on the next `env.sh up`, where the platform gives
   this agent's VM `/dev/kvm` ([engines/helm-k3s/README.md](engines/helm-k3s/README.md) → **KVM**).
   The first such `up` on a running cluster stops k3s once and starts it again, to move the
   kubelet's root off the overlay root.

## 3.43.0 — 2026-10-27

**Upgrade:**
1. `bash "$HOME/scripts/hooks/install.sh"`, effective from the next session: it registers the policy
   hook for the platform's schedule tools too (rule `platform-schedule`). Re-running changes nothing;
   until then the audit's `policy_schedules` warns, and the gate stays green.
2. Nothing else — docs are re-read per run. A dashboard button pressed beside a scheduled run's chat
   ("create issue for …", "module … set", "dismiss D-k", "recheck D-k", "discuss D-k") now goes to a
   fresh session of its own ([docs/persistence.md](docs/persistence.md) → **Handoff**); look for its
   answer there.

## 3.42.0 — 2026-10-27

**Upgrade:**
1. `cp "$HOME/scripts/suite-skeleton/lib/criterion.ts" "$HOME/work/suite/lib/criterion.ts"` —
   `suite.sh init` copies missing files only. The new `criterion()` puts a red frame on the
   control of a failed check ([docs/test-authoring.md](docs/test-authoring.md) → **The mark of a
   failed check**).
2. In each `work/suite/tests/*.e2e.ts` that imports `criterion`, import `expect` from
   `../lib/criterion.js` and remove it from the `from 'e2e'` import. Change only the import
   lines; no AC block changes, so `check-asserts.sh` stays clean. A test not yet changed works
   as before, without the red frame.
3. Nothing else to run: the report, the dashboard and the found-issue draft draw the frames on
   the next run, and a verdicts entry can now carry the agent's `mark`
   ([docs/reporting.md](docs/reporting.md) → **The mark**).

## 3.41.0 — 2026-10-27

**Upgrade:**
Nothing to run — docs are re-read per run, and the dashboard rebuilds itself on the next catalog
build. New operator commands for a design finding, also on its card's "Manage" in the Design view:
`recheck D-<k>` sweeps its page and viewport again on the candidate now ([docs/ui-sweep.md](docs/ui-sweep.md)
→ **5. Recheck**; its files go to `work/design/recheck/`), and `discuss D-<k>[: <question>]` answers
about it, read-only (→ **6. Discuss**).

## 3.40.0 — 2026-10-27

**Upgrade:**
Nothing to run — the reports rebuild themselves on the next run. A report's video now pauses after
each step and names it, and a click on a step plays the video from there
([docs/reporting.md](docs/reporting.md) → **The report**). A report rendered before 3.35.1 opens a
screenshot as a page of its own; render it again to get the in-page viewer.

## 3.39.0 — 2026-10-27

**Upgrade:**
Nothing to run. A profile may now list `expected_requests` in its `profile.json`
([docs/profile-contract.md](docs/profile-contract.md)): requests the nested install answers with an
error on purpose. The UI sweep records no `failed-request` finding for them and the UI diff never
reports them as new. Open design findings of such a request resolve on the next sweep; to close them
now, dismiss them (`dismiss D-<k> as by-design`). Without the key nothing changes.

## 3.38.3 — 2026-10-27

**Upgrade:**
Nothing to run — docs are re-read per run. A public report no longer uploads its videos: the
platform's `/raw` link serves only images inline, so the page carries the videos as data
([docs/reporting.md](docs/reporting.md) → **Delivery** step 1). A refused served type no longer
stops the report: `media-urls.json` records it under `refused`, and the page carries its files. A
report stopped by 3.33.1 (`blocked`) is delivered by the next run with no `unblock`. The rejected
public video artifacts stay: delete them in the app.

## 3.38.2 — 2026-10-27

**Upgrade:**
Nothing to run — docs are re-read per run. From now on every finished report removes the retest
label, also with `issue_comments: disabled` ([docs/reporting.md](docs/reporting.md) → **Delivery**
step 4), so the GitHub connection needs issues write on the target. With a read-only connection the
removal fails and the report stays `report_pending`: give the account issues write, or remove the
label by hand. A `reports_due` entry now carries `retest_label_present`.

## 3.38.1 — 2026-10-27

**Upgrade:**
Nothing to run: the next run of `scripts/hooks/install.sh` takes `~/.claude/settings.json.lock` while it merges, so it no longer races the platform's own settings writes.

## 3.38.0 — 2026-10-27

**Upgrade:**
Nothing to run — docs are re-read per run. Existing `work/MAINTENANCE.md`, `work/HEALS.md` and
`work/REGRESSION.log` stay valid (the new kind `rework` and the log key `reworked=` are additive);
the dashboard shows "Repair this test" from the next catalog build.

## 3.37.0 — 2026-10-27

**Upgrade:**
Nothing to run — docs are re-read per run, and the dashboard and the reports rebuild themselves on
the next run. New:
1. Every verdicts file (an issue run, a scenario run, a night) carries the agent's `analysis`:
   a summary, each problem with what happened, where, the probable cause, its certainty and the
   repair, and the next step ([docs/reporting.md](docs/reporting.md) → **The agent's analysis**).
   The report shows it above its table; a run's panel on the dashboard opens with it.
2. The dashboard now shows the agent's sentence on each result that is not a pass (a night's
   `explanation`, a criterion's `note`). A verdicts file's `notes` stay off the page.
3. A run written before this version has no `analysis`: its panel shows a sentence that the page
   builds from the results ("Why this result"), until the next run of that kind.

## 3.36.0 — 2026-10-27

**Upgrade:**
Nothing to run — docs are re-read per run, and the reports and the dashboard rebuild themselves on
the next run. Changed:
1. A criterion that passes on the candidate while its baseline stopped for `environment`, `model`
   or `setup` is now `blocked` (with its `cause`), not `inconclusive`. A report written before this
   version keeps its verdict until the issue is tested again.
2. A pass whose `AC-<k>` screenshot shows an error message that the criterion does not expect does
   not count: the criterion is `blocked`, and the new verdicts-file field `error_at_check` quotes
   the message in the report.

## 3.35.1 — 2026-10-27

**Upgrade:**
Nothing to run — the reports and the evidence pages of found issues rebuild themselves on the next run.
A click on a screenshot, or "Enlarge" under a video, shows it larger over the page, with zoom in
and out, fit and 1:1. A screenshot no longer links its file, which opened an empty page in a
strict viewer and downloaded the file after a reload. A report made before this version keeps the
old behavior.

## 3.35.0 — 2026-10-26

**Upgrade:**
Nothing to run — docs are re-read per run, and the dashboard and the reports rebuild themselves on
the next run. New:
1. `include_comments` now defaults to `enabled`: an issue run reads the issue's comments too. A
   `work/CONFIG.md` line written before this version keeps its value; set `enabled` or `disabled`
   there as you want it.
2. A criterion quotes its source verbatim: `quote:` in the criteria file, shown in the report and
   in the dashboard. A file frozen before this version has none until its next freeze.
3. A contradiction between the issue and a comment, or between two comments, is an open question
   (`## Q-<k>`); the report and the run's chat summary show it. The operator's answer is a dated
   line in `work/OPERATOR.md`, and the next freeze follows it.
4. A run's panel shows its window as text (the builds and times of the night, never
   `[object Object]`); a dashboard side panel opens at half the width of the screen; a click on a
   report screenshot shows it at its full size over the page; every AC in a report links its
   source issue.
5. The hash of an issue's criteria now covers the operator's `#<n> Q-<k>:` answers in
   `work/OPERATOR.md`, and `github.sh comments` lints each comment for injection.

## 3.34.1 — 2026-10-26

**Upgrade:**
Nothing to run — scripts and docs are re-read per run. `live_cdp` now reads the shared browser's current
port from `~/.local/share/platform/browser/DevToolsActivePort` when `live_browser` is empty or its port
does not answer. Optional, operator: in `work/CONFIG.md` empty `live_browser:` (or drop the stale port) so
it follows the browser across restarts; `disabled` still turns live off.

## 3.34.0 — 2026-10-26

**Upgrade:**
Nothing to run — docs are re-read per run. New on the dashboard ([docs/catalog.md](docs/catalog.md)):
1. Every link to an issue or a scenario shows its title, and the issue's panels its summary: a
   criteria file now has a `summary:` line ([docs/acceptance-criteria.md](docs/acceptance-criteria.md)
   → Output). A file frozen before has none until its next freeze.
2. Every result that is not a pass names its `cause` — `product`, `test` or `environment`
   ([docs/reporting.md](docs/reporting.md) → Cause of a failure; regression entries
   [docs/triage.md](docs/triage.md) → Cause). Earlier verdicts files stay as they are: a `failed`
   or `regression` shows as a product defect, a `needs-review` as a test defect, the rest as not known.
3. Sharp screenshots: a WebP copy up to 1440 px beside each small JPEG in `work/catalog/thumbs/`,
   rendered on the next build of the catalog; the image budget is 8 MiB.
4. `work/FOUND.md` gets a `title` column, written by `github.sh create-issue`; earlier rows have none.

## 3.33.1 — 2026-10-26

**Upgrade:**
Nothing to run — docs are re-read per run. A refused served type now blocks the report's media
(`media-urls.json` key `blocked`) until the operator says so; then `report-media.mjs unblock <dir>`.

## 3.33.0 — 2026-10-25

**Upgrade:**
Nothing to run — docs are re-read per run, and `scripts/lib/gherkin.mjs` needs no install. New:
1. **Gherkin in** ([docs/acceptance-criteria.md](docs/acceptance-criteria.md) → Gherkin): an issue's
   ```` ```gherkin ```` block is criteria. The worklist's `spec.gherkin` names it. The injection lint
   does not count a pure-Gherkin block as code (closed, no error, no doc string, every line reaches an AC
   or has no words to drop),
   so an issue that was an injection suspect only for such a block is not one any more; any other
   block still counts. Earlier frozen criteria stay as they are (the `ac_hash` is unchanged).
   A Gherkin error is a new spec-feedback trigger.
2. A profile may keep a scenario as `scenarios/<slug>.feature` ([docs/profile-contract.md](docs/profile-contract.md)
   → `scenarios/`); the nightly run adopts it like a `.md`, and its verbatim copy is `source-<spec_hash>.feature`.
   Profile maintainers: `check-profile.mjs` checks it with the core's parser.
3. **Gherkin out:** "export #N as Gherkin" in the direct session ([docs/on-demand.md](docs/on-demand.md)), and
   "Copy as Gherkin" on the catalog (a criterion's panel, each feature) from the next catalog build. The spec
   feedback's suggested "Done when" is now a ```` ```gherkin ```` block.

## 3.32.1 — 2026-10-25

**Upgrade:**
Nothing to run — docs are re-read per run. Every artifact upload now sends its `Content-Type`
(`report-media.mjs list` gives each media file's); before, a public report's media were stored as
`application/x-www-form-urlencoded` and served as downloads, so a strict viewer showed no image or
video. Addresses in `media-urls.json` recorded before this version count as not uploaded, so the next
revision of a public report uploads its media again, typed. A report already published stays as it
is until then; to repair one now, ask in the direct session to deliver its report again by
[docs/reporting.md](docs/reporting.md) → **Delivery** step 1 (the media are uploaded again, typed;
`update_artifact` keeps the share link). The old
mis-typed media artifacts are then unused; delete them in the app when you want to.

## 3.32.0 — 2026-10-25

**Upgrade:**
1. Create the schedule `quality-inspector-radar-3h` from its `kit.yaml` entry, verbatim and switched
   off ([ONBOARDING.md](ONBOARDING.md) Step 5); offer the operator to switch it on. Then
   `bash "$HOME/scripts/verify-onboarding.sh" --schedules /tmp/quality-inspector-schedules.json` and
   `bash "$HOME/scripts/modules.sh" schedules /tmp/quality-inspector-schedules.json`.
2. Nothing else to run: `work/PRSCAN.md` is created on the first radar run. New: the Change radar
   ([docs/radar.md](docs/radar.md)) reads the target's pull requests — title and description only,
   sanitized by `github.sh prs` through the issues listing, never a diff; no new egress rule — and opens
   maintenance proposals of kind `predicted` for the recurring tests a change names. The regression
   run's `maintenance.mjs sweep` now takes `--built <to.utc>`. `github.sh comments`, `comment` and
   `unlabel` now refuse a pull request.

## 3.31.0 — 2026-10-25

**Upgrade:**
Nothing to run — docs are re-read per run. New: from the next regression run on, step 3 opens
maintenance proposals before the replay ([docs/maintenance.md](docs/maintenance.md) → **Predicted
from the change context**): `obsolete`, `moved` and `renamed`, for a recurring test whose frozen block
names a control the UI map shows renamed, moved or removed, or that needs a page or interface that is
gone. The night's triage row of the test replaces such a proposal, and `maintenance.mjs sweep` closes
it when the test passes (`--unchanged`) or the triage absorbs the change (`--absorbed`). `impact.mjs`
now writes each hit's `type` and `block`. Existing rows of `work/MAINTENANCE.md` stay as they are.

## 3.30.0 — 2026-10-25

**Upgrade:**
Nothing to run — docs are re-read per run. New: intent tests ([docs/intent.md](docs/intent.md)).
From the next issue run on, an issue that states its purpose gets up to two `IN-<k>` tests: frozen in
`intent-<ac_hash>.md` with the issue's goal sentence quoted, checked by the judge, run red-green with
the criteria, and reported as `intent_verdict` beside the issue verdict, which they never change.
Issues tested before have no intent file: "test #N" gives them one. `check-asserts.sh --hash` now
covers IN blocks too; a promoted file without IN blocks keeps its `assert_hash`, so no drift. A "test #N"
that adds IN blocks to a promoted file changes its hash: the run opens a `drift` proposal at once, and the
nightly run skips the file until the operator accepts it, also under `auto_promote: verified`.

## 3.29.1 — 2026-10-25

**Upgrade:**
Nothing — docs are re-read per run.

## 3.29.0 — 2026-10-25

**Upgrade:**
Nothing to run — docs are re-read per run. New: a night whose environment fails writes why
(`work/regression/<candidate>/environment.json`: the failed step, cause, repair, next step and
evidence), shows it in the catalog's night panel, and posts it to `regression_channel` (🟠, or 🔴
from the second such night in a row). `env.sh up` and `reset` keep their whole output in
`work/env/last-up.log` / `last-reset.log`, and `env.sh wait` prints the end of a failed install.
Earlier failed nights have no file: the catalog says the cause was not recorded.

## 3.28.0 — 2026-10-25

**Upgrade:**
Nothing to run — docs are re-read per run, and `work/FEATURES.md` and `work/MAINTENANCE.md` are
created on first use by `scripts/features.mjs` and `scripts/maintenance.mjs`. New:
1. **Features** ([docs/features.md](docs/features.md)): from now on a test that becomes recurring
   goes into a feature, and "run feature …" (the direct session) or "test feature …" (Slack, within
   `slack_tests_per_day`) runs a feature's recurring tests. Tests promoted before have no feature:
   the operator may add them ("add #N to the feature <id>"), or ask the agent to propose features
   for the regression tier in the direct session ("propose features").
2. **Test maintenance** ([docs/maintenance.md](docs/maintenance.md)): the triage's `needs-review`,
   `superseded`, drift, quarantine and third-heal results open proposals `M-<k>` the operator answers
   with "accept / rewrite / retire / keep M-<k>"; "accept the review of #N" still works. Earlier
   nights' open items are not migrated: the next night opens what still holds.
3. The audit has two more checks, `features` and `maintenance`; the next catalog build shows the
   features, the open proposals and the feature runs.

## 3.27.0 — 2026-10-25

**Upgrade:**
1. In `work/CONFIG.md`, a key still at the old default moves to the new one:
   `e2e_version: 0.20.0` → `0.21.3`, `e2e_web_version: 0.14.0` → `0.15.3`. A value the
   operator chose differently stays. Under 0.20 every test that restores the setup session failed
   at its `app.screenshot()` with `POLICY_DENIED` and recorded a video without frames
   ([docs/test-authoring.md](docs/test-authoring.md) → **Upgrading `e2e`**). Both releases were
   two days old, an exception to the seven-day rule: no older release keeps screenshots and video
   after the setup's secret fill.
2. `bash "$HOME/scripts/suite.sh" init` — installs the new pins and re-checks that
   `playwright-core` (now 1.64.1) matches the image's browser.
3. Expect the next run of every test to record its steps again (the replay cache misses
   once across an `e2e` minor bump); no action.
4. Run the smoke test as in `ONBOARDING.md` Step 6 and `verify-onboarding.sh --live`.
5. A verdict of the last runs that is `blocked` or `failed` only by that `POLICY_DENIED` is no
   product result: tell the operator the issues, and test each again on their "test #N"
   ([docs/on-demand.md](docs/on-demand.md)).

## 3.26.1 — 2026-10-24

**Upgrade:**
Nothing to run. A link to another site on the catalog (a report, GitHub) now opens in a new tab also
when the page is drawn in a frame, or shows its address to copy. The next catalog build ships the page.

## 3.26.0 — 2026-10-24

**Upgrade:**
Nothing — the next catalog build ([docs/catalog.md](docs/catalog.md) → Build and publish) ships the
header with wrapped tabs, the day / night switch and a side panel that changes width by drag.

## 3.25.0 — 2026-10-24

**Upgrade:**
1. A report is now published as one file: `scripts/report-media.mjs` makes `publish.html` from the
   rendered report — public: each media file its own public artifact, linked by its address;
   private: the media inline ([docs/reporting.md](docs/reporting.md) → Delivery step 1). Reports
   published before show no video (their `media/` links answer 404). To repair one, publish its
   report directory again by the new step 1 as a new revision (`update_artifact`) when the operator
   asks; nothing else to run.
2. A verdicts file now carries `started_utc` (and `cost_usd` when the platform states the cost;
   [docs/reporting.md](docs/reporting.md) → Verdicts file): write them from the next run on. Older
   runs show their length from the logs, or none. The next catalog build ships the page.

## 3.24.0 — 2026-10-24

**Upgrade:**
Nothing — docs are re-read per run. The regression worklist's `profile_scenarios.deferred` is now a
list of the waiting scenarios (the same shape as `adopt[]`), not a count; the nightly summary names
them, `scenarios.sh queue` prints the whole adoption queue, and the next catalog build
([docs/catalog.md](docs/catalog.md) → Build and publish) shows it under Activity and Requests.

## 3.23.0 — 2026-10-24

**Upgrade:**
Nothing to run — the next catalog build ([docs/catalog.md](docs/catalog.md) → Build and publish) ships
the Test builder view. It sends the existing scenario request shape, and one new operator command,
`walk these steps live: …` ([docs/on-demand.md](docs/on-demand.md)); the live part needs `live_browser`
([docs/test-authoring.md](docs/test-authoring.md) → Watching live), else the walk runs headless.

## 3.22.0 — 2026-10-24

**Upgrade:**
Nothing to run — every session from the next one on names itself first, a scheduled run with the
pre-flight's new `title` ([docs/logging.md](docs/logging.md) → **Session titles**).

## 3.21.0 — 2026-10-24

**Upgrade:**
Nothing to run — the next catalog build ([docs/catalog.md](docs/catalog.md) → Build and publish) ships
the redesigned page. The operator command `open the report <id>` is gone: a private report on the
dashboard now shows a "private" mark that points to Artifacts in the app, and a report opens from the
page only by its share link (`report_visibility: public`, [docs/reporting.md](docs/reporting.md) →
Delivery). If the operator still types it, say that the report is in Artifacts in the app.

## 3.20.0 — 2026-10-23

**Upgrade:**
1. **Operator-only — the egress.** The kit now allows `POST` on `api.github.com`
   `/repos/*/*/issues` — opening an issue, only through `scripts/github.sh create-issue` on the
   operator's word — with the two denies beside it (`/repos/*/*/*/issues`, `/repos/*_2F*/issues`)
   ([docs/black-box.md](docs/black-box.md) → Egress rules). A kit never updates an existing agent's
   rules: recreate the agent from the kit, or give the operator what
   `bash "$HOME/scripts/egress-rules.sh" --kit` lists for these three rules (host, method, path) to add
   by hand. Until then "create issue for …" fails at the gateway; nothing else changes.
2. Optional config keys: `found_label` (default `qa:found`) and `fix_label` (no default — the label
   the software architect picks up). Ask the operator for `fix_label`; without it the dashboard
   offers no "for the architect".
3. Artifact text is now ASD-STE100 ([docs/reporting.md](docs/reporting.md) → **Artifact text is ASD-STE100**):
   write report notes and found issues so from now on; the next catalog build ships the rewritten page.
4. Nothing else — `work/design/DISMISSED.md` keeps its two columns until the next dismissal adds the
   reason column's rows; the next catalog build ships the new page.

## 3.19.0 — 2026-10-23

**Upgrade:**
Nothing to run — scripts and docs are re-read per run. A report's publish now writes its share link
to `artifact.url` beside `artifact.id` ([docs/reporting.md](docs/reporting.md) → Delivery step 1), and
the catalog links it, so the dashboard opens that report in one click; a report published before
gets the file at its next revision. Offer, never enable: with **`report_visibility: public`**
(default `private`) every report but the security run's is published as a public link anyone
holding it opens — for the dashboard only, never in an issue comment or a Slack answer but a
thread's under `slack_report_visibility: public`. Re-run `scripts/verify-onboarding.sh`: it now
knows the key.

## 3.18.0 — 2026-10-23

**Upgrade:**
Nothing — docs are re-read per run. A check is tested once: a scenario's criterion or an
exploration that would repeat what a `regression`-tier test, the security run, a module that is on,
or the profile's `## Tested elsewhere` list already checks is `testable: no — tested by <where>`
(an exploration is not written), and the judge flags it. A test's own earlier version (its
own id) never counts as elsewhere, for the judge's duplicate check too. An issue's ACs are exempt
([docs/test-authoring.md](docs/test-authoring.md) → **Tested once**).

## 3.17.0 — 2026-10-23

**Upgrade:**
Nothing — docs are re-read per run. From now on everything the agent writes is in English, its chat
included; product copy and words as received stay as written. Files written earlier stay as they are
([docs/acceptance-criteria.md](docs/acceptance-criteria.md) → Language).

## 3.16.0 — 2026-10-23

**Upgrade:**
Nothing — the next catalog build ([docs/catalog.md](docs/catalog.md) → Build and publish) ships the
linked viewer with back navigation. An address of the old page still opens (its keys are unchanged).

## 3.15.2 — 2026-10-23

**Upgrade:**
Nothing — the lint runs in every pre-flight. A product verb in a spec (run, delete, fetch,
open, post a comment, mark or report as passed) is an injection suspect only aimed at the agent
— an imperative at the sentence's start, after a leading word ("Then", "Next,") or after "please",
or in a sentence that addresses a QA agent — or at the tracker or the issue itself. "asks the agent to open a pull request" stays a
criterion now ([docs/acceptance-criteria.md](docs/acceptance-criteria.md) → Injection suspects).

## 3.15.1 — 2026-10-23

**Upgrade:**
Nothing — docs are re-read per run. "test scenario <slug>" now releases its own lock,
`env.sh unlock P-<slug>`, after the reply and on every abort. Before, the `S-<k>` unlock of
pipeline step 12 did nothing and left the lock held ([docs/scenarios.md](docs/scenarios.md) → Profile
scenarios → On demand).

## 3.15.0 — 2026-10-23

**Upgrade:**
1. `bash "$HOME/scripts/hooks/install.sh"`, effective from the next session: it registers the trace
   hook ([docs/logging.md](docs/logging.md) → Harness trace), and on Claude Code 2.1.101 or newer
   also the backup on an API-error stop. Re-running changes nothing; until then the audit's
   `trace_hooks` warns.
2. `bash "$HOME/scripts/verify-onboarding.sh"` and read its `trace_hook` line: a harness older than
   2.1.101 leaves failed tool calls untraced until the platform upgrades it — then repeat step 1.

## 3.14.0 — 2026-10-23

**Upgrade:**
Nothing to run — scripts and docs are re-read per run. Every `suite.sh run <label>` now runs as
a harness background task, followed by the new `suite.sh wait <label>` (exit 0 prints the
summary, 3 = call again), like `env.sh up` / `wait` ([docs/nested-env.md](docs/nested-env.md) →
Shape); both background tasks pass the tool a two-hour `timeout`, or a scheduled run stops
them at 30 minutes. `env.sh unlock` now refuses while a background suite run still runs.
A test whose criterion waits minutes sets its own `timeout`
([docs/test-authoring.md](docs/test-authoring.md) → Long waits). "test scenario <slug>" now
resets the nested product before the candidate comes up ([docs/scenarios.md](docs/scenarios.md)
→ Profile scenarios → On demand).

## 3.13.0 — 2026-10-23

**Upgrade:**
Nothing to run — scripts and docs are re-read per run. An answer in a Slack thread (a "test #N"
report, a scenario's reply) now carries one picture of the screenshots behind its verdicts
(`scripts/evidence-sheet.mjs`, from the report's new `proof.json`). It, a status answer, the
scenario digest and the nightly summary post a link only where one opens in Slack — the
report's or the dashboard's share link (once the operator shares the dashboard), never a
`platform://` reference. A Slack "test #N" report reply now goes after the catalog is published,
so the run is already there ([docs/slack.md](docs/slack.md) → **The answer in the thread**).
Offer, never enable: with **`slack_report_visibility: public`** (default `private`) a report answered in a thread is
published as a public link anyone holding it opens, posted in that thread only — never in a
status answer or an issue comment. `kit.yaml`'s Slack note changed wording only.

## 3.12.1 — 2026-10-23

**Upgrade:**
Nothing to run — scripts are re-read per run. A scheduled run is now known by the
`<qi-scheduled-run>` line its Precheck puts into the prompt, not by a run marker younger than
`lock_ttl_min`: a direct session opened soon after a scheduled run (the **Update** button's
included) is no longer refused `git fetch origin`, commits or `work/CONFIG.md` edits. A
`scheduled …` line left in `work/env/RUN_MODE` means nothing now. A Slack-ordered "test #N" is
marked only when the shell knows its session id, and its marker no longer expires.

## 3.12.0 — 2026-10-23

**Upgrade:**
Nothing to run. On the dashboard's next build, a tab or a navigation button walks the Product map
to the page it led to where the current UI map recorded it. From the next regression run on, the UI
map records where each link leads, the first row of a list per detail page, and every tab per page
([docs/change-awareness.md](docs/change-awareness.md)), so links, list rows and tabs walk too.

## 3.11.1 — 2026-10-23

**Upgrade:**
Nothing to run — scripts are re-read per run. The short locks (`work/scenarios/.lock`,
`work/env/LOCK.mutex`, the `work/` backup's lock) are now files, not directories; a lock directory
an older version left behind is removed on its own once it is past its age limit.

## 3.11.0 — 2026-10-23

**Upgrade:**
Nothing to run — only the `qi-profile-creator` skill changed, which a product team runs on its
own profile and an instance never does.

## 3.10.1 — 2026-10-23

**Upgrade:**
Nothing to run — the policy hook and the engine are re-read per call. In a scheduled run or a
channel turn the policy hook now also allows `modules.sh status|due|ran|focus-done|check|value|schedules` and a
read-only command naming it with `2>&1`/`2>/dev/null` and pipes into `jq|head|tail|grep|egrep|fgrep|wc`,
`$HOME/` written as such ([docs/modules.md](docs/modules.md) → Control). On the `helm-k3s`
engine, `env.sh reset` now removes every image no container uses, and `up` does so while the
k3s data volume has less than `engine_config.prune_below_gi` free (default 20 Gi). Where an
install was refused for disk space: once, **"reset the environment"**
([docs/on-demand.md](docs/on-demand.md)) — it holds the environment lock — frees the earlier
builds' images.

## 3.10.0 — 2026-10-22

**Upgrade:**
Nothing to run. On the dashboard's next build: Overview opens with **Activity** — what the agent
tests now (with its time budget), the queue, the schedules (from `work/schedules.json`, empty until
the agent next lists them) and the last 14 days of runs; the catalog is now
also published when a run claims an issue or a scenario. A report opens through "Open the report"
(the command `open the report <id>`, answered with the report's chip in the chat), and the Product
map draws every control — dashed where no test names it — with navigation items and links walking
to the page they lead to.

## 3.9.2 — 2026-10-22

**Upgrade:**
Nothing to run — scripts are re-read per run. A profile's `bin/<cmd>` now counts without its
exec bit and starts through the interpreter its `#!` line names (`bash` when it has none).
On a profile installed as plain files, its own `bin/env`, `bin/versions`, `bin/build-time` and
`bin/sandbox` now run where the engine's commands (or nothing, for `sandbox`) ran before:
1. `bash "$HOME/scripts/verify-onboarding.sh" --config` and read the `profile_bin:*` lines —
   each names the command that now runs.
2. `bash "$HOME/scripts/verify-onboarding.sh" --live` once to see the sandbox accounts checked.

## 3.9.1 — 2026-10-22

**Upgrade:**
1. Only where the profile lists `egress`: `bash "$HOME/scripts/egress-rules.sh"` and have the
   operator add each `by-hand` profile row the agent's network settings do not hold yet
   ([docs/black-box.md](docs/black-box.md) → Egress rules). New `by-hand` row: one that said
   `kit` but falls under a longer kit deny (a sandbox repository's
   `GET /repos/<owner>/<repo>/<rest>`) — no prompt appears for it.
2. Nothing to run for the suite: a test removes its sandbox leftovers only after its last
   criterion passes ([docs/test-authoring.md](docs/test-authoring.md) → Clean up only after a
   pass); a repair of a sandbox test follows it from the next run.

## 3.9.0 — 2026-10-22

**Upgrade:**
1. Nothing to run for the kit: the black-box probes gain the target's web pages on the next
   run ([docs/black-box.md](docs/black-box.md) → The gate).
2. Only where the profile's sandbox now lists git requests to its repository or the OAuth sign-in on `github.com`
   or the target's GitHub Enterprise host
   ([docs/black-box.md](docs/black-box.md) → Sandbox accounts): `bash "$HOME/scripts/egress-rules.sh"`
   and have the operator add its `by-hand` rows in the agent's network settings (on a GitHub
   Enterprise target every such row is `by-hand`, under that host's shared deny), then
   `bash "$HOME/scripts/sandbox.sh" template` for the new credential lines, which the operator
   fills in `work/env/credentials.env` — never in chat.

## 3.8.0 — 2026-10-22

**Upgrade:**
Nothing to run. The dashboard's Product map gains "Ask for a test" on its next build: a page or
control plus the person's own words become a scenario request ([docs/scenarios.md](docs/scenarios.md)
→ A request from the dashboard); a viewer the operator shared the page with may ask too, within
`max_scenarios_per_day`.

## 3.7.0 — 2026-10-22

**Upgrade:**
1. Create the schedule `quality-inspector-modules-nightly` from `kit.yaml` if
   `mcp__platform-outbound__list_schedules` lacks it (ONBOARDING.md Step 5); it declines while
   every module is off. Then `bash "$HOME/scripts/modules.sh" schedules` with that listing.
2. `bash "$HOME/scripts/verify-onboarding.sh"` and apply every `FAIL` line's `fix:`. The new
   `work/CONFIG.md` keys may stay missing: each reads as its default (every module off).
3. `bash "$HOME/scripts/suite.sh" init` — installs axe-core into the suite for the UI sweep.
4. Offer the operator the testing modules ([docs/modules.md](docs/modules.md)): `ui_sweep`,
   `validation_checks`, `stress_checks` (`per-build` or `weekly`) and a feature focus — never
   switch one on unasked.
5. **operator-only:** to send the dashboard's commands with a click, switch on Interactive
   artifacts in the platform; then the operator's "module global set dashboard_interactive=enabled"
   — the next catalog publish creates a new, interactive artifact ([docs/catalog.md](docs/catalog.md)
   → Build and publish); the operator deletes the old one.

## 3.6.0 — 2026-10-22

**Upgrade:**
1. Nothing to run: the new version re-runs the black-box probes on the next run
   ([docs/black-box.md](docs/black-box.md) → The gate). They now also go through `git
   ls-remote` (HTTPS and SSH) and a GraphQL query for the target's tree, and an answer from
   GitHub itself fails whatever its status. A new `boundary_breach` is reported as before;
   a new `warn boundary:ssh:…` (an SSH server answers) goes to the operator as an
   **operator-only** request to the platform to block SSH to code hosts.
2. The gate now also runs `scripts/hooks/install.sh --check` once a day: when it fails, run
   `bash "$HOME/scripts/hooks/install.sh"` in the direct session (ONBOARDING.md Step 2e).
3. A breach is also posted to `regression_channel`, else `slack_channel`, when one is set
   ([docs/black-box.md](docs/black-box.md) → The gate). With neither set, offer the operator
   `regression_channel` — the offer, never the setting.

## 3.5.0 — 2026-10-22

**Upgrade:**
Nothing to run. The catalog gains the Runs and Product map views and "as of a build" on its next
build ([docs/catalog.md](docs/catalog.md)); the map's clickable controls appear once the next
regression run records a UI map with `boxes` — until then its pages show without them.

## 3.4.0 — 2026-10-20

**Upgrade:**
1. Nothing is required: a profile without a `sandbox` section works as before, and
   `scripts/sandbox.sh status` says so.
2. When the installed profile declares sandbox accounts
   ([docs/profile-contract.md](docs/profile-contract.md) → `sandbox`): offer the operator
   ONBOARDING.md Step 3a in the direct session — the guides, `sandbox.sh template`, the new
   `by-hand` egress rows of `bash "$HOME/scripts/egress-rules.sh"`, `sandbox.sh check`. Until
   then `verify-onboarding.sh` names the empty credentials and the criteria that need the
   accounts stay `testable: no`.
3. Nothing to run for the `helm-k3s` engine: it now fills `{{sandbox:<id>.<NAME>}}` and applies
   `when: "@sandbox:<id>"` overlays, fills `{{gateway_ip}}` (the VM gateway's address, for a nested
   platform's egress policy), and reads `credentials.env` with `export` and quotes. A test run and
   the `e2e` MCP server now have `QI_PROFILE_CONFIG` (the profile's config) in their environment.
4. A profile egress row now listed `refused` is never added: on a GitHub host only the
   sandbox shapes pass ([docs/black-box.md](docs/black-box.md) → Sandbox accounts). If the
   operator added such a rule earlier, ask them to delete it from the agent's network settings.

## 3.3.0 — 2026-10-20

**Upgrade:**
1. In `work/CONFIG.md`, a key still at the old default moves to the new one:
   `e2e_version: 0.17.0` → `0.20.0`, `e2e_web_version: 0.12.0` → `0.14.0`. A value the
   operator chose differently stays.
2. `bash "$HOME/scripts/suite.sh" init` — installs the new pins and re-checks that
   `playwright-core` matches the image's browser.
3. Expect the next run of every test to record its steps again (the replay cache misses
   once across an `e2e` minor bump); no action.
4. Run the smoke test as in `ONBOARDING.md` Step 6 and `verify-onboarding.sh --live`.

## 3.2.0 — 2026-10-20

**Upgrade:**
1. **Operator-only — the egress.** The kit now allows `GET` on `github.com` for two release files a
   helm-k3s profile applies: `/cert-manager/cert-manager/releases/download/v*/cert-manager.yaml`
   and `/kubernetes-sigs/gateway-api/releases/download/v*/standard-install.yaml`
   ([docs/black-box.md](docs/black-box.md) → Egress rules). A kit never updates an existing
   agent's rules: recreate the agent from the kit, or have the operator add these two allows in
   the agent's network settings. `bash "$HOME/scripts/egress-rules.sh"` now lists rules as host,
   method, path and why with how each lands (`prompt`, `by-hand`, `kit`) — never commands; give
   the operator its `by-hand` rows in those words, then run
   `bash "$HOME/scripts/verify-onboarding.sh" --egress` and have the operator approve each prompt.
2. The suite skeleton changed; `suite.sh init` copies only missing files, so bring
   `work/suite` up to it, keeping any operator change:
   - `grep -q "role === 'owner'" "$HOME/work/suite/e2e.config.ts"` fails → take the
     `credentials` filter of `scripts/suite-skeleton/e2e.config.ts` (a role without a password
     is left out; e2e refuses an empty one).
   - `grep -q "getByRole('main')" "$HOME/work/suite/tests/smoke.e2e.ts"` fails → copy the
     skeleton's `tests/smoke.e2e.ts` (it waits for the page before judging it).
   - `grep -q QI_CANARY_THING "$HOME/work/suite/tests/canary.e2e.ts"` fails → keep the old file as
     `canary.e2e.ts.pre-3.1` outside `tests/`, copy the skeleton's, and tell the operator: the
     object it creates now comes from the profile's `canary` ([docs/profile-contract.md](docs/profile-contract.md)).
3. A standing operator preference kept anywhere else (the harness memory, a note in chat) moves
   to `work/OPERATOR.md`, one dated line each (docs/persistence.md → **Operator preferences**).
4. Nothing to run for the rest: `verify-onboarding.sh --models` lists the models that answer,
   a 429 is reported as a rate limit, a restore without `work/VERSION` migrates from 1.0.0 and
   drops obsolete `CONFIG.md` keys itself.

## 3.1.0 — 2026-10-20

**Upgrade:**
1. Nothing is required: the two new keys default when missing — `profile_scenarios: enabled`,
   `regression_channel` empty. Add both lines to `work/CONFIG.md` to make them visible.
2. Optional — the product team's scenarios: a profile may now carry `scenarios/<slug>.md`
   ([docs/profile-contract.md](docs/profile-contract.md) → `scenarios/`). The nightly regression
   run (`quality-inspector-regression-nightly`, off by default) adopts each new or changed
   one — freezes its criteria, writes and runs its test, registers it in the regression
   tier without an operator "promote" — and retires one whose file is gone. Turn the schedule
   on to use them; set `profile_scenarios: disabled` to ignore them.
3. Optional — set `regression_channel` to a Slack conversation bound to this agent for the
   nightly summary post.

Cost: an adoption costs about what a scenario run does (a few hundred thousand tokens),
only for a new or changed text, at most `max_scenarios_per_run` a night; a night with no
new build and no changed text still wakes no model. Replays cost as other promoted tests.

## 3.0.2 — 2026-10-16

**Upgrade:**
Nothing — the policy hook runs from the checkout. In a channel turn the `channel-write` rule
is now a closed set: a command naming `github.sh`, `comment` or `unlabel` passes only as one
plain `github.sh` call or one plain read-only command, and no file naming `github.sh` is
written ([docs/slack.md](docs/slack.md)).

## 3.0.1 — 2026-10-16

**Upgrade:**
Nothing — the policy hook runs from the checkout. In a channel turn it now refuses
`comment|unlabel` after any path, script, expansion or glob but a literal `github.sh` path,
and an expansion after the path a command runs, after dropping quotes and redirections
(rule `channel-write`).

## 3.0.0 — 2026-10-15

**Upgrade:**
1. **Operator-only — the egress.** A kit never updates an existing agent's rules: recreate the
   agent from the kit, or apply what `bash "$HOME/scripts/egress-rules.sh" --kit` prints and
   delete the rules 2.x printed for this instance (`dam network list "$AGENT"`): the allows on
   `/repos/<target>/…`, `/repos/<definition>/*`, `github.com/<definition>/*`, the profile path
   and every `--source`. Until the probes pass, the black-box gate stops every run
   ([docs/black-box.md](docs/black-box.md) → The gate).
2. **Operator-only — the profile's home.** It moves to `.quality-inspector/<profile>/` of its
   repository (DAM: `qa/qi-profile-dam` → `.quality-inspector/qi-profile-dam` in
   `dam-agents/dam`), and its skill source's `path` becomes `.quality-inspector`
   ([docs/profile-contract.md](docs/profile-contract.md) → Where it lives).
3. Delete the `- profile_source_path:` line from `work/CONFIG.md` when present (obsolete).
4. `bash "$HOME/scripts/hooks/install.sh"` — the `github` rule and the wider deny list; they
   apply from the next session.
5. `bash "$HOME/scripts/verify-onboarding.sh"` and apply every `FAIL` line's `fix:`.
6. Local edits in the checkout (`git -C /home/agent status --porcelain`): turn them into a
   patch per [docs/self-modification.md](docs/self-modification.md) §8 and show it to the
   operator — the live definition is no longer edited.

## 2.22.0 — 2026-10-15

**Upgrade:**
1. Agent steps now send the model connection's placeholder instead of a literal key
   ([docs/test-authoring.md](docs/test-authoring.md) → Model access). When
   `grep -q createAnthropic "$HOME/work/suite/e2e.config.ts"` fails, keep the old file and
   take the new one:
   `cp "$HOME/work/suite/e2e.config.ts" "$HOME/work/suite/e2e.config.ts.pre-2.22"` and
   `cp "$HOME/scripts/suite-skeleton/e2e.config.ts" "$HOME/work/suite/e2e.config.ts"`, then
   `diff` the two and carry over any operator change to `system`/`context`. Until then
   `suite.sh run` refuses with a pointer here.
2. **Operator-only:** in the agent's setup, *Inject only into addressed requests* stays on
   (`requireConnectionAddress: true` in `kit.yaml` reaches new agents only). On an agent
   where it is off, turn it on; the platform restarts the agent's gateway.
3. `bash "$HOME/scripts/verify-onboarding.sh" --live` — `model_provider` now makes one model
   call the way the tests do; apply its `fix:` when it fails.

## 2.21.0 — 2026-10-15

**Upgrade:**
Nothing — a `helm-k3s` prerequisite of kind `manifest` may now name a `file` of the
profile instead of a `url`; profiles that use `url` work as before.

## 2.20.0 — 2026-10-15

**Upgrade:**
1. Nothing to migrate: the new `github_login` key is empty by default and `gh api user` stays
   the identity. An agent whose GitHub connection is a GitHub App (`gh api user` answers
   `403 Resource not accessible by integration`) asks the operator for the app's bot login
   (`<slug>[bot]`), writes `- github_login: <login>` into `work/CONFIG.md`, then re-runs
   `scripts/verify-onboarding.sh --live`.

## 2.19.0 — 2026-10-15

**Upgrade:**
1. Nothing to migrate for `kit.yaml` (`backend: vm`, memory 12Gi): it reaches new agents
   only. An agent the kit created before as a container cannot run a nested product that
   needs root — `verify-onboarding.sh --live` reports `vm_root`; recreating it on the vm
   backend is **operator-only**. On a laptop host runner, lowering a larger agent's memory
   to 12Gi in its settings is **operator-only** too.
2. Nothing to install for the Browser Panel button: with `live_browser` set, a direct
   session pastes what `scripts/env.sh watch` prints ([docs/test-authoring.md](docs/test-authoring.md) → Watching live).
   Reports and issue comments say "N of M criteria tested" from the next render.

## 2.18.1 — 2026-10-15

**Upgrade:**
Nothing — `kit.yaml` is read before create only; the change is its schema line and `docsUrl`.

## 2.18.0 — 2026-10-14

**Upgrade:**
1. Nothing to migrate for the environment lock: `work/env/LOCK` lines written before this
   version (no session) are still read, by age ([docs/nested-env.md](docs/nested-env.md) → Shape).
   k3s takes its low priority at its next start (a VM restart).
2. Offer, once, the new off-by-default features — the step is the offer; a yes writes the
   key ([docs/persistence.md](docs/persistence.md) → **Definition version & upgrade**):
   - `slack_channel: <chat id>` — people in that Slack chat order "test #N" and get the
     report in the thread ([docs/slack.md](docs/slack.md)). It needs the Slack channel
     connected to the agent (2.12.0); `describe_channel` for `slack` names the id.
     `slack_tests_per_day: 3` caps it.
   - `lend_model: enabled` — the nested product calls this agent's model by placeholder
     instead of a mock; tokens per product AI step, and only once the profile uses
     `QI_MODEL_*` or a `when: "@model"` overlay ([docs/profile-contract.md](docs/profile-contract.md)).
   - `live_browser: <CDP endpoint>` — when `/etc/AGENTS.md` names the shared browser's: the
     operator watches exploration in the Browser Panel, in a direct session whose
     transcript the shell finds. It needs `work/suite/e2e.config.ts` to carry the
     skeleton's `E2E_CDP_ENDPOINT` lines — without them, copy those two changes from
     `scripts/suite-skeleton/e2e.config.ts` (`diff` shows them).
3. Nothing to install for the policy hook: its rule `channel-write` now lets a Slack-ordered
   "test #N" post its issue comment and remove its retest label on that one issue; every
   other GitHub write in a Slack turn stays refused. It applies with the hook, from the next
   session ([docs/slack.md](docs/slack.md)).
4. Run `bash "$HOME/scripts/verify-onboarding.sh" --live` and apply every `fix:` — its new
   `lock_liveness` line says whether a dead run's lock is freed at once or after `lock_ttl_min`.

## 2.17.0 — 2026-10-14

**Upgrade:**
1. Seed `work/CATALOG.md` as in ONBOARDING.md Step 2b, only when it is missing.
2. Nothing to enable: `test_catalog` defaults to `enabled`, so the next run that changes the
   suite publishes the test catalog as a private artifact ([docs/catalog.md](docs/catalog.md));
   tell the operator, who shares it in the app or sets `test_catalog: disabled`.
3. Run `bash "$HOME/scripts/verify-onboarding.sh"` and apply every `fix:`.

## 2.16.0 — 2026-10-14

**Upgrade:**
1. Run `bash "$HOME/scripts/hooks/install.sh"` — it adds the Stop backup hook, a no-op until
   `work_repo` is set; it applies from the next session.
2. Offer `work_repo` (unset = local-only): a private repository the Stop hook backs `work/` up
   to after every turn, so the suite, replay cache, criteria and state survive a lost volume or
   a move to another pod ([docs/persistence.md](docs/persistence.md) → **Backup & restore**). On a
   yes — **operator-only:** create the private repository (empty), give the connection's account
   Contents read & write on it, protect its `main` for that account where the GitHub plan offers
   protection on a private repository, run the work backup lines
   `bash "$HOME/scripts/egress-rules.sh"` prints; then write the key and run
   `bash "$HOME/scripts/work-backup.sh" persist` and `… check` in the direct session.
3. Run `bash "$HOME/scripts/verify-onboarding.sh" --live` and apply every `fix:`.

## 2.15.0 — 2026-10-14

**Upgrade:**
1. **operator-only, with `profile_source_path` set:** first make sure the platform carries
   dam-agents/dam#4909 (README → Runtime requirements) — before it, the profile allow
   opens the repository through `<path>/..`. Then run the commands
   `bash "$HOME/scripts/egress-rules.sh"` prints, skipping the rules the agent already
   has: the new `GET /repos/<T>` and `GET /repos/<T>/git/refs/heads/*` allows, which the
   platform's scan of a private source needs ([docs/black-box.md](docs/black-box.md) →
   **Egress rules**).
2. Run `bash "$HOME/scripts/verify-onboarding.sh" --live` and apply every `fix:`. Its new
   probe `boundary:…/issues/<n>/TIMELINE` fails or warns on every agent until the platform
   carries dam-agents/dam#4909.

## 2.14.2 — 2026-10-14

**Upgrade:**
Nothing — only the offline suite's runner changed.

## 2.14.1 — 2026-10-14

**Upgrade:**
Nothing — engine scripts are read per run.

## 2.14.0 — 2026-10-14

**Upgrade:**
Nothing — the `qi-profile-creator` skill (`skills/`) is for product teams writing a
profile, and the helm-k3s engine's `bin/check` runs only when a profile is checked;
neither runs on a deployed instance.

## 2.13.0 — 2026-10-14

**Upgrade:**
1. Add `- profile_source_path: <path>` to `work/CONFIG.md` unless present: the skill
   source's path when the profile's source is `target_repo` (for DAM: source
   `dam-agents/dam`, path `qa`), else empty.
2. **operator-only:** run the commands `bash "$HOME/scripts/egress-rules.sh"` prints (add
   `--source <owner>/<repo>` per other GitHub skill source), skipping the rules the agent
   already has, then delete the target rules it no longer prints — among them the
   `…/contents/<path>*` allow of 2.2.0 ([docs/black-box.md](docs/black-box.md) → **Egress
   rules**). The target's GitHub hosts become deny-by-default: forks, other-case spellings
   of the target and other repositories were readable.
3. Run `bash "$HOME/scripts/verify-onboarding.sh" --live` and apply every `fix:` — the
   probes now also cover the target in the other case and a dot segment out of the
   profile's directory, and check that directory is readable and symlink-free. A `fail`
   on `…/contents/<path>/..` is the platform's gateway: its `fix:` empties
   `profile_source_path` and drops the profile allows; report the gateway.

## 2.12.0 — 2026-10-14

**Upgrade:**
1. Seed `work/SCENARIOS.md` and `work/scenarios/` as in ONBOARDING.md Step 2b (only what
   is missing).
2. Create the schedule `quality-inspector-scenarios-weekly` from its `kit.yaml` entry,
   **disabled**, unless it exists (ONBOARDING.md Step 5).
3. Offer `scenario_discovery: propose` (weekly judged scenario proposals) or `run` (also
   tested, a few hundred thousand tokens per scenario), and `scenario_channel` for their
   Slack digest — off when unanswered ([docs/scenarios.md](docs/scenarios.md)).
4. **operator-only:** to take scenario requests from Slack, connect a channel to the agent
   on the platform. The policy hook treats its turns as non-direct by itself.
5. Run `bash "$HOME/scripts/verify-onboarding.sh"` and apply every `fix:`.

## 2.11.0 — 2026-10-14

**Upgrade:**
1. **operator-only:** run the commands `bash "$HOME/scripts/egress-rules.sh" --kit`
   prints, skipping the rules the agent already has ([docs/black-box.md](docs/black-box.md)
   → **Egress rules**): the kit's denies (GraphQL, code search, `/repositories/*`, gists,
   the code hosts) and `GET` denies for the target's issue timelines and events — the
   earlier method-`*` ones lost to the `GET` issues allow.
2. Run `bash "$HOME/scripts/verify-onboarding.sh" --live` and apply every `fix:` — the
   probes now also cover GraphQL, code search, a repository by number, the target's web
   archive and the code hosts, and report a `404` as unproven instead of refused.

## 2.10.0 — 2026-10-14

**Upgrade:**
1. Offer the operator the new `work/CONFIG.md` keys at their defaults, adding only the
   ones the file lacks (`grep -q '^- <key>:' work/CONFIG.md` first):
   `max_wallclock_min_per_issue: 150`, `max_model_steps_per_issue: 400` (per-issue
   budgets, [docs/nested-env.md](docs/nested-env.md) → **Budgets**) and
   `min_free_disk_gi: 10` (`env.sh up` refuses below it). Keep `lock_ttl_min` above the
   wall-clock budget.
2. Unless an event of the last 14 days already has `"event":"ledger_start"`
   (`grep -l '"event":"ledger_start"' work/logs/events-*.jsonl`), log one:
   `. "$HOME/scripts/log.sh"; logev info ledger_start "external-write ledger begins"` —
   the audit's `ledger_reconcile` does not judge comments older than it.
3. Run `bash "$HOME/scripts/verify-onboarding.sh" --config` and apply every `fix:`.

## 2.9.0 — 2026-10-14

**Upgrade:**
1. Run `bash "$HOME/scripts/verify-onboarding.sh" --config` — it now knows
   `confirm_regressions` and `bisect_max_steps`; apply every `fix:`.
2. Offer once per key not yet in `work/CONFIG.md`, never enable unasked (missing = off):
   `- confirm_regressions: enabled` re-runs an unexplained regression on the previous
   build before reporting it — one extra install (15–25 min) on a night with one, none
   otherwise; `- bisect_max_steps: <n>` (needs the former) narrows a confirmed regression
   over the builds in between — up to n more installs, 15–25 min each
   ([docs/triage.md](docs/triage.md) → **Order of work**).
3. **operator-only**, optional: the profile's maintainers may add `interfaces` (`cli`,
   `openapi`) to its `profile.json`, and `bin/versions --between` to a profile with its
   own `bin/versions` ([docs/profile-contract.md](docs/profile-contract.md)); the
   interface snapshots then start on their own. Nothing else to run.

## 2.8.0 — 2026-10-14

**Upgrade:**
1. `mkdir -p "$HOME/work/security"`; `touch "$HOME/work/SECURITY.log"`.
2. Missing schedule `quality-inspector-security-weekly` → create it from its `kit.yaml` entry
   verbatim (cron, `sessionMode: fresh`, precheck, task), **disabled**. Offer once to enable
   it: frozen security checks of each new candidate, findings in a private artifact only
   ([docs/security.md](docs/security.md)). Footprint: one product reset + install per new
   candidate (time, no tokens), the script half without model calls, the e2e half and the
   report ~50–150k tokens — under 1M a month.
3. Offer once: `security_checks` (default `enabled`; `disabled` idles the security pre-flight)
   and `security_failed_logins` (default `10`). A yes writes the key; no answer writes nothing.
4. Re-run `bash "$HOME/scripts/suite.sh" init` (adds `tests/security.e2e.ts`). Older UI maps
   lack `api_requests`; the security pre-flight treats them as missing, so the run rebuilds them.
5. **operator-only:** full coverage needs the profile's `VIEWER`/`OUTSIDER` accounts,
   `security.entity` and optionally `suite/lib/security-api.ts`
   ([docs/profile-contract.md](docs/profile-contract.md)); without them those checks skip with the reason.
6. Run `bash "$HOME/scripts/verify-onboarding.sh"` and apply every `fix:`.

## 2.7.0 — 2026-10-14

**Upgrade:**
1. Run `bash "$HOME/scripts/suite.sh" init` — it adds `work/suite/tests/canary.e2e.ts`
   (missing files only; existing tests are untouched).
2. Unless `work/suite/e2e.config.ts` already contains `dataNotInstructions`, copy that
   constant and the `agents:` line from `scripts/suite-skeleton/e2e.config.ts` into it
   (`init` never overwrites an existing config).

## 2.6.0 — 2026-10-14

**Upgrade:**
1. `work/COVERAGE.md` missing → create it with the `COVERAGE.md` block of
   [ONBOARDING.md](ONBOARDING.md) Step 2b (header only; the next regression run fills it).
2. Offer `auto_promote: verified` — the issues run promotes tests whose every criterion
   was verified red-green into the nightly regression without the operator's "promote"
   (missing key = `disabled`; [docs/regression.md](docs/regression.md) → Tiers).
3. Run `bash "$HOME/scripts/verify-onboarding.sh"` and apply every `fix:`.

## 2.5.0 — 2026-10-14

**Upgrade:**
1. Offer the explorations layer ([docs/explorations.md](docs/explorations.md)): scenarios
   derived from each AC (negative paths, persistence, roles…), run on the candidate only and
   reported under "Beyond the criteria", never in a verdict. It is on by default; when
   `work/CONFIG.md` lacks `explorations` or `max_explorations_per_ac`, add the key with the
   operator's choice (defaults `enabled`, `3`). Cost per issue: at most 3 × its testable ACs
   extra tests and one extra candidate run (no install, video for failures only) — roughly
   +30–60 % of the issue's first-run tokens; nothing nightly (explorations are never
   replayed). Per month: that × the issues tested.
2. Run `bash "$HOME/scripts/suite.sh" init` (it copies missing skeleton files only). Then,
   when `work/suite/e2e.config.ts` has no `member` credential, replace its `credentials`
   with the four-role block of `scripts/suite-skeleton/e2e.config.ts`; when
   `work/suite/tests/auth.setup.e2e.ts` has no `ROLES`, adopt the skeleton's role loop,
   keeping the file's own sign-in steps and the `owner` session name.
3. **operator-only, optional:** ask the profile's maintainers for `MEMBER` / `VIEWER` /
   `OUTSIDER` accounts ([docs/profile-contract.md](docs/profile-contract.md)); without them
   `roles-isolation` explorations are `blocked`.
4. Run `bash "$HOME/scripts/verify-onboarding.sh" --config` and apply every `fix:`.

## 2.4.0 — 2026-10-14

**Upgrade:**
1. `mkdir -p "$HOME/work/perf"` — the test-duration history of `scripts/perf-trend.mjs`.
2. Nothing else: UI maps recorded before 2.4.0 carry no page signals, so the first diff
   against one reports none ([docs/change-awareness.md](docs/change-awareness.md)); re-run
   `bash "$HOME/scripts/verify-onboarding.sh"` to confirm.

## 2.3.0 — 2026-10-14

**Upgrade:**
1. Run `bash "$HOME/scripts/hooks/install.sh"` — merges the policy hook and its deny list
   into `$HOME/.claude/settings.json`, keeping every other key; re-running changes nothing.
   It applies from the next session.
2. Schedule `quality-inspector-audit-weekly`: when its precheck is empty, set it to
   `bash "$HOME/scripts/precheck.sh" audit` (its `kit.yaml` entry) with the platform's
   schedule tools; leave its enabled state alone.
3. **operator-only:** if the product ships npm packages the suite installs, ask the
   profile's maintainers to list their scopes under `boundary.packages`
   ([docs/profile-contract.md](docs/profile-contract.md)).
4. Run `bash "$HOME/scripts/verify-onboarding.sh"` and apply every `fix:` until
   `policy_hook` is `ok`.

## 2.2.1 — 2026-10-14

**Upgrade:**
1. **operator-only:** replace the egress allow `DELETE api.github.com /repos/<T>/issues/*/labels/*`
   with the retest label only, `…/labels/<RL>` (README → Black-box boundary); skip when it
   is already narrowed.
2. Mask the runs written before this version (idempotent):
   `for d in "$HOME"/work/suite/.e2e/runs/*/; do node "$HOME/scripts/lib/secrets.mjs" mask "$HOME/work/env/credentials.env" "$d"; done`
   — the audit's `secrets_in_runs` confirms it.
3. Nothing else: markers now count only in the agent's own comments; if the GitHub
   account changed since the first comment, expect at most one repeated comment per issue.

## 2.2.0 — 2026-10-13

**Upgrade:**
1. **operator-only:** the profile is assigned on the platform now, and the DAM profile
   moved into the DAM repository: add the source `https://github.com/dam-agents/dam` with
   path `qa`, assign `qi-profile-dam`, and add the egress allow
   `GET api.github.com /repos/<T>/contents/qa*` (README → Black-box boundary). Remove the
   old `quality-inspector-profiles` source if one was added.
2. The DAM profile now runs on the `helm-k3s` engine; its `profile.*` keys are unchanged.
3. Run `bash "$HOME/scripts/verify-onboarding.sh" --live` and apply every `fix:`.

## 2.1.1 — 2026-10-13

**Upgrade:**
1. **operator-only:** replace the egress rules with README → Black-box boundary: issue
   patterns end in `*` (the matched path includes the query string), explicit denies for
   `…/issues/*/timeline*` and `…/issues/*/events*`, and codeload denied for the target's
   path only (a host-wide codeload deny breaks skill installs).
2. Run `bash "$HOME/scripts/verify-onboarding.sh" --live` — the boundary probes now also
   cover issue events.

## 2.1.0 — 2026-10-13

**Upgrade:**
1. `mkdir -p "$HOME/work/benchmark"`.
2. Create the schedule `quality-inspector-benchmark-monthly` from its `kit.yaml` entry
   (name, cron, `sessionMode: fresh`, precheck, task text verbatim), **disabled** — a
   suggested schedule the operator turns on once `work/benchmark/cases.json` holds cases
   ([docs/benchmark.md](docs/benchmark.md)).
3. Offer once: writing a first set of benchmark cases with the operator.

## 2.0.0 — 2026-10-13

**Upgrade:** (major — the product moved into a profile)
1. **operator-only:** connect the skill source holding the product's profile (for DAM:
   `https://github.com/dam-agents/quality-inspector-profiles`), then install it as in
   `ONBOARDING.md` Step 2 and write `- profile: <name>` into `work/CONFIG.md`.
2. Move the product keys into the profile's namespace, keeping their values:
   `chart_ref`, `mock_image`, `istio_version`, `cert_manager_version`,
   `gateway_api_version`, `helm_version` → `profile.<same key>`. Delete the old bullets.
   Empty `candidate_channel` / `baseline_channel` now mean the profile's defaults.
3. `work/env/values.yaml` and `credentials.env` stay; the profile's `bin/env` reads them.
4. Run `bash "$HOME/scripts/verify-onboarding.sh" --live` and apply every `fix:`.

## 1.1.0 — 2026-10-12

**Upgrade:**
1. Seed the new state, only where missing (`ONBOARDING.md` Step 2 holds the exact
   seeds): `work/HEALS.md`, `work/FLAKY.md`, `work/inventory/`, `work/regression/`.
2. Re-run `bash "$HOME/scripts/suite.sh" init` — it adds `work/suite/lib/criterion.ts`
   from the skeleton. Existing tests keep working; wrap their AC blocks in `criterion()`
   when they are next touched ([docs/test-authoring.md](docs/test-authoring.md)).
3. Offer once: `spec_feedback: enabled` — comment a suggested observable "Done when" on
   issues with nothing testable (public, opt-in; missing key = disabled).
4. `media_retention_days` defaults to 14 when missing; nothing to write.
5. Run `bash "$HOME/scripts/verify-onboarding.sh"` and apply every `fix:`.

## 1.0.0 — 2026-10-02

**Upgrade:**
Nothing — initial version; onboarding records it (`work/VERSION`).
