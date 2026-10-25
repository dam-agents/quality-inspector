# Change awareness

A regression run never starts blind. Before any test replays, you know what landed since
the build the suite last passed on, and what moved in the UI and the interfaces — from
three black-box sources, never from code or pull requests ([black-box.md](black-box.md)).

## The three sources

1. **What was merged — the issues.** `bash "$HOME/scripts/changes.sh" <previous> <candidate>`
   lists every target issue closed as *completed* between the two builds' publish times,
   with title, labels, its "Done when" text and `may_supersede` ([triage.md](triage.md) →
   Retiring a superseded test). It is the product team's own statement of
   intended change. The window is approximate (an issue closed minutes before a build may
   ship in the next); treat it as context, and an issue just outside the window as
   possibly in it.
2. **What the UI looks like now — the UI map.** `node "$HOME/scripts/ui-inventory.mjs"
   work/inventory/<build>` signs in and walks the nested product read-only: every page
   reachable through links, navigation items and tabs, with its headings, nav items,
   buttons, tabs, fields and links (repeated data rows and cards excluded), where each sits in
   the screenshot and the page a link, navigation item or tab leads to (`boxes`, `navigates`, for
   the catalog's product map, where a list's first row per detail page stands for the list), its forms with their fields' types
   and limits read from attributes (`forms`, for [validation.md](validation.md)), an accessibility snapshot, a
   screenshot, and the page's **signals** — console errors,
   failed same-origin requests, load timing. `node "$HOME/scripts/ui-diff.mjs" <old> <new>`
   turns two maps into pages added/removed and controls renamed, moved, removed or added —
   including a **likely rename** when one control left and one arrived in exactly the same
   places with unlike text — and the signals new on this build (`console_errors_new`,
   `failed_requests_new`, `slower_pages`: load above `--perf-factor`, default 2×, and
   +1000 ms; triage: [triage.md](triage.md) → **Signals no test covers**). Two maps of one
   build diff to nothing; anything it reports is a real change.
3. **What the product publishes — its CLI and API.** When the profile's `profile.json`
   names `interfaces` ([profile-contract.md](profile-contract.md)),
   `node "$HOME/scripts/iface-snapshot.mjs" <build> work/inventory/<build>` writes
   `iface.json`: `<cli> --help`, recursively over the subcommands each help lists (run
   with an empty HOME and no credentials; its files are never read), and the API
   description fetched from `app.url` (an HTTP response). `node
   "$HOME/scripts/iface-diff.mjs" <old> <new>` lists commands, flags, endpoints and
   response fields removed or added. No `interfaces` → `{"skipped": …}`, nothing written;
   a missing snapshot on either side → the diff is skipped and says so.

## Building the context

Right after `env.sh up <candidate>` on a freshly reset platform (so the map holds no test
data), before the suite runs:

```bash
QI_BUILD=<candidate> node "$HOME/scripts/ui-inventory.mjs" "$HOME/work/inventory/<candidate>"
node "$HOME/scripts/ui-diff.mjs" work/inventory/<previous>/inventory.json work/inventory/<candidate>/inventory.json > /tmp/quality-inspector-diff.json
node "$HOME/scripts/iface-snapshot.mjs" <candidate> "$HOME/work/inventory/<candidate>"
node "$HOME/scripts/iface-diff.mjs" work/inventory/<previous>/iface.json work/inventory/<candidate>/iface.json > /tmp/quality-inspector-iface.json
bash "$HOME/scripts/changes.sh" <previous> <candidate> > /tmp/quality-inspector-changes.json
node "$HOME/scripts/impact.mjs" /tmp/quality-inspector-diff.json --iface /tmp/quality-inspector-iface.json work/suite/tests/{issue,scenario,profile}-*.e2e.ts > /tmp/quality-inspector-impact.json
```

(Source `work/env/credentials.env` for the map's sign-in.) `impact.mjs` names, per test,
every changed page or control it opens or mentions — and every removed command, flag,
endpoint or response field it names — and whether the hit is inside an AC or IN block (frozen, [intent.md](intent.md));
`maintenance.mjs predict` turns it into proposals ([maintenance.md](maintenance.md) → **Predicted from the change context**). With no
map of `<previous>` (first run, lost volume), the UI diff is skipped (pass `none` in its
place) and the run says so — the triage then leans on the issues alone.

Then, before replaying, read it once as a whole and write down — in the run's notes — a
one-line expectation per impacted test: *"#101 AC-1 checks the API keys tab, which the
map shows renamed to Access tokens; #4552 says the analytics report gets a share link"*.
The triage ([triage.md](triage.md)) compares outcomes against these expectations.

## Coverage

```bash
node "$HOME/scripts/coverage.mjs" work/inventory/<build>/inventory.json work/SUITE.md work/suite/tests/{issue,scenario}-*.e2e.ts --md > work/COVERAGE.md
```

Without `--md` it prints the JSON (`pages[]` with `tests` and `covered`, `uncovered[]`,
`nav_without_golden_path[]`). A page is **covered** when a `regression`-tier test opens
its URL or names, in a quoted string, a control that only this page shows (shared chrome
such as navigation or a "Save" on every form counts for no page). A top-level navigation
item of the root page whose target page is uncovered has **no golden path**. Read-only;
the audit reports the counts, never as a fail.

## Keeping maps

`work/inventory/<build>/` (the map and `iface.json`) per regression-tested build; the audit pre-flight keeps the
newest three. The map of the build last tested is what the next diff starts from, so
never delete the newest.
