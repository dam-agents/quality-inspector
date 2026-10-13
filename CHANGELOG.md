# Changelog

**Migration instructions, not a change log.** Per version, the idempotent **Upgrade**
steps a deployed instance applies when crossing it — what to run, update, or change
(schedules, config keys, state formats). Most versions need nothing. What changed and
why lives in the PR and commit history, not here. Consumed by the version check
([docs/persistence.md](docs/persistence.md) → **Definition version & upgrade**);
authoring rules: [docs/self-modification.md](docs/self-modification.md) §12.

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
