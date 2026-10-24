# Logging

Two layers under `work/`, both append-only, never loaded whole into context (`tail`,
`grep`, `jq`).

## Run summary logs

| File | Writer | Line |
| --- | --- | --- |
| `work/ISSUES.log` | pre-flight (every call, declined ones included) and you (`ran …`) | `<ISO> candidate=<c> baseline=<b> due=<n> reports=<n> deferred=<n> scenarios=<n>` / `<ISO> ran issues=<…> verdicts=<…>` / `<ISO> busy holder=<o>` |
| `work/REGRESSION.log` | pre-flight and you | `<ISO> due candidate=<c> tests=<n>` / `<ISO> ran candidate=<c> passed=… failed=… drift=… replayed=… handed_off=… missed=…` |
| `work/SECURITY.log` | pre-flight and you | `<ISO> due candidate=<c> inventory=<yes\|no>` / `<ISO> ran candidate=<c> critical=<n> high=<n> medium=<n> low=<n> info=<n> skipped=<n>` |
| `work/DISCOVERY.log` | pre-flight and you | `<ISO> due candidate=<c> budget=<n>` / `<ISO> ran candidate=<c> proposed=<n> rejected=<n> passed=<n> failed=<n> regression=<n>` |
| `work/MODULES.log` | pre-flight and `scripts/modules.sh ran` | `<ISO> due candidate=<c> modules=<ids> focus=<n>` / `<ISO> ran module=<id> candidate=<c> <counts>` ([modules.md](modules.md)) |
| `work/AUDIT.log` | you | `<ISO> ok=<n> warn=<n> red=<n> sent=chat` |

A failure line starts `<ISO> ERROR: ` — one grep finds them. The pre-flight keys
"already regression-tested", "already security-tested", "already explored" and a module's "already ran" on `ran candidate=` / `ran module=`; never write
that prefix for a run that did not finish.

## Structured events — `work/logs/events-YYYY-MM-DD.jsonl`

Written through `scripts/log.sh` (`logev <level> <event> <msg>`), one JSON line
`{ts, run, job, level, event, msg}`, secrets masked before writing. Set `LOG_JOB` to the
run type (`issues`, `regression`, `security`, `modules`, `scenario`, `discovery`, `audit`, `slack_test`, `channel`, `session`).

| Event | Writer | `msg` grammar (parsed) |
| --- | --- | --- |
| `issue_start` | you | `issue=<n> kind=<kind>` |
| `issue_milestone` | you | `issue=<n> step=<freeze\|env_up\|authored\|baseline\|candidate>` |
| `issue_abort` | you | `issue=<n> reason=<environment\|label_removed\|…>` |
| `issue_injection_suspect` | you, at the freeze | `issue=<n> sentences=<k> urls=<n> fences=<n> comments=<n>` ([acceptance-criteria.md](acceptance-criteria.md) → Injection suspects) |
| `issue_done` | you | `issue=<n> verdict=<v> minutes=<m> model_steps=<k>` — the audit's `stats.cost_7d` |
| `report_delivered` / `report_failed` | you | `issue=<n> surface=<artifact\|comment> …` |
| `external_write` / `ledger_start` | you | **Ledger of external writes** below / free text |
| `issue_budget_exceeded` | you | `issue=<n> budget=<wallclock\|model_steps> used=<n> limit=<n>` |
| `triage` | you | `issue=<n> ac=<k> category=<c> basis=<…>` |
| `heal` | you | `issue=<n> ac=<k> old=<hash> new=<hash>` |
| `scenario_new` | `scripts/scenarios.sh` | `id=S-<k> source=<s>` |
| `scenario_adopt` | `scripts/scenarios.sh adopt` | `id=P-<slug> spec=<spec_hash>` — a profile scenario's text copied ([scenarios.md](scenarios.md) → Profile scenarios) |
| `scenario_run` | `scripts/scenarios.sh` (`set … status=in_progress`) | `id=S-<k> build=<c>` — what `max_scenarios_per_day` counts |
| `scenario_done` / `scenario_abort` | you | `id=<S-<k>\|P-<slug>> verdict=<v>` / `id=S-<k> reason=<environment\|budget\|…>` |
| `scenario_injection_suspect` / `scenario_saved` / `scenario_declined` | you | `id=S-<k> sentences=<k>` / `id=S-<k> by=<user id>` / `intent=<intent>` |
| `discovery_done` | you | `candidate=<c> proposed=<n> rejected=<n>` |
| `security_run` | you | `candidate=<c> critical=<n> high=<n> medium=<n> low=<n> skipped=<n>` |
| `modules_run` | you | `candidate=<c> modules=<ids> focus=<n> minutes=<m>` |
| `module_set` | `scripts/modules.sh` | `module=<id> key=<k> old=<v> new=<v>` |
| `issue_created` | `scripts/github.sh create-issue` | `issue=<n> refs=<count> fix=<0\|1> build=<b>` — a found issue opened ([skills/create-issue](../skills/create-issue/SKILL.md)) |
| `steps_walked` | you | `steps=<n> done=<k> live=<0\|1> build=<b>` — the Test builder's walk ([on-demand.md](on-demand.md) → "walk these steps live") |
| `artifact_viewer_declined` | you | `artifact=<id>` — a shared dashboard's viewer asked for anything but a scenario ([modules.md](modules.md) → Control) |
| `env_up` / `env_reset` / `env_failed` / `env_lock_takeover` | `scripts/env.sh` | free text; `env_up` ends `took_s=<seconds>` |
| `slack_test` | you, when a Slack test starts | `issue=<n> user=<sender id>` — counted against `slack_tests_per_day` ([slack.md](slack.md)) |
| `suite_run` / `suite_failed` | `scripts/suite.sh` | `<label> exit=<rc>` / free text |
| `onboarding_verify` | `scripts/verify-onboarding.sh` | free text |
| `policy_denied` (warn) | `scripts/hooks/policy.sh` | `tool=<name> rule=<id>[ at=<host/path or file>]` — never a command or query string |
| `turn_start` / `turn_end` | `scripts/hooks/trace.sh` (**Harness trace** below) | `kind=<scheduled\|channel\|direct> bytes=<n> sha=<hex12>` / `status=<ok\|interrupted\|<API error>> kind=<k> secs=<n> tools=<n> failed=<n>` — `interrupted` is `warn`, an API error `error` |
| `tool_failed` (warn) | `scripts/hooks/trace.sh` | `tool=<name>[ code=<exit>][ interrupt=1][ agent=<type>] ms=<n> err=<excerpt>` |
| `work_backup` | `scripts/work-backup.sh` (job `backup` from the Stop hook) | free text; `error` = a refused or failed persist, foreign commits, a failed restore ([persistence.md](persistence.md) → **Backup & restore**) |

The issue events are what the pre-flight's row liveness reads when the environment lock
cannot tell whether its holder runs ([nested-env.md](nested-env.md) → Shape): it matches
`issue=<n>` followed by a space or the end of `msg`. Log an `issue_milestone` at every
step of [issue-qa.md](issue-qa.md) that refreshes the row — such a run that stays silent
for 30 minutes past the TTL is taken over. Without `scripts/log.sh`, write the same line
by hand with `jq -cn`.

Errors are grouped by the audit into `failures[]` signatures (digits normalized).
Retention: 14 days, swept by the audit pre-flight.

## Harness trace

`scripts/hooks/trace.sh`, a Claude Code hook the harness runs (not you), writes the
`turn_start`, `turn_end` and `tool_failed` lines above with the session id as `run` and the
turn's job (the mode in a scheduled run's frame, `channel`, else `session`), so a turn
that dies mid-pipeline or a failure you never logged still leaves a line. A prompt is only its
size and hash; a failure's error has its credential values and token shapes masked, then is
cut to 160 characters. Counted, not logged: a Bash exit 1 with no output (`grep` without a
match), and a Bash exit 3 that ends "— run env.sh wait again" or "— run suite.sh wait again"
(a wait poll while the run lasts). A turn
that never reached Stop is closed `interrupted` by the session's next prompt. Its state is
`work/env/turns/<session>`. `PostToolUseFailure` and `StopFailure` need Claude Code 2.1.101
or newer, so `scripts/hooks/install.sh` registers them only there. The audit reads the lines
as `trace_hooks`, `unfinished_runs`, `tool_failures` and `stats.turns_7d` ([audit.md](audit.md)).

## Ledger of external writes

Every outward effect — a verdict comment, a spec-feedback comment, a label removal, an
artifact publish (create or revision, its uploads included), the audit's definition-repo
issue, a found issue (surface `issue`, key `found@<slug>`, [skills/create-issue](../skills/create-issue/SKILL.md)), a Slack reply, a push of the `work/` backup — is one `external_write` pair: `intent` (`info`) as the last line before the send,
then `done` (`info`) or `failed` (`error`) as the first write after it returns (a create's
`artifact.id` alone comes first — it is the dedup key), and only then the state flip.
Never a body, a link with a token, or a credential. A marker found by the pre-post check
is no send and gets no entry.

`msg`: `surface=<s> action=<intent|done|failed> issue=<n> key=<k> target=<t>`; a value
never holds a space (`%20`), and `intent` and its outcome share `surface`, `issue`, `key`.

| `surface` | `key` | `target` |
| --- | --- | --- |
| `comment` | `<ac_hash>@<candidate>` (the marker's `ac`, `build`) | `target_repo` |
| `spec_comment` | `<ac_hash>` | `target_repo` |
| `label` | the label name | `target_repo` |
| `artifact` | `<ac_hash>@<candidate>`; regression: `issue=-`, `regression@<candidate>`; the test catalog: `issue=-`, `catalog@<hash>` | `artifact:<id>`, `artifact:new` before a first create |
| `definition_issue` | 12-hex sha256 of the `failures[]` signature; `issue=-` | `<definition repo>`, `#<n>` appended on `done` |
| `slack` | a scenario's answer `S-<k>:<spec_hash>`, a digest `digest@<candidate>`, a black-box breach alert `breach@<hash>` (the gate's `key`); `issue=-` | the conversation id |
| `slack_test` | `start` or `report` of a Slack-ordered "test #N" ([slack.md](slack.md)) | `slack:<slack_channel>` |
| `backup` | the pushed tree's sha, 12 hex; `issue=-`; written by `scripts/work-backup.sh` | `work_repo` |

A scenario's artifact is surface `artifact`, `issue=-`, key `S-<k>:<spec_hash>@<build>`.

The audit's `ledger_reconcile` checks it against GitHub ([audit.md](audit.md)).
