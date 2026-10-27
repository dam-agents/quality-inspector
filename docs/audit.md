# Weekly audit

Read-only toward every external system and repair-free; it reports. Skip the report only
when `audit_report: disabled` (still append the log line).

1. Run `bash "$HOME/scripts/preflight.sh" audit`. Its `checks[]` are the deterministic
   half: GitHub identity, issues reachability, **the black-box boundary probes**, the
   profile and its builds, the profile's requirements, disk (use and `min_free_disk_gi`),
   `work/` not a repo, leftovers, stale locks, the write ledger, assertion drift,
   the issues pre-flight cadence, definition cleanliness and version, the policy and backup
   hooks and the week's refusals (`policy_hook`, `policy_denied`), the work backup
   (`work_backup`: `fail` when `work_repo` is not private, is the target or its fork, or is
   unreachable; `warn` for files changed over an hour ago and not pushed, or a backup error
   since the last push), `secrets_in_runs` (a credential
   value left in a raw run's text files; a `fail` names the paths, never the value),
   **coverage** of the newest UI map (`warn` while pages are uncovered, never `fail`;
   [change-awareness.md](change-awareness.md) → Coverage), `features`, `maintenance` and `radar` (the
   registry's, the queue's and `work/PRSCAN.md`'s format; members that do not run; proposals open over 14 days —
   [features.md](features.md), [maintenance.md](maintenance.md), [radar.md](radar.md)), and `criteria_injection` (the
   week's criteria files of issues and scenarios and intent files of issues holding URLs, code fences or HTML comments;
   the week's `issue_injection_suspect` and `scenario_injection_suspect` events) — a `warn`
   lists the issues and `S-<k>`: sample one and check its instruction sentences are
   `testable: no`. From the harness trace ([logging.md](logging.md) → **Harness trace**):
   `trace_hooks` (registered for every event the harness has), `unfinished_runs` (turns that
   never ended, issues and scenarios left mid-pipeline in their session — `silent` when that
   session logged no error — and API-error stops) and `tool_failures` (by tool; a `warn` names
   a loop: one session's same failure five times or more) — treat each `warn` like a
   `failures[]` signature in step 2; `stats.turns_7d` counts the week's turns.
   `failures[]` groups the week's error events; `stats` counts verdicts,
   `stats.coverage` the pages, and `stats.cost_7d` the week's speed and cost: finished
   issues with their median and total minutes and model steps, installs with their median
   seconds ([logging.md](logging.md)) — name the median issue in the report.
   - `ledger_reconcile` ([logging.md](logging.md) → **Ledger of external writes**): for
     the newest 20 `reported` QA rows of the week, one `GET …/issues/<n>/comments?since=`
     each; every comment of the agent's login (`agent_login`) created this week (and after
     the newest `ledger_start` event) that carries `<!-- <marker_prefix>` needs a `done`
     entry with its surface and key —
     missing → `fail` (unrecorded external write). An `intent` of the week older than
     15 minutes with no later `done`/`failed` → `warn` (unfinished write).
2. Add the judgment half:
   - `mcp__platform-outbound__list_schedules`: every `quality-inspector-*` schedule of `kit.yaml` exists; their
     task text and precheck match `kit.yaml` (drift is a `warn` — the operator updates a
     live schedule). Save the JSON to `/tmp/quality-inspector-schedules.json` and run
     `bash "$HOME/scripts/verify-onboarding.sh" --schedules /tmp/quality-inspector-schedules.json`
     (offline structure pass) and `bash "$HOME/scripts/modules.sh" schedules` with it (the
     dashboard's switches); delete the file afterwards.
   - `precheck.sh issues` and `… regression`, timed: exit 0 or 1 within
     two minutes.
   - Each `failures[]` signature: cause + fix, classified *environment* / *agent
     mistake* / *definition bug*. A reproduced environment cause → `work/LESSONS.md`. A
     definition bug → one deduplicated issue on the definition repository (search open
     issues first) — the audit's only external write, ledgered as `definition_issue`.
   - Sample up to three reports of the week: criteria and intent files predate the test file; no
     `verified` without a baseline failure or `baseline_blocked_reason: absent`; no candidate
     pass counted whose `AC-<k>` screenshot shows an error (reporting.md → Error at the check); every
     tested AC has a candidate video and its `AC-<k>` screenshot; AC blocks contain checks
     only; no internal identifiers or credentials in the text, the screenshots or the
     first and last frames you look at; every block `check-asserts.sh --lint` lists checks
     state the test changed (else a warn — the AC may not discriminate), and the lint's
     `ex_with_issue_tag` is empty (else a warn); the explorations
     file predates the test file and the report states its observations count
     ([explorations.md](explorations.md)).
   - Benchmark: the newest line of `work/benchmark/history.jsonl` — its age, accuracy and
     `false_verified` (above 0 is a red line until a later run is clean); a benchmark
     never run, or older than two months with cases defined, is a warn.
   - Security: the newest `ran` line of `work/SECURITY.log` — a critical or high count above
     0 stays a red line until a later run is clean; `security_checks` enabled with no run in
     five weeks is a warn. Never quote a finding beyond its id.
   - Spec quality: this week's `not-testable` verdicts and `testable: no` ACs by reason,
     issues without "Done when", and how many suggested rewrites authors adopted (an
     issue that became due again by `ac_changed` after a `spec-feedback` file).
   - Scenarios (`stats.scenarios_7d`, by source and verdict): `needs-review` left by judge
     disagreements, the `rejected` share, saves and by whom (`scenario_saved`), days the cap
     was hit. A `passed` scenario whose `judge-verdict-*.json` disagrees is red.
   - Flakiness: rows added to `work/FLAKY.md` this week, tests `quarantined`, and whether
     one cause dominates (the same page, the nested product right after `up`).
   - Triage health: heals this week from `work/HEALS.md` (each one's basis is a UI-map
     change or an issue — sample one), tests at three heals a month, open maintenance
     proposals by kind, `retired` tests, `promotable` rows waiting.
   - Trends: verdict distribution (100 % one verdict is suspicious), `inconclusive`
     share (a non-discriminating suite), replay cache `handed_off + missed` share from
     `REGRESSION.log`, environment failures per week, observations per week by severity
     (the week's `verdicts-*.json` → `explorations`), and one line of `needs-review`
     signal items per week from `stats.signals_by_week` (a rising line while every test
     passes is drift the suite does not see).
3. Report to the chat UI, traffic-light:

```
🩺 Quality Inspector weekly audit — <date> · 🟢 N ok · 🟡 N warn · 🔴 N fail
Week in numbers: issues tested N (verified a · failed b · inconclusive c · blocked d) · env failures N · cache replay x % · pages covered c/p
🔴 <id> — <detail>          (every fail, never summarized away)
🟡 <id> — <detail>
🟢 all other checks passed (<count>)
Action needed: <one line per item needing the operator, or "none">
```

4. Append `<ISO> ok=<n> warn=<n> red=<n> sent=chat` to `work/AUDIT.log`.

A boundary probe that `fail`s is always the first line of the report: the agent could
read source, and every verdict since the rules changed is suspect.
