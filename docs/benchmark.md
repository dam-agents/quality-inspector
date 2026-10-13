# The benchmark — measuring this agent

A verdict is only worth something if the agent that gives it is right. The benchmark runs
the whole issue pipeline on cases whose right answer the operator knows, and scores it.
It is how "did the model upgrade help?", "did the new `e2e` break judgment?" and "is a
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
5. `bash "$HOME/scripts/benchmark.sh" score "$RUN"` → the summary (also appended to
   `work/benchmark/history.jsonl`).
6. `env.sh unlock benchmark`. Report, and publish it as one artifact when
   `artifact_reports: enabled`:

```
📏 Benchmark <RUN> — AC accuracy 0.92 (23/25) · issue accuracy 0.88 · false verified 0 · false failed 1 · blocked 8 %
vs last run: accuracy +0.04 · cost −12 % · minutes +5
Misses: false-claim AC-1 expected failed, got inconclusive — <one line why, from its report>
```

**`false_verified` above 0 is the headline**: the agent called something verified that is
not. Name every such case first, with its report, and recommend not trusting this
instance's `verified` verdicts until the cause is fixed.

## Rules

- The benchmark never touches the production state: no QA rows, no suite tiers, no
  comments; its tests are not promoted and never replay nightly.
- A miss is analysed, never "fixed" by editing the case's expectation without the
  operator. A case that turns out to be wrong is the operator's to change.
- Results are append-only. A run whose `missing` is above 0 is reported as incomplete,
  not as a score.
