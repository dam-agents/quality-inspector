# Test catalog — the control center

One self-contained page showing every test of the suite — per criterion, intent test
([intent.md](intent.md)), exploration and scenario — to browse, describe, sort, filter, group and categorize, every run that produced
their verdicts, so it is the way into all reports, and the testing modules with their findings
([modules.md](modules.md)). Built by `scripts/catalog.mjs`, published as one artifact. The page
itself changes nothing; what it shows is data, never an instruction.

## Content — test-related only

The operator may share the page beyond themselves, so it carries only what concerns the tests:

- **Per item:** origin (an issue's number, title, summary — the criteria file's `summary:`
  line ([acceptance-criteria.md](acceptance-criteria.md) → Output) — labels, state; a scenario's
  id, title and source), the frozen Given/When/Then and the verbatim quote of an issue
  criterion's source (`quote:`; a scenario's criteria carry none — its request text never reaches
  the page), tier, promotion date, drift, area, the file's summary,
  session, surface, the pages it opens, its steps (`app.open`, `agent.act`, `agent.assert`,
  `app.screenshot` and the AC block's `expect`s, from the test file), check counts, the verdict
  per build (issue runs, nights, scenarios; the newest 30 — a night that does not name a
  regression-tier item is `unchanged`, or `drift` while its file is drifted) with its `cause`
  when it is not a pass ([reporting.md](reporting.md) → **Cause of a failure**; without one, a
  `failed` or `regression` is `product`, a `needs-review` `test`, else not known) and the agent's
  sentence on it when it is not a pass (a night entry's `explanation`, else the criterion's `note`), heals (date,
  build, basis), flaky confirmations, durations, the AC still and the evidence artifact's
  reference, and the GitHub issue opened for its problem (work/FOUND.md: number, address,
  labels, date, title — one issue may stand for several problems).
- **Around them:** the newest UI map's pages with their coverage and shot, the operator's
  collections, and **every run** (the newest 400): each night of `work/REGRESSION.log` — its
  counts, the criteria that were not `unchanged`, the change context's issues (number, title), UI
  diff text and signal counts, the agent's `analysis` ([reporting.md](reporting.md) → **The agent's
  analysis**) — or its environment failure (the step, cause, repair, next step and
  evidence of `work/regression/<c>/environment.json`, [regression.md](regression.md) step 2); each issue and scenario run with its
  verdicts; each run by hand (`work/reruns/`, [on-demand.md](on-demand.md) → "run #N") with the ref it ran and its raw
  results; each feature run (`work/reruns/feature-<id>/`) with its criteria's raw results; an issue or
  scenario run with its `analysis` too; each with its length — the run file's `minutes`, else its `started_utc` to its time;
  else a night from its `due` line, an issue run from its `issue_done minutes=`, a scenario run
  from its `scenario_run` ([logging.md](logging.md)) — and its `cost_usd` only when the file
  states it (never estimated); each with its build and report reference (a link when the report has one —
  `artifact.url`, its share link, e.g. under `report_visibility: public`
  ([reporting.md](reporting.md) → Delivery step 1), or an `https://` `artifact.id` — opened in a
  new tab; else a "private" mark that says where to find it, Artifacts in the app: a private
  artifact has no address a page can open, and the page never asks the agent to open a report).
  The security run's report never links. Whoever sees the
  page can pass a public link on: the link is that report's whole access control.
- **Product map:** per page of the newest map, every named control the map saw on screen (its
  `boxes`, [change-awareness.md](change-awareness.md) → The three sources) with the items that
  name it in a quoted string — on that page only, or in a test that opens the page; a control
  that leads to another page (a navigation item, a tab, a link, a list's first row) stands for
  the items that reach that page.
- **Activity** (Overview, as of the page's build): the environment lock's holder and since (never
  its session), the `work/QA.md` rows `in_progress` or `report_pending`, the labelled open issues
  with no row yet or carrying `retest_label` (unknown, not empty, when the listing failed), the queued scenario requests,
  the profile scenarios still to adopt (`scenarios.sh queue`: id, the file's `# ` title, kind, and
  when — the next night within `max_scenarios_per_run`, a later night past it, a retry on a new
  build; `null` with `profile_scenarios: disabled`), the time budget
  (`max_wallclock_min_per_issue`), each schedule's name, switch and cron from
  `work/schedules.json`, and the last 14 days of runs drawn from the runs above.
- **Requests:** the scenarios still queued, running, awaiting delivery or rejected — id,
  source, state, the frozen title, the build and verdict once there are any, the time of the
  row's last update; never the request's words. Under them, every profile scenario still to adopt, as in Activity.
- **Control center:** every module's state, settings, schedule and last run (`modules.sh
  status`), the focus queue and the areas; the design findings register with each finding's crop
  ([ui-sweep.md](ui-sweep.md)) with the operator's category and dismissal reason; the newest validation results and stress checks; of the newest
  security run only its counts by severity and its report's reference.
- **Never:** a scenario's request text, requester or thread; a verdicts file's `notes` (the agent's
  `analysis`, `explanation` and a criterion's `note` are written for the page, [reporting.md](reporting.md)
  → **The agent's analysis** — the builder drops a field of them that names a requester or thread, or
  repeats 6 words in a row of a request or a profile scenario's source, and a `notes` entry counts them); a run by hand's error text; `work/LESSONS.md`; the operator conversation; a security finding or anything else
  of `work/security/`; anything of `work/env/`; a credential value or a token (the builder refuses the page). A new field follows
  the same rule; `scripts/tests/test_catalog.sh` holds it.

## Describing and categorizing

- A test is described by its criterion and its own steps, plus the file's doc comment
  ([test-authoring.md](test-authoring.md) → File and test shape): `@qi-summary` and `@qi-area`
  (without one, the first path segment the test opens).
- **Facets**, automatic: tier, origin, the issue or scenario, kind, verdict, run type, surface, area, page, session,
  issue labels and state, flags (flaky, healed, drift, quarantined, `agent.assert`, still).
- **Collections**, the operator's, in `work/CATALOG.md` — changed only on their word in the
  direct session ("add #42 and S-7 to the collection Upload"):

  ```
  | collection | members |
  | --- | --- |
  | Upload | #42, #51 AC-2, S-7 |
  ```

  A member is `#N`, `#N AC-k`, `#N IN-k`, `S-k` or `S-k AC-j`; an unknown one is kept and matches nothing.
- **Features**, the agent's ([features.md](features.md)), from `work/FEATURES.md`: a facet and a
  grouping like the collections, and in a test's panel. The Overview lists them with their recurring
  test count and a "Run this feature" action (`run feature <id>`).
- **Maintenance**, from `work/MAINTENANCE.md` ([maintenance.md](maintenance.md)): the open proposals
  on Overview (id, test, kind, basis, proposal) with the operator's four actions (`accept M-<k>`,
  `rewrite M-<k>`, `retire M-<k>`, `keep M-<k>`), the test's own in its panel, and the flag
  "maintenance". Closed proposals are not shown. A failing recurring test whose cause is not
  `product` or `environment`, with no open proposal, gets "Repair this test" (`repair <ref> <AC-k>`,
  [on-demand.md](on-demand.md)); the bug-issue action is then not the highlighted one.
- **Pins:** each viewer's own, kept in their browser.
- **Gherkin:** "Copy as Gherkin" in a criterion's panel (every criterion of its issue or scenario)
  and on each feature of Overview copies them as one `Feature`, a `Scenario` per criterion in its
  frozen words, `@not-testable` where it is; explorations stay out. The same shape as
  `gherkin.mjs export` ([on-demand.md](on-demand.md)).

**An issue is never only its number.** Every link to an issue or a scenario shows its title
(cut at 60 characters; the whole title and the issue's summary in its tooltip) — from its test
cases, else the GitHub listing, the activity rows, a night's completed issues or the requests; a
place that shows the title beside it keeps the number alone. A bug issue shows its title too.
The issue's panel and each of its test cases' panels show the summary as "About this issue".

**Why it failed, at first sight.** Beside every verdict that is not a pass — the catalog,
cards, Needs attention, the panels, a run's results — a badge names its cause: 💥 Product defect,
🔧 Test defect, 🏗️ Environment problem, or ❔ Cause not known. "Cause of the failure" is a
facet; Needs attention opens with the count per cause, and says so when the newest night did
not run because the environment failed.

**What the agent found, first.** A run's panel opens, under its verdict, with **🧠 What the agent
found**: the `summary`, then each problem as a card — its title, its cause badge, the test cases it
is about (links), *What happened*, *Where*, *Probable cause* (with its certainty), *How to repair it*
— and *Next step*. A run without an `analysis` (older runs) gets a sentence the page builds from the
data — why its verdict is what it is (for a night `needs-review` with no such result: a signal no test
covers, else the agent's choice) — marked as the page's, not the agent's. Each result in the run's
list shows the agent's sentence on it under its link; a test case's panel shows it beside its latest
result that is not a pass, and the Runs view a run's `summary` under its result.

**Explained on the page**, in ASD-STE100 ([reporting.md](reporting.md) → **Artifact text is ASD-STE100**).
- **One name and one icon per thing**, the same everywhere — 🎫 issue, 💬 scenario, 🎯 acceptance
  criterion, 💡 intent test, 🔦 exploration, 🧪 test case (one criterion or exploration with its test), 📝 test file,
  🏃 test run, 📦 build, 🎬 report, 🐞 bug issue, 🖥️ page, 🔘 control, 🎨 design finding, ⌨️ validation
  finding, 🏋️ stress check, 🗂️ collection, 🧩 testing module. A short reference (`#42 AC-1`) always
  carries its icon, and its tooltip gives the whole name ("Test case — acceptance criterion AC-1 of
  issue #42 …").
- **One kind of control, one look.** Blue with → goes to another view of the page, with ▯ opens a
  panel, with ⌖ a page of the product map; teal with ↗ opens another site in a new tab (GitHub, a
  report's link) — by the page's own script, as the page is often drawn in a frame where a plain link
  stays and the other site refuses to load; when no tab opens, a teal box shows the address to copy; violet with the agent's mark is a message for the agent — it never sends: it opens the box at
  the bottom, which names what the agent then does, shows the exact message, and sends it only on
  its own "Send to the agent" (beside the agent's chat; else "Copy"), Esc or Cancel closes it with
  nothing sent (dashed: takes your input first); grey changes only this page in this browser (filters, sorting,
  pins, selections). Each one's tooltip says first what it does and where it goes, then its meaning.
- **Where you are:** the header always names the view and the panel open on it, beside **Back**;
  each view opens with its icon, its name and one line of what it is for (the line hideable, per
  browser); a panel names its kind (test case, test run, issue, scenario).
- **Day / night:** the header switch picks the colours — Auto (as the system), Day or Night — per
  browser; the tabs wrap to more lines, never scroll sideways.
- **Panel width:** a side panel opens at half the width of the screen; drag the left edge (or focus it
  and use the arrow keys) to make it wider or narrower; the width stays per browser, and a double click
  on the edge resets it to the default.
- Overview has a "How this page works" guide (the kinds of control, then issue, test case, test
  run, verdict, tier, report, commands, reporting a bug); every verdict badge, tier, severity,
  design check, validation input, run type, column, filter, quick filter, label of a panel and
  figure carries its meaning as a tooltip — the page's own, on hover, keyboard focus or a tap of an
  ⓘ; the Legend lists the kinds of control, every name and icon, verdict, tier and run type.

Views: Overview, Modules (each module's switches and settings, and what a job tests: the
Nightly regression lists its test cases by issue and scenario), Findings (validation, stress,
security counts, edge-case observations), Design (the design findings: crops, filters, "copy as
Markdown" for the design team), Runs, Product map (the page shots with every control clickable, coloured by
its tests' worst verdict, dashed where no test names it; a drawn outline where a shot did not fit; a
navigation item, tab, link or list row that leads to a mapped page opens that page, like a
click-through wireframe, with a "back" to the page before), Catalog, Gallery, Coverage,
History (item × build), Lifecycle and Test builder (below), plus a detail panel per item, per run (a night's
lists every test case it had, with its result, its length and cost) and per origin (an
issue's or a scenario's criteria and explorations, every run that judged them, its report).

**Links and navigation.** Every reference is a link to its place: an issue or a scenario
(`#42`, `S-7`) to its origin panel, a build to the runs on it (Runs filtered by build, with "as of
this build"), a page a test opens to that page on the Product map, an area, a session, a surface,
a label or a collection to the catalog filtered by it, a history cell or entry to its run, a
design finding's page to the map, and from a map page to its design findings. Every report — the
artifact with the video, the screenshots and the steps — shows wherever its run or its
origin appears (a link in a new tab, or the "private" mark): the catalog's Report column, cards, Overview, the map's test lists, the runs in an
item's and an origin's panel, the Runs view and the run panel. Every move to another place (a view,
a panel, a map page, a build, "as of") is a history step the browser's back and forward walk; a filter, a sort,
a search or a picked control of the map refines the place instead. The page's own **Back** (in the "You are here" bar under the tabs and in every panel) returns to the place before,
named — in memory where the frame may not touch the browser history. A panel has previous and
next (the item in the list it was opened from, the run before or after, the neighbouring origin)
and breadcrumbs up to its origin; Close returns to the place under it. **As of a
build** shows every view with the verdicts as they stood when that build last ran (files, tiers
and steps stay today's); older catalogs are the artifact's earlier revisions. An action appears
as a command for the direct session (`promote #42`, `module stress set stress_checks=weekly`) —
only one of the closed set of [on-demand.md](on-demand.md), [modules.md](modules.md) →
**Control** and [skills/create-issue](../skills/create-issue/SKILL.md), built from constants, ids and a
name or category the person types (checked against its pattern), never from other page data.

**Managing from the page.** A test's panel has "What you can do": run it now (`run #42 AC-1`, or
every test of its issue), retest the whole issue (`test #42`), promote or demote it, put it in or
take it out of a collection, and report it as a GitHub issue (`create issue for #42 AC-1`, plus
`… for the architect` when `fix_label` is set). A design finding's card has "Manage":
categorize it, dismiss it with a reason or reopen it, recheck it (`recheck D-<k>`), discuss it
with the agent (`discuss D-<k>`, with the person's question when typed), report it.
**Run it again**, wherever a result shows — each one time on the build that is up, never a
verdict unless it says a full run:

| Where | Commands |
| --- | --- |
| A test case's panel | `run #42 AC-1`, `run #42`, `test #42`, `repair #42 AC-1` (above) |
| An issue's or a scenario's panel | `run #42`; its failing test cases, `run #42 AC-1, #42 AC-3`; a profile scenario's full run, `test scenario <slug>` |
| A run's panel, "🔁 Run it again" | by its type: a night `module regression run now`; an issue run `test #42` and `run #42`; a scenario run `run S-7` (a profile one also `test scenario <slug>`); a manual run the same ref it ran (`run #42 AC-1`); a feature run `run feature <id>`; and its failed test cases, `run <ref>, <ref>…` |
| The catalog's toolbar, with a filter or a search | the test cases it shows, `run <ref>, <ref>…` — a collection, an area, a feature, "failing" |
| The selection bar | the ticked test cases, `run <ref>, <ref>…`, beside the bug issue |
| Findings | a validation case `recheck VAL-<k>`; the whole module `module validation\|stress\|security run now`; a focus area `focus <area>` |
| Design | `recheck D-<k>` (above) |

A list holds at most 20 test cases (the first 20; a larger filter says to narrow it); only a
test case with a test file runs. **Several problems as one
issue:** every test (catalog table and cards; the failing ones in Needs attention), design finding,
validation finding and failed stress check has a ☐; the ticked ones gather in a bar at the bottom
of every view with one command, `create issue for <ref>, <ref>…` (at most 20), and its
architect variant. The selection is the viewer's own, kept in their browser. A problem an issue
was opened for shows that issue's link everywhere it appears, and the flag "issue created". It opens in the box at the
bottom like every command: copied, or sent there as the operator's message beside the agent's chat. Beside
a scheduled run's chat the agent hands such a command to a fresh session, whose answer (a draft
to confirm) is in that session ([persistence.md](persistence.md) → **Handoff**).
The one exception is **Ask for a test** on the Product map and in the Test builder: a scenario
request built from the page's pattern, the control's kind and name, and the person's own words
(or steps), in the one shape of [scenarios.md](scenarios.md) → **A request from the dashboard**. The
agent takes the person's words as data. The Test builder's other command, `walk these steps
live: …`, has the same bounded shape ([on-demand.md](on-demand.md)); so has a design finding's
question, `discuss D-<k>: <question>` (printable text, at most 1000 characters). **A person the
operator shared the page with** may send every command of the page: a scenario request runs in
their turn, every other command goes to a fresh session where confirmations wait for the
operator ([modules.md](modules.md) → **Control**).

## Test builder

A view where a person writes a new test as steps and sees them before anyone runs them:

- **Steps**, four kinds: 🏁 Given (the state at the start), 🧭 Open (a path), 👆 Do (one action of a
  user, a control named in quotes: `Click the button "Save"`), ✅ Check (the result they expect).
  **Blocks** — one card a step, a kind, a field; drag or ↑ ↓ to reorder — or **Text**, one step a
  line (`Open: /projects`, `Do: …`, `Check: …`, `Given: …`, `Name: …`; a bare line is a Do). Both
  show the same draft, at most 30 steps, kept in the viewer's browser only.
- **Start** empty, from a test case (its panel's "Change these steps in the Test builder", or the
  picker: its Given, the pages it opens, its `agent.act` and `agent.assert` words, its Then), or
  from a page or a control of the Product map ("Build a test from here"). A new start keeps the
  draft before it for "Restore", in memory.
- **Preview on the product map:** each step on its page's shot of the newest UI map (its outline
  where there is no shot). An Open step goes to the page its path matches; a Do step marks the
  control it names — in quotes first, else by its name — and a control that leads to a mapped page
  moves the next step there. Play shows the steps one after the other; a film strip opens any one.
  **Add steps with clicks** shows the page where the next step happens with every control as a
  button: a click writes that control's Do step after the current one (or into an empty Do), so a
  person clicks a flow through like a wireframe. The preview is the map, not the product: a page
  not on the map, or a control without a name there, shows as text.
- **Give the steps to the agent**, once there is an Open or Do step and a Check, within 2000
  characters — the steps numbered, one a line, after the start page (the first Open step's map
  pattern, else `/`):
  - **Ask for this test** — `test this scenario: On the page <pattern>: Name: …
1. Open: …
2. Do: …`:
    the scenario request above, for anyone who sees the page.
  - **Do the steps live in the Browser Panel** — `walk these steps live: On the page <pattern>: …`,
    the operator's ([on-demand.md](on-demand.md)): the agent does the steps on the product that is
    up, live in the Browser Panel, and says per step what it did and saw. No verdict, report or test.

## Build and publish

With `test_catalog: enabled` and `artifact_reports: enabled`, right after a run claims an issue
or a scenario (its row `in_progress`, so Overview → Activity shows the work), at the end of an issues run, a
regression run, a modules run and a scenario delivery, at the end of every turn of a dashboard
request ([scenarios.md](scenarios.md) → **A request from the dashboard**), and after an
operator's promote, demote, collection change or module change ([modules.md](modules.md) → **Control**).
Apart from the claim, a run publishes only after its unlock, so Activity never shows a finished run
as working. A run that published at its claim publishes again after its unlock on every path: its
release ([issue-qa.md](issue-qa.md) step 10, also for an operator's or a Slack "test #N"), an abort
([issue-qa.md](issue-qa.md) steps 2 and 4, [scenarios.md](scenarios.md) step 6) and its delivery.
The steps:

1. `node "$HOME/scripts/design-findings.mjs" merge --noticed-only` (the run's "noticed in passing"
   items into the design register, [ui-sweep.md](ui-sweep.md)), then
   `node "$HOME/scripts/catalog.mjs"` → `{html, bytes, items, images, dropped_images,
   sharp_images, sharp_dropped, thumbnails, notes, hash, changed}`. `changed: false` → done. Each `notes` entry is a source it
   could not read: log it as a `warn` and publish anyway. `refused` (exit 1): log it as an
   `error` and publish nothing; `secrets.mjs scan-all work/env/credentials.env work/suite/tests
   work/issues work/scenarios` (in `$HOME/scripts/lib/`) names the file to fix.
2. Publish `work/catalog/index.html` as [reporting.md](reporting.md) → Delivery step 1 — artifact
   only, through an upload URL (it exceeds the inline limit), sent with `Content-Type: text/html;
   charset=utf-8`. It has no `media/` links (its images
   are in the page), so it is already one file: it skips `report-media.mjs`; the reference lives in
   `work/catalog/artifact.id`, a revision when it exists — refused as not found, a new artifact
   whose reference replaces it. With `dashboard_interactive: enabled` it is created with
   `interactive: true` (the platform's Interactive artifacts; never public); that is fixed at
   creation, so when `work/catalog/artifact.interactive` does not say `true` the next publish
   creates a new artifact, replaces the reference, writes that file, and tells the operator to
   delete the old one — never by itself. Never change its sharing: private,
   restricted or public is the operator's choice in the app. Ledger: surface `artifact`,
   `issue=-`, key `catalog@<hash>`.
3. Write `<hash>` to `work/catalog/published.hash`. A failure is logged; the next run retries.

A failed item's still shows its mark ([reporting.md](reporting.md) → **The mark**): the test's
`<id>: the failing check` with a red frame, else the agent's `mark` as an orange frame on the AC
still; the framed copy is cached as `thumbs/<key>.mark-<hash>.png`.

Images are the AC stills and the UI map's page shots, each twice in `work/catalog/thumbs/`
(rendered by the suite's `playwright-core`; without it there are none) — backed up, unlike the
page; one whose item or page is gone is removed:

- **small** — a JPEG, 360 px (a still) or 720 px (a page shot) wide, for the lists and cards;
- **sharp** — a WebP up to 1440 px wide (the screen at its own size), for a test case's panel,
  the Gallery and the Product map. A click on a panel's screenshot, or **🔍 Full size**, shows it
  over the page: fit to the window or at its real size (a click changes between them), Esc closes.

The page embeds them within 8 MiB — less when the data is large (a `notes` entry says so): first
every small one (the regression tier's stills, the design crops, the page shots, then the other
stills), then the sharp ones in the same order while room is left — a place shows the small one
where its sharp copy did not fit (`sharp_dropped`) — so it stays under the platform's 10 MiB
render limit.
