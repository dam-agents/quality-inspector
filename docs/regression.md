# Regression tier and the nightly run

## Tiers — `work/SUITE.md`

```
| test | issue | tier | assert_hash | promoted_utc |
| --- | --- | --- | --- | --- |
| tests/issue-42.e2e.ts | 42 | regression | 9c1e44a0f2b3 | 2026-10-03T08:12:40Z |
```

- `exploratory` — written by an issues run; `promoted_utc` is `-`. Not replayed nightly.
- `regression` — promoted by the operator only ("promote #N" → [on-demand.md](on-demand.md)).
  `assert_hash` is the `scripts/check-asserts.sh --hash` value at promotion time and is
  the frozen contract of that file's AC blocks.
- A test file whose issue's ACs changed stays at its tier with its old hash until the
  operator promotes the new version; the retest's new file content is `exploratory` drift.

## The regression run

The worklist carries `candidate`, `tests[]` and `assert_drift[]` (or `null` when the
check could not run — say so in the summary, do not treat it as clean).

1. `env.sh lock regression` (busy → end the run, log it).
2. `env.sh reset`, `env.sh up <candidate>`, `suite.sh run smoke-<candidate> --tag smoke`.
   Failure → environment failure ([nested-env.md](nested-env.md) → Failures); append
   `<ISO> ERROR: environment candidate=<c>` to `work/REGRESSION.log`, unlock, end.
3. Drifted tests are **not run** — list them as `drift` in the summary for the operator.
4. Run the rest: `suite.sh run regression-<candidate> --evidence failures --tag issue-<a> --tag issue-<b> …`
   (any-tag mode; video and steps are kept for failures only).
5. Per failing test: judge it like an AC ([reporting.md](reporting.md) → Verdicts, with
   no baseline). A test defect → repair outside the AC blocks per
   [test-authoring.md](test-authoring.md) and re-run that file once. A product failure →
   a **regression finding**: one line in the summary with the issue number, the AC and
   the evidence path. No issue comments from regression runs.
6. Summary to the chat UI and, with `artifact_reports: enabled`, one artifact per run.
   Append `<ISO> ran candidate=<c> passed=<n> failed=<n> drift=<n> replayed=<n> handed_off=<n> missed=<n>`
   to `work/REGRESSION.log` — the pre-flight keys "already tested" on `ran candidate=`.
7. `env.sh unlock regression`.

A cache that hands off or misses on most steps every night is a finding for the audit,
not something to fix by re-recording blindly.
