# Stress — bounded load on the local product

A module of the modules run ([modules.md](modules.md)), switch `stress_checks`, always last
in the run. It loads the nested product on `localhost` — nothing else: the script refuses
any other origin and aborts every browser request to another host, the owner's sign-in
included. No model calls. Load against anything but the nested product stays out of scope
([security.md](security.md)).

`node "$HOME/scripts/stress.mjs" "$HOME/work/inventory/<c>/inventory.json" --build <c> [--previous "$HOME/work/stress/<p>/stress.json"]`
→ `work/stress/<c>/stress.json` (`--dry-run` prints the plan). `<p>` is the worklist's
`previous.stress`. Exit 1 = a browser ran and the owner could not sign in: an environment
failure. Exit 3 = no browser to sign in with (`{"error": "no browser: …"}`): the module
failed — an `<ISO> ERROR: module=stress candidate=<c> <error>` line in `work/MODULES.log`, never
`ran`. Neither writes `stress.json`.

**Load**, as the owner: `stress_max_concurrency` workers for `stress_duration_s` replay the
map's `GET` requests round-robin (writes are never replayed); then up to 5 browser
contexts load the first 5 pages for a third of that time; then, 5 s later, one request to
the app. **Caps in code**, whatever the settings say: 50 workers, 300 s, 20 000 requests,
30 endpoints, 5 contexts — a clamp is a note.

| Id | Fails when | Severity |
| --- | --- | --- |
| `STRESS-HEALTH-1` | the app does not answer 2xx/3xx within 10 s after the load | critical |
| `STRESS-API-1` | an endpoint's error rate (non-2xx/3xx and network errors) > 1 % | high |
| `STRESS-API-2` | an endpoint answered 5xx | high |
| `STRESS-UI-1` | a page failed to load, answered 5xx or threw under load | high |
| `STRESS-API-3`, `STRESS-UI-2` | p95 > 2× the previous build's and ≥ 1000 ms more | medium |

A comparison without a previous build is `skipped`; so is the UI half without a browser
(only with `--skip-signin`, or when it fails after the sign-in). Evidence is counts,
statuses and timings only — never a header, cookie or body.

**A failure is confirmed once.** Any `fail` in `stress.json` → keep the first run and run
again with the same settings, naming it:
`cp work/stress/<c>/stress.json work/stress/<c>/stress.first.json`, then the same command
with `--confirm "$HOME/work/stress/<c>/stress.first.json"`. It overwrites `stress.json`: a
check (same id and target) that failed in the first file and passes now is `flaky` — not a
finding, not in `counts`' severities; one that fails again stays `fail`. Other settings
than the first run's are a note; another build is refused. A `critical` leads the run's chat
summary. Then `modules.sh ran stress <c> critical=<n> high=<n> medium=<n>` from the final
`counts`. The run's closing `env.sh reset` clears what the load left.
