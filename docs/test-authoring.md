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

test('#42 AC-1: a renamed agent keeps its sessions', { session: 'owner', tags: ['issue-42', 'ac-1'] },
  async ({ app, agent, screen }) => {
    const name = unique(`qa-${Date.now()}`);
    await app.open('/');
    await agent.act('create an agent named {name} from the mock template', { params: { name } });
    await agent.act('rename the agent {name} to {name}-2', { params: { name } });
    await app.screenshot('AC-1: the renamed agent and its sessions');
    // AC-1 begin
    await expect(screen.getByRole('heading', { name: `${name}-2` })).toBeVisible();
    await agent.assert('the agent still lists the session it had before the rename');
    // AC-1 end
  });
```

- **Right before each AC block, `app.screenshot('AC-<k>: <what the Then line looks at>')`.**
  It is the still a reader checks the verdict against; the report captions it with that
  label. `agent.assert` adds its own screenshot. Never screenshot inside the setup test.
- **The `// AC-<k> begin` / `end` block holds only the checks**, written from the
  criteria file's *Then* line before the first run. Everything before it — navigation,
  setup, `agent.act` — is free to change.
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
- Tags: `issue-<n>` and `ac-<k>` on every test; `smoke` only on the skeleton's smoke test.
- Sign-in comes from the `owner` setup session; never type credentials in a test.

## Finding the steps

Explore the running candidate with `npx e2e mcp` (registered for this harness at
onboarding): open a session, look at the screen, use its `locate` tool to turn a
`screen.*` locator into test code. Explore only what the criterion needs.

## CLI and API criteria

Same file, same AC blocks; there is no browser video for these, so print the command
and its output into the test's log and keep the evidence textual. CLI: install the published CLI once into `work/suite`
(`npm i -D @dam-agents/cli`), run it with `execa`, `DAM_SERVER=http://localhost:4444` and
a `DAM_TOKEN` API key minted through the UI in the test's setup; assert on `--json`
output and exit codes. API: `fetch` against `app.baseUrl` with the same token. **Run it,
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
(README → Black-box boundary lists the hosts). From `e2e` 0.19 the trace is a markdown
page per test instead of a Playwright zip; the report renders either.
