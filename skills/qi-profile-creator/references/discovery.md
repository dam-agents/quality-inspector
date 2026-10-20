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
| 17 | The main object a user creates, with a name and a description (a project, a document), and where in the UI; the namespace its pods run in when no engine names one | `security.entity`, `security.namespace`, `canary.thing` (`canary.field` when the text shows in another field, `canary.none` when there is no such object) |
| 18 | API calls the security run cannot make through the UI: create that object, mint and use an API key | `suite/lib/security-api.ts` (its exports: the core's `docs/security.md`) |
| 19 | Main flows that leave the product (it answers in Slack, files a GitHub issue) and the throwaway accounts that would make them testable: what the product's connection asks for, the hosts, methods and paths, what the test person does there | `sandbox`, `sandbox/<name>.md`, `bin/sandbox`, `suite/` helpers, `ask` config keys, `egress` (Sandbox accounts, below) |

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

## Sandbox accounts

Some outside services are the point of a main flow — an agent that answers in Slack, files
a GitHub issue. A stand-in cannot show those; a throwaway account can. Ask the person
whether the flow should be testable end to end; if so, per service (the core's
`docs/profile-contract.md` → `sandbox`):

- **What the product's connection asks for** — read its configuration reference: a GitHub
  App or a token, a Slack bot token and Socket Mode or a webhook. A webhook into the nested
  product cannot work (it is on `localhost`), so a service it needs inbound is testable only
  through an outbound mode (Socket Mode, polling); otherwise it stays `testable: no`.
- **The guide** — `sandbox/<name>.md`, the operator's steps in order: create the
  organization or workspace (never the product's own, never a company one), the narrowest
  app or token, where each value is shown, which line of `credentials.env` it fills. A
  manifest to paste beats a list of scopes. The operator does it once; write it for someone
  who has never seen the service's developer pages.
- **Credentials** — the names in `credentials` (they become `E2E_SANDBOX_<ID>_<NAME>`);
  a key file as one base64 line named `…_B64`. Names that are no secret (an organization
  and repository) are `ask` config keys, so the egress can name them as `{profile.<key>}`.
- **Egress** — each request the product and the test person make, by method and path. On a
  GitHub host only `/repos/{profile.<key>}/<rest>` passes — the core refuses anything else
  there, a GitHub App's `/app/…` endpoints included; prefer a fine-grained token scoped to the
  sandbox repository (`GET /user` the kit already allows).
- **Install-time values** — a service the product configures per install (a Slack app's
  tokens in its Helm values) takes them in the engine's values as
  `{{sandbox:<id>.<NAME>}}`, inside an overlay `when: "@sandbox:<id>"`, so an instance
  without the account installs as before (helm-k3s README → Placeholders).
- **`bin/sandbox check`** — one request per account: who the token is, that the channel or
  repository exists and is no fork; `ok`/`FAIL` lines, never a value.
- **The test person** — helpers in `suite/` (`personSays`, `repliesTo`): the only way a test
  writes to or reads from the service. A result the agent leaves on GitHub is checked
  through what the product shows, never by reading GitHub.

## Egress

Every host the install and the build listing contact, with `method` (`GET` unless more is
needed), a `path` where the host is shared (e.g. `github.com` release downloads), and a
`why`. Registries hand blobs to other hosts — quay.io → `*.quay.io`; ghcr.io →
`pkg-containers.githubusercontent.com`; Docker Hub → `registry-1.docker.io`,
`auth.docker.io`, `production.cloudflare.docker.com`; GitHub release downloads →
`objects.githubusercontent.com`, `release-assets.githubusercontent.com`. The helm-k3s
engine also needs `get.helm.sh`. `scripts/egress-rules.sh` lists these entries for the operator (the core's
`docs/black-box.md` → Egress rules): a host no kit rule covers lands through its approval
prompt, one under a kit deny (any `github.com` path) only by hand — keep those few. GitHub
is deny-by-default for every repository there, so an install that downloads from the
target repository's own releases cannot work — such builds must come from a registry; a
third-party release download needs an entry with its exact path. The kit already opens
cert-manager's `cert-manager.yaml` and Gateway API's `standard-install.yaml` release files,
and the `trusted` preset the hosts GitHub redirects downloads to — leave those out.

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
