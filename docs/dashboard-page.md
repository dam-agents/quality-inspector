# The new dashboard page — how it behaves, how it looks, how it speaks

`scripts/dashboard/page.html` is the test catalog's new, simpler page. Read this before you change
it. Its skeleton, its controls, its look and its rules are Design Desk's **Desk**
(`github.com/xjacka/design-desk`, `desk/page.html` and `docs/desk-page.md` at 1.102.0, full mode —
the Desk's simple mode is not taken over): one product, one family of pages. Only the product's
colour differs (The look). The page's `<style>` is the Desk's stylesheet as it is; a rule both pages
share changes in both.

**Where it stands.** The first step: the skeleton with the four menu tabs, their lists and an item's
page, on the data the dashboard server already serves ([catalog.md](catalog.md) → The server). The
published dashboard is still `scripts/catalog/viewer.html`; this page is not built or published by
`scripts/catalog.mjs` yet. Open it in development:

```bash
WORK_DIR=<work> node scripts/catalog.mjs
WORK_DIR=<work> node scripts/dashboard/dev/harness.mjs 5600 5599   # then http://localhost:5600/?page=new
```

## The menu

One row, the same on every tab: **Problems** leads (the page opens on it), then **Tests** and **Runs**, then **Product**,
each group behind a thin separator; **+ Ask for a test** follows behind one more. At the right: the
search, then the person's menu (**Settings**, **How it works**, day or night): Settings is not a tab in the row. Only the open tab is marked; every
count is grey and counts only what still needs someone; Problems' count is amber while a problem is
still in the product.

| Tab | The question it answers | Pages (tabs on the list) | Filter (segmented, with counts) | An item's page |
| --- | --- | --- | --- | --- |
| **Problems** | What is wrong in the product now? | — | **Still there** (default), **Not seen now**, All | what happens, where, why, what fixes it, the runs that found it; **Create a bug issue…**, **Run the tests again** |
| **Tests** | What do we test, and does it pass? | All, Nightly, From issues, Scenarios, **Upkeep**, **Features** | **Failing** (default; failing or needing a person), Passing, Not decided, All | a test: what it checks (Given / When / Then and the issue's own words), how it is kept (Nightly, Ready to keep, Ran once, Set aside, Retired), **why** a result is not a pass (a product defect, the test is wrong, the product did not run), every result with its report's number, the screens it opens, the features and collections it is in; the first button follows the cause — **Create a bug issue…**, **Repair the test**, **Keep it each night**, else **Run it again** — then **Report R-n**, ⋯ **Stop running it each night**, **Add to a collection…**, **Change these steps…**. **Upkeep**: each proposal `M-n` (what changed, what Quality Inspector proposes; **Accept**, **Keep it as it is**, ⋯ **Rewrite**, **Retire**) and the tests ready to keep (**Keep all … ready**). **Features**: each feature and collection — its tests and their states, **Run them all** (`run feature <id>`, or the tests of a collection), **Copy as Gherkin**, a collection's ✕ per test |
| **Runs** | When was the product tested, and how did it go? Each run is its report, `R-n` | All, Nightly, Issues, Scenarios | All, With problems | the report (below): the result, the agent's summary, **since the run before** (tests newly failing, fixed, still failing and new; how the product's screens changed; new errors in the browser console), the counts, why it could not start, the problems, each test's result; ◀ ▶ the reports before and after. A row says how many tests fail newly |
| **Product** | What does the product have, what do the tests reach, how does it look? | **Map**, **Coverage**, **Screenshots**, **Design**, **Builds** | Design: **Open** (default), Fixed, Dismissed, All | a screen (Map and Coverage): its picture with each control outlined in its coverage's ink (each night green, once amber, none grey and dashed); a click on a control shows its kind and name, where it leads and its tests, **+ Ask about it**; the tests that open the screen, what looks wrong there; **Build a test from here**, **+ Ask for a test**. Coverage lists the screens worst first, with a bar of their controls; nothing open shows the counts of screens and controls and the menu items no nightly test goes through. A design finding (`D-n`): its picture, where, the screen size, who found it, first and last seen; **Send to design**, **Check it again**, ⋯ **Create a bug issue…**, **Dismiss: …**; a dismissed one **Open it again**. **Screenshots**: every test's newest picture as a gallery, a click opens the test. A build: its runs |
| **Settings** | What does Quality Inspector do beside the issues, and when? | — (one page, the whole width, no list) | — | **The week at a glance:** each check that is on, Mon–Sun, its days in the product's colour and its time; one a week or a month says so in words; a name opens its row. **The checks, grouped by when they run** (With each issue, Each night, During the day, Each week or month, When you ask): a row is its name, when it runs and its last run, and at the right its switch — a schedule's on and off, a module's own on-off, or its cadence as a segmented control. A click on the name opens the row in place: what it does, each other setting in words (a choice segmented, a number or sizes with **Change**, the range and the default), **Run now**, Feature focus's area. **Limits** last: the settings for all. **The operator's change of a value applies at once** — the server writes it ([catalog.md](catalog.md) → The server), a toast says what was saved, the page shows it; a schedule's on and off and **Run now** stay commands to Quality Inspector, asked first. A viewer sees the same page; each change they press is a command, asked first, for the operator |

Not in the menu yet, and where each goes when it comes: the validation, property and
stress results (Product → **Findings**); the whole page as of an earlier build. A
new place is a page or a filter of these five tabs before it is a tab of its own.

## The page

- **List and item.** The list on the left, the item open on the right, as on the Desk. Each row is its
  title, its number in grey (`#42 AC-1`, `S-7 AC-1`, `F-3`, a run's build, a screen's address) and its
  state's dot at the right end; one line under it with its facts, each a grey label and its value
  (*Last run:* Today, *Build:* c3, *Kept:* Nightly). Newest first. 20 rows, then 20 more as the end
  scrolls into view. Pointing at a dot unfolds it into its word.
- **An item's state.** The box under the title says where the item stands, in one word in its state's
  ink, and what happened last (*Nightly regression on build c3 · 2 days ago*); its buttons stand at
  the right. Pointing at the word says what it means. One primary button per view, the next step.
- **Nothing open.** The pane shows what Quality Inspector does now (*Now: Testing issue #57 on build
  c4*), a tile per state with its count (a click filters the list), then the tab's intro. On
  **Problems** — where the page opens — the first line is the overview, quiet and short: each blocker
  in one line (what stops, its cause, who repairs it; **Try again** when it is the operator's or the
  platform's, **Details**), then one row of three — **Now** (what it tests, the build, the minutes of
  its budget; or Idle and the last run), **Waiting** (how many issues, retests and scenarios wait, the
  first of them, reports on their way), **Next** (the soonest scheduled run and the one after, in the
  schedules' UTC clock).
- **Numbers and history** stand in the pane of the tab they belong to, before an item is open, as
  quiet charts in the state inks: **Tests** — **Look into what needs a look**, the tests build by
  build (with a result, kept each night) and the kept tests' history on the last 12 builds, a square
  per result that opens its report; **Runs** — each night's results as a bar (a click opens the
  night) and every run of the last 14 days, a dot per run on its lane; **Product** — Map the coverage
  counts, Screenshots the gallery.
- **Tab intros** explain the process, never the screen: its steps in order, each saying who acts, its
  number in the colour of who acts (the product's colour Quality Inspector, amber you, green done),
  and under **You can** the buttons a person presses there. A short tip ends it. Folding one folds
  every tab's, and the browser keeps it. **How it works** shows them all.
- **Commands.** A button does one of two things, never a message the person cannot follow:
  - **At once, without the model** — what a script does: a setting, Feature focus's area, a design
    finding's dismissal, reopening or category, a test into or out of a
    collection. The operator's press goes to the server (`POST /api/act`, `POST /api/settings`;
    [catalog.md](catalog.md) → The server); a toast says what was done and the page shows it.
  - **Through the chat** — work for Quality Inspector (run, repair, keep each night, create an issue,
    a new test, an upkeep decision, a schedule on or off, Run now) and questions. The chat in the
    corner opens with the request ready: its name, the exact message, room for a note; **Send** sends
    it, and Quality Inspector's report or question comes into the same chat. A dialog (Ask for a test,
    Add to a collection) sends at once and opens the chat on it. A viewer's press of an operator's
    action goes this way too, as a request for the operator.
- **Ask for a test** — the header's button, and a screen's on Product — opens one dialog with three
  kinds; the kind last used opens next time, a screen's button opens the second with its address:
  - **An issue or pull request** — its number → `test #N`. A pull request stands for the issues
    it closes ([on-demand.md](on-demand.md) → "test #N").
  - **A scenario in your words** — what to try and see, and, if the person wants, the page it starts
    on (the product's screens offered as you type) → `test this scenario: On the page <address>:
    <words>`; no page is `/`, which the agent reads as any page ([scenarios.md](scenarios.md) → A
    request from the dashboard).
  - **Step by step** — the Test builder of the old page ([catalog.md](catalog.md) → Test builder),
    whole: the dialog widens, the steps at the left, the preview at the right.
    - **Steps**: a name, then Given, Open, Do and Check, as **Blocks** (a kind and its words; drag
      by the grip or ↑ ↓, ✕ removes, **+ Given / Open / Do / Check** after the current step) or as
      **Text** (one a line, `Open: /projects`; a bare line is a Do). At most 30. **Start from a
      test…** copies a test's Given, pages, actions and Then; **Copy as text**, **New draft**,
      **Restore the draft before**. The draft stays in this browser.
    - **Preview**: each step on its screen's picture from the product map, a Do's control marked
      (its name in quotes first), a Check written over it; a control that leads to another page
      moves the next step there. **Play the steps**, ◀ ▶, a strip of all steps. **Add steps with
      clicks** shows every control of the page as a button: a click writes its Do step.
    - It needs an Open or a Do and a Check, an Open step being an address. → `test this scenario:
      On the page <first Open>: Name: …` and the numbered steps, one a line. The operator also has
      **Do the steps live** → `walk these steps live: …`.

    A test's ⋯ **Change these steps…** and a screen's **Build a test from here** open it with that
    test's steps or that screen; the draft before stays for Restore.

  What is missing is said in amber under the fields; nothing goes until it is right. Send asks
  first with the exact message (Commands); Cancel there goes back to the filled dialog.
- **Reports on the page.** Every run is its report, numbered `R-1`, `R-2` … in the order the
  catalog first saw it, and opens in Runs at its own address (`#runs/R-12`). A test's **Report R-n** and
  each result in its history open that report at the test's own result (`#runs/R-12@issue-42/AC-1`).
  Under the summary, each test of the run, folded when it passed: the agent's sentence, then its
  test on the **New build** and on the **Last release** — the status and length, the error in red,
  the screenshots (a click shows one at its full size) and the steps (a failed one red, open when
  one failed). The data is catalog.mjs's `rep` ([catalog.md](catalog.md) → The report on the page).
  Each side's **▶ Play the video** plays it on the page, in a dialog: the server sends it in parts
  ([catalog.md](catalog.md) → The server), the page joins them. A run whose videos are no longer kept
  here (the evidence's retention) links its report instead: **The report with the videos ↗**. The number is the
  run's `id` in the data ([catalog.md](catalog.md) → The report on the page): it never moves, and
  a link keeps its target, when older runs leave the page.
- **The chat.** **Ask Quality Inspector** waits in the bottom-right corner, as Design Desk's private
  ask: a question about what is open (its label shows *About: …*), with three starters that fit it.
  Only the asker and Quality Inspector see it. The server records it and the page sends its ping
  (`answer dashboard question A-<n>`); the answer comes into the chat within seconds of being written
  ([on-demand.md](on-demand.md)). Quality Inspector explains; it changes nothing from a question. The
  chat's corner drags it bigger, and the browser keeps the size.
- **Search** finds words in every title, an issue's number, a scenario's, a problem's, a report's
  (`R-12`), a screen's address. Hits show as you type; ↑ ↓ pick, Enter opens, Escape closes.
- **Links.** The address follows the page (`#tests/issue-42%2FAC-1`, `#problems/F-3`, `#runs/R-12`,
  `#product/screen%3A%2Fprojects`), so a link opens the same place.
- **Tooltips.** Every button, label and dot says on hover what it does or means, in the page's own
  box half a second after the pointer rests; a button that opens a dialog starts with *[Opens a
  dialog]*.
- **Dialogs** close with Cancel and Escape; one with something typed asks before Escape closes it.
- **Redraws keep your place.** The page asks the server every 16 s; what did not change is not
  redrawn, and keyboard focus stays where it was.
- **Not reached.** No answer within 15 s shows *Can't reach Quality Inspector right now. Retrying…*
  with **Reload the page**, and the page asks every 4 s; after 20 s it loads itself anew unless a
  dialog is open or a field holds text.
- **The list folds** with the arrow on its edge, and its edge drags 30 px wider or narrower (arrow
  keys 10 px, double click back); the browser keeps both.

## Writing on the page

The words follow Design Desk's rules (its `explain` skill and `docs/desk.md` → Writing on the
Desk); for this page they replace Simplified Technical English.

- **The reader** is a person on the product team — a PM, a designer, a developer — smart and busy,
  who does not read test code. They read to decide: is it broken, is it mine, what do I do.
- **The answer first.** The first sentence is the gist; a reader who stops there is not misled.
  Then only the layers that help: what you see, why, what to do.
- **Every sentence earns its place.** A sentence that only says nothing was found is cut; a section
  with nothing to tell is not drawn, and has no heading.
- **The product's words**, exactly as the product shows them. **No code words**: not selector,
  assertion, fixture, endpoint, exit code, null — say what it means for a person ("the Save button
  did not answer"). No ids or status names the page does not show (`in_progress`, `needs-review`):
  the page's own words instead (*Running*, *Needs a look*). A number only as the page shows it
  (`#42 AC-1`, `F-3`).
- **Short sentences**, one idea each; digits with units; concrete over abstract.
- **Never invent a reason.** A "why" comes from a run, a report or an issue; with none, say it is not
  known.
- **Labels** before a value are sentence case and grey (*Last run:*, *Build:*); capitals with spacing
  only head a group (*Step by step*).
- **Language.** Everything on the page is in English; product copy and quotes stay as written.
  A reply to a person (chat, Slack) is in the language they write in.

## The look

Every change keeps to one scale — the Desk's ("The look" in its `docs/desk-page.md`):

- **Text:** only the `--fs-*` tokens: `title` 26 (an item's name), `head` 17 (a section, a dialog's
  name), `ui` 14 (text, controls, lists), `meta` 12.5 (dates, who, counts), `micro` 11 (badges).
  Weights 400, 500 (a control's label), 600 (names, emphasis); nothing bolder. One family: `--font`,
  `--mono` for code and numbers of items.
- **Corners:** `--r-xs` 4 (tags), `--r-sm` 6, `--r-md` 8 (buttons, fields, menus), `--radius` 10
  (cards, panels), `--r-lg` 12 (dialogs); `999px` a pill, `50%` a dot.
- **Space:** multiples of 4 (4, 8, 12, 16, 24, 32); 1 or 2 px only as a hairline.
- **Buttons:** `.btn` 32 px high, `.btn.small` 26 px; one `.primary` (ink) per view.
- **Colours:** only the tokens on `:root`, each in light and dark; never a near copy. An ink means a
  state, never decoration. Text on a coloured fill is `--bg` or `--accent-ink`, never `#fff`.
- **The product's colour** is petrol: `--accent` `#0a6e8c` (night `#6cc9e3`), `--info-soft`
  `#e1f0f5` (night `#14303a`), `--accent-ink` `#ffffff` (night `#072029`). Design Desk's is blue;
  every other token is the Desk's.
- **State inks:** passing `--approved` (green), failing `--closed` (red), needs a look `--waiting`
  (amber), blocked or could not start `--decided` (slate), running `--accent` (pulsing), not run
  `--muted`. A test's dot, its box on its page and its results read in the same ink.
- **One line:** the header holds one row down to about 1024 px; a list's page tabs never wrap: they
  scroll, faded at the cut.
- **Exempt from the scale:** glyphs (✕, ‹ ›, arrows), pictures of the product, a tile's numeral.
