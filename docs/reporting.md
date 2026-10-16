# Verdicts and reports

Step 7–8 of [issue-qa.md](issue-qa.md), and every `reports_due` entry.

## Verdicts

Per AC, from the candidate and baseline summaries (`scripts/suite.sh summary <label>`)
and the failing traces:

| Candidate | Baseline | AC verdict |
| --- | --- | --- |
| passed | failed — assertion ran and was false | `verified` |
| passed | blocked, `baseline_blocked_reason: absent` | `verified` |
| passed | blocked for `environment`, `model` or `setup` | `inconclusive`, with a note naming the reason |
| passed | passed | `inconclusive` — the behaviour predates the change, or the test does not discriminate |
| passed | not run (`baseline_channel: none`) | `inconclusive` |
| failed — assertion ran and was false | any | `failed` |
| could not reach the AC block (step failed, timeout, missing dependency) | any | `blocked` |
| mixed passes and failures on the confirmation re-run, either side | any | `flaky` |
| — (criterion `testable: no`) | — | `not-testable` |

Issue verdict: `failed` if any AC failed; else `verified` if every testable AC is
verified; else `partial` if at least one is verified; else `inconclusive` / `blocked`
(a `flaky` AC counts as blocked) by majority; `not-testable` when no AC was testable.

**Baseline blocked.** On the baseline the usual red is a test that ends before its AC
block because the control the issue introduces does not exist yet. Every AC whose baseline
run did not reach its AC block gets one `baseline_blocked_reason`:

- `absent` — counts as red. The failing step acts on or waits for a control or page the
  issue introduces (named in its criteria), the step's screenshot shows the screen without
  it, and the failure text (the agent's, or a locator's timeout) says nothing matched.
- `environment` (the product did not answer), `model` (the agent step failed on its own: a
  model error, a limit, a wrong turn on a screen that has the control), `setup` (the test
  failed before the issue's area) — not red.
- `null` — the baseline reached the AC block, or did not run.

Doubt between `absent` and the others is not `absent`: a `verified` needs the proof.

A `failed` verdict claims a product defect. Before you write it, read the candidate
trace and confirm the assertion evaluated a screen that got there the way a user would.

## Verdicts file — `work/issues/<n>/verdicts-<ac_hash>-<candidate>.json`

Your judgment, the renderer's only input besides the runs:

```json
{"issue": 42, "title": "…", "ac_hash": "3f9a0c12b7de", "criteria_source": "done-when",
 "candidate": "0.0.0-main.5203", "baseline": "0.2.19",
 "candidate_run": "issue-42-candidate", "baseline_run": "issue-42-baseline",
 "verdict": "partial", "generated_utc": "2026-10-12T19:20:00Z", "display_name": "<display_name>",
 "acs": [{"id": "AC-1", "name": "…", "given": "…", "when": "…", "then": "…", "surface": "ui",
          "testable": true, "verdict": "verified", "baseline_blocked_reason": null,
          "note": "optional, one sentence"}],
 "notes": ["assertion edits after the first run, blocked reasons, anything a reader needs"]}
```

`given` / `when` / `then` are copied from the criteria file verbatim; `baseline_run` is
`null` when no baseline ran. Explorations and `noticed` add their own keys, never touching
`acs` or `verdict` ([explorations.md](explorations.md) → **Reporting**, **Noticed in passing**). Never: credentials,
internal state, the operator conversation.

## The report — `work/issues/<n>/report-<ac_hash>-<candidate>/`

`node "$HOME/scripts/render-report.mjs" <verdicts.json> <dir>` writes:

- `index.html` — one self-contained page: the issue verdict, "N of M criteria tested" (an
  AC judged `verified`, `failed` or `inconclusive`; `comment.md` carries it too), a summary table, and per AC
  the frozen criterion, then candidate and baseline side by side, each with the **video
  of the whole test**, the screenshots captioned by their step (the `AC-<k>` still first),
  the step list with durations and replay-cache use, the assertion error, and the trace
  (Playwright `trace.zip`, or the trace page from `e2e` 0.19 on).
- `media/` — the copied videos, screenshots and traces it links to.
- `comment.md` — the short issue comment, with the literal `EVIDENCE_LINK` to replace.

It reads only tests tagged `issue-<n>` (a scenario: `scenario-<k>`) and `ac-<k>` (explorations: `issue-<n>-ex` and
`ex-<k>`), so the sign-in setup test is never in the evidence. Videos are not redacted by
`e2e`; that is why no test but the setup one ever types a credential. Text artefacts are:
`scripts/suite.sh` replaces every `work/env/credentials.env` secret with `***` in the run
dir and its summary.

## Delivery

Order per effect is **send-then-record**: its `intent` ledger line, the send, its
`done`/`failed` line ([logging.md](logging.md) → **Ledger of external writes**), then
`status: reported` as the next state write. A failed delivery leaves `report_pending`, is
logged, and the next run's `reports_due` retries only the delivery — the tests are not
re-run. Never retry within the same run.

1. **Artifact** (`artifact_reports: enabled`): publish the report directory with the
   platform's artifact tools — `index.html` as the artifact, `media/` beside it
   (`create_artifact_folder`, files through `create_artifact_upload_url`), keeping the
   relative paths so the page's links resolve. `work/issues/<n>/artifact.id` holds the
   reference — when it exists, publish a new revision (`update_artifact`) instead of a new
   artifact, and write the file immediately after a create. Visibility stays private;
   share it with the issue's readers only through the comment's link. Open the published
   page once and confirm a video plays before recording the delivery.
2. **Issue comment** (`issue_comments: enabled`):
   - **Own markers only.** A marker — this one, `-data`, `-spec` — counts only in a comment
     whose `user` is the agent's own login (`github.sh whoami` — `github_login` when set —
     once per run); anyone can paste one. A failed lookup is "could not look".
   - Right before posting, list the issue's comments (`github.sh comments <n>`) and look for
     `<!-- <marker_prefix> issue=<n> ac=<ac_hash> build=<candidate> -->`. Found → do not
     post; record as delivered. A failed listing is "could not look" → do not post, log,
     leave `report_pending`.
   - Post `comment.md` with `github.sh comment <n> <file>` (with `EVIDENCE_LINK` replaced by the artifact's share link, or by
     "evidence kept by the agent" when artifacts are disabled) with that marker and one
     machine copy next to it:
     `<!-- <marker_prefix>-data {"issue":42,"ac":"…","build":"…","verdicts":{"AC-1":"verified"}} -->`.
   - When the worklist entry had `retest_label_present`, remove that label after a
     successful post (`github.sh unlabel <n>`).
3. **Spec feedback comment** (`spec_feedback: enabled`, independent of
   `issue_comments`): when `spec-feedback-<ac_hash>.md` exists, post it (`github.sh comment`) once per
   `ac_hash` with the marker `<!-- <marker_prefix>-spec issue=<n> ac=<ac_hash> -->`,
   checked the same way right before posting. Tone: a short, specific suggestion to the
   author; no verdict language.
4. Both artifact and comments disabled → the report stays in `work/` and is summarized in
   the chat UI; still set `reported`.

Every delivery outcome is one event (`report_delivered` / `report_failed`, with
`issue=<n>` and the surface), beside the ledger pair of each send — [logging.md](logging.md).
