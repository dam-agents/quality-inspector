# Changelog

**Migration instructions, not a change log.** Per version, the idempotent **Upgrade**
steps a deployed instance applies when crossing it — what to run, update, or change
(schedules, config keys, state formats). Most versions need nothing. What changed and
why lives in the PR and commit history, not here. Consumed by the version check
([docs/persistence.md](docs/persistence.md) → **Definition version & upgrade**);
authoring rules: [docs/self-modification.md](docs/self-modification.md) §12.

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
