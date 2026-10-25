# Test maintenance — proposals for recurring tests

A recurring test outlives the product it was written against: a page moves, a control is
renamed, a behaviour is changed on purpose, a feature goes away. The triage
([triage.md](triage.md)) decides each night what it may absorb alone (a heal under its rules);
everything else becomes **one proposal for the operator** — what changed, the evidence, and what
to do with the test — instead of a line in one night's report that the next night forgets.
Scope: the tests of `work/SUITE.md` tiers `regression`, `quarantined` and `retired`.

## The queue — `work/MAINTENANCE.md`

```
| id | test | kind | build | basis | proposal | state | opened_utc | closed_utc |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| M-3 | #42 AC-1 | needs-review | 0.0.0-main.5951 | ui-map: tab "API keys" → "Access tokens" | heal | open | 2026-10-13T03:41:07Z | - |
```

Written only through `node "$HOME/scripts/maintenance.mjs" …` (its header lists the commands):
one **open** row per (test, kind) — opening it again updates its build, basis and proposal. The
`basis` is a short evidence pointer (a UI-map change, `#<n>` and its quoted sentence, a build),
at most 160 characters — the catalog shows it, so never a triage explanation, a request's words
or a credential. It may quote an issue, so it never goes on a command line: per call, `kind=basis; mktemp
"/tmp/quality-inspector-$kind.XXXXXX"` prints a path of its own under `/tmp`
(never `-t`: it follows `$TMPDIR`, where the policy hook lets no file be written); write the basis
there with the file tool and pass it as `--basis-file`. The script refuses any other name or
folder, and removes the file once read — also when it then refuses the call. The details go to `work/maintenance/M-<k>.md`: what changed, the before and
after screenshots (`work/inventory/<previous>/shots/`, the run's), and a `heal` or `rewrite`
proposal's change as a diff of the test file in `work/maintenance/M-<k>.diff` — prepared, never
applied before the operator's word.

## What opens a proposal

| kind | opened by | proposal |
| --- | --- | --- |
| `needs-review` | the triage's `needs-review` ([triage.md](triage.md)): a healing rule failed | `heal` with the repair ready in the diff; `review` when none is (it fails on the previous build too) |
| `superseded` | the triage retired the test for a completed issue | `retire` — already done; accept confirms it, keep restores it |
| `drift` | the worklist's `assert_drift` ([regression.md](regression.md) step 4) | `re-promote`, or `rewrite` when the changed block no longer matches the criterion |
| `quarantined` | the triage moved it to `quarantined` | `re-promote` once its cause is fixed, else `retire` |
| `fighting` | the third heal of one test inside a month | `rewrite` |

```bash
kind=basis; mktemp "/tmp/quality-inspector-$kind.XXXXXX"   # prints its own path, <f>: write the basis there with the file tool
node "$HOME/scripts/maintenance.mjs" open "#42 AC-1" --kind needs-review --build <candidate> --proposal heal --basis-file <f>
```

## The operator decides

Only in the direct session, the dashboard's buttons sending the same words; a Slack or
dashboard-viewer request to decide one is declined. Show `M-<k>.md` (and the diff) first.

| Words | What happens | `close` state |
| --- | --- | --- |
| "accept M-<k>" | the proposal: `heal` → apply the diff, `suite.sh run heal-<candidate> --strict`, new `assert_hash`, a `work/HEALS.md` row with basis `operator M-<k>`; `retire` → tier `retired`; `re-promote` → "promote #N" ([on-demand.md](on-demand.md)). `review` has nothing to accept: ask for rewrite, retire or keep | `accepted` |
| "rewrite M-<k>" | rewrite the test against the build that is up ([test-authoring.md](test-authoring.md)); an AC block that checks something new is shown beside its frozen criterion and needs the operator's yes; `--strict` pass, new `assert_hash`, a `HEALS.md` row with basis `operator M-<k> rewrite` | `rewritten` |
| "retire M-<k>" | tier `retired`; the file stays | `retired` |
| "keep M-<k>" | the test stays as it is; a superseded one goes back to `regression`, and a still-false criterion is a `regression` from the next night | `kept` |

`node "$HOME/scripts/maintenance.mjs" close M-<k> <state>`, then the catalog
([catalog.md](catalog.md) → Build and publish). "accept the review of #N" is "accept M-<k>" of
that test's open `needs-review` row; "reject the review of #N" is "keep M-<k>", filed as a
regression in the next report.

## Closing by itself

At the end of each regression run (step 7) and after each promote or demote:
`node "$HOME/scripts/maintenance.mjs" sweep --unchanged <test> …`, one `--unchanged` per test the
night replayed plain `unchanged`. It resolves the rows whose cause is gone — a drift no longer
measured, a quarantine or a retirement the operator undid, a test no longer in `work/SUITE.md`,
a `needs-review` or `fighting` test that passed unchanged — and changes no test.

## Where it shows

The nightly summary names the open proposals, newest first ([regression.md](regression.md)
step 9); the dashboard lists them with their basis and buttons ([catalog.md](catalog.md)); the
audit warns about any left open over 14 days ([audit.md](audit.md)).
