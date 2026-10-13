# The product profile

This definition tests any product with a web UI. Everything it knows about one product
comes from a **profile**: a skill installed from a skill source at onboarding, named by
the `profile` config key. The core owns the method — issues to frozen criteria, the
suite, red-green, evidence, change awareness, triage, flakiness, spec feedback, the
benchmark. The profile owns the product — how to run it, which versions exist, how to
sign in, what is off limits, and what a tester should know about it.

## Where it lives

A skill directory, installed by the platform's skill tools into the agent's skill path
(`$HOME/.agents/skills/<name>/`, also seen as `$HOME/.claude/skills/<name>/`).
`scripts/lib/profile.sh` resolves it; `QI_PROFILE_DIR` overrides the lookup (tests,
local development). The core never edits a profile; changes go to its own repository.

```
<profile>/
  SKILL.md        product knowledge for the agent (below)
  profile.json    the manifest (below)
  bin/env         the product environment
  bin/versions    which builds exist
  bin/build-time  when a build was published
  suite/          optional: files merged into work/suite on init (fixtures, helpers)
  README.md       for the people who maintain the profile
```

## `profile.json`

```json
{
  "schema": "qi-profile/v1",
  "product": "Acme Widgets",
  "app": { "url": "http://localhost:8080" },
  "issues": { "provider": "github" },
  "boundary": {
    "github_paths": ["actions/runs"],
    "urls": ["https://docs.internal.example/architecture/"]
  },
  "egress": [{ "host": "registry.example.com", "method": "GET", "why": "product images" }],
  "requires": { "root": true, "commands": ["docker"], "memory_gi": 8 },
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
  `/repos/<target>/`, and full URLs.
- `egress` — hosts the product environment needs, for README and the operator's egress
  rules. Listed, never applied by the agent.
- `requires` — checked by `verify-onboarding.sh --live`: root (a vm-backend agent), the
  commands on `PATH`, memory.
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

**Read-only commands** (the pre-flight calls them inside the Precheck's two minutes):

- `bin/versions` → stdout `{"candidate": "<build>", "baseline": "<build>"|null}` for the
  channels; exit non-zero with a reason on stderr when it cannot look. Never a guess.
- `bin/build-time <build>` → stdout one ISO-8601 UTC timestamp, the moment the build was
  published; non-zero when unknown. The change window of [change-awareness.md](change-awareness.md).

**Acting commands** (only the agent calls them, under the environment lock):

- `bin/env init` — idempotent: create `$QI_ENV_DIR` and **`$QI_ENV_DIR/credentials.env`**
  (mode 600) with `E2E_USER_OWNER_USERNAME` and `E2E_USER_OWNER_PASSWORD` — the account
  the suite signs in as — plus any further `E2E_USER_<NAME>_*` pairs the product needs.
  Never prints a secret.
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
the product's vocabulary, its main areas and how a user reaches them, the test account
and what it can do, what the nested environment cannot do (no outbound network, no email,
a mock instead of a real model…), and the sentences that tell a tester an AC is
`testable: no` for that reason. Never implementation detail — a profile that describes
the code breaks the black box as surely as reading it.

## Choosing and changing the profile

Onboarding installs it ([ONBOARDING.md](../ONBOARDING.md) Step 3). Switching an
onboarded agent to another product is a new agent: the suite, the maps and the state
belong to one product.
