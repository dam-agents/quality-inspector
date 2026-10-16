# Discovery — what to find out before writing

Two sources: the product's repository (read it — you work for the product team) and the
person (what only they know). A product without source access — a vendor's — gets the
same brief from its install documentation, its registry and a trial install. Batch the
questions; propose a default for each from what you read; skip what the repository
already settled.

## The profile brief

Present this table filled in; mark a row `unknown` rather than guessing, and get it
confirmed before writing files.

| # | Fact | Lands in |
| --- | --- | --- |
| 1 | Product name as users know it; one sentence of what it does for them | `product`, `SKILL.md` intro |
| 2 | Port (and base path) the UI answers on inside the VM | `app.url` (`http://localhost:<port>`), the engine's port |
| 3 | What ships: a Helm chart, images and a compose file, a package, a binary — and its reference | Phase 2 choice; `engine_config.chart` or `bin/` |
| 4 | Build channels: names, tag pattern, ordering, which is the default candidate and baseline | `channels`, the defaults, README → Channels |
| 5 | Prerequisites a fresh cluster or host needs (CRDs, operators, a database, ingress) | `prerequisites`, or `bin/env up` |
| 6 | How a fresh install gets a signed-in-able **owner** account without a person | values with `{{user:owner.…}}`, or `bin/env up` |
| 7 | Further accounts, by the contract's role names: `member`, `viewer`, `outsider` (The owner account, below) | more `credentials.users` / `E2E_USER_<ROLE>_*` |
| 8 | First-run screens (terms, a setup wizard, a tour) and how to skip them | values, or a `SKILL.md` note |
| 9 | Where product data lives — what `reset` must wipe | the engine (release + PVCs), or `bin/env reset` |
| 10 | Every outside service the product calls, and whether a stand-in exists | `SKILL.md` → cannot do; an optional `config` key |
| 11 | Every host `up` and `versions` download from | `egress` |
| 12 | Extra surfaces that would expose the implementation; the product's npm scopes or package names | `boundary`, `boundary.packages` |
| 13 | Root, commands, memory a fresh install with two builds' images needs | `requires` |
| 14 | Settings an operator may change, and which have no safe default | `config` (`ask`) |
| 15 | Main UI areas and the terms users see | `SKILL.md` |
| 16 | A published CLI or API (the command, the path of its OpenAPI JSON), its npm package, and how a user gets a token for it | `interfaces`, `boundary.packages`, `SKILL.md` → CLI and API |
| 17 | The main object a user creates, with a name and a description (a project, a document); the namespace its pods run in when no engine names one | `security.entity`, `security.namespace` |
| 18 | API calls the security run cannot make through the UI: create that object, mint and use an API key | `suite/lib/security-api.ts` (its exports: the core's `docs/security.md`) |

## Where to look

- **Delivery**: `Chart.yaml` and `charts/` or `helm/`; `compose.yaml` /
  `docker-compose*.yml`; `Dockerfile` plus the CI workflow that publishes it; the release
  or install documentation. The CI workflow that pushes images or charts tells you the
  registry and how dev builds and releases are tagged.
- **Port and URL**: the chart's service and ingress values, compose `ports`, the server's
  flags. Many products need their public URL configured — set it to the `app.url`.
- **Sign-in**: the auth configuration — an initial-admin value or environment variable, a
  bootstrap command, a bundled identity provider with a test user, or only
  self-registration.
- **Outside services**: the configuration reference — model providers, email, payment,
  OAuth or SSO, object storage, maps, webhooks, telemetry.

## Builds and channels

- A **build** is exactly what `bin/env up <build>` installs and what `bin/versions`
  prints — for a chart, its version tag.
- Typical channels: a dev channel built on every merge to the main branch
  (`0.0.0-main.<n>`, `main-<n>`, a commit hash) and a release channel (`X.Y.Z`). The
  candidate is the newest dev build, the baseline the newest release. Without releases,
  a baseline channel equal to the candidate's means "the build before" (helm-k3s), or
  `none` turns red-green off.
- **Order**: `semver` for releases; `numeric-suffix` for a counter at the tag's end;
  `time` (helm-k3s, quay.io only) for commit-hash tags. Hash tags elsewhere need their
  publish time — own `bin/versions` (references/custom-bin.md).
- **Bisection** (optional, `bin/versions --between` in `docs/profile-contract.md` → The
  bin/ contract) needs nothing more: helm-k3s and the `versions` template answer it from
  the same sorted listing. An own script without it exits 2.
- **Confirm against the registry**, not the CI file: list the tags (quay.io's
  `/api/v1/repository/<repo>/tag/`, `/v2/<repo>/tags/list` with an anonymous token,
  `crane ls`, `oras repo tags`, `skopeo list-tags`) and check that each anchored regex
  (`^…$`) picks the newest real build and never `latest`, `-rc`, `-debug`, `sha256-….sig`
  or attestation tags.
- Never list builds through the target repository's GitHub API (releases, tags): the
  agent's egress denies every path under the target, and builds come from where they are
  published.

## The owner account

`bin/env init` writes `E2E_USER_OWNER_USERNAME` / `_PASSWORD` (generated, never in the
profile); `bin/env up` must leave that account able to sign in. Best first:

1. The install accepts an initial user — a chart value or environment variable. Template
   it: `{{user:owner.username}}`, `{{user:owner.password}}` (helm-k3s).
2. A bundled identity provider with a test-user option — the same placeholders.
3. A bootstrap command or public setup API — own `bin/env up` calls it once the UI
   answers, idempotently.
4. Self-registration only — last resort: `SKILL.md` says the first sign-in registers the
   owner with the generated credentials, and the brief flags it as brittle across
   resets.

A product that offers SSO only needs option 2. Each further account takes a role name
of the contract (`docs/profile-contract.md` → The bin/ contract: `member`, `viewer`,
`outsider`) — explorations and the security run find accounts by those names only — and
is one more user with the same mechanism. Without them, `SKILL.md` says ACs about other
users are `testable: no — single user`.

## Outside services

The nested product reaches only the hosts in its `egress` list, and those exist to
install it — treat every runtime call to an outside service as unavailable: model
providers, email delivery, payment, third-party OAuth, webhooks to the internet, maps.
For each, either a stand-in exists (a mock image, a bundled mail catcher, bundled object
storage) — then it is a `config` key or a literal in the install, and `SKILL.md` says how
a user observes it — or `SKILL.md` makes the ACs that need it `testable: no — external
dependency`.

## Egress

Every host the install and the build listing contact, with `method` (`GET` unless more is
needed), a `path` where the host is shared (e.g. `github.com` release downloads), and a
`why`. Registries hand blobs to other hosts — quay.io → `*.quay.io`; ghcr.io →
`pkg-containers.githubusercontent.com`; Docker Hub → `registry-1.docker.io`,
`auth.docker.io`, `production.cloudflare.docker.com`; GitHub release downloads →
`objects.githubusercontent.com`, `release-assets.githubusercontent.com`. The helm-k3s
engine also needs `get.helm.sh`. The operator applies these entries with the rules
`scripts/egress-rules.sh` prints (the core's `docs/black-box.md` → Egress rules). GitHub
is deny-by-default for every repository there, so an install that downloads from the
target repository's own releases cannot work — such builds must come from a registry; a
third-party release download needs an entry with its exact path.

## Boundary

The core already denies and probes its own list for the provider (its
`docs/black-box.md` → Enforcement layers). Add what would otherwise expose the
implementation for this product:

- `github_paths` — repository API paths, probed as `repos/<target>/<path>`: CI runs and
  logs (`actions/runs?per_page=1`), releases with source assets (`releases?per_page=1`).
  The operator's wildcard deny already refuses them; listing them proves it.
- `urls` — sites that describe the internals: architecture or design docs, a component
  catalogue built from the code, hosted source maps. `{repo}` stands for the target. Each
  needs an explicit deny from the operator — the README lists them.
- `packages` — the product's npm scopes or package names (`@acme`, `acme-cli`): the
  agent refuses to read their files under any `node_modules/`, for example a published
  CLI the suite installs. Without the list nothing is refused there.

## Config keys

- Names: `[a-z][a-z0-9_]*` (placeholders match nothing else); stable once released.
- Values are strings; an empty default means off, and its `about` says so.
- Good keys: the chart or image repository (mirrors), prerequisite versions, optional
  stand-ins. Not keys: secrets, per-run values, anything no instance would change.

## Requirements

`root: true` when the runtime needs it (k3s, docker); `commands` the agent's image must
have (`k3s`, `curl`, `jq`, `node`, the runtime your scripts call); `memory_gi` measured on
a fresh install with both builds' images present, plus about 2 GiB for the browser. The
kit's default VM is 8 CPU, 12 GiB, 80 GiB of disk; a product that needs more says so in
its README.
