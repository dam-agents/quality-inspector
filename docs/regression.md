# Regression tier and the nightly run

## Tiers — `work/SUITE.md`

```
| test | issue | tier | assert_hash | promoted_utc |
| --- | --- | --- | --- | --- |
| tests/issue-42.e2e.ts | 42 | regression | 9c1e44a0f2b3 | 2026-10-03T08:12:40Z |
```

- `exploratory` — written by an issues run; `promoted_utc` is `-`. Not replayed nightly.
- `promotable` — written instead by an issues run when, in that run, every AC and every
  testable IN ([intent.md](intent.md)) in the file was `verified`, the file passed `--strict`
  on the candidate, no step inside an AC or IN block was `judged`, and `scripts/check-asserts.sh --agent-asserts <file>` prints nothing. Like
  `exploratory` otherwise (not replayed, not drift-checked); the queue for "promote all
  pending". A saved scenario joins it ([scenarios.md](scenarios.md) → Saving). With `auto_promote: verified` the issues run promotes such a file itself
  (tier `regression`, `assert_hash`, `promoted_utc` now) — the risk: an AC freeze the
  operator never read then gates every nightly run.
- `regression` — promoted by the operator ("promote #N", "promote all pending" →
  [on-demand.md](on-demand.md)), by `auto_promote: verified`, or — a profile scenario — by
  its adoption ([scenarios.md](scenarios.md) → **Profile scenarios**): merged in the
  product's repository, it needs no operator.
  `assert_hash` is the `scripts/check-asserts.sh --hash` value of its AC and IN blocks; it changes
  only by a heal ([triage.md](triage.md), logged in `work/HEALS.md`) or by the operator.
- `retired` — superseded by a completed issue ([triage.md](triage.md)), or a profile
  scenario's test whose file is gone or whose text changed ([scenarios.md](scenarios.md) →
  **Profile scenarios**); kept, not replayed.
- `quarantined` — flaky on two builds within 14 days ([triage.md](triage.md) → Flaky tests
  and quarantine); kept, not replayed until the operator re-promotes it.
- A scenario's row (`tests/scenario-<k>.e2e.ts`, `S-<k>` in the `issue` column) is tagged
  `scenario-<k>`, a profile scenario's (`tests/profile-<slug>.e2e.ts`, `P-<slug>`)
  `profile-<slug>`: wherever this file and [triage.md](triage.md) say `issue-<n>`, use that
  tag, and its report entries carry `scenario` instead of `issue`.

## The regression run

The worklist carries `candidate`, `previous_candidate` (the build last regression-tested,
`null` the first time), `replay`, `tests[]`, `assert_drift[]` (`null` when the check could
not run — say so, never treat it as clean), `profile_scenarios`, `channel`, and
`confirm_regressions` / `bisect_max_steps` ([triage.md](triage.md) → Order of work, steps 5–6).

- `profile_scenarios` — `{files, adopt[], retire[], deferred[]}`, or `null` with
  `profile_scenarios: disabled`: the profile's `scenarios/` against the `source=profile`
  rows of `work/SCENARIOS.md`. `adopt[]` (`id`, `slug`, `spec_hash`, `kind` new|changed|retry
  — `retry`: the same text, its adoption failed, blocked or flaky, taken on a new build only)
  holds at most `max_scenarios_per_run` entries, retries last. `deferred[]` (the same shape)
  names the rest, in the order a later night takes them: the texts past the cap, then the
  retries that wait for a new build. Not adopted tonight; listed by id in step 3a and step 9.
- `replay` — `false` when the candidate was already regression-tested and only profile
  scenarios changed, or when no test is in the regression tier yet: adopt and retire them
  (step 3a), replay nothing else, skip steps 3 and 4–6. Steps 7–10 still run; step 8 records the
  candidate.
- `channel` — `regression_channel`, or `null`: where step 9's summary goes.

1. `env.sh lock regression` (busy → end the run, log it).
2. `env.sh reset`, `env.sh up <candidate>`, `suite.sh run smoke-<candidate> --tag smoke`.
   Failure → environment failure: diagnose and try the one repair of
   [nested-env.md](nested-env.md) → Failures. Still failing → **the night without results**:
   1. Write `work/regression/<candidate>/environment.json` — `{"mode": "regression",
      "verdict": "environment", "candidate", "utc", "stage", "exit", "cause", "evidence", "repair", "next"}`:
      `utc` the write's time (the ERROR line's too); `stage` the step that failed — `reset`,
      `up`, `smoke` or `canary` ([nested-env.md](nested-env.md) → **The injection canary**);
      `exit` its exit code (`null` for a test); `cause` one or two sentences — what failed and
      why, as far as the evidence shows ("the image pull of `api` was refused by the egress
      gateway", "the pod `db` restarted 5 times: out of memory"), else "unknown: <what the
      output shows>"; `evidence` up to 30 lines that show it, as `env.sh wait` printed them or
      from `env.sh status` (credential values masked, never a line that holds one); `repair`
      what you tried and what it did; `next` what fixes it and whose it is (the operator's
      egress, disk space, a product defect — the build's, so a later build retries it, the
      pre-flight takes this candidate again the next night). In English, in ASD-STE100.
   2. Append `<ISO> ERROR: environment candidate=<c>` (the same `<ISO>`) to `work/REGRESSION.log`, unlock.
   3. The summary of step 9 is the failure only: in the chat UI, and with `channel` set as one
      `send_channel_message` to it, ledgered — every night, so a silent night is never a
      failed one: `🟠 Nightly regression <date> · build <candidate>: the environment failed —
      no test ran.` then `Step: <stage> (exit <n>)`, `Cause: <cause>`, `Repair: <repair>`,
      `Next: <next>`, up to 5 lines of `evidence` in a code block, and the catalog's link.
      `<n>` = the `ERROR: environment` lines of `work/REGRESSION.log` after its last
      `ran candidate=` line, tonight's included (other lines, `due` among them, do not count):
      from 2 it opens with 🔴 and `<n>. night in a row` instead.
   4. The catalog (step 10), then end.
3. **Build the change context** ([change-awareness.md](change-awareness.md)): the UI map
   of the candidate, its diff against `previous_candidate`'s map, the completed issues in
   the window, the published interfaces' diff, the impact per test, and your one-line
   expectation per impacted test; open the predicted proposals from the impact
   ([maintenance.md](maintenance.md) → **Predicted from the change context**). Rewrite `work/COVERAGE.md` from the new map
   ([change-awareness.md](change-awareness.md) → Coverage).
3a. **Profile scenarios** ([scenarios.md](scenarios.md) → **Profile scenarios**): each
   `retire[]` id, then each `adopt[]` entry — Adopt steps 1–6, the budgets counted per
   scenario. A newly registered test is in step 5's replay from the next night: its
   adoption run is tonight's result. List what was adopted, rejected and retired, and each
   `deferred[]` id with its `kind`, in the report's `notes`, with the adoption runs' verdicts
   as entries (`scenario`: `P-<slug>`).
4. Drifted tests (`assert_drift`) are **not run** — list them for the operator, each one a
   `drift` proposal ([maintenance.md](maintenance.md)).
5. Replay: `suite.sh run regression-<candidate> --evidence failures --tag issue-<a> --tag issue-<b> …`.
   `criterion()` judges a check whose control moved instead of failing it. Explorations
   (`issue-<n>-ex`) are never replayed in this version ([explorations.md](explorations.md)).
6. **Triage** every result that is not plain `unchanged` per [triage.md](triage.md):
   re-run without cache, look, check the context, decide, heal or retire where the rules
   allow. Re-run every healed file strictly. Every `needs-review`, `superseded`, quarantine and
   third heal in a month is a proposal ([maintenance.md](maintenance.md) → What opens a proposal).
7. **Report**: write `work/regression/<candidate>/verdicts.json` with `"mode": "regression"`
   — one entry per criterion that was not `unchanged`, each with `issue`, `id`, `name`,
   `then`, `verdict` (the category), `cause` for a `regression`, `needs-review`, `flaky` or
   `blocked` ([triage.md](triage.md) → **Cause**), `explanation`, `because_issue` when an issue explains
   it, `heal` `{from, to}` for a repair, `regressed_between` `{from, to, builds_between}`
   for a confirmed regression, and `before_shot` (the previous map's screenshot of the
   page). Add `context` `{previous, window, issues[{number,title}], ui_diff, iface_diff, signals}`
   (`ui_diff`, `iface_diff`: the diffs' `--md` text; `signals`: `{console_errors_new,
   failed_requests_new, slower_pages, slow_tests}` — the UI diff's lists plus `slow_tests` from
   `node "$HOME/scripts/perf-trend.mjs" regression-<candidate>`, each item made a
   `needs-review` entry per [triage.md](triage.md) → **Signals no test covers**). Render it with `scripts/render-report.mjs` into
   `work/regression/<candidate>/report/` and publish as in
   [reporting.md](reporting.md) → Delivery (artifact only, its reference in
   `work/regression/<candidate>/artifact.id`; regression runs never comment).
   The run's top verdict is `regression` if any criterion is, else `needs-review` if any
   criterion or signal is, else `healed`, `relearned` or `unchanged`. Then
   `maintenance.mjs sweep` with the night's `unchanged`, `relearned` and `healed` tests and `--built`
   ([maintenance.md](maintenance.md) → Closing by itself).
8. Append `<ISO> ran candidate=<c> unchanged=<n> relearned=<n> healed=<n> needs_review=<n> superseded=<n> flaky=<n> regression=<n> blocked=<n> drift=<n>`
   to `work/REGRESSION.log` — the pre-flight keys "already tested" and
   `previous_candidate` on `ran candidate=`.
9. `env.sh unlock regression`. Summary in the chat UI: regressions first, each with its
   evidence link; then what needs review; then one line of what was absorbed; then the open
   maintenance proposals (`M-<k>`, test, kind, proposal; none → no line); then the
   profile scenarios adopted, rejected and retired; then the `deferred[]` ids that wait, with
   `max_scenarios_per_run` (none → no line). With `channel` set, the same summary
   as one `send_channel_message` to it — every night, also when all is `unchanged`, so a
   missing post is noticed; its links per [slack.md](slack.md) → **The answer in the thread**; a regression or a failed adoption opens with 🔴 and the test's
   owner (the scenario's file, or the issue). Ledgered as surface `slack`
   ([logging.md](logging.md) → **Ledger of external writes**); a refused post is logged,
   never retried by the run.
10. The catalog ([catalog.md](catalog.md) → **Build and publish**).
