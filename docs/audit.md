# Weekly audit

Read-only toward every external system and repair-free; it reports. Skip the report only
when `audit_report: disabled` (still append the log line).

1. Run `bash "$HOME/scripts/preflight.sh" audit`. Its `checks[]` are the deterministic
   half: GitHub identity, issues reachability, **the black-box boundary probes**, the
   profile and its builds, the profile's requirements, disk, `work/` not a repo, leftovers, stale locks, assertion drift,
   the issues pre-flight cadence, definition cleanliness and version, the policy hook and
   the week's refusals (`policy_hook`, `policy_denied`), and `secrets_in_runs` (a
   credential value left in a raw run's text files; a `fail` names the paths, never the
   value). `failures[]` groups the week's error events; `stats` counts verdicts.
2. Add the judgment half:
   - `mcp__platform-outbound__list_schedules`: the three `quality-inspector-*` schedules exist; their
     task text and precheck match `kit.yaml` (drift is a `warn` — the operator updates a
     live schedule). Save the JSON to `/tmp/quality-inspector-schedules.json` and run
     `bash "$HOME/scripts/verify-onboarding.sh" --schedules /tmp/quality-inspector-schedules.json`
     (offline structure pass); delete the file afterwards.
   - `QI_PRECHECK_PROBE=1 precheck.sh issues` and `… regression`, timed: exit 0 or 1 within
     two minutes.
   - Each `failures[]` signature: cause + fix, classified *environment* / *agent
     mistake* / *definition bug*. A reproduced environment cause → `work/LESSONS.md`. A
     definition bug → one deduplicated issue on the definition repository (search open
     issues first) — the audit's only external write.
   - Sample up to three reports of the week: criteria file predates the test file; no
     `verified` without a baseline failure; every tested AC has a candidate video and its
     `AC-<k>` screenshot; AC blocks contain checks only; no internal identifiers or
     credentials in the text, the screenshots or the first and last frames you look at.
   - Benchmark: the newest line of `work/benchmark/history.jsonl` — its age, accuracy and
     `false_verified` (above 0 is a red line until a later run is clean); a benchmark
     never run, or older than two months with cases defined, is a warn.
   - Spec quality: this week's `not-testable` verdicts and `testable: no` ACs by reason,
     issues without "Done when", and how many suggested rewrites authors adopted (an
     issue that became due again by `ac_changed` after a `spec-feedback` file).
   - Flakiness: rows added to `work/FLAKY.md` this week, tests `quarantined`, and whether
     one cause dominates (the same page, the nested product right after `up`).
   - Triage health: heals this week from `work/HEALS.md` (each one's basis is a UI-map
     change or an issue — sample one), tests at three heals a month, `needs-review` items
     the operator has not answered, `retired` tests.
   - Trends: verdict distribution (100 % one verdict is suspicious), `inconclusive`
     share (a non-discriminating suite), replay cache `handed_off + missed` share from
     `REGRESSION.log`, environment failures per week, and one line of `needs-review`
     signal items per week from `stats.signals_by_week` (a rising line while every test
     passes is drift the suite does not see).
3. Report to the chat UI, traffic-light:

```
🩺 Quality Inspector weekly audit — <date> · 🟢 N ok · 🟡 N warn · 🔴 N fail
Week in numbers: issues tested N (verified a · failed b · inconclusive c · blocked d) · env failures N · cache replay x %
🔴 <id> — <detail>          (every fail, never summarized away)
🟡 <id> — <detail>
🟢 all other checks passed (<count>)
Action needed: <one line per item needing the operator, or "none">
```

4. Append `<ISO> ok=<n> warn=<n> red=<n> sent=chat` to `work/AUDIT.log`.

A boundary probe that `fail`s is always the first line of the report: the agent could
read source, and every verdict since the rules changed is suspect.
