# Risks — checks that come from what went wrong before

A **risk rule** is one check a user can see, with a trigger that says when it applies. It comes from
a defect that got through ([escapes.md](escapes.md)), from a lesson the agent proved, or from the
operator. An issue run checks only the rules whose trigger the issue meets — usually none to three —
so nobody has to remember the old defects, and the run does not grow with the list.

A risk check is an **exploration** of heuristic `risk` ([explorations.md](explorations.md)): it runs on
the candidate only and never changes a criterion's verdict or the issue verdict.

## The register — `work/RISKS.md`

`| id | mode | triggers | check | source | added_utc | runs | observations | last_utc | last_ref |`,
written only by `scripts/risks.mjs` under a mutex (the policy hook refuses a file-tool edit of it in a
scheduled run or a channel turn).

- `triggers` — up to 8, `word:<phrase>` (the issue's title, body or frozen criteria hold it as whole
  words, in any case) or `label:<name>` (the issue carries it). Only words this agent already has: never
  a file path of the code, a diff or a pull request's content ([black-box.md](black-box.md)).
- `check` — one sentence: what a user does and what every correct product shows, by the rules of
  [acceptance-criteria.md](acceptance-criteria.md) (no exact copy the source does not state).
- `source` — `E-<k>` (an escaped defect), `L-<yyyy-mm-dd>` (the dated line of `work/LESSONS.md` it
  comes from), or `operator`.
- `mode` — `observe` | `enforce` | `retired`.

## Observe first

A new rule starts in **`observe`**: it runs and its result counts (`runs`, `observations`), but the
report and the dashboard do not show it — a new check could be noise, and it must not reach a reader
before the operator saw what it finds. The weekly audit names an `observe` rule that ran 5 times
(`risks` check): with an observation, suggest `enforce`; without one, suggest `retire`. The operator
decides. An `enforce` rule shows under "Beyond the criteria" like any exploration, with its rule id.
Only the operator starts a rule in `enforce` (`add --mode enforce`, direct session only).

## Adding a rule

Write the triggers (one a line) and the check each to the file of
`mktemp /tmp/quality-inspector-words.XXXXXX`, then
`node "$HOME/scripts/risks.mjs" add --trigger-file <path> --check-file <path> --source <source>`.
Choose triggers that the issues which touch the same function hold — the function's name as users see
it ("upload", "share link"), its label — not the words of one issue only. Exit 2 names what to fix; an
active rule with the same check is refused (name it instead).

## In an issue run

At issue-qa step 3, after the criteria file and before the explorations file
([issue-qa.md](issue-qa.md)):

1. Write the issue's title, body and the frozen criteria to a words file, then
   `risks.mjs match --text-file <path> [--label <label>]…` with each of the issue's labels.
2. Each rule in `risks` becomes one EX of heuristic `risk` in the explorations file, from the AC it
   concerns most (the first AC when none fits better), with a `risk: R-<k>` line; its Expected is the
   rule's check made concrete for this issue — never wider. At most `max_risk_checks_per_issue` (3;
   `0` = none); they do not count against `max_explorations_per_ac`. `explorations: disabled` → none.
3. After the explorations run, per risk EX:
   `risks.mjs hit R-<k> --result ok|observation|blocked --ref "#<n> EX-<k>"` (`observed-ok` → `ok`).
   The verdicts file's explorations entry adds `"risk": "R-<k>", "mode": "<its mode>"`; the report
   leaves out an `observe` one ([reporting.md](reporting.md)).

## The operator's words (direct session)

- **"enforce R-`<k>`"**, **"observe R-`<k>`"**, **"retire R-`<k>`"** — `risks.mjs set R-<k> <mode>`.
- **"add risk: when <words> check <sentence>"** — **Adding a rule** with source `operator`; ask whether
  it starts in `observe` or `enforce`.
- **"show risks"** — `risks.mjs list`: id, mode, triggers, runs, observations, last run.

## Pruning

Rules, like tests, only grow if nobody prunes them. The weekly audit's `risks` check names:
an `observe` rule ready for a decision; an active rule no issue met in 90 days (suggest `retire`); and
the dated lines of `work/LESSONS.md` older than 180 days. The operator decides; a lesson line is removed
only after the operator's word, in the direct session, and a lesson a rule holds stays as its source.
