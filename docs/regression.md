# Regression tier and the nightly run

## Tiers — `work/SUITE.md`

```
| test | issue | tier | assert_hash | promoted_utc |
| --- | --- | --- | --- | --- |
| tests/issue-42.e2e.ts | 42 | regression | 9c1e44a0f2b3 | 2026-10-03T08:12:40Z |
```

- `exploratory` — written by an issues run; `promoted_utc` is `-`. Not replayed nightly.
- `regression` — promoted by the operator ("promote #N" → [on-demand.md](on-demand.md)).
  `assert_hash` is the `scripts/check-asserts.sh --hash` value of its AC blocks; it changes
  only by a heal ([triage.md](triage.md), logged in `work/HEALS.md`) or by the operator.
- `retired` — superseded by a completed issue ([triage.md](triage.md)); kept, not replayed.
- `quarantined` — flaky on two builds within 14 days ([triage.md](triage.md) → Flaky tests
  and quarantine); kept, not replayed until the operator re-promotes it.

## The regression run

The worklist carries `candidate`, `previous_candidate` (the build last regression-tested,
`null` the first time), `tests[]` and `assert_drift[]` (`null` when the check could not
run — say so, never treat it as clean).

1. `env.sh lock regression` (busy → end the run, log it).
2. `env.sh reset`, `env.sh up <candidate>`, `suite.sh run smoke-<candidate> --tag smoke`.
   Failure → environment failure ([nested-env.md](nested-env.md) → Failures); append
   `<ISO> ERROR: environment candidate=<c>` to `work/REGRESSION.log`, unlock, end.
3. **Build the change context** ([change-awareness.md](change-awareness.md)): the UI map
   of the candidate, its diff against `previous_candidate`'s map, the completed issues in
   the window, the impact per test, and your one-line expectation per impacted test.
4. Drifted tests (`assert_drift`) are **not run** — list them for the operator.
5. Replay: `suite.sh run regression-<candidate> --evidence failures --tag issue-<a> --tag issue-<b> …`.
   `criterion()` judges a check whose control moved instead of failing it.
6. **Triage** every result that is not plain `unchanged` per [triage.md](triage.md):
   re-run without cache, look, check the context, decide, heal or retire where the rules
   allow. Re-run every healed file strictly.
7. **Report**: write `work/regression/<candidate>/verdicts.json` with `"mode": "regression"`
   — one entry per criterion that was not `unchanged`, each with `issue`, `id`, `name`,
   `then`, `verdict` (the category), `explanation`, `because_issue` when an issue explains
   it, `heal` `{from, to}` for a repair, and `before_shot` (the previous map's screenshot
   of the page). Add `context` `{previous, window, issues[{number,title}], ui_diff, signals}`
   (`ui_diff`: the diff's `--md` text; `signals`: `{console_errors_new, failed_requests_new,
   slower_pages, slow_tests}` — the diff's lists plus `slow_tests` from
   `node "$HOME/scripts/perf-trend.mjs" regression-<candidate>`, each item made a
   `needs-review` entry per [triage.md](triage.md) → **Signals no test covers**). Render it with `scripts/render-report.mjs` into
   `work/regression/<candidate>/report/` and publish as in
   [reporting.md](reporting.md) → Delivery (artifact only, its reference in
   `work/regression/<candidate>/artifact.id`; regression runs never comment).
   The run's top verdict is `regression` if any criterion is, else `needs-review` if any
   criterion or signal is, else `healed`, `relearned` or `unchanged`.
8. Append `<ISO> ran candidate=<c> unchanged=<n> relearned=<n> healed=<n> needs_review=<n> superseded=<n> flaky=<n> regression=<n> blocked=<n> drift=<n>`
   to `work/REGRESSION.log` — the pre-flight keys "already tested" and
   `previous_candidate` on `ran candidate=`.
9. `env.sh unlock regression`. Summary in the chat UI: regressions first, each with its
   evidence link; then what needs review; then one line of what was absorbed.
