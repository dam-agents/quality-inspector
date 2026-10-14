# Explorations — scenarios beyond the criteria

The criteria file holds only what the issue states ([acceptance-criteria.md](acceptance-criteria.md)).
Explorations are the scenarios you design around each AC to test the feature harder: a
second layer with its own frozen oracle, its own tests and its own report section.
`explorations: disabled` turns the layer off; `max_explorations_per_ac` (default `3`,
`0` = none) caps it. A missing or invalid value → its default.

## The separation rule

- An exploration never changes an AC verdict or the issue verdict, never becomes a
  criterion, and is never red-green. Its result is `observed-ok`, `observation` or
  `blocked`, with severity `info | minor | major`, reported only under "Beyond the criteria".
- Observations never produce an issue comment of their own and never file an issue; the
  issue comment carries at most the renderer's one summary line. A `major` observation is
  named in the chat summary; the operator decides what follows.

## The frozen oracle — `work/issues/<n>/explorations-<ac_hash>.md`

Written at issue-qa step 3 right after the criteria file, from it, the issue text and the
profile's `SKILL.md` alone, **before** the product is opened. When it exists, reuse it
unchanged; it is never edited. No testable AC → no file.

```markdown
# #42 — explorations        frozen_utc: 2026-10-02T13:41:10Z        ac_hash: 3f9a0c12b7de

## EX-1 (from AC-1, heuristic: roles-isolation)
Given <state a user can set up, including who acts>
When <one user action>
Expected <an observable outcome every correct implementation shows>
surface: ui | cli | api
requires: viewer | nothing
```

## Heuristic catalogue

The only allowed sources; each EX names exactly one, by its name in the first column.

| Heuristic | Derive from the AC | Expected |
| --- | --- | --- |
| `negative-path` | its input made invalid, empty, over-long, unicode, or a duplicate | refused with a visible message, or accepted intact — never lost, mangled, or an error page |
| `persistence` | its outcome, then reload the page; sign out and back in | the state survived |
| `idempotence` | its action submitted twice; back and repeat | one effect, or a visible refusal of the second |
| `reverse-action` | delete or undo what it created | gone wherever it was shown; what depended on it follows a cascade the issue or `SKILL.md` states, else stays consistent |
| `cross-surface` | its action on the UI read back through the CLI `--json` or API, and the reverse — only when `SKILL.md` names a CLI or API | the same state on both surfaces |
| `roles-isolation` | its object reached by a `member`, `viewer` or `outsider` (another tenant) | cannot see or act beyond what `SKILL.md` says the role may |
| `error-visibility` | its action made to fail (missing prerequisite, invalid state) | the failure is shown to the user, never silent |
| `boundary-values` | a limit the issue states: 0, 1, max, max+1 | inside accepted, outside refused visibly |

- **Expected states only what every correct implementation satisfies.** A choice the issue
  leaves open (refuse or allow a duplicate) is written either-or, never guessed; no exact
  copy the issue does not state — the AC rules of [acceptance-criteria.md](acceptance-criteria.md) apply.
- **Selection:** per testable AC, derive candidates and keep them in the order
  `roles-isolation` → `persistence` → `negative-path` → the rest in table order, at most
  `max_explorations_per_ac`; at most 3 × the testable ACs per issue; a scenario two ACs
  share is one EX. Number EX-1… in AC order.

## Identities

`requires` names a role of [profile-contract.md](profile-contract.md) → **The `bin/` contract**
(`owner`, `member`, `viewer`, `outsider`); the test uses `session: '<role>'`, saved by
`auth.setup.e2e.ts`. `bash "$HOME/scripts/suite.sh" roles` lists the provided roles (names
only). A required role that is missing → no test; the EX is `blocked`, note
`role not provided by the profile`.

## Tests

Same file `tests/issue-<n>.e2e.ts`, one test per EX, written at issue-qa step 5 with the
AC tests and by the same rules ([test-authoring.md](test-authoring.md)), `EX` for `AC`:

```ts
test('#42 EX-1: a viewer cannot rename the agent', { session: 'viewer', tags: ['issue-42-ex', 'ex-1', 'from-ac-1'] },
  async ({ app, agent, screen }) => {
    // …steps…
    await app.screenshot('EX-1: the agent page as the viewer sees it');
    // EX-1 begin
    await criterion('EX-1', 'renaming is not offered, or is refused with a visible message', { agent, app }, async () => {
      await expect(screen.getByRole('button', { name: 'Rename' })).toHaveCount(0);
    });
    // EX-1 end
  });
```

- **Tag `issue-<n>-ex`, never `issue-<n>`.** Tags match exactly, and every AC run (red-green,
  confirmation, heal, regression) selects `--tag issue-<n>` — so explorations never run on
  the baseline or nightly. Explorations are not replayed nightly in this version.
  `check-asserts.sh --lint <file>` lists in `ex_with_issue_tag` every EX block whose test
  carries `issue-<n>`; issue-qa step 5 retags each one before red-green.
- `check-asserts.sh --ex-hash <file>` hashes the EX blocks alone (`none` without any);
  `--hash` and `work/SUITE.md` cover AC blocks only, so EX blocks may evolve without drift.

## Run and judge — candidate only

On the candidate install of issue-qa step 6, after its AC run:
`bash "$HOME/scripts/suite.sh" run issue-<n>-explorations --evidence failures --strict --tag issue-<n>-ex`.

| EX result | `verdict` | `severity` |
| --- | --- | --- |
| passed | `observed-ok` | `null` |
| could not reach its EX block, or its role is missing | `blocked` | `info` |
| reached it, Expected false | `observation` | `major` for `roles-isolation` or `persistence`, else `minor` |

Read the trace before writing an `observation`, as for a `failed` AC. Confirm a would-be
`major` like an AC failure (`--repeat-each 3 --no-cache`, issue-qa step 7); mixed results →
`observation`, `info`, note `flaky`.

## Reporting

`verdicts-<ac_hash>-<candidate>.json` ([reporting.md](reporting.md) → **Verdicts file**) adds
`"explorations_run": "issue-<n>-explorations"`, `"ex_hash"` (from `--ex-hash`) and
`"explorations": [{"id": "EX-1", "from_ac": "AC-1", "heuristic": "roles-isolation", "given": "…", "when": "…", "expected": "…", "surface": "ui", "verdict": "observation", "severity": "major", "note": "…"}]`
— `given` / `when` / `expected` verbatim from the explorations file. `render-report.mjs`
renders them after the ACs as "Beyond the criteria", labelled not part of the verdict,
candidate side only, and adds one line to `comment.md`:
`N explorations beyond the criteria: M observations (see evidence)`.

## Noticed in passing

What you happen to see outside the ACs while exploring, authoring or reading a run's
screenshots — an error page, a console error on screen, a broken layout, a wrong count — is
one `noticed` item in `verdicts-<ac_hash>-<candidate>.json`:
`"noticed": [{"where": "<page or step>", "saw": "<what a user sees>", "shot": "<screenshot path>" | null}]`.
It costs nothing extra: no test, no re-run, no chase, no verdict. `render-report.mjs` lists
it as "Noticed in passing — not tested" and adds one count line to `comment.md`. Something
that looks like a security weakness is never a `noticed` item: it goes to the operator's
chat only ([security.md](security.md)).
