# The benchmark — measuring this agent

The benchmark runs the whole issue pipeline on cases whose right answer the operator knows,
and scores it: "did the model upgrade help?", "did the new `e2e` break judgment?", "is a
`verified` from this agent trustworthy?" get numbers instead of impressions.

## Cases — `work/benchmark/cases.json` (the operator's)

```json
[
  { "id": "rename-agent", "type": "issue", "issue": 4552,
    "candidate": "0.0.0-main.5937", "baseline": "0.2.20",
    "expected": { "verdict": "verified", "acs": { "AC-1": "verified" } },
    "note": "known fixed between these builds" },
  { "id": "false-claim", "type": "criteria", "build": "0.2.21",
    "title": "The home page greets the user with a purple unicorn",
    "criteria": [ { "id": "AC-1", "given": "a signed-in user", "when": "they open the home page",
                    "then": "a purple unicorn greets them", "surface": "ui" } ],
    "expected": { "acs": { "AC-1": "failed" } } }
]
```

- **`issue`** cases replay a real, already-decided issue at pinned builds — true positives
  (`verified`), known regressions (`failed`), known-untestable issues (`not-testable`).
- **`criteria`** cases give frozen criteria directly, at one build — controls the product
  cannot satisfy (expected `failed`) and plain truths (expected `inconclusive` without a
  baseline, or `verified` against a baseline without the feature).
- A useful set has both kinds and at least one case per verdict the agent may give.
  Ground truth lives only here; it is never shown to the pipeline that runs a case.

### Escape cases

An `issue` case whose `expected` holds `bug` — one sentence of what a user sees go wrong — replays an
issue at the build where a defect got through this agent ([escapes.md](escapes.md)). The sentence is
the answer key: the run scores only when what it produced describes **that** defect. `escapes.mjs
propose-case` writes one to `work/benchmark/proposed/E-<k>.json`; the operator's "accept E-<k> as a
benchmark case" adds it here. Keep the cases that pass beside the ones that missed, as the control
against flagging too much: a set of escape cases alone rewards an agent that fails everything.

## The run (schedule `quality-inspector-benchmark-monthly`, or "run the benchmark")

The pre-flight's `benchmark` mode is due when cases exist and the last run is 28 days old,
or the definition version, `e2e_version`, `e2e_model` or `profile` changed since.

1. `RUN=$(date -u +%Y%m%dT%H%M%SZ)`; `bash "$HOME/scripts/benchmark.sh" prepare "$RUN"` —
   one `work/benchmark/runs/$RUN/<case>/input.json` per case, the expected answers removed.
2. `env.sh lock benchmark` (busy → end, log it).
3. **Each case in a harness sub-agent** (your harness's own, not a platform spawn — it
   needs this VM's nested product), given only its `input.json` path and this file's
   step 4. It must not read `cases.json`, `history.jsonl` or other cases; the brief says so.
4. *The sub-agent's brief:* run [issue-qa.md](issue-qa.md) steps 3–8 for the input —
   for `issue`, freeze from the issue as usual; for `criteria`, the given criteria **are**
   the frozen criteria; builds from the input (no baseline run when it names none) —
   with these differences: tests under `work/suite/tests/benchmark/<case>.e2e.ts` tagged
   with the input's `tag`; every file under `work/benchmark/runs/$RUN/<case>/` (criteria,
   `verdicts.json` with `minutes` and `cost_usd` added, the rendered report); no
   `QA.md`/`SUITE.md` rows, no comments, no artifact.
4b. **Grade each escape case** yourself, after its sub-agent ended — the grader is not the pipeline:
   read the case's `bug` in `cases.json` and its run directory, and write
   `work/benchmark/runs/$RUN/<case>/grade.json`:
   `{"stages": {"criteria": …, "test": …, "flagged": …, "reported": …}, "by": "<AC-k | IN-k | EX-k | null>", "note": "…"}`,
   each `true` or `false`:
   `criteria` — a criterion, intent test or exploration states the behaviour the bug breaks;
   `test` — its test reached the step where the bug shows (its trace shows the input, role and state);
   `flagged` — its verdict is not a pass (`failed`, `regression`, `observation`), or a `noticed` item shows it;
   `reported` — the report's analysis has a problem that describes this bug.
   A finding about something else is `false`, however true it is. The score counts a stage only while
   every stage before it holds.
5. `bash "$HOME/scripts/benchmark.sh" score "$RUN"` → the summary (also appended to
   `work/benchmark/history.jsonl`). With escape cases it adds `escape_recall` per stage and, per case,
   `lost_at` — the first stage that lost the bug (`ungraded` without a `grade.json`). A recall that drops
   between two stages shows where defects are lost: `criteria` → the freeze, `test` → authoring,
   `flagged` → judgment, `reported` → the report.
6. `env.sh unlock benchmark`. Report, and publish it as one artifact when
   `artifact_reports: enabled`:

```
📏 Benchmark <RUN> — AC accuracy 0.92 (23/25) · issue accuracy 0.88 · false verified 0 · false failed 1 · blocked 8 %
vs last run: accuracy +0.04 · cost −12 % · minutes +5
Misses: false-claim AC-1 expected failed, got inconclusive — <one line why, from its report>
Escapes: 4 cases · recall criteria 1.00 → test 0.75 → flagged 0.50 → reported 0.50 · lost: escape-E-3 at test, escape-E-7 at flagged
```

**`false_verified` above 0 is the headline**: the agent called something verified that is
not. Name every such case first, with its report, and recommend not trusting this
instance's `verified` verdicts until the cause is fixed.

## Rules

- The benchmark never touches the production state (step 4); its tests are never promoted
  nor replayed nightly.
- A miss is analysed, never "fixed" by editing the case's expectation without the
  operator. A case that turns out to be wrong is the operator's to change.
- Results are append-only. A run whose `missing` is above 0 is reported as incomplete,
  not as a score.
