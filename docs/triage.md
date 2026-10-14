# Triage — redesign or regression

Every regression-tier criterion that did not simply pass gets exactly one category. The
goal is twofold: a reworked UI never fails the suite, and a broken product never hides
behind "the UI changed". When the two pull apart, the bias is towards **regression**: a
false alarm costs one look; a hidden regression costs users.

## What each test already tells you

`suite.sh summary <label>` per result: `status`, `code`, `judged` (exact checks that
failed while `criterion()` judged the Then sentence true on screen), `relearned` (steps
the replay cache handed to the agent because the recorded control was not found), plus
the step list and screenshots in `report.json`.

## Categories

| Category | When | What you do |
| --- | --- | --- |
| `unchanged` | passed, nothing judged, nothing re-learned | nothing |
| `relearned` | passed; only steps outside AC blocks were re-learned | nothing — the next passing run re-records; note which steps moved |
| `healed` | passed with `judged` checks, and the healing rules below hold | repair the check, log it |
| `needs-review` | passed with `judged` checks, but a healing rule fails | leave the file; the operator decides |
| `superseded` | the criterion is false, and a completed issue in the window changes exactly this behaviour on purpose | retire the test (below) |
| `regression` | the criterion is false (strict re-run fails and the judge agrees), and nothing in the context explains it | report it with both screens |
| `flaky` | the confirmation re-run mixes passes and failures | log it in `work/FLAKY.md`; quarantine on the second flaky night (below) |
| `blocked` | the test could not reach its AC block for a reason outside the product (environment, model, setup) | fix or report as environment |

## Order of work per failing or judged test

1. **Confirm by repetition**: `suite.sh run confirm-<candidate> --strict --tag issue-<n>
   --tag ac-<k> --tag-mode all --repeat-each 3 --no-cache`, and read `by_test[].stability`.
   `flaky` ends the triage of this criterion as `flaky`; only `stable-fail` can become a
   `regression` or `superseded`, and only `stable-pass` (non-strict for a judged check)
   can become `relearned` or `healed`. A stale recording is not a finding either — the
   re-run is uncached.
2. **Look at the evidence**: the AC screenshot, the failing step, the previous build's
   screenshot of the same page (`work/inventory/<previous>/shots/`).
3. **Check the context** ([change-awareness.md](change-awareness.md)): the test's
   `impact` hits and every completed issue whose title or spec touches this area.
4. **Decide** by the table. Write one `explanation` sentence that names the evidence
   (*"the tab is now 'Access tokens' — UI map, likely rename"*, *"#4552 replaces the
   export button with a share link"*, *"nothing in 13 completed issues touches agent
   lists; the list shows two agents after creating one"*).

## Healing rules — when a check may be repaired without the operator

All of them, or it is `needs-review`:

- The criterion's **Then sentence was judged true** on the new build (`criterion()`'s
  fallback passed, with its screenshot).
- The change is **explained**: the UI map reports the control renamed or moved, or a
  completed issue in the window describes the change.
- The repair touches **only how the same thing is located** — role, name, label, place.
  The matcher, the expected value and the Then sentence stay byte-identical.
- The repaired file **passes strict** (`suite.sh run heal-<candidate> --strict --tag issue-<n>`):
  the new exact check discriminates on its own.

Then update the file, set its `work/SUITE.md` `assert_hash` from
`scripts/check-asserts.sh --hash`, and append one row to `work/HEALS.md`:

```
| utc | test | ac | build | old_hash | new_hash | basis |
| 2026-10-12T21:04:11Z | tests/issue-101.e2e.ts | AC-1 | 0.0.0-main.5937 | 9c1e44a0f2b3 | 51d0e2aa7c90 | ui-map: tab "API keys" → "Access tokens" |
```

A heal never touches a criteria file. Three heals of the same test inside a month →
`needs-review` from then on: the test is fighting the product.

## Flaky tests and quarantine

Append one row per flaky criterion to `work/FLAKY.md`:

```
| utc | test | ac | build | runs | passes |
| 2026-10-13T03:41:07Z | tests/issue-42.e2e.ts | AC-2 | 0.0.0-main.5951 | 3 | 1 |
```

A test with flaky rows from two different builds inside 14 days moves to tier
`quarantined` in `work/SUITE.md`: it no longer replays, and the report names it under
"needs review". A quarantined test comes back only by the operator ("promote #N") after
its cause is fixed — usually a wait for state the test assumed, or nested-platform
instability recorded in `work/LESSONS.md`. A flaky result is never a regression and
never a pass.

## Signals no test covers

Each of these is a `needs-review` item in the report's `context.signals`
([regression.md](regression.md) step 7) even when every test passed — never a
`regression` on its own. Each item keeps the script's fields and adds
`verdict: "needs-review"` and one `explanation` sentence:

- **A new console error or failed request on a page** (`ui-diff.mjs`
  `console_errors_new`, `failed_requests_new`): the error text and the page's screenshot
  from the new map (`shot`) are the evidence.
- **A slower page or test** (`ui-diff.mjs` `slower_pages`, `scripts/perf-trend.mjs`
  `slow_tests`): the explanation names both numbers.

A signal on the page of a failing test is also evidence in that test's triage.

## Retiring a superseded test

Only with a quoted sentence from the completed issue that contradicts the criterion.
Set the test's tier to `retired` in `work/SUITE.md` (it no longer replays), keep the
file, and name the superseding issue in the report. When that issue carries `qa_label`,
its own issues run writes the replacement tests.

## What never happens

- A failing check is never deleted, loosened (`toBeVisible` → `toBeAttached`, an exact
  text → a substring) or replaced by `agent.assert` to make a run green.
- A `regression` is never downgraded because a completed issue merely mentions the same
  page; the issue must state the new behaviour.
- `superseded` and `healed` are never decided from the UI map alone when the criterion is
  about behaviour (data saved, an action's effect) rather than presentation.
