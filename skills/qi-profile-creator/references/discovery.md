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
| 7 | Further accounts, by the contract's role names: `member`, `viewer` (only a truly read-only user), `outsider` (The owner account, below); whether the product must change to create them | more `credentials.users` / `E2E_USER_<ROLE>_*` |
| 8 | First-run screens (terms, a setup wizard, a tour) and how to skip them | values, or a `SKILL.md` note |
| 9 | Where product data lives — what `reset` must wipe | the engine (release + PVCs), or `bin/env reset` |
| 10 | Every outside service the product calls, and whether a stand-in exists (a model provider: a mock, or the agent's lent model) | `SKILL.md` → cannot do; a `config` key with a working default; `expected_requests` for a request the UI still sends and the install answers with an error (method, path pattern, status) |
| 11 | Every host `up` and `versions` download from | `egress` |
| 12 | Extra surfaces that would expose the implementation; the product's npm scopes or package names | `boundary`, `boundary.packages` |
| 13 | Root, commands, memory a fresh install with two builds' images needs | `requires` |
| 14 | Settings an operator may change, and which have no safe default | `config` (`ask`) |
| 15 | Main UI areas and the terms users see | `SKILL.md` |
| 16 | A published CLI or API (the command, the path of its OpenAPI JSON), its npm package, and how a user gets a token for it | `interfaces`, `boundary.packages`, `SKILL.md` → CLI and API |
| 17 | The main object a user creates, with a name and a description (a project, a document), and where in the UI; the namespace its pods run in when no engine names one | `security.entity`, `security.namespace`, `canary.thing` — one a user creates in one step, with nothing set up first (`canary.field` when the text shows in another field, `canary.none` when there is no such object) |
| 18 | API calls the security run cannot make through the UI: create that object, mint and use an API key | `suite/lib/security-api.ts` (its exports: the core's `docs/security.md`) |
| 19 | Main flows that leave the product (it answers in Slack, files a GitHub issue) and the throwaway accounts that would make them testable: what the product's connection asks for, the hosts, methods and paths, what the test person does there, how the product treats posts from apps and bots | `sandbox`, `sandbox/<name>.md`, `bin/sandbox`, `suite/` helpers, `ask` config keys, `egress` (Sandbox accounts, below) |

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

- **`viewer` only for a read-only user.** The security run replays every write as
  `viewer` and reports each success as a finding. A product without a read-only user gets
  no `viewer`; an account that fits no contract role keeps a name of its own
  (`E2E_USER_<NAME>_*`), and `SKILL.md` says what it may do.
- **The mechanism may need a product change** — the install creates one user, not a list.
  That change lands in the product first (a list value beside the single one, empty by
  default, so other installs do not change), and builds before it have only the owner:
  `SKILL.md` says criteria that need another account are `blocked` on such a build, the
  baseline included until a release carries it.
- Each account's unique fields (an e-mail derived from the name) must not collide with
  the owner's or each other's — an identity provider refuses the whole import otherwise.

## Outside services

The nested product reaches only the hosts in its `egress` list, and those exist to
install it — treat every runtime call to an outside service as unavailable: model
providers, email delivery, payment, third-party OAuth, webhooks to the internet, maps.
For each, either a stand-in exists (a mock image, a bundled mail catcher, bundled object
storage) — then it is a `config` key or a literal in the install, and `SKILL.md` says how
a user observes it — or `SKILL.md` makes the ACs that need it `testable: no — external
dependency`.

- **Default the stand-in, don't ask for it.** A stand-in the main flows need (a mock model
  for a product whose agents otherwise never answer) is on by default with a working
  value; an empty, asked default leaves most criteria `blocked` until someone answers. An
  image without release tags is pinned to a digest or a source revision, and the README
  says how to move the pin when the product needs a newer one.
- **A model provider** can also be the agent's own connection, lent per instance
  (`lend_model`, `docs/profile-contract.md` → The bin/ contract: `QI_MODEL_*`); the mock
  stays the default, and `SKILL.md` says which criteria only a lent model makes testable.

## Sandbox accounts

Some outside services are the point of a main flow — an agent that answers in Slack, files
a GitHub issue. A stand-in cannot show those; a throwaway account can. Ask the person
whether the flow should be testable end to end; if so, per service (the core's
`docs/profile-contract.md` → `sandbox`):

- **What the product's connection asks for** — read its configuration reference: a GitHub
  App, a token or an OAuth sign-in, a Slack bot token and Socket Mode or a webhook. A
  webhook into the nested product cannot work (it is on `localhost`), so a service it needs
  inbound is testable only through an outbound mode (Socket Mode, polling); otherwise it
  stays `testable: no`. Prefer the connection a user really makes when the flow under test
  is that connection (a "Connect with GitHub" sign-in); a token the install imports is
  enough when the flow only uses it.
- **The guide** — `sandbox/<name>.md`, the operator's steps in order: create the
  organization or workspace (never the product's own, never a company one), the narrowest
  app or token, where each value is shown, which line of `credentials.env` it fills. A
  manifest to paste beats a list of scopes. The operator does it once; write it for someone
  who has never seen the service's developer pages.
- **Credentials** — the names in `credentials` (they become `E2E_SANDBOX_<ID>_<NAME>`);
  a key file as one base64 line named `…_B64`. Names that are no secret (an organization
  and repository) are `ask` config keys, so the egress can name them as `{profile.<key>}`.
- **Egress** — each request the product and the test person make, by method and path. On a
  GitHub host only the core's closed set passes (its `docs/black-box.md` → Sandbox
  accounts): a sandbox repository's API paths `/repos/{profile.<key>}/<rest>`, git's four
  smart-HTTP requests to it, and the OAuth sign-in's exact requests on the web host, each
  with its own method. Copy those rows from there; anything else there is `refused`, a
  GitHub App's `/app/…` and `/installation/…` endpoints included — prefer a fine-grained
  token scoped to the sandbox repository (`GET /user` the kit already allows). Every GitHub
  row the kit does not already allow lands by hand; the hosts a third-party page loads its scripts and styles from (the
  sign-in pages' `github.githubassets.com`, `GET /assets/*`) land by prompt.
- **A GitHub sign-in** — a sandbox user of its own (login, password and a TOTP secret as
  credentials; no passkey, no e-mail device check), and an OAuth App registered in the
  sandbox organization, its callback on the nested product's `localhost` URL. The product
  gets the App's client through the install (an overlay value), so a test never types a
  sandbox value. A `suite/` helper drives the pages and computes the TOTP code (RFC 6238 —
  check it against the RFC's test vectors).
- **Chat services** — the test person posts through an app or user of its own, never the
  product's: the product ignores its own app's messages, so nothing would answer. Find out
  how the product treats posts from apps and bots — loop guards that drop a run of bot
  posts in one conversation, rate limits — and shape the helpers around it (one thread per
  request; replies read without the test person's own posts).
- **Install-time values** — a service the product configures per install (a Slack app's
  tokens in its Helm values) takes them in the engine's values as
  `{{sandbox:<id>.<NAME>}}`, inside an overlay `when: "@sandbox:<id>"`, so an instance
  without the account installs as before (helm-k3s README → Placeholders). The overlay is
  on only while every credential of the account is filled.
- **The nested product's own way out** — it reaches the sandbox through the VM's gateway,
  which may terminate TLS: the product trusts the gateway's CA (`{{gateway_ca}}`), and a
  product with an egress policy of its own names the gateway's address (`{{gateway_ip}}`)
  — helm-k3s README → Placeholders.
- **`bin/sandbox check`** — one request per credential: who the token is, that the channel
  or repository exists and is no fork, that a client is valid (an OAuth code exchange with
  a made-up code answers `bad_verification_code` only for a valid client); `ok`/`FAIL`
  lines, never a value.
- **The test person** — helpers in `suite/` (`personSays`, `repliesTo`): the only way a test
  writes to or reads from the service. A result the agent leaves on GitHub is checked
  through what the product shows, never by reading GitHub. Labels and button names on a
  third-party page are assumptions until a live run: a helper waits for each with a
  timeout that names what it missed, so a changed page fails visibly. A test removes its
  leftovers only after its last criterion passes, so the helpers also remove older runs'
  leftovers by their `unique()` id (the core's `docs/test-authoring.md` → Clean up only
  after a pass).

## Egress

Every host the install and the build listing contact, with `method` (`GET` unless more is
needed), a `path` where the host is shared, and a `why`. Registries hand blobs to other
hosts — quay.io → `*.quay.io`; Docker Hub → `registry-1.docker.io`, `auth.docker.io`,
`production.cloudflare.docker.com`; a mirror that serves layers from its own host
(`mirror.gcr.io` for Docker Hub images) needs one rule. ghcr.io hands its blobs to
`pkg-containers.githubusercontent.com`, a GitHub host a profile cannot name: publish the
QA builds to another registry or a mirror, or propose that host for the core's kit (a
separate change there). The helm-k3s engine also needs
`get.helm.sh`. A page a browser renders in a sandbox flow loads assets from further hosts.

- **How each lands.** The checker classifies every rule through the core's
  `scripts/egress-rules.sh` (Phase 4); the full table, as the operator will get it:

  ```bash
  w="$(mktemp -d)"; printf -- '- profile.<key>: <sample value>\n' > "$w/CONFIG.md"
  WORK_DIR="$w" QI_PROFILE_DIR="$PWD/<profile-dir>" bash "$QI_CORE/scripts/egress-rules.sh"; rm -rf "$w"
  ```

  A host no kit rule covers lands through its approval prompt. A request under a kit deny
  is refused at once and no prompt ever appears — also where a kit allow covers it but a
  longer kit deny beside it wins — so the operator adds it by hand; keep those few.
- **No GitHub downloads.** On `github.com`, `*.github.com` and `*.githubusercontent.com` a
  profile rule outside the sandbox shapes is `refused`, a third-party release download
  included. Take such a file from a registry or a mirror; a generic cluster prerequisite
  many products need may join the core's kit instead (a separate change there — the kit
  already opens cert-manager's `cert-manager.yaml` and Gateway API's
  `standard-install.yaml`). Builds never come from the target repository's releases.
- **Host-wide where the gateway must not look inside.** A rule with a path or a method
  makes the VM's gateway terminate the TLS to read the request. A long-lived websocket (a
  chat service's socket mode) or a client that does not trust the gateway's CA breaks then:
  give such a host `"method": "*"` and no path, and say so in its `why`.
- **Least privilege.** A host the nested product needs is the profile's, never a platform
  preset's or the kit's, however harmless it looks.

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
