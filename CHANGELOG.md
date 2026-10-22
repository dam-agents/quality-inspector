# Changelog

**Migration instructions, not a change log.** Per version, the idempotent **Upgrade**
steps a deployed instance applies when crossing it — what to run, update, or change
(schedules, config keys, state formats). Most versions need nothing. What changed and
why lives in the PR and commit history, not here. Consumed by the version check
([docs/persistence.md](docs/persistence.md) → **Definition version & upgrade**);
authoring rules: [docs/self-modification.md](docs/self-modification.md) §12.

## 3.9.0 — 2026-10-22

**Upgrade:**
1. Nothing to run for the kit: the black-box probes gain the target's web pages on the next
   run ([docs/black-box.md](docs/black-box.md) → The gate).
2. Only where the profile's sandbox now lists git requests to its repository or the OAuth sign-in on `github.com`
   ([docs/black-box.md](docs/black-box.md) → Sandbox accounts): `bash "$HOME/scripts/egress-rules.sh"`
   and have the operator add its `by-hand` rows in the agent's network settings — also a row that
   said `kit` before and says `by-hand` now (a longer kit deny beside the kit's allow), then
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
