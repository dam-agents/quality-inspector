# Validation — every mapped form, fed bad input

A module of the modules run ([modules.md](modules.md)), switch `validation_checks`. It
fills the forms the UI map found with empty, too long, wrong-type, unicode, RTL, emoji,
HTML-like and duplicate input, and checks each answer against a frozen oracle. No model
steps: the planner and the test are deterministic.

## Plan — `scripts/validation-plan.mjs`

`node "$HOME/scripts/validation-plan.mjs" "$HOME/work/inventory/<c>/inventory.json" --build <c>`
→ `work/validation/<c>/plan.json` (`--dry-run` prints it, writes nothing). The forms come
from the map's `forms` (fields with type, required, length and number limits, pattern;
read from attributes, nothing is typed — [change-awareness.md](change-awareness.md)). A map
without `forms` (older than this version) → map the candidate again.

- **Skipped forms**, each with its reason in `skipped[]`: no submit button; a destructive
  submit or form name (the map's danger words, `scripts/lib/danger.mjs`); a page, form or
  submit name in the profile's `validation.exclude` (exact match); a password field; no
  labelled field.
- **Cases** `VAL-<k>`, at most `validation_max_cases` (round-robin over forms); ids are
  stable, so a capped plan has gaps. Other required fields get valid fillers (`qa-val-<k>`,
  `…@example.invalid`, numbers within range).

| Kind | Field | Oracle |
| --- | --- | --- |
| `required-empty`, `wrong-type`, `num-below`, `num-above`, `pattern-miss`, `max-len+1` | as the attributes allow | `refused-visibly` |
| `whitespace` | text-like | `refused-visibly` when required, else `refused-or-intact` |
| `max-len`, `long`, `unicode`, `rtl`, `emoji`, `html` | text-like | `refused-or-intact` |
| `duplicate-submit` | once per form | `single-effect` |

## Run

`QI_VALIDATION_INPUT="$HOME/work/validation/<c>/plan.json" bash "$HOME/scripts/suite.sh" run validation-<c> --strict --tag validation --evidence failures`
— `tests/validation.e2e.ts` of the skeleton, one test per case. Confirm each failure with
`--repeat-each 3 --no-cache --tag val-<k>`: stays failing → a finding; mixed → `flaky`, not a
finding. Each failure message opens with the oracle that broke:

| Prefix | Means | Severity |
| --- | --- | --- |
| `[setup]` | the case never reached a check (page, field or button not found) | none — `blocked` |
| `[no-server-error]`, `[no-uncaught-error]`, `[no-error-page]` | a 5xx, an uncaught page error, an error page | major |
| `[value-intact]` | accepted but changed: lost, cut, double-escaped | major |
| `[single-effect]` | a double submit took effect twice | major |
| `[refused-visibly]` | invalid input accepted with no visible refusal | minor |

`node "$HOME/scripts/validation-results.mjs" work/validation/<c>/plan.json --run validation-<c> [--confirm <label>]…`
→ `work/validation/<c>/results.json`: per case `result` `ok` | `finding` | `flaky` | `blocked`,
`severity` from the table, `message` (the failure's first line); a case the run has no
result for is `blocked` ("not run"). Exit 1 (`{"error"}`, nothing written) = the run never
reached the tests: its `report.json` is missing or unreadable, or holds no `val-*` result
while the plan has cases. The module failed — an `<ISO> ERROR: module=validation candidate=<c>
<error>` line in `work/MODULES.log`, never `ran`. Otherwise
`modules.sh ran validation <c> cases=<n> major=<n> minor=<n> blocked=<n>`.

Passing cases and double submits create `qa-val-*` objects; the run's closing `env.sh reset`
removes them. A finding is never a verdict or a comment, an issue only on the operator's "create issue for VAL-`<k>`" ([skills/create-issue](../skills/create-issue/SKILL.md)); the dashboard lists it
([catalog.md](catalog.md)) with its run's evidence.
