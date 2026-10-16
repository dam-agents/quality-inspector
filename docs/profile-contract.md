# The product profile

This definition tests any product with a web UI. Everything it knows about one product
comes from a **profile**: a skill installed from a skill source at onboarding, named by
the `profile` config key. The core owns the method — issues to frozen criteria, the
suite, red-green, evidence, change awareness, triage, flakiness, spec feedback, the
benchmark. The profile owns the product — how to run it, which versions exist, how to
sign in, what is off limits, and what a tester should know about it.

## Where it lives

A skill, assigned to the agent by the operator from a skill source on the platform (the
agent does not install it), which lands in the agent's skill path
(`$HOME/.agents/skills/<name>/`, also seen as `$HOME/.claude/skills/<name>/`). It lives in
**`.quality-inspector/<profile>/`** of a GitHub repository — usually the product's own, so
the product team versions it with the product — added as a skill source with `path`
`.quality-inspector`. That directory, in any repository, is the one path of a repository
the kit's egress opens, so the platform fetches only it and no instance needs a rule for it
([black-box.md](black-box.md) → **Egress rules**); a profile anywhere else cannot be
installed. Keep symlinks and submodules out of it.
`scripts/lib/profile.sh` resolves it; `QI_PROFILE_DIR` overrides the lookup (tests,
local development). The core never edits a profile; changes go to its own repository.

```
<profile>/
  SKILL.md        product knowledge for the agent (below)
  profile.json    the manifest (below)
  bin/env         optional — the product environment (else its engine's)
  bin/versions    optional — which builds exist (else its engine's)
  bin/build-time  optional — when a build was published (else its engine's)
  suite/          optional: files merged into work/suite on init (fixtures, helpers, lib/security-api.ts)
  README.md       for the people who maintain the profile
```

## Engines

Most products run the way many others do — a Helm chart, a compose file, a Python or
Node server. An **engine** is a reusable implementation of the `bin/` contract shipped in
this definition under `engines/<name>/`; a profile names it with `"engine": "<name>"` and
describes its product as data in `"engine_config"`. A profile that ships its own
`bin/<cmd>` overrides the engine for that command. Engines today:

| Engine | For | Configuration |
| --- | --- | --- |
| `helm-k3s` | a Helm chart in an OCI registry, run in k3s | [engines/helm-k3s/README.md](../engines/helm-k3s/README.md) |

A new engine is a new directory with `bin/env`, `bin/versions`, `bin/build-time` and a
README of its configuration; it receives the profile's `engine_config` (placeholders its
own business) as `QI_ENGINE_CONFIG`, and never product facts of its own. An optional
`bin/check` validates that configuration offline (`FAIL <problem>` / `WARN <note>` lines,
exit 1 on any `FAIL`); only the profile checker below calls it.

## Writing a profile

The product team writes it with the
[`qi-profile-creator`](../skills/qi-profile-creator/SKILL.md) skill: discovery and a brief
they confirm, the files from templates, and
`skills/qi-profile-creator/scripts/check-profile.mjs`, which checks a profile against
this contract (`--live` also lists its builds).

## `profile.json`

```json
{
  "schema": "qi-profile/v1",
  "product": "Acme Widgets",
  "app": { "url": "http://localhost:8080" },
  "issues": { "provider": "github" },
  "boundary": {
    "github_paths": ["actions/runs"],
    "urls": ["https://docs.internal.example/architecture/"],
    "packages": ["@acme"]
  },
  "egress": [{ "host": "registry.example.com", "method": "GET", "why": "product images" }],
  "requires": { "root": true, "commands": ["docker"], "memory_gi": 8 },
  "canary": { "thing": "widget, under Widgets → New", "field": "description" },
  "interfaces": { "cli": "widgets", "openapi": "/api/openapi.json" },
  "config": {
    "image_ref": { "default": "registry.example.com/widgets", "about": "image repository the builds come from" },
    "admin_email": { "default": "", "about": "which address the seeded admin account uses", "ask": true }
  }
}
```

- `app.url` — the product's base URL **inside this agent's VM**; it must be `localhost`
  or `127.0.0.1` (the nested-only rule).
- `issues.provider` — `github` today; the target repository is the instance's
  `target_repo`.
- `boundary` — what the black-box probes must find refused **in addition** to the core's
  own list for the provider ([black-box.md](black-box.md)): repository API paths under
  `/repos/<target>/`, and full URLs. Optional `packages` — the
  product's npm scopes or package names; the policy hook refuses reading their files
  under any `node_modules/` (without it, nothing is refused there).
- `egress` — hosts the product environment needs, for README and the operator's egress
  rules. Listed, never applied by the agent.
- `requires` — checked by `verify-onboarding.sh --live`: root (a vm-backend agent), the
  commands on `PATH`, memory.
- `security` (optional) — `entity`: the noun of the main object a user creates, with a
  name and a description (`"project"`); `namespace`: where its pods run, when the engine
  names none. The security run's input and deployment checks need them ([security.md](security.md)).
- `canary` (optional) — what the injection canary ([nested-env.md](nested-env.md) →
  Failures) creates: `thing`, an object a user creates with a name, in the product's words
  and where (`"project, under Projects → New"`), and `field`, the free-text field that shows
  the injected text (`description` by default; `name` puts it into the name itself). A
  product with no such object says why in `none`; the canary is then skipped with that
  reason. Absent → the act model looks for one.
- `interfaces` — optional, both fields too: `cli`, the published CLI's command (on `PATH`
  or installed into `work/suite`), and `openapi`, the path under `app.url` that serves the
  API description as JSON. Their snapshots are change context
  ([change-awareness.md](change-awareness.md)); absent → no snapshot.
- `config` — the profile's own keys, written in `work/CONFIG.md` as
  `- profile.<key>: <value>`, each with a default and an `about` sentence; `"ask": true`
  makes onboarding ask the operator instead of defaulting. The core validates that no
  unknown `profile.*` key is set and hands the resolved values to every `bin/` call.
- Channels — `candidate_channel` / `baseline_channel` are the instance's words for "which
  build"; the profile's README names the ones it understands and its defaults (used when
  the key is empty). `none` as a baseline always means no baseline.

## The `bin/` contract

Every executable runs with cwd `$HOME/work`, and with:

| Variable | Holds |
| --- | --- |
| `QI_WORK` | the work directory |
| `QI_ENV_DIR` | `$QI_WORK/env` — the profile's own state (values, secrets, logs) |
| `QI_PROFILE_CONFIG` | one JSON object: every `profile.json` config key, resolved (instance value, else default) |
| `QI_CANDIDATE_CHANNEL`, `QI_BASELINE_CHANNEL` | the instance's channels |
| `QI_PROFILE_DIR`, `QI_ENGINE_CONFIG` | the profile's directory, and its `engine_config` (JSON) for an engine |
| `QI_MODEL_KEY`, `QI_MODEL_KIND`, `QI_MODEL_BASE_URL` | with `lend_model: enabled`, the agent's own model connection lent to the product: its placeholder `platform:conn:<id>` — never a key; the gateway swaps it for the key on the way out —, the credential kind (`api-key`, `oauth`, `auth-token`, `bedrock`, `unknown`) and the base URL or empty. All empty when not lent: the product keeps its mock |

**Read-only commands** (the pre-flight calls them inside the Precheck's two minutes):

- `bin/versions` → stdout `{"candidate": "<build>", "baseline": "<build>"|null}` for the
  channels; exit non-zero with a reason on stderr when it cannot look. Never a guess.
- `bin/versions --between <from> <to>` — **optional** → stdout a JSON array of the builds
  published strictly between the two (same channel), oldest first; `[]` when adjacent.
  Not implemented → exit 2 (output that is not an array counts the same); bisection is
  then skipped with that reason ([triage.md](triage.md) → Order of work, step 6).
- `bin/build-time <build>` → stdout one ISO-8601 UTC timestamp, the moment the build was
  published; non-zero when unknown. The change window of [change-awareness.md](change-awareness.md).

**Acting commands** (only the agent calls them, under the environment lock):

- `bin/env init` — idempotent: create `$QI_ENV_DIR` and **`$QI_ENV_DIR/credentials.env`**
  (mode 600) with `E2E_USER_<ROLE>_USERNAME` / `_PASSWORD` pairs — **the role convention**.
  `OWNER` is required — the account the suite signs in as; optional roles: `MEMBER` (an
  ordinary user of the owner's tenant or workspace), `VIEWER` (read-only there), `OUTSIDER`
  (another tenant or organization, with no access to the owner's data). Every role written
  signs in after each `up`; `SKILL.md` says what each may do. Explorations
  ([explorations.md](explorations.md)) and the security run's access checks
  ([security.md](security.md)) use them. Further `E2E_USER_<NAME>_*` pairs the product needs
  are allowed. Never prints a secret.
- `bin/env up <build>` — bring the product up at exactly that build, reachable at
  `app.url`; idempotent; exit 0 only when the UI answers. A forward-only upgrade is fine.
- `bin/env reset` — wipe product data so the next `up` starts clean (fresh users, no
  content). Needed before every downgrade.
- `bin/env status` → stdout `{"running": bool, "build": "<build>"|null, "ui_http": "<code>"}`.
- `bin/env down` — stop it; state may stay on disk.

Exit 0 is success; anything else is an environment failure, which never becomes a
verdict ([issue-qa.md](issue-qa.md)). Diagnostics go to stderr; secrets never.

## `SKILL.md` — what a tester should know

Read at the AC freeze and when writing tests. It holds **user-facing** knowledge only:
the product's vocabulary, its main areas and how a user reaches them, each test
account's role and what it may do, what the nested environment cannot do (no outbound network, no email,
a mock instead of a real model…), and the sentences that tell a tester an AC is
`testable: no` for that reason — and which of them a lent model (`lend_model`) makes testable. Never implementation detail — a profile that describes
the code breaks the black box as surely as reading it.

## Choosing and changing the profile

Onboarding installs it ([ONBOARDING.md](../ONBOARDING.md) Step 3). Switching an
onboarded agent to another product is a new agent: the suite, the maps and the state
belong to one product.
