---
name: create-issue
description: >-
  Open one GitHub issue on the target repository for one or more problems the Quality
  Inspector found — a failed or regressed test of a criterion, an exploration's observation, a
  design finding, a validation case, a stress check — with an exact description of what is
  wrong, how it should work and where that comes from (the original issue's criterion), the
  steps to reproduce it, the evidence (screenshots, video, the marked crop) and a "Done when"
  the issue run can test once it is fixed; optionally labelled for the software architect to
  fix. Use it only when the operator asks in the direct session — "create issue for #42 AC-2",
  "create issue for D-7, D-9, VAL-3 for the architect", the dashboard's "Report it as a GitHub
  issue" and its bar of selected problems send exactly these words.
---

# Create a found issue

The operator's word alone opens an issue (CLAUDE.md → trust boundary): in the direct session,
never in a scheduled run, a Slack turn or a shared dashboard viewer's turn. A viewer's button
asking for one is declined like any other non-scenario request: change nothing, log
`artifact_viewer_declined`, end ([docs/modules.md](../../docs/modules.md) → Control).
`scripts/github.sh create-issue` refuses outside the direct session, and the policy hook refuses
the command in a scheduled or channel turn (rule `issue-create`).

## The request

`create issue for <ref>[, <ref>…][ for the architect]` — 1 to 20 refs, one issue for all of them:

| Ref | The problem |
| --- | --- |
| `#42 AC-2`, `#42 EX-1` | a criterion's or an exploration's test of issue #42 — its newest bad result (failed, regression, needs-review, flaky, observation, blocked), else its newest |
| `S-7 AC-1`, `P-<slug> AC-1` | a scenario's or a profile scenario's criterion |
| `D-12` | a design finding ([docs/ui-sweep.md](../../docs/ui-sweep.md)) |
| `VAL-3` | a validation case of the newest validation run ([docs/validation.md](../../docs/validation.md)) |
| `STRESS-API-2` | a check of the newest stress run, on every target it failed ([docs/stress.md](../../docs/stress.md)) |

`for the architect` adds `fix_label` (work/CONFIG.md; no default) — the label the software
architect picks up to fix the issue. Without `fix_label` say so and offer the issue without it.

## Procedure

1. **Draft.** `node "$HOME/scripts/issue-draft.mjs" "<ref>, <ref>…" [--fix]` → `{dir, refs,
   build, title, labels, images, video, missing, already, notes}`, the draft in
   `work/found/<slug>/`: `title.txt`, `body.md`, `draft.json`, `evidence/` (`index.html` and
   `media/`). Exit 2 = none of the refs is known: tell the operator which, end. `missing` refs
   are left out — say so. `already` names refs that have an issue (work/FOUND.md): give its
   link and ask whether to open another; only on a yes pass `--again` in step 5.
2. **Check it before anyone sees it.** Read `body.md` and look at every image in
   `evidence/media/`. The draft claims a product defect, so hold it to
   [docs/reporting.md](../../docs/reporting.md) → Verdicts: the screen got where it is the way a
   user would, and what it shows contradicts the expected behaviour. A `flaky` or `blocked`
   result, a `suspect` design finding, or a screen that shows a test's own mistake is not a
   defect as it stands: tell the operator and draft it only if they still want it, saying so
   in the body. Then edit `body.md` so a developer can act on it without asking:
   - **The problem** — what a user sees, in a sentence, then the check's own message.
   - **The correct function** — the frozen criterion (Given / When / Then) with its source
     (`#42` links the original issue on GitHub); for a module finding, the check's rule.
   - **Steps to reproduce** — numbered steps a person can follow in the product: the test's
     `agent.act` steps rewritten as plain actions, concrete values where the test has
     `{tokens}` that are not secrets, the build it was seen on, and when it last worked.
   - **Evidence** — what each screenshot shows; the evidence page carries them
     (`EVIDENCE_LINK`).
   - **Done when** — keep it: an issue run freezes its criteria from that section once the
     issue carries `qa_label`.
   Write every sentence you add or change in ASD-STE100
   ([docs/reporting.md](../../docs/reporting.md) → **Artifact text is ASD-STE100**).
   Keep the hidden marker line as it is. Never add: the product's source or a code location
   (you have none), internal ids of the product's data, a credential or token, `work/env/`,
   a verdict's notes, a triage explanation, `work/LESSONS.md`, the operator conversation,
   anything of `work/security/`. Several refs keep one section each.
3. **Evidence page.** Make it one file — `node "$HOME/scripts/report-media.mjs" publish
   work/found/<slug>/evidence private` (the media go into the page) — and publish
   `evidence/publish.html` as an artifact, exactly as [docs/reporting.md](../../docs/reporting.md)
   → Delivery step 1 for a private report (an upload URL, private), ledgered (surface
   `artifact`, `issue=-`, key `found-evidence@<slug>`). Replace every `EVIDENCE_LINK` in
   `body.md` with the artifact's share link, never a `public` one; with
   `artifact_reports: disabled`, or no image and no video, with "the evidence is kept by
   the agent — ask in its chat". GitHub's API takes no attachment, so the pictures are on
   that page, not inline.
4. **Ask.** Show the operator the title, the labels (`found_label`, `fix_label` with
   `for the architect`) and the whole body in the chat, with the evidence page's link, and
   ask: open it? Changes requested → edit and show again. No yes → nothing is posted; the
   draft stays in `work/found/`.
5. **Open it.** Ledger `surface=issue action=intent issue=- key=found@<slug> target=<target_repo>`,
   then `bash "$HOME/scripts/github.sh" create-issue "<dir>" [--fix] [--again]` →
   `{refs, number, url, labels}`, then `action=done issue=<number>` (or `failed`). github.sh
   writes one work/FOUND.md row per ref and logs `issue_created`. A refusal (exit 3) is
   final: tell the operator its reason. Labels GitHub dropped (the token may not label) are
   missing from `labels`: say so.
6. **Answer** with the issue's link and its labels in one line, then rebuild and publish the
   catalog ([docs/catalog.md](../../docs/catalog.md) → Build and publish): each problem shows
   its issue.

Never add `qa_label` or `retest_label`: whether the fixed issue is tested is the team's call.
One issue per request; a request for twenty refs is one issue with twenty sections.
