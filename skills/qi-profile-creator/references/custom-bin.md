# Own `bin/` scripts

For a product no engine runs. What each command must do, its environment and its exit
codes are the contract's (`docs/profile-contract.md` → The bin/ contract); this file is
how to write them well. Start from `templates/bin/*.template`: they implement the generic
parts and leave the product's part as `TODO(profile)`.

## Conventions

- `#!/usr/bin/env bash`, `set -u`, `export LC_ALL=C`; `curl`, `jq` and the runtime you
  use listed in `requires.commands`.
- Settings from `QI_PROFILE_CONFIG` (`jq -r '.<key> // empty'`), never from
  `work/CONFIG.md` directly. Product facts every instance shares stay in the script.
- State in `$QI_ENV_DIR` only (mode 700): `credentials.env`, a `STATE.json` with the
  installed build, logs. Files the profile ships beside its scripts (a compose file,
  manifests) are found through `$QI_PROFILE_DIR`.
- Scratch under `/tmp/quality-inspector-<purpose>`, removed before exit — the agent's
  runs must end with none left.
- Diagnostics to stderr, one line, saying what failed and what the operator can do
  ("pull failed — allow ghcr.io"). Never print a secret, not even in debug output.
- Every command idempotent; a failed `up` safe to run again.

## `bin/versions` and `bin/build-time`

- The template lists tags of one OCI repository over `/v2` with an anonymous token
  (ghcr.io, Docker Hub, quay.io, most registries) and sorts each channel by `semver` or
  `numeric-suffix`. Fill in the channel table and the repository.
- Builds come from where they are published — a registry, a package index — never from
  the target repository's GitHub API, which the agent's egress denies.
- `build-time` reads the image's `org.opencontainers.image.created` annotation or its
  config's `created`, through a multi-arch index when there is one, and prints it as
  ISO-8601 UTC. A build without a recorded time exits non-zero: never print "now".
- Both are read-only and called by the scheduled pre-flight inside a two-minute budget.
  `/v2` lists tags in name order, so the template reads every page: a repository with
  thousands of tags (one per commit) takes most of a minute on some registries. The
  checker warns above 30 seconds; then list through an API that returns newest first
  (quay.io's), or publish the QA builds to a repository of their own.

## `bin/env`

The template does `init`, `status` and the waiting; you write five functions:

| Function | Does |
| --- | --- |
| `product_start <build>` | Install or upgrade to exactly that build, the owner account from `credentials.env` included. |
| `product_ready` | Exit 0 once the UI answers at `app.url` (the template polls it; extend it when the UI answers before the product is usable). |
| `product_running` | Exit 0 when the product's processes or containers run. |
| `product_stop` | Stop it; data may stay. |
| `product_wipe` | Delete all product data so the next `up` starts with fresh users and no content. |

Patterns, by what the agent's image offers:

- **Images on k3s** (the usual QA image: root, `k3s`): `k3s kubectl apply` of manifests
  the profile ships, the image tag substituted with the build; data in a PVC that
  `product_wipe` deletes. A Helm chart is the `helm-k3s` engine's job — use it instead.
- **Compose** (an image with `docker` or `podman`): the profile ships the compose file;
  `docker compose -p qi -f "$QI_PROFILE_DIR/compose.yaml" up -d` with the build in an
  environment variable; `down -v` wipes.
- **A package or binary** (npm, pip, a release archive from a registry): install that
  version under `$QI_ENV_DIR/app`, start it with `nohup`, keep its PID file in
  `$QI_ENV_DIR`; data in a directory under `$QI_ENV_DIR` that `product_wipe` removes.

`up` may only move forward; the core always runs `reset` before installing an older
build. `status` must answer quickly and without side effects.

## Trying it out

The read-only commands: `scripts/check-profile.mjs --live`. The acting ones, only on a
machine like the agent's VM and only where the person says it is safe:

```bash
export QI_WORK="$(mktemp -d /tmp/quality-inspector-try.XXXXXX)" QI_ENV_DIR="$QI_WORK/env" \
  QI_PROFILE_DIR="$PWD/<profile-dir>" QI_PROFILE_CONFIG='<the resolved config as JSON>'
"$QI_PROFILE_DIR/bin/env" init && "$QI_PROFILE_DIR/bin/env" up <candidate> && "$QI_PROFILE_DIR/bin/env" status
"$QI_PROFILE_DIR/bin/env" up <candidate>      # again: must be a no-op
"$QI_PROFILE_DIR/bin/env" reset && "$QI_PROFILE_DIR/bin/env" up <baseline> && "$QI_PROFILE_DIR/bin/env" down
rm -rf "$QI_WORK"
```

Then sign in at `app.url` in a browser with the owner credentials from
`$QI_ENV_DIR/credentials.env` — the agent's sign-in setup test does the same.
