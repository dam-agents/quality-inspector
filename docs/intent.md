# Intent tests — what the author wanted

The criteria check the letter of an issue: each one observable outcome it states
([acceptance-criteria.md](acceptance-criteria.md)). An implementation can satisfy every
criterion and still miss why the issue was written — a model picker that lists the new
model while the next answer still comes from the old one. An **intent test** (`IN-<k>`)
checks the purpose: one user journey that, done end to end, shows the change does what the
author wanted it for. It has its own frozen oracle, its own red-green and its own verdict,
and it never changes the issue verdict.

## When there is one

Only when the issue states a purpose beyond its criteria — a "so that", a "because", a "the
user needs to …", a problem the change solves — and that purpose has an outcome a user can
see. At most two per issue. None when the purpose is only the criteria said again, when it
is not observable, or when no criterion is testable; the file then says `none — <reason>`.

## The frozen oracle — `work/issues/<n>/intent-<ac_hash>.md`

Written at issue-qa step 3 right after the criteria file, from the issue text and the
criteria alone, **before** the product is opened. Once frozen (**The judge** below) it is
reused unchanged and never edited; one a takeover finds unfrozen is finished by the judge's
steps first. A changed issue text is a new `ac_hash` and a new file.

```markdown
# #42 — intent        frozen_utc: 2026-10-02T13:41:30Z        ac_hash: 3f9a0c12b7de

## IN-1 — the next answer comes from the chosen model
Goal "so that a user can get answers from the faster model when they need them"
Given a conversation with the default model
When the user picks "Fast" in the model picker, then asks a question
Then the answer is marked as written by "Fast"
covers: AC-1, AC-2
surface: ui
testable: yes | no — <reason>
```

- **`Goal` quotes the issue verbatim** — the one sentence that states the purpose, in its
  own language ([acceptance-criteria.md](acceptance-criteria.md) → Language). A purpose no
  sentence states is no intent test.
- **`Then` follows from the goal**, not from how the product behaves today, and states an
  outcome every correct implementation shows: no copy the issue does not state, a choice
  it leaves open written either-or.
- **`When` is the journey**: the user actions in order, at most five, through the criteria it
  `covers` and on to the outcome the goal names. It adds no feature the issue does not ask
  for and checks nothing a criterion already checks alone
  ([test-authoring.md](test-authoring.md) → **Tested once**).
- The rules of observability, surface and external dependencies are the criteria's
  ([acceptance-criteria.md](acceptance-criteria.md) → Rules).

## The judge

Before the product is opened, a judge reads the file ([judge.md](judge.md) → **Intent**):
the issue text (`github.sh issue <n>` saved as `work/issues/<n>/issue-<ac_hash>.json`), the
criteria file and the intent file. The first answer goes to `intent-judge-<ac_hash>.json`,
the second to `intent-judge-<ac_hash>-2.json`. `accept` → the file is frozen. `revise` →
apply its fixes to the file (a fix already applied stays as it is) and judge once more;
a second `revise` or a `reject` → every IN of the file becomes
`testable: no — judge: <reason>`, and the file is frozen so. A judge that does not answer
with its JSON is a `reject` with the reason "judge unavailable" ([judge.md](judge.md) →
Briefing).

A takeover or retest finds the file in one of these states, each with one action:

| Found | Action |
| --- | --- |
| no intent file | write it, then the first reading |
| the intent file, no judge answer | the first reading |
| the first answer `revise`, no second | apply its fixes, then the second reading |
| the last answer `accept` | frozen: reuse it |
| the last answer `reject`, or the second `revise` | frozen: make every IN not yet so `testable: no — judge: <reason>`, then reuse it |

## Tests

The same file `tests/issue-<n>.e2e.ts`, one test per testable IN, written at issue-qa step 5
by the rules of an AC test ([test-authoring.md](test-authoring.md)): tags
`['issue-<n>', 'in-<k>']`, the screenshot `IN-<k>: <what the Then line looks at>` right before
the block, and one block `// IN-<k> begin` … `// IN-<k> end` holding one
`criterion('IN-<k>', '<Then verbatim>', …)` whose checks discriminate. The tag `issue-<n>`
puts it in every AC run: red-green, confirmation, heal, the nightly replay.

## Verdict

Each IN is judged like an AC, by the same table and the same baseline rules
([reporting.md](reporting.md) → Verdicts), into `intents[]` of the verdicts file —
`{"id": "IN-1", "name", "goal", "given", "when", "then", "covers", "surface", "testable",
"verdict", "baseline_blocked_reason", "note"}`, the frozen lines verbatim — never into
`acs[]`. The file's `intent_verdict`:

| `intent_verdict` | When |
| --- | --- |
| `met` | every testable IN is `verified` |
| `not-met` | any IN is `failed` |
| `unclear` | otherwise (inconclusive, blocked, flaky, or no testable IN) |
| `none` | the intent file says `none` |

The issue `verdict` stays the criteria's alone. An issue `verified` whose intent is
`not-met` is named first in the run's chat summary: "the criteria hold, the goal does not",
with the IN's evidence. The report renders the IN after the criteria as "What the author
wanted"; `comment.md` gets one line.

## After the issue run

- **Promotion**: a file is `promotable` only when every testable IN in it is `verified`
  too ([regression.md](regression.md) → Tiers). Its IN blocks count in `assert_hash`
  (`check-asserts.sh --hash` hashes AC and IN blocks), so they are frozen like the criteria.
  IN blocks added to a file promoted before change its hash: the file drifts until it is
  re-promoted ([issue-qa.md](issue-qa.md) step 9).
- **Nightly**: an IN replays with its file and is triaged as a criterion
  ([triage.md](triage.md)): where that doc says `AC-<k>`, read `IN-<k>` too, and where a
  command selects the tag `ac-<k>`, an IN selects `in-<k>` — never its AC's tag.
- **References**: `#N IN-<k>` is a test case everywhere a `#N AC-<k>` is — "run #N IN-1",
  a feature's member ([features.md](features.md)), a maintenance proposal's test
  ([maintenance.md](maintenance.md)), "create issue for #N IN-1"
  ([skills/create-issue](../skills/create-issue/SKILL.md)), the catalog (💡).
