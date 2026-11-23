# Property checks — rules that hold for every input

A module of the modules run ([modules.md](modules.md)), switch `property_checks`, after
`validation`. You state **properties** — rules the product must keep for every input — and
`scripts/property.mjs` tries each with many generated inputs against the nested product on its
`localhost` URL (fast-check, installed by `suite.sh init`), then shrinks a failure to the smallest
input that still breaks it. Black box only: the inputs go to the running product, never to its
code. No model steps in the run; yours is the freeze.

## 1. Freeze — `work/property/<c>/properties.json` (you, before the run)

At most `property_max_properties` (12) properties, from what you may read
([black-box.md](black-box.md)): the profile's `SKILL.md`, the UI map (its forms and the requests
its pages send), the `interfaces` snapshots — the OpenAPI description and the CLI's `--help`
([change-awareness.md](change-awareness.md)) — and earlier findings. Never change the file after
the run starts; a new set is a new file for the next build. Prefer the API or the product's CLI
(fast, hundreds of tries); the UI only to read back a value (`ui` step) or for design properties.

```json
{ "build": "<c>", "properties": [
  { "id": "PROP-1", "kind": "round-trip", "statement": "A project keeps the name it was created with",
    "source": "SKILL.md: “the name you give a project is shown everywhere”",
    "input": { "type": "text", "min": 1, "max": 120, "mix": ["unicode", "whitespace", "long", "boundary", "html"] },
    "steps": [ { "as": "made", "api": { "method": "POST", "path": "/api/projects", "body": { "name": "{input}" } } },
               { "as": "back", "cli": ["projects", "get", "{made.body.id}", "--json"] } ],
    "expect": [ { "equal": ["back.body.name", "{input}"] } ] },
  { "id": "PROP-2", "kind": "design", "statement": "The project list holds its layout",
    "source": "WCAG 1.4.10 reflow and 1.4.3 contrast", "page": "/projects",
    "invariants": ["no-sideways-scroll", "controls-reachable", "no-clipped-text", "no-overlap", "contrast"],
    "vary": { "width": [320, 1920], "zoom": [1, 2], "text_length": [0, 200], "locales": ["en-US", "de-DE", "ar", "ja-JP"] } } ] }
```

- **`kind`** — `round-trip` (create, read back the same value: an `equal` or `contains`),
  `idempotent` (the same submit twice is one effect: a step with `repeat` 2–3 and a `delta` with
  `max`), `invariant` (a count never negative, a total equals its items, any input answered
  without an error: `compare`, `sum`, `count`, `ok`), `cross-surface` (one state on two surfaces: steps on two of `api`, `cli`, `ui`),
  `design` (below). `source` quotes where the rule comes from; a rule you cannot source is no property.
- **`input`** — `text` (`min`, `max` ≤ 2000, `mix` of `unicode` — graphemes of every script,
  RTL, emoji —, `whitespace` around a value, `long`, `boundary` — lengths `min`, `max`, `max`+1 —,
  `html`) or `integer` (`min`, `max`; the bounds and one past each are tried too).
- **A step** — `as` (its name) and one of `api` (`method` `GET`|`POST`|`PUT`|`PATCH`, `path` on
  the product's origin, JSON `body`), `cli` (the argv of the profile's `interfaces.cli`, run
  without a shell) or `ui` (`open`: a path; its answer is the page's visible text). `{input}`,
  `{stamp}` (unique per try: names that must not collide) and `{<as>.<path>}` fill a step; a path
  is `.key`, `[n]` or `[]` (every element) into the answer's `body` (JSON), `status` or `text`.
  Never a delete: a method other than those four, or a path, body or argv that names a
  destructive action (`lib/danger.mjs`), is refused.
- **`expect`** — `{"ok": "<as>"}` (2xx, exit 0), `{"equal": [a, b]}`, `{"contains": [a, b]}`,
  `{"compare": [a, ">=", b]}` (`>= <= > < == !=`; every element of a `[]` path), `{"sum": a,
  "equals": b}`, `{"count": a, "equals": b}`, `{"delta": [before, after], "max": n}`; `normalize`
  `trim`, `nfc` or `trim+nfc` only where the product promises it (say so in `source`).

**Oracles, for every try:** a 5xx answer (`no-server-error`) or a broken `expect` (`assertion`) is
`major`. The first step's refusal (4xx, a non-zero exit) is the product refusing that input — not
a try; a property every input was refused for is `vacuous`.

**Design properties** — each try opens `page` as the owner in a fresh browser at a generated
`width` (px), `zoom` (in quarters: the viewport is `width / zoom` CSS px at that pixel ratio),
`text_length` (the names and titles in the page's own JSON answers made that long, in the browser
only) and locale, and runs the UI sweep's checks (`lib/ui-checks.mjs`): `no-sideways-scroll`
(`overflow-x`) and `controls-reachable` (`offscreen`) are `major`, `no-clipped-text`,
`no-overlap` and `contrast` (WCAG AA: 4.5:1, 3:1 for large text) `minor`. A UI try costs seconds:
at most 20 tries a property.

## 2. Run

`node "$HOME/scripts/property.mjs" "$HOME/work/property/<c>/properties.json" --build <c>` →
`work/property/<c>/results.json` (`--dry-run` validates and prints the plan). `property_runs` (50)
tries a property, `property_max_seconds` (180) for its tries and shrinking together. The seed is
random and recorded; every result carries its `seed`, the shrunk `path` and its `replay` command.
Exit 2 with `{error, problems}` = the file breaks a rule above: fix the file before the run (that is
still the freeze). Exit 1 = a browser ran and the owner could not sign in (an environment failure);
exit 3 = no fast-check or no browser where a property needs one: the module failed
([modules.md](modules.md) step 4).

Per property `result`: `ok`, `finding` (with `severity`, `oracle`, `message`, `counterexample`),
`flaky` (the shrunk input passed in one of two more tries: not a finding), `vacuous`, `blocked`
(a step could not run, or fast-check gave up). Then
`modules.sh ran property <c> properties=<n> major=<n> minor=<n> flaky=<n> blocked=<n>`.
Created objects (names with `{stamp}`) stay until the run's closing `env.sh reset`. The crops in
`work/property/<c>/shots/` age out after `media_retention_days`.

## 3. Findings

Outside every verdict, never a comment ([modules.md](modules.md) → Findings of a module); the
dashboard's Findings view shows them, and "create issue for PROP-`<k>`" drafts one
([skills/create-issue](../skills/create-issue/SKILL.md)) with the smallest input and its seed.
A design property's finding — one per element and invariant, at the shrunk sample, a marked crop —
also goes:

- to the design findings register: `node "$HOME/scripts/design-findings.mjs" merge --property
  "$HOME/work/property/<c>/results.json"` (source `property`, check `property:<invariant>`). A later
  run that tried that invariant on that page and did not break it there resolves it.
- with `design_desk_findings: enabled`, to the Design Desk: `results.json` joins the files of
  [design-checks.md](design-checks.md) → **4. To the Design Desk** — `Check: property`, Ref
  `qi-prop-<hash>` of the page, the invariant and the element (never the sample: another seed
  shrinks to another one), the shrunk sample and the seed in `What happens`, the steps that
  reproduce it in `Steps`.

## Replay — the operator's "replay PROP-`<k>`"

The recorded failure again, on the build that is up, under [modules.md](modules.md) → **Rechecks
and discussions** (lock, reset, unlock as a recheck): the property's `replay` command from the newest
`results.json` that has it. It runs only the shrunk input (`--only`, `--seed`, `--path`; no
shrinking) and writes `results-replay-PROP-<k>.json` beside `results.json`, which it never changes
and the register never merges. Answer `finding` (still breaks, with the message) or `ok` (possibly
fixed; the next run decides), and the build.

## Cost

No model step in the run: tens of seconds a functional property, a few minutes a design one. The
freeze is yours: about one feature focus's planning (30–80k tokens) a run, on the cadence you set.
