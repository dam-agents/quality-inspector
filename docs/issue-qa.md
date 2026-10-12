# Issue QA — one `issues_due` entry, end to end

Read for every `issues_due` entry and for "test #N". The worklist gives `issue`, `ac_hash`,
`kind`, `takeover`, `has_done_when` and the run's `candidate` / `baseline` chart
versions. `T` below is the configured `target_repo`; never print it outside the issue.

## State

`work/QA.md`, one row per issue, written only by you:

```
| issue | ac_hash | candidate | baseline | verdict | status | updated_utc |
| --- | --- | --- | --- | --- | --- | --- |
| 42 | 3f9a0c12b7de | 0.0.0-main.ab12cd3 | 0.2.19 | verified | reported | 2026-10-02T14:03:11Z |
```

- `status`: `in_progress` (the lock; refresh `updated_utc` at every milestone below) →
  `report_pending` (report written, delivery not done) → `reported`.
- `verdict`: `verified` | `failed` | `partial` | `inconclusive` | `blocked` |
  `not-testable` | `-` (while in progress). Meanings: [reporting.md](reporting.md).
- Rewrite a row with an atomic `tmp + mv` of the whole file; never two rows per issue.
- Per-issue files live in `work/issues/<n>/`: `criteria-<ac_hash>.md` (frozen, never
  edited), `verdicts-<ac_hash>-<candidate>.json` (your judgment),
  `report-<ac_hash>-<candidate>/` (the rendered evidence page), `artifact.id`.

## Procedure

1. **Claim.** `bash "$HOME/scripts/env.sh" lock issues` (exit 1 → someone holds the
   environment: end this entry untouched, log it). Write the row as `in_progress` with
   this run's `ac_hash`, `candidate`, `baseline`, verdict `-`, now. Remember the previous
   row — an abort restores it. Log `issue_start issue=<n> kind=<kind>`
   ([logging.md](logging.md)).
2. **Re-check at action time.** `gh api repos/$T/issues/<n>` (host flag per CLAUDE.md
   when `T` names one). The issue must still carry `qa_label` (or `retest_label`). Gone →
   restore the previous row, unlock, log `issue_abort`, next entry. Recompute nothing by
   hand: the pre-flight's `ac_hash` is authoritative for this run.
3. **Freeze the ACs** → [acceptance-criteria.md](acceptance-criteria.md). Output
   `work/issues/<n>/criteria-<ac_hash>.md`. Written **before** you look at the product;
   when it already exists (a takeover or a retest of the same text), reuse it unchanged.
   No testable AC → verdict `not-testable`, go to step 8.
4. **Candidate environment.** `bash "$HOME/scripts/env.sh" up <candidate>`, then
   `bash "$HOME/scripts/suite.sh" run smoke-<candidate> --tag smoke`. Either failing is
   an **environment failure** ([nested-env.md](nested-env.md) → Failures): restore the
   previous row, unlock, log `issue_abort reason=environment`, end the run's issue work —
   an environment problem never becomes a verdict.
5. **Author** `work/suite/tests/issue-<n>.e2e.ts` per [test-authoring.md](test-authoring.md):
   one test per testable AC, AC blocks written from the criteria file, steps found by
   exploring the candidate. Iterate until every test *reaches* its AC block on the
   candidate. Refresh the row.
6. **Red-green**, both runs with full evidence (video, screenshots, steps for every test):
   - `env.sh reset`, `env.sh up <baseline>`,
     `suite.sh run issue-<n>-baseline --evidence full --strict --tag issue-<n>`.
   - `env.sh reset`, `env.sh up <candidate>`,
     `suite.sh run issue-<n>-candidate --evidence full --strict --tag issue-<n>`.
   `--strict` keeps `criterion()` from judging: red-green needs checks that discriminate.
   - `baseline` is `null` (`baseline_channel: none`) → skip the baseline run; no AC can
     then be `verified`, only `inconclusive` or `failed`.
   Refresh the row after each install.
7. **Judge each AC** from the two summaries, the failing steps and the screenshots, per
   [reporting.md](reporting.md) → Verdicts: a step the test could not perform is
   `blocked`, an assertion that ran and was false is `failed`. Write
   `verdicts-<ac_hash>-<candidate>.json` ([reporting.md](reporting.md) → Verdicts file).
8. **Report.** Render it — `node "$HOME/scripts/render-report.mjs" <verdicts.json>
   work/issues/<n>/report-<ac_hash>-<candidate>` — open its `index.html` and check
   every tested AC shows a video, set the row to the issue verdict with
   `status: report_pending`, then deliver per [reporting.md](reporting.md) (which sets
   `reported`).
9. **Register the tests.** One `work/SUITE.md` row per new or changed test file, tier
   `exploratory`, `assert_hash` from `bash "$HOME/scripts/check-asserts.sh" --hash <file>`
   ([regression.md](regression.md) → Tiers). A retest of a promoted file never demotes it
   and never rewrites its hash — that is the operator's promotion.
10. **Release.** `env.sh unlock issues`; log `issue_done issue=<n> verdict=<v>`.

A failure between steps 5 and 8 that is not an environment failure → finish with the
evidence you have: the ACs you could not judge are `blocked` with the reason. Never
leave the row `in_progress` at run end.

## Self-check before ending the run

- Every `issues_due` entry ended `reported`, `report_pending` (delivery failed, logged),
  or restored with an `issue_abort` event.
- `criteria-<ac_hash>.md` predates the first test file edit of this run.
- No AC is `verified` without a baseline failure and a candidate pass.
- Every tested AC in the rendered report has a candidate video and at least one screenshot.
- The environment lock is released; no `/tmp/quality-inspector-*` left behind.
- One line appended to `work/ISSUES.log`: `<ISO> ran issues=<n,…> verdicts=<v,…>`.
