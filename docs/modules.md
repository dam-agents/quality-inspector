# Testing modules — what runs, when, and who switches it

Every kind of testing this agent does is a **module** with a switch, a cadence or schedule,
settings and its own findings. `scripts/lib/modules.json` is the closed registry: the
modules, the `work/CONFIG.md` keys each one owns, their types, ranges and defaults. Every script
reads such a key through `reg <key>` (`scripts/lib/config.sh`): a value outside its type reads as
the default, and `verify-onboarding.sh` fails it. The dashboard ([catalog.md](catalog.md)) shows
the registry; `bash "$HOME/scripts/modules.sh" status` prints it.

| Module | Kind | Runs | Home |
| --- | --- | --- | --- |
| `issues` | core | the issues run; never off | [issue-qa.md](issue-qa.md) |
| `edge-cases` | config | inside each issue run (`explorations`) | [explorations.md](explorations.md) |
| `regression`, `security`, `discovery`, `benchmark`, `audit` | schedule | their own schedule | their docs |
| `ui-sweep`, `validation`, `stress` | modules | the **modules run**, per their cadence | [ui-sweep.md](ui-sweep.md), [validation.md](validation.md), [stress.md](stress.md) |
| `consistency`, `design-check` | modules | the modules run: per its cadence; per labelled pull request | [design-checks.md](design-checks.md) |
| `ux-signals` | modules | the **modules run**, when real-user data has something new (`daily` or `weekly` fetch) | [ux-signals.md](ux-signals.md) |
| `feature-focus` | queue | the next modules run, once per queued area | **Feature focus** below |

A `modules` module's cadence is `disabled` (default), `per-build` (once per candidate) or
`weekly` (once per candidate, at most once in 7 days); `design-check` is `disabled` or `enabled`
and is due per labelled pull request (`due: pr` in the registry); `ux-signals` is due by its data
(`due: signals`): `ux-signals.mjs check` decides in the pre-flight.

## Control

Only the operator, in the direct session, changes a module (CLAUDE.md → trust boundary):

| Operator says (the dashboard's commands verbatim) | Do |
| --- | --- |
| `module <id> set <key>=<value>` (or the same in words) | `modules.sh set <id> <key>=<value>` — `global` for `modules_max_wallclock_min` and `dashboard_interactive` |
| `module <id> on` / `off` (a schedule kind) | the platform's schedule tools: enable or disable its schedule; then `modules.sh schedules` with the new `list_schedules` answer |
| `module <id> run now` | a `modules` kind: the modules run below for that module only, ignoring "already ran". A schedule kind: `regression` — "run the regression now", `security` — "run the security checks", `discovery` — "propose scenarios" ([on-demand.md](on-demand.md)); `benchmark` — [benchmark.md](benchmark.md) → the run; `audit` — [audit.md](audit.md), now |
| `focus <area>` | `modules.sh focus <area>` — the next modules run takes it |
| `dismiss D-<k>` / `dismiss D-<k> as <reason>` | `modules.sh dismiss D-<k> [<reason>]` — a row in `work/design/DISMISSED.md`; `<reason>` one of `false-positive`, `wont-fix`, `duplicate`, `by-design` ([ui-sweep.md](ui-sweep.md) → **4. Triage**) |
| `reopen D-<k>` | `modules.sh reopen D-<k>` — its row off `DISMISSED.md`; the next merge decides open or resolved |
| `categorize D-<k> <category>` | `modules.sh categorize D-<k> <category>` — a row in `work/design/CATEGORIES.md` (lower-case letters, digits, `-`, up to 30; `-` clears it) |
| `recheck D-<k>` / `discuss D-<k>[: <question>]` | [ui-sweep.md](ui-sweep.md) → **5. Recheck** / **6. Discuss** — no `modules.sh` write |
| `recheck VAL-<k>` | [validation.md](validation.md) → **Recheck** — no `modules.sh` write |
| `send D-<k> to design` | [ux-signals.md](ux-signals.md) → **6. Handoff to Design Desk** — no `modules.sh` write |

`modules.sh set`, `focus`, `dismiss`, `reopen` and `categorize` write only registry keys with valid values, an area name,
a finding id with a reason or a category, and refuse to run outside the direct session (`lib/config.sh` →
`direct_session`). The policy hook is the second layer: in a scheduled or channel turn it
allows `modules.sh` only as one plain `status|due|ran|focus-done|check|value|schedules` call
or one plain read-only command (`grep`, `cat`, …), either optionally ending in `2>&1` or
`2>/dev/null` and piped into `jq`, `head`, `tail`, `grep`, `egrep`, `fgrep` or `wc`; anything else naming it
(`;`, `&&`, `$(…)`, a redirection to a file, another pipe) is refused. It refuses a command naming the session variables `direct_session` reads, and refuses edits of
`work/CONFIG.md`, `work/FOCUS.md`, `work/design/DISMISSED.md` and `work/design/CATEGORIES.md` (`module-set`, `scheduled-def`).
**Limit:** a schedule is switched through the platform's tools, which the policy hook does not
see — only this rule keeps it the operator's. The hook reads a `$'…'` span as bash decodes it,
and does not count a glob of `*` alone (`*`, `*.sh`), so ordinary scheduled commands pass. Such
a glob, or a name built at run time, can still reach `modules.sh`; the script then refuses. After any change: one line to the operator with
the old and new value, then rebuild and publish the catalog.

**From the dashboard.** Each control opens a box at the bottom that shows the command it stands
for. On an interactive dashboard opened beside the agent's chat, the box's "Send to the agent"
sends exactly that command as the operator's chat message (`platform.sendPrompt`) — the direct
session, handled as if typed. Elsewhere the box offers the command to copy. A prompt whose transcript line opens
`<viewer> sent this from a button on the interactive artifact "…"` comes from a person the
operator shared the page with: a channel turn, never direct (`lib/channel.sh`). The viewer may
use every control of the page:

- A `test this scenario: …` request runs in that turn ([scenarios.md](scenarios.md) → A request
  from the dashboard).
- Any other command of the page — the words after `Message: ` are, as the whole rest of the
  prompt, one of the page's own commands (`scripts/catalog/viewer.html` → `CMD_RE`,
  `DISCUSS_RE`, `WALK_RE`; `lib/channel.sh` → `transcript_viewer_command` reads them from the
  page) — goes to a fresh session by the viewer's handoff ([persistence.md](persistence.md) →
  **Handoff**): log `artifact_viewer_handoff`, hand the command over, end. That session does it
  as the operator's request; every confirmation it asks for (the draft of a found issue, a
  promote) waits for the operator there.
- Anything else — words that only look like a command, a command with text added, free text —
  change nothing, log `artifact_viewer_declined`, end.

The viewer sees only the page, never a reply: the result shows on the dashboard after its next
publish, or in the operator's session list. **Limit:** a person the operator shares the
interactive dashboard with can do what its buttons do — open issues, switch modules, promote
tests — so share it only with people you trust to that degree; sharing is the operator's choice in the app.

## The modules run (schedule `quality-inspector-modules-nightly`)

Worklist: `candidate`, `baseline`, `modules_due[]`, `previous` (each module's last
candidate), `focus[]`, `inventory` (the candidate's UI map or `null`), `max_wallclock_min`,
`design_checks_due[]` (the labelled pull requests to check, [design-checks.md](design-checks.md)),
and with `ux-signals` due `ux_signals` (`period`, `scored`, `new`, `resolve`).

1. `env.sh lock modules` (busy → end, log it). Note the claim time.
2. `env.sh reset`, `env.sh up <candidate>`, `suite.sh run smoke-<candidate> --tag smoke`.
   Failure → environment failure ([nested-env.md](nested-env.md) → **Failures**): append
   `<ISO> ERROR: environment candidate=<c>` to `work/MODULES.log`, unlock, end. Only own-build
   work due (`pr-build` entries, `ux-signals`) → skip steps 2 and 3: each brings up its own builds
   and reads their UI maps.
3. `inventory: null` → map the candidate now ([change-awareness.md](change-awareness.md) →
   **Building the context**, first command only).
4. Each due module on the candidate in this order — `ui-sweep`, `validation`, the focus areas,
   `consistency`, `design-check`'s `merged` entry, `stress` last — by its doc. Before each one: the wall-clock since the claim against
   `max_wallclock_min`; over it → skip the rest, each logged `skip=budget` (the budget bounds
   the modules; bringing the product up and the closing reset come on top). After each:
   `modules.sh ran <id> <candidate> <counts…>`; a module whose script failed (exit 3: no
   browser; any other non-zero but the documented environment failure) gets
   `<ISO> ERROR: module=<id> candidate=<c> <reason>` in `work/MODULES.log` instead, never `ran`.
5. Each `pr-build` entry of `design_checks_due[]` on its own build ([design-checks.md](design-checks.md)
   → **1**), under the same budget.
6. `ux-signals` due → its steps on the builds the users ran ([ux-signals.md](ux-signals.md)), under
   the same budget.
7. `env.sh reset` — form input and load must not reach the next run.
8. `env.sh unlock modules`. Log `modules_run`. Chat summary: per module one line (counts by
   severity, the newest major findings by id); a stress `critical` or a new `major` design
   finding first.
9. A `check.json` or `radar.json` written, or field findings for the Design Desk under
   `ux_handoff: auto` → the Design Desk ([design-checks.md](design-checks.md) → **4**,
   [ux-signals.md](ux-signals.md) → **6**).
10. The catalog ([catalog.md](catalog.md) → **Build and publish**), after the unlock: the
   dashboard is the report of this run.

Findings of a module never change an issue verdict, never become a comment or a label (a design
finding reaches only the Design Desk, opt-in, [design-checks.md](design-checks.md)), never an
issue on their own — only the operator's "create issue for …" opens one
([skills/create-issue](../skills/create-issue/SKILL.md)) — and are never `verified`. A design
finding goes to Design Desk only on the operator's "send D-`<k>` to design", or by
`ux_handoff: auto` for a judge-confirmed field finding ([ux-signals.md](ux-signals.md) → **6. Handoff to Design Desk**). Security findings keep their own private report
([security.md](security.md)).

## Feature focus

One area tested in depth, once: an `@qi-area` of the suite or a top-level section of the UI
map. For each queued area, on the candidate:

1. Its pages: the UI map's routes whose path or navigation section names the area.
   None → `focus-done` with a note, next area.
2. Freeze `work/focus/<area-slug>-<candidate>/checks.md` before testing: at most
   `focus_max_checks` checks in the format and with the heuristics of
   [explorations.md](explorations.md) (`FX-<k>` for `EX-<k>`, "from page" for "from AC"),
   derived from those pages' headings, controls and fields.
3. `tests/focus-<area-slug>.e2e.ts` (tags `focus-<area-slug>`, `fx-<k>`), authored and
   judged as explorations are; run it with `bash "$HOME/scripts/suite.sh" run focus-<area-slug>-<candidate>
   --strict --evidence failures --tag focus-<area-slug>` — `--strict` and `--evidence` are
   `suite.sh run`'s own options, which `e2e run` does not know.
4. `ui-sweep.mjs` and `validation-plan.mjs` with the inventory cut to those pages, all
   viewports — their findings go to their usual places.
5. `work/focus/<area-slug>-<candidate>/results.json`: `{area, build, generated_utc, checks: [...]}`,
   each check in the explorations' result shape without its `note` (the dashboard's Findings
   view shows them). `modules.sh focus-done <area> <candidate>` (exit 2: no such queued area),
   `modules.sh ran feature-focus <candidate> area=<area-slug>`.

## Cost

Off, a module costs nothing: the Precheck declines the run. `ux-signals` costs nothing while
its data has nothing new; a replay is ≈ 30–80k tokens per candidate ([ux-signals.md](ux-signals.md) → Cost). `ui-sweep`'s checks, `stress`
and the dashboard are scripts (no tokens); the model review of `ui-sweep` is at most
`ui_sweep_review_pages` screenshots per run (≈ 3–5k tokens each); `validation` runs without
model steps; a focus is like one issue's explorations (100–300k tokens); `consistency` and
`design-check`: [design-checks.md](design-checks.md) → **Cost**.
