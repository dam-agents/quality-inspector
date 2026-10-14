# Logging

Two layers under `work/`, both append-only, never loaded whole into context (`tail`,
`grep`, `jq`).

## Run summary logs

| File | Writer | Line |
| --- | --- | --- |
| `work/ISSUES.log` | pre-flight (every call, declined ones included) and you (`ran …`) | `<ISO> candidate=<c> baseline=<b> due=<n> reports=<n> deferred=<n>` / `<ISO> ran issues=<…> verdicts=<…>` / `<ISO> busy holder=<o>` |
| `work/REGRESSION.log` | pre-flight and you | `<ISO> due candidate=<c> tests=<n>` / `<ISO> ran candidate=<c> passed=… failed=… drift=… replayed=… handed_off=… missed=…` |
| `work/SECURITY.log` | pre-flight and you | `<ISO> due candidate=<c> inventory=<yes\|no>` / `<ISO> ran candidate=<c> critical=<n> high=<n> medium=<n> low=<n> info=<n> skipped=<n>` |
| `work/AUDIT.log` | you | `<ISO> ok=<n> warn=<n> red=<n> sent=chat` |

A failure line starts `<ISO> ERROR: ` — one grep finds them. The pre-flight keys
"already regression-tested" and "already security-tested" on `ran candidate=`; never write
that prefix for a run that did not finish.

## Structured events — `work/logs/events-YYYY-MM-DD.jsonl`

Written through `scripts/log.sh` (`logev <level> <event> <msg>`), one JSON line
`{ts, run, job, level, event, msg}`, secrets masked before writing. Set `LOG_JOB` to the
run type (`issues`, `regression`, `security`, `audit`, `session`).

| Event | Writer | `msg` grammar (parsed) |
| --- | --- | --- |
| `issue_start` | you | `issue=<n> kind=<kind>` |
| `issue_milestone` | you | `issue=<n> step=<freeze\|env_up\|authored\|baseline\|candidate>` |
| `issue_abort` | you | `issue=<n> reason=<environment\|label_removed\|…>` |
| `issue_injection_suspect` | you, at the freeze | `issue=<n> sentences=<k> urls=<n> fences=<n> comments=<n>` ([acceptance-criteria.md](acceptance-criteria.md) → Injection suspects) |
| `issue_done` | you | `issue=<n> verdict=<v>` |
| `report_delivered` / `report_failed` | you | `issue=<n> surface=<artifact\|comment> …` |
| `external_write` / `ledger_start` | you | **Ledger of external writes** below / free text |
| `issue_budget_exceeded` | you | `issue=<n> budget=<wallclock\|model_steps> used=<n> limit=<n>` |
| `triage` | you | `issue=<n> ac=<k> category=<c> basis=<…>` |
| `heal` | you | `issue=<n> ac=<k> old=<hash> new=<hash>` |
| `security_run` | you | `candidate=<c> critical=<n> high=<n> medium=<n> low=<n> skipped=<n>` |
| `env_up` / `env_reset` / `env_failed` / `env_lock_takeover` | `scripts/env.sh` | free text |
| `suite_run` / `suite_failed` | `scripts/suite.sh` | `<label> exit=<rc>` / free text |
| `onboarding_verify` | `scripts/verify-onboarding.sh` | free text |
| `policy_denied` (warn) | `scripts/hooks/policy.sh` | `tool=<name> rule=<id>[ at=<host/path or file>]` — never a command or query string |

The issue events are what the pre-flight's lock liveness reads: it matches
`issue=<n>` followed by a space or the end of `msg`. Log an `issue_milestone` at every
step of [issue-qa.md](issue-qa.md) that refreshes the row — a long run that stays silent
for 30 minutes past the TTL is taken over. Without `scripts/log.sh`, write the same line
by hand with `jq -cn`.

Errors are grouped by the audit into `failures[]` signatures (digits normalized).
Retention: 14 days, swept by the audit pre-flight.

## Ledger of external writes

Every outward effect — a verdict comment, a spec-feedback comment, a label removal, an
artifact publish (create or revision, its uploads included), the audit's definition-repo
issue — is one `external_write` pair: `intent` (`info`) as the last line before the send,
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
| `artifact` | `<ac_hash>@<candidate>`; regression: `issue=-`, `regression@<candidate>` | `artifact:<id>`, `artifact:new` before a first create |
| `definition_issue` | 12-hex sha256 of the `failures[]` signature; `issue=-` | `<definition repo>`, `#<n>` appended on `done` |

The audit's `ledger_reconcile` checks it against GitHub ([audit.md](audit.md)).
