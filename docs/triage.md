# Triage — redesign or regression

Every regression-tier criterion that did not simply pass — an `AC-<k>` or an intent test's
`IN-<k>` ([intent.md](intent.md)), alike — gets exactly one category: a moved control never
fails the suite, a replaced flow waits for the operator's word, and a broken product never hides behind "the UI changed". In doubt,
**regression**: a false alarm costs one look; a hidden regression costs users.

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
| `reworked` | not assigned by the agent since 3.68.0: a step before the frozen block that no longer works is a `needs-review` with a `rework` proposal (below); older nights keep the word | — |
| `needs-review` | passed with `judged` checks, but a healing rule fails; or fails on the previous build too (step 5) | leave the file; open a proposal for the operator ([maintenance.md](maintenance.md)) |
| `superseded` | the criterion is false, and a completed issue in the window that `may_supersede` changes exactly this behaviour on purpose | retire the test (below) and open a proposal |
| `regression` | the criterion is false (strict re-run fails and the judge agrees), and nothing in the context explains it | report it with both screens |
| `flaky` | the confirmation re-run mixes passes and failures | log it in `work/FLAKY.md`; quarantine on the second flaky night (below) |
| `blocked` | the test could not reach its frozen block, and the cause is `environment` or not known | diagnose and repair ([autonomy.md](autonomy.md) → **Diagnosis**); a cause that will stop it again is a `tests` blocker |

## Cause

Each `regression`, `needs-review`, `flaky` or `blocked` entry also names its `cause`
([reporting.md](reporting.md) → **Cause of a failure**): `product` (a `regression` is
always `product`), `test` (a `needs-review` that fails on the previous build too, a check the UI
moved away from, a `flaky` wait), `environment` (the product as a whole did not work on this
night: a `blocked` with no answer, a smoke failure after the start). A night whose environment
failed before any test ran is no entry: its `environment.json` stands for all
([regression.md](regression.md) step 2). A `test` cause that stops a test before its frozen block
is never left as `blocked`: it goes to **Reworking the steps before a block** (below). Without the
evidence for a cause, leave it out.

## Order of work per failing or judged test

1. **Confirm by repetition**: `suite.sh run confirm-<candidate> --strict --tag issue-<n>
   --tag ac-<k> --tag-mode all --repeat-each 3 --no-cache` (an intent test: `--tag in-<k>`),
   and read `by_test[].stability`.
   `flaky` ends the triage of this criterion as `flaky`; only `stable-fail` can become a
   `regression`, `superseded` or a `rework` proposal (a fail before the frozen block), and only `stable-pass` (non-strict for a judged check)
   `relearned` or `healed`. The re-run is uncached, so a stale recording is no finding.
2. **Look at the evidence**: the AC screenshot, the failing step, the previous build's
   screenshot of the same page (`work/inventory/<previous>/shots/`).
3. **Check the context** ([change-awareness.md](change-awareness.md)): the test's
   `impact` hits, its `issue_hits` (completed issues whose text names it), and every completed
   issue whose title or spec touches this area.
4. **Decide** by the table, with one `explanation` sentence that names the evidence
   (*"the tab is now 'Access tokens' — UI map, likely rename"*, *"#4552 replaces the
   export button with a share link"*, *"nothing in 13 completed issues touches agent
   lists; the list shows two agents after creating one"*).
5. **Confirm on the previous build** — only with `confirm_regressions: true` in the
   worklist, once per run, after every criterion is decided and every heal re-run. When
   any criterion is headed for `regression`: `env.sh lock regression` (refreshes it),
   `env.sh reset`, `env.sh up <previous_candidate>`, then per such criterion
   `suite.sh run prev-<n>-<k> --strict --tag issue-<n> --tag ac-<k> --tag-mode all
   --repeat-each 3 --no-cache` (an intent test: `--tag in-<k>`):
   - `stable-pass` → a confirmed `regression`; its verdicts entry gets
     `regressed_between: {from: <previous_candidate>, to: <candidate>}`.
   - `stable-fail` → not new: `needs-review`, explanation *"fails on <previous> as well —
     drift or test defect"*. Never `regression`, never a pass.
   - Anything else (flaky, blocked, the install fails, `previous_candidate` is `null`) →
     it stays `regression`, unconfirmed; the explanation says why.
6. **Bisect** — only with `bisect_max_steps` > 0, for the regressions step 5 confirmed.
   `env.sh between <previous_candidate> <candidate>` lists the builds in between, oldest
   first; non-zero → skip, and say why in the report (exit 2: the profile cannot list
   them). Each step probes the middle build of the widest interval that still holds an
   untested build: `env.sh lock regression`, `env.sh reset`, `env.sh up <build>`, the
   step-5 run of each criterion whose interval holds it. `stable-pass` moves that criterion's `from` up
   to the build, `stable-fail` its `to` down; anything else ends the bisection. Stop after
   `bisect_max_steps` installs or when no interval holds an untested build. Report the
   smallest interval as `regressed_between`, plus `builds_between` (the untested builds
   left inside it; `0` = adjacent builds).

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
`needs-review` from then on, and a `fighting` proposal: the test is fighting the product.

## Reworking the steps before a block

A test that stops at a step outside every frozen block — a field, a dialog or a sequence the
product replaced — is out of date, or the product lost a way its users had. The agent never
changes the test alone: it finds the new way, and the operator decides. The test does not pass on
this night: its entry is `needs-review`, `cause` `test`, and the night's report says that a new way
waits for a decision.

1. **Confirm** — the confirmation re-run (step 1) stops **at the same step outside the frozen
   blocks** each time. Else it is `flaky` or `blocked`, not a rework.
2. **Find the new way** through the nested product alone (its UI, and its CLI or API as
   [test-authoring.md](test-authoring.md) allows), helped by what may say how the product does it now:
   the profile ([profile-contract.md](profile-contract.md); its `SKILL.md` and the references it names),
   the text of the completed issues in the window, and the Change radar's pull request text
   ([radar.md](radar.md)). A flow that needs a surface the test cannot drive — another product's app,
   a mailbox, a chat client — is no new way.
3. **Prove it, then put the test back**: copy the test file to
   `mktemp /tmp/quality-inspector-rework.XXXXXX`, write the new steps in the test file, and check that
   the rewritten steps reach **the state the criterion's Given and When describe**, the frozen blocks stay
   **byte-identical** (`scripts/check-asserts.sh --hash` prints the same value as for the copy), and the
   file **passes strict** (`suite.sh run rework-<candidate> --strict --tag <its tag>`). Then write
   `diff -u <copy> <test file>` to `mktemp /tmp/quality-inspector-diff.XXXXXX` and copy the old file
   back, also when a check failed: the night ends with the test as it was.
4. **Name the reason** — the issue or the merged pull request that states the new flow, quoted. The
   UI map's line that shows the step's control removed or moved says what changed, not why. **No issue or
   pull request found → the change has no specification**: the proposal shows a warning (`"spec": false`, maintenance.md → **The
   proposal's details**), since a lost way with no issue behind it may be a regression. The agent never
   guesses a reason.
5. **Open the proposal**: `maintenance.mjs open <test> --kind rework --proposal rewrite`; the saved diff
   becomes `work/maintenance/M-<k>.diff`, the details `M-<k>.json`, and both `/tmp` files are removed ([maintenance.md](maintenance.md)). The basis
   is the reason (`#<n> "<quoted sentence>"`, `PR #<n>: <title>`), or `no specification: <what changed
   on the screen>` (the UI-map line when there is one).

Step 2 or 3 fails → the same entry, and a `rework` proposal `review` whose basis names what is missing
(*"#3810: the channel is bound in the chat client — no product surface"*), with a `tests` blocker of the
same cause when no build can repair it ([autonomy.md](autonomy.md)), so the next nights do not replay
it; `blocked` (`cause` `environment`) when the environment stopped the strict run. For a profile
scenario (`P-<slug>`) the report also tells the product team what its profile must give the test.

The operator's "accept M-<k>" applies the diff ([maintenance.md](maintenance.md) → **The operator
decides**); it counts as a heal for the three-heals rule above.

## Flaky tests and quarantine

Append one row per flaky criterion to `work/FLAKY.md`:

```
| utc | test | ac | build | runs | passes |
| 2026-10-13T03:41:07Z | tests/issue-42.e2e.ts | AC-2 | 0.0.0-main.5951 | 3 | 1 |
```

A test with flaky rows from two different builds inside 14 days moves to tier
`quarantined` in `work/SUITE.md`: it no longer replays, the report names it under
"needs review", and it gets a `quarantined` proposal ([maintenance.md](maintenance.md)). It comes back only by the operator ("promote #N") once
its cause is fixed — usually a wait for state the test assumed, or nested-platform
instability recorded in `work/LESSONS.md`. A flaky result is never a regression nor a pass.

## Signals no test covers

Each of these is a `needs-review` item in the report's `context.signals`
([regression.md](regression.md) step 7), also when every test passed, never a
`regression` on its own: the script's fields plus `verdict: "needs-review"` and one
`explanation` sentence. The signals:

- **A new console error or failed request on a page** (`ui-diff.mjs`
  `console_errors_new`, `failed_requests_new`): the error text and the page's screenshot
  from the new map (`shot`) are the evidence.
- **A slower page or test** (`ui-diff.mjs` `slower_pages`, `scripts/perf-trend.mjs`
  `slow_tests`): the explanation names both numbers.

A signal on the page of a failing test is also evidence in that test's triage.

## Retiring a superseded test

The superseding issue must have `author_association` `OWNER`, `MEMBER` or
`COLLABORATOR`, **or** `state_reason: completed` with a `closed_by` that is not its
author — `changes.sh` computes this as `may_supersede`. Otherwise the result is
`regression`, whatever the issue says. And only with a quoted sentence from that issue
that contradicts the criterion.
Set the test's tier to `retired` in `work/SUITE.md` (it no longer replays), keep the
file, and name the superseding issue in the report. When that issue carries `qa_label`,
its own issues run writes the replacement tests.

A profile scenario (`profile-<slug>`) is never `superseded` by an issue: its file in the
product's repository is the truth, and the product team updates it with the change. A
criterion that no longer holds is `regression`, its explanation naming
`scenarios/<slug>.md` or `.feature` ([scenarios.md](scenarios.md) → **Profile scenarios**).

## What never happens

- A failing check is never deleted, loosened (`toBeVisible` → `toBeAttached`, an exact
  text → a substring) or replaced by `agent.assert` to make a run green.
- A `regression` is never downgraded because a completed issue merely mentions the same
  page; the issue must state the new behaviour.
- `superseded` and `healed` are never decided from the UI map alone when the criterion is
  about behaviour (data saved, an action's effect) rather than presentation.
- A judged pass (`judged` non-empty) is never `unchanged` (see the table). A failing injection canary in the run's
  smoke voids every judged result of that run ([nested-env.md](nested-env.md) → Failures).
