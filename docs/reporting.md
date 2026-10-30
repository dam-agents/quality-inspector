# Verdicts and reports

Step 7–8 of [issue-qa.md](issue-qa.md), and every `reports_due` entry.

## Verdicts

Per AC, from the candidate and baseline summaries (`scripts/suite.sh summary <label>`)
and the failing traces:

| Candidate | Baseline | AC verdict |
| --- | --- | --- |
| passed, but the screen at the check shows an error (**Error at the check**) | any | `blocked`, with `error_at_check` |
| passed | failed — assertion ran and was false | `verified` |
| passed | blocked, `baseline_blocked_reason: absent` | `verified` |
| passed | blocked for `environment`, `model` or `setup` | `blocked` — no red-green was possible; `cause: environment` for `environment`, else `test` |
| passed | passed | `inconclusive` — the behaviour predates the change, or the test does not discriminate |
| passed | not run (`baseline_channel: none`) | `inconclusive` |
| failed — assertion ran and was false | any | `failed` |
| could not reach the AC block (step failed, timeout, missing dependency) | any | `blocked` |
| mixed passes and failures on the confirmation re-run, either side | any | `flaky` |
| — (criterion `testable: no`) | — | `not-testable` |

**Error at the check.** Examine the candidate's `AC-<k>` still of every AC that passed. If it
shows an error message that the criterion does not expect — an error toast or banner, an error
page, a dialog that says something failed — the pass does not count, also when the message is
about a different area: the check ran on a product in a broken state. The AC is `blocked`,
`error_at_check` quotes the message as written, and `cause` is what the message shows
(`environment` for the nested platform or the VM, for example a runner that cannot start;
`product` for a function of the product). An error that the criterion itself expects (the
error text that the issue asks for) is not an error at the check. The same message on the
baseline's still makes its red not count: `baseline_blocked_reason: environment`.

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
  failed before the issue's area) — not red, so a candidate pass cannot prove the change:
  the AC is `blocked` (the table above), to test again when the cause is repaired.
- `null` — the baseline reached the AC block, or did not run.

Doubt between `absent` and the others is not `absent`: a `verified` needs the proof.

A `failed` verdict claims a product defect. Before you write it, read the candidate
trace and confirm the assertion evaluated a screen that got there the way a user would.

**Cause of a failure.** Every AC, intent test or exploration whose verdict is `failed`,
`blocked` or `flaky` gets one `cause` — the dashboard shows it beside the verdict, so a reader
sees at once whose problem it is ([catalog.md](catalog.md)):

- `product` — the function under test does not do what the criterion says; the test and the
  environment worked. The only cause a `failed` may have.
- `test` — the test itself is wrong: a step, a control name, a wait, a check, or the agent
  step (`model`) that went wrong on a screen that has the control.
- `environment` — the product as a whole did not work in this VM, not the function under test:
  its install, its deployment configuration, a service it needs, the nested platform, the VM
  (the product did not answer, a page of another area failed, sign-in failed).

Doubt between `product` and the others is `product` for a `failed` (it claims the defect);
for a `blocked` or `flaky` result name the cause the evidence shows, else leave `cause` out —
the dashboard then says "cause not known". Every other verdict has `cause: null`.

## Verdicts file — `work/issues/<n>/verdicts-<ac_hash>-<candidate>.json`

Your judgment, the renderer's only input besides the runs:

```json
{"issue": 42, "title": "…", "ac_hash": "3f9a0c12b7de", "criteria_source": "done-when",
 "candidate": "0.0.0-main.5203", "baseline": "0.2.19",
 "candidate_run": "issue-42-candidate", "baseline_run": "issue-42-baseline",
 "verdict": "partial", "started_utc": "2026-10-12T18:41:07Z", "generated_utc": "2026-10-12T19:20:00Z", "display_name": "<display_name>",
 "acs": [{"id": "AC-1", "name": "…", "quote": "…", "given": "…", "when": "…", "then": "…", "surface": "ui",
          "testable": true, "verdict": "verified", "baseline_blocked_reason": null,
          "cause": null, "error_at_check": null, "mark": null, "note": "optional, one sentence"}],
 "open_questions": [{"id": "Q-1", "ac": "AC-2", "question": "…",
                     "variants": [{"source": "the issue", "quote": "…"}, {"source": "a comment of 2026-10-20", "quote": "…"}]}],
 "notes": ["assertion edits after the first run, blocked reasons, anything a reader needs"]}
```

A scenario's file (`"mode": "scenario"`) adds `request_file`: the path under `work/` of its
words as received (`scenarios/S-7/request.md`, `scenarios/P-<slug>/source-<spec_hash>.md` or `.feature`),
which the renderer shows verbatim above the criteria ([scenarios.md](scenarios.md) → State).
`given`, `when`, `then`, `quote` and `open_questions` are copied from the criteria file verbatim
([acceptance-criteria.md](acceptance-criteria.md) → **Contradictions**); they never change a
verdict. `baseline_run` is `null` when no baseline ran. `started_utc` is the run's start (the `issue_start`'s time; the
dashboard shows the run's length from it); `cost_usd` only when the platform states the run's
cost — never an estimate, else leave it out. Intent tests (`intents`, `intent_verdict`, [intent.md](intent.md) → Verdict), explorations and `noticed` add their own keys, never touching
`acs` or `verdict` ([explorations.md](explorations.md) → **Reporting**, **Noticed in passing**).
`environment` `{url, expires_utc, account}` — the row `env.sh keep` printed, when the run kept
its platform Environment for a person ([nested-env.md](nested-env.md) → **Kept for a person**):
the page and the comment say where to open it, until when, and the account's name. Never:
credentials (the account's password included), internal state, the operator conversation.

**The mark — `mark`.** A screenshot must show the problem, not only the page. A failed check of
a test marks itself: a red frame on the still `<id>: the failing check`
([test-authoring.md](test-authoring.md) → **The mark of a failed check**). When an entry
(`acs`, `intents`, `explorations`) is not a pass and its run has no such still — an
`agent.assert` check, a test that imports `expect` from `e2e`, a problem on a different control
than the check's — examine the entry's still (the `<id>:` screenshot, else the screen at
failure). When the problem shows on it, add:

```json
"mark": {"box": {"x": 357, "y": 553, "w": 447, "h": 49}, "saw": "The editor sees the Chat control.",
         "shot": "AC-8: the general page", "side": "candidate"}
```

- `box` — the area of the problem in pixels of that screenshot file (its own size, not a
  scaled view); `boxes` — up to 8 such areas instead.
- `saw` — one sentence: what a user sees in the frame (ASD-STE100, below).
- `shot` — optional: the start of the caption of a different still of the same test (a step
  that shows the problem better); `side` — `baseline` only when the baseline decides the verdict.

The report, the dashboard and a found issue draw it as an orange frame, with `saw` in the
caption. It is the agent's reading of the screen, so it never changes a verdict, and it is not
drawn where the test's red frame exists. A frame that cannot be drawn (a box off the screenshot)
is left out with its caption, and the next choice applies. A problem that does not show on a screenshot (an
absent control, a wrong answer of the API) gets no mark; leave `mark` out.

**The agent's analysis — `analysis`.** Every verdicts file — an issue run's, a scenario run's, a
night's (`work/regression/<c>/verdicts.json`) — carries your reading of the run for a person, the
first thing the report and the dashboard show. The badges and the counts say *what*; this says
*why* and *what to do*:

```json
"analysis": {
  "summary": "The night ran 3 test cases of P-agent-files-a-github-issue-asked-in-slack. All 3 are blocked: the product has no GitHub connection in this environment. No product defect is known.",
  "problems": [{"title": "The agent of the product cannot connect to GitHub",
                "about": ["P-agent-files-a-github-issue-asked-in-slack AC-1", "P-agent-files-a-github-issue-asked-in-slack AC-2"],
                "cause": "environment",
                "what": "The setup step opens the connections page. The GitHub connection shows \"Not connected\". The next steps did not run.",
                "where": "/settings/connections, the step \"connect the agent to GitHub\"",
                "why": "The profile gives no GitHub sandbox account, so the nested product has no token for GitHub.",
                "fix": "Add a GitHub sandbox account to the profile (its repository). The next night then runs the test.",
                "certainty": "high"}],
  "next": "Ask the profile's owner for a GitHub sandbox account, or retire the scenario."}
```

- `summary` — two to four sentences: what ran, the result, and why it needs a person, or that it
  does not. A `needs-review` night names the result or signal that made it so.
- `problems[]` — one per problem, not per criterion: three blocked criteria with one reason are one
  problem whose `about` names all three (`#N AC-k`, `#N IN-k`, `#N EX-k`, `S-k AC-j`, `P-<slug> AC-j`).
  Each verdict that is not a pass is in one problem. Empty when all passed. Most important first.
  - `title` — the problem in at most 80 characters, in the user's words ("The upload stops at 99 %"),
    never a verdict name.
  - `cause` — `product`, `test` or `environment`, as **Cause of a failure** above; `null` when not known.
  - `what` — what the test did and what it saw, from the evidence: the step, the screen, the message.
  - `where` — the page, the control or the step, as the product shows it.
  - `why` — the most probable reason, as far as the evidence shows it. You see the product from the
    outside only ([black-box.md](black-box.md)): name what you observed ("the request
    `POST /api/upload` answered 413"), never a guess about the code. Not known → say what you
    examined and what is still open.
  - `fix` — what repairs it and whose task it is: the product's team (a defect: the behaviour that
    the criterion expects), the operator (a test to heal or retire, an open question to answer, a
    setting), the profile's owner (an account, an egress rule), or the agent's next run.
  - `certainty` — `high` (the evidence shows it directly), `medium` (it agrees with the evidence;
    another reason is possible), `low` (a hypothesis to examine).
- `next` — the one action a person should do first, or `null` when nothing waits on a person.

Write it last, from the final verdicts, in ASD-STE100 (below). It goes on the dashboard, which the
operator may share: never a credential (the builder refuses the page), a scenario's request words or
its requester (the builder drops that field), a security finding, the operator conversation or
`work/LESSONS.md`.

**Artifact text is ASD-STE100** (Simplified Technical English). Every sentence a reader sees in an
artifact — a report, the dashboard, an evidence page, a found issue's body — and every text you
write for one (a verdict's `note`, `notes`, `explanation`, `analysis`, an edit of a found issue): one statement or instruction
per sentence, at most 20 words for an instruction and 25 for a description, active voice, simple
tenses, one word for one meaning from the common technical words (`examine`, not "look into";
`repair`, not "fix up"), no idioms, phrasal verbs or `-ing` nouns. Identifiers, commands, quoted
product text and the frozen criteria stay verbatim.

## The report — `work/issues/<n>/report-<ac_hash>-<candidate>/`

`node "$HOME/scripts/render-report.mjs" <verdicts.json> <dir>` writes:

- `index.html` — the page: the issue verdict, "N of M criteria tested" (an
  AC judged `verified`, `failed` or `inconclusive`; `comment.md` carries it too), a summary table, and per AC
  the frozen criterion, then candidate and baseline side by side, each with the **video
  of the whole test**, the screenshots captioned by their step (a marked still first — the
  test's red frame or the agent's orange one, **The mark** above — then the `AC-<k>` still),
  the step list with durations and replay-cache use, the assertion error, and the trace
  (Playwright `trace.zip`, or the trace page from `e2e` 0.19 on). Each AC names its source issue,
  linked to it when `target_repo` is set, and quotes the source verbatim; an open question
  (`open_questions`) has its own section above the criteria. A click on a screenshot, or "Enlarge"
  under a video, shows it larger over the page (`scripts/lib/media-viewer.mjs`: zoom in and out,
  fit, 1:1; the video keeps playing). No screenshot links its file: a strict viewer opens an empty
  page for it, and the browser downloads the published file. When `report.json` gives the video's
  start and each step's start and duration, the video pauses for 1.5 s after each step and names
  the step under it (and in the viewer's bar), so a reader sees the result of a short step; a
  checkbox turns the pauses off, and a click on a step in the step list plays the video from that
  step. Without these times the video plays as recorded.
- `media/` — the copied videos, screenshots and traces it links to by relative paths, which
  only `report-media.mjs` turns into the published file `publish.html` (**Delivery** step 1).
- `comment.md` — the short issue comment, with the literal `EVIDENCE_LINK` to replace.
- `proof.json` (not regression or security) — the screenshots in `media/` that back the
  verdicts, per criterion and deciding side, for the one picture of a Slack answer
  (`scripts/evidence-sheet.mjs` → `evidence.png` beside it; [slack.md](slack.md) → **The
  answer in the thread**). Neither is published with the artifact.

It reads only tests tagged `issue-<n>` (a scenario: `scenario-<k>`) and `ac-<k>` (intent tests: `in-<k>`; explorations: `issue-<n>-ex` and
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

1. **Artifact** (`artifact_reports: enabled`): an artifact is **one file** — a viewer never
   gets `media/`, so a relative `media/<name>` link answers 404. First make the page one file
   with `node "$HOME/scripts/report-media.mjs"` (its header has the contract), then publish
   `<dir>/publish.html` — never a page with `media/` links — through `create_artifact_upload_url`.
   **Every upload sends its `Content-Type` header**: a page `text/html; charset=utf-8`, a media
   file the `content_type` that `report-media.mjs list` gives it (`image/png`, `application/zip`, …).
   An upload without it (curl's `PUT --data-binary` default) is stored as
   `application/x-www-form-urlencoded` and served as `application/octet-stream` with
   `Content-Disposition: attachment`: a click downloads the file, and a strict viewer shows no
   image or video.
   - **A public report** (below, or a Slack thread's): `report-media.mjs list <dir>`; each
     file with `upload: true` and `url: null` becomes an artifact of its own — upload it with its
     `content_type`, `create_artifact` with `visibility: public` and its `file_name`, then
     `report-media.mjs set <dir> <path> <shareUrl> <version>` from the response — right after each
     create. **A video is never uploaded** (`upload: false`): the platform's `/raw` link serves
     only images inline, any other type as `application/octet-stream` with `Content-Disposition:
     attachment`, so `publish public` puts the videos into the page as data, within the page
     limit. **The first image of a run is checked before its `set`:** `HEAD` its
     `<shareUrl>/raw?v=<version>` and pass the served type as `set … --served-type <type>`. On
     another type `set` exits 1, records no address and refuses that type: from then on `list`
     gives its files `upload: false`, and the page carries them too — the delivery goes on, with
     no further upload of that type. The rejected artifact is public and stays: never delete it
     yourself — log a `warn` line with its id and name it in the chat UI for the operator to
     delete. Only on the operator's word in the direct session (the platform serves the type
     again) run `report-media.mjs unblock <dir>`; the next revision uploads that type again. A
     refused or failed `HEAD` is a `warn` line and a `set` without `--served-type`. Then
     `report-media.mjs publish <dir> public` (exit 1 names a file to upload still without an
     address); `left_out` names a file that did not fit the page (the page says so) — tell it in
     the chat when it is a video. The addresses are kept by content and type, so a revision
     uploads only new files — and again each file recorded without its type (before 3.32.1). One
     ledger pair covers the media of one report.
   - **A private report**: `report-media.mjs publish <dir> private` puts the screenshots and
     videos into the page as data, within the platform's page limit; `left_out` names what
     did not fit (the page says so) — tell it in the chat when it is a video.

   `work/issues/<n>/artifact.id` holds the
   reference — when it exists, publish a new revision (`update_artifact`) instead of a new
   artifact, and write the file immediately after a create. Visibility stays private —
   a report answered in a Slack thread under `slack_report_visibility: public` aside
   ([slack.md](slack.md) → **The answer in the thread**); share it with the issue's readers
   only through the comment's link. Open the published
   page once and confirm a video plays before recording the delivery.
   - **`report_visibility: public`** (default `private`): every report but the security run's
     ([security.md](security.md) → Rules) is published `public` — `create_artifact` with
     `visibility: public`, or `set_artifact_sharing` on one that is private (a restricted one
     stays as the operator set it). The link is then the whole access control: anyone who holds
     it sees the videos and screenshots of the nested product, and an issue's artifact is one
     per issue, so its later revisions too. It is for the dashboard: the catalog links it and
     opens the report in one click ([catalog.md](catalog.md)). Switching back to `private`
     changes no report already public — the operator makes those private in the app. Only the
     operator sets the key (CLAUDE.md → Runtime configuration).
   - **`artifact.url`**, beside `artifact.id`: after every create or revision, the response's
     `shareUrl` when it is an `https://` link (one line), else the file removed — whatever
     opened the link (this key, the operator's sharing, a Slack thread). The catalog reads it;
     nothing else does, and a link goes elsewhere only by its own rule (step 2,
     [slack.md](slack.md) → **The answer in the thread**). Never for the security run's report.
2. **Issue comment** (`issue_comments: enabled`):
   - **Own markers only.** A marker — this one, `-data`, `-spec` — counts only in a comment
     whose `user` is the agent's own login (`github.sh whoami` — `github_login` when set —
     once per run); anyone can paste one. A failed lookup is "could not look".
   - Right before posting, list the issue's comments (`github.sh comments <n>`) and look for
     `<!-- <marker_prefix> issue=<n> ac=<ac_hash> build=<candidate> -->`. Found → do not
     post; record as delivered. A failed listing is "could not look" → do not post, log,
     leave `report_pending`.
   - Post `comment.md` with `github.sh comment <n> <file>` (with `EVIDENCE_LINK` replaced by the artifact's share link —
     never a `public` one while `slack_report_visibility: public` or `report_visibility: public`,
     which may have opened it for a Slack thread ([slack.md](slack.md) → **The answer in the
     thread**) or the dashboard (step 1) — or, with none, by
     "evidence kept by the agent") with that marker and one
     machine copy next to it:
     `<!-- <marker_prefix>-data {"issue":42,"ac":"…","build":"…","verdicts":{"AC-1":"verified"}} -->`.
3. **Spec feedback comment** (`spec_feedback: enabled`, independent of
   `issue_comments`): when `spec-feedback-<ac_hash>.md` exists, post it (`github.sh comment`) once per
   `ac_hash` with the marker `<!-- <marker_prefix>-spec issue=<n> ac=<ac_hash> -->`,
   checked the same way right before posting. Tone: a short, specific suggestion to the
   author; no verdict language.
4. **Retest label** (always, independent of `issue_comments`): when the worklist entry has
   `retest_label_present` (an `issues_due` or a `reports_due` entry), remove that label
   with `github.sh unlabel <n>` after the steps above. The pre-flight checks the label
   before the row's `ac_hash`, so a label left on the issue re-tests it on every run. A
   failed removal is a failed delivery: the row stays `report_pending`, and the next run
   delivers again (the pre-flight puts a `report_pending` row in `reports_due` before it
   looks at the label).
5. Both artifact and comments disabled → the report stays in `work/` and is summarized in
   the chat UI; still remove the retest label (step 4) and set `reported`.

Every delivery outcome is one event (`report_delivered` / `report_failed`, with
`issue=<n>` and the surface), beside the ledger pair of each send — [logging.md](logging.md).
