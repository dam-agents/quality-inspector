# Features — recurring tests by what the product does

A feature is a group of recurring test cases named by what the product does for its user
("Model switching", "Reply in Slack"), so a person can ask for a feature by its name and have
its tests run again on the build that is up. Only **recurring** tests belong in one: a
`work/SUITE.md` row of tier `regression` or `promotable`. Explorations, runs by hand and
unsaved scenarios never do. Collections ([catalog.md](catalog.md)) stay the operator's own
free grouping; features are the agent's, kept by the rules below.

## The registry — `work/FEATURES.md`

```
| feature | name | aliases | members | updated_utc |
| --- | --- | --- | --- | --- |
| model-switch | Model switching | model picker; Změna modelu | #42 AC-1, #51, S-7, P-chat-basics | 2026-10-25T08:16:50Z |
```

- `feature` — an id, `[a-z0-9][a-z0-9-]{0,39}`; `name` and each alias (`; `-separated) — 1–80
  characters. A member is `#N`, `#N AC-k`, `S-k`, `S-k AC-j`, `P-<slug>` or `P-<slug> AC-j`.
- Written only through `node "$HOME/scripts/features.mjs" …` (its header lists the commands and
  their JSON), never by hand: the script keeps the format the catalog and the audit read
  (`features.mjs check`, the audit's `features` check).
- **Words never go on a command line.** A query, a name or an alias is often a person's or an
  issue's text; a quote in it would end a shell argument. Per call: `kind=words; mktemp
  "/tmp/quality-inspector-$kind.XXXXXX"` prints a path of its own under `/tmp`
  (two sessions never share one; never `-t`, which follows `$TMPDIR`, where the policy hook lets
  no file be written); write the words to that path with the file tool, and pass it as `--file`
  (`--name-file` for `add`). The script refuses any other name or folder, and removes the file once
  read — also when it then refuses the call.
- A member whose test is not recurring stays listed and is skipped with its reason when the
  feature runs (`skipped[]`); `check` warns about it.

## Who puts a test into a feature

- **The agent**, when a test becomes recurring: issue-qa step 9 for a `promotable` (or
  auto-promoted) file ([issue-qa.md](issue-qa.md)), a saved scenario
  ([scenarios.md](scenarios.md) → Saving), an adopted profile scenario (Adopt step 5).
  Each criterion goes into one feature, at most two: `features.mjs list` first, and an existing
  feature whose name says what the criterion exercises wins over a new one. A new feature is
  named from the issue's or the scenario's own words for the behaviour and the product's
  visible labels — a user's name for it, never a page path, a component or anything of the
  code. Add the issue title's words as an alias when they differ from the name. Name every
  feature written in the run's chat summary.
- **The operator**, in the direct session ([on-demand.md](on-demand.md)): "add #N[ AC-k] to the
  feature <id>", "remove … from the feature <id>", "alias feature <id> <text>", "rename feature
  <id> <text>", "merge feature <a> into <b>", "drop feature <id>", "show features", and "propose
  features" — every recurring test case in no feature, grouped by the rules above and shown as one
  list; written on the yes. The agent never removes a member, merges or drops a feature on its own. After each change, the catalog
  ([catalog.md](catalog.md) → Build and publish).

## Asking for a feature

| Who | Words | Where |
| --- | --- | --- |
| the operator | "run feature <words>" | the direct session ([on-demand.md](on-demand.md)) |
| a person in `slack_channel` | "test feature <words>" | Slack ([slack.md](slack.md)), within `slack_tests_per_day` |
| the operator, on the dashboard | its "Run this feature" button: "run feature <id>" | its message box ([catalog.md](catalog.md)) |

**Resolve** — `node "$HOME/scripts/features.mjs" resolve --file <path>`, the words in a file of
its own as above. Case, accents and punctuation
do not count; a whole name or alias is an `exact` match. Then:

- `exact` → run it.
- `ranked` → answer with each candidate (id, name, how many tests run) and ask for the id; run
  nothing yet.
- `none` → read `features.mjs list` and match by meaning (another language, a synonym). A match
  found so is offered like a `ranked` one; in the direct session, on the yes, also `alias` the
  words. Still none → say so, and name the closest features.
- A feature with an empty `runnable[]` → say why (its `skipped[]`), run nothing.

## The run

The operator's "run #N" procedure ([on-demand.md](on-demand.md)) with the feature's tests:
`env.sh lock operator` (from Slack: `slack`; busy → say who holds it, end); no product up → `env.sh up <candidate>` and
`wait`; then

```bash
bash "$HOME/scripts/suite.sh" run feature-<id>-<candidate>-<HHMM> --evidence full <tags>   # <tags> from resolve
bash "$HOME/scripts/suite.sh" wait feature-<id>-<candidate>-<HHMM>
node "$HOME/scripts/features.mjs" record feature-<id>-<candidate>-<HHMM> <id> --build <candidate>
```

then `env.sh unlock operator` (or `slack`). A member that names one criterion runs its whole file; `record`
keeps the members' criteria only. Answer per criterion — `passed`, `failed` with its message,
`blocked` — failures first with the run's screenshots, then the skipped members with their
reasons. Log `feature_run feature=<id> build=<candidate> passed=<n> failed=<n> blocked=<n>`
([logging.md](logging.md)). It is never a verdict: no criteria, no verdicts file, no comment, no
tier, `work/QA.md` or `work/MAINTENANCE.md` change. A failure is offered as "create issue for
<ref>" ([skills/create-issue](../skills/create-issue/SKILL.md)) or "run the regression now",
never decided here. Then the catalog — the run shows in its history as "Feature run".
