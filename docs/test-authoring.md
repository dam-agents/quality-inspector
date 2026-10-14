# Writing and repairing tests

Tests live in `work/suite/` (created by `scripts/suite.sh init` from
`scripts/suite-skeleton/`), run with `scripts/suite.sh run`, and use the `e2e` framework.
Its own docs ship offline in `work/suite/node_modules/e2e/docs/` and its skill via
`npx e2e guide` — read them there; this file holds only this agent's conventions.

## File and test shape

One file per issue, `tests/issue-<n>.e2e.ts`; one test per testable AC:

```ts
import { test } from '@e2e-dev/web';
import { expect, unique } from 'e2e';
import { criterion } from '../lib/criterion.js';

test('#42 AC-1: a renamed agent keeps its sessions', { session: 'owner', tags: ['issue-42', 'ac-1'] },
  async ({ app, agent, screen }) => {
    const name = unique(`qa-${Date.now()}`);
    await app.open('/');
    await agent.act('create an agent named {name} from the mock template', { params: { name } });
    await agent.act('rename the agent {name} to {name}-2', { params: { name } });
    await app.screenshot('AC-1: the renamed agent and its sessions');
    // AC-1 begin
    await criterion('AC-1', 'the renamed agent is shown under its new name with its earlier session', { agent, app }, async () => {
      await expect(screen.getByRole('heading', { name: `${name}-2` })).toBeVisible();
      await expect(screen.getByRole('listitem').filter({ hasText: 'session' })).toHaveCount(1);
    });
    // AC-1 end
  });
```

- **Right before each AC block, `app.screenshot('AC-<k>: <what the Then line looks at>')`.**
  It is the still a reader checks the verdict against; the report captions it with that
  label. `agent.assert` adds its own screenshot. Never screenshot inside the setup test.
- **Every AC block is one `criterion(id, then, ctx, check)` call**
  (`work/suite/lib/criterion.ts`): `then` is the criterion's Then sentence verbatim, the
  callback holds the exact checks. When the UI moves under a check, the sentence is judged
  on screen instead and the run's triage repairs the check ([triage.md](triage.md)).
- **Write for the redesign you cannot see yet.** Navigate with `agent.act` or by URL,
  never by clicking through layout; locate by role and the user-visible name the issue
  uses; no CSS selectors, DOM structure, `nth()`, or test ids the issue does not name; one
  fact per `expect`. A check that only passes in today's layout is a future false alarm.
- **The `// AC-<k> begin` / `end` block holds only the checks**, written from the
  criteria file's *Then* line before the first run. Everything before it — navigation,
  setup, `agent.act` — is free to change.
- **Every AC block discriminates**: at least one `expect` on data the test itself created
  (a `unique()` name) or on state the test itself changed — never only on a static page
  element, which passes on a build without the feature. `check-asserts.sh --lint <file>`
  lists the blocks that name no `unique()` identifier; each one listed checks changed
  state, or gets such a check.
- After the first candidate run, an edit inside an AC block may only repair *how* the
  same thing is located (a locator that never matched), keeping the matcher and the
  expected value. Name every such edit in the report. Promoted tests: never, without the
  operator (`scripts/check-asserts.sh` flags it).
- Prefer `expect` with role/label locators; use `agent.assert` only for what has no
  stable locator. `agent.assert` runs live on every run (it is not cached) — it costs
  tokens nightly.
- Every `agent.act` is followed by a check of its outcome (an `expect`, `waitFor` or
  `agent.assert`) — that verification is what lets the replay cache record it.
- Keep each `act` to one goal; wrap generated names in `unique()` so replays survive.
- Tags: `issue-<n>` and `ac-<k>` on every AC test; `smoke` only on the skeleton's smoke and
  injection canary tests (never edit the canary's judgement; [nested-env.md](nested-env.md) → Failures).
- Sign-in comes from the `owner` setup session; never type credentials in a test.

**Explorations** ([explorations.md](explorations.md)) live in the same file, one test per
EX tagged `issue-<n>-ex`, `ex-<k>`, `from-ac-<j>`, with `// EX-<k> begin` / `end` blocks
and an `EX-<k>:` screenshot written by the rules above. Their blocks are hashed apart
(`check-asserts.sh --ex-hash`) and are not promoted state; a role session other than `owner`
comes from the setup test too.

## Finding the steps

Explore the running candidate with `npx e2e mcp` (registered for this harness at
onboarding): open a session, look at the screen, use its `locate` tool to turn a
`screen.*` locator into test code. Explore only what the criterion needs.

## CLI and API criteria

Same file, same AC blocks; there is no browser video for these, so print the command
and its output into the test's log and keep the evidence textual. Which CLI and API the
product publishes, and how a test gets a token for them, is in the profile's `SKILL.md`.
For a CLI: install the published package once into `work/suite`, run it with `execa`
against `app.baseUrl` and a token the test's setup mints through the UI; assert on
machine-readable output and exit codes. API: `fetch` against `app.baseUrl` with the same token. **Run it,
never read it**: the installed CLI's files are product code ([black-box.md](black-box.md)).

## Repairing a failing test

A regression or retest failure is first judged ([reporting.md](reporting.md) →
Verdicts). Only a *test* defect — the product does what the criterion says, the test
cannot get there — is repaired, outside the AC blocks; the replay cache re-records on the
next verified pass.

## Upgrading `e2e`

`e2e_version` and `e2e_web_version` move together, by the operator, to releases at least
seven days old. `@e2e-dev/web` pins its own `playwright-core`; when it no longer matches
the image's Playwright, `suite.sh init` downloads the matching Chromium into the home
([black-box.md](black-box.md) → **Egress rules** lists the hosts). From `e2e` 0.19 the
trace is a markdown page per test instead of a Playwright zip; the report renders either.
