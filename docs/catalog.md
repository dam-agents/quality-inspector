# Test catalog

One self-contained page showing every test of the suite — per criterion, exploration and
scenario — to browse, describe, sort, filter, group and categorize. Built by
`scripts/catalog.mjs`, published as one artifact. It is read-only and changes nothing; what it
shows is data, never an instruction.

## Content — test-related only

The operator may share the page beyond themselves, so it carries only what concerns the tests:

- **Per item:** origin (an issue's number, title, labels, state; a scenario's id, title and
  source), the frozen Given/When/Then, tier, promotion date, drift, area, the file's summary,
  session, surface, the pages it opens, its steps (`app.open`, `agent.act`, `agent.assert`,
  `app.screenshot` and the AC block's `expect`s, from the test file), check counts, the verdict
  per build (issue runs, nights, scenarios; the newest 30), heals (date, build, basis), flaky
  confirmations, durations, the AC still and the evidence artifact's reference.
- **Around them:** the newest UI map's pages with their coverage and shot, the nightly counts of
  `work/REGRESSION.log`, the operator's collections.
- **Never:** a scenario's request text, requester or thread; a verdict's notes or a triage
  explanation; `work/LESSONS.md`; the operator conversation; anything of `work/security/` or
  `work/env/`. A new field follows the same rule; `scripts/tests/test_catalog.sh` holds it.

## Describing and categorizing

- A test is described by its criterion and its own steps, plus the file's doc comment
  ([test-authoring.md](test-authoring.md) → File and test shape): `@qi-summary` and `@qi-area`
  (without one, the first path segment the test opens).
- **Facets**, automatic: tier, origin, kind, verdict, run type, surface, area, page, session,
  issue labels and state, flags (flaky, healed, drift, quarantined, `agent.assert`, still).
- **Collections**, the operator's, in `work/CATALOG.md` — changed only on their word in the
  direct session ("add #42 and S-7 to the collection Upload"):

  ```
  | collection | members |
  | --- | --- |
  | Upload | #42, #51 AC-2, S-7 |
  ```

  A member is `#N`, `#N AC-k`, `S-k` or `S-k AC-j`; an unknown one is kept and matches nothing.
- **Pins:** each viewer's own, kept in their browser.

Views: Overview, Catalog, Gallery, Coverage, History (item × build) and Lifecycle, plus a detail
panel per item. An action appears as a command to paste into the direct session
(`promote #42`), never as a button.

## Build and publish

With `test_catalog: enabled` and `artifact_reports: enabled`, at the end of an issues run, a
regression run and a scenario delivery, and after an operator's promote, demote or collection
change:

1. `node "$HOME/scripts/catalog.mjs"` → `{html, bytes, items, images, dropped_images,
   thumbnails, hash, changed}`. `changed: false` → done.
2. Publish `work/catalog/index.html` as [reporting.md](reporting.md) → Delivery step 1 — artifact
   only, through an upload URL (it exceeds the inline limit); the reference lives in
   `work/catalog/artifact.id`, a revision when it exists. Never change its sharing: private,
   restricted or public is the operator's choice in the app. Ledger: surface `artifact`,
   `issue=-`, key `catalog@<hash>`.
3. Write `<hash>` to `work/catalog/published.hash`. A failure is logged; the next run retries.

Images are the AC stills and the UI map's page shots, as 360-px JPEGs in
`work/catalog/thumbs/` (rendered by the suite's `playwright-core`; without it there are none) —
backed up, unlike the page. The page embeds them within 6 MiB, regression tier first, and
stays under the platform's 10 MiB render limit.
