# Engine `helm-k3s`

Runs a product that ships as a **Helm chart in an OCI registry** inside the inspector's VM:
k3s, the profile's prerequisites, then the chart at the build under test. A profile uses
it with `"engine": "helm-k3s"` and describes its product in `engine_config` — no scripts
of its own ([docs/profile-contract.md](../../docs/profile-contract.md) → Engines).

Needs a vm-backend agent (root), `k3s`, `curl`, `jq` and `node` in the image; installs
`helm` into `~/.local/bin`.

## Configuration (`engine_config` in the profile's `profile.json`)

| Key | Meaning |
| --- | --- |
| `chart` | `oci://<host>/<repo>` of the chart |
| `registry_api` | `quay` (quay.io's API: push times, newest first — fast) or `oci` (any registry over `/v2`, every tag; publish time from the manifest's `org.opencontainers.image.created`) |
| `release`, `namespace` | the Helm release and its namespace |
| `app_port` | the port the product's UI answers on at `localhost` |
| `traefik_port` | `true` — expose `app_port` through k3s' bundled Traefik |
| `apply_chart_crds` | `true` — apply the chart's `crds/` before every upgrade (Helm never upgrades them) |
| `channels` | `{name: {tag: <regex>, order: semver \| numeric-suffix \| time}}` — what a build of each channel looks like and how they sort (`time` needs `registry_api: quay`) |
| `default_candidate`, `default_baseline` | channels used when the instance leaves its own empty; a baseline equal to the candidate channel means "the one before" |
| `helm_version` | the helm release to install |
| `credentials` | `users: {name: {username}}` — passwords are generated into `credentials.env` as `E2E_USER_<NAME>_*`; `secrets: [name]` — generated as `QI_SECRET_<NAME>` |
| `prerequisites` | ordered, installed once, never upgraded by `up` — see below |
| `values` | the Helm values, as JSON, with placeholders |
| `overlays` | `[{when: <config key>, values: {…}}]` — merged into `values` when that profile key is set |
| `max_pages` | quay pages to read at most (default 30) |

`bin/versions --between <from> <to>` (bisection) reads the same tag listing — tags only —
and returns the tags of the channel both builds match, in that channel's order.

## Prerequisites

| `kind` | Fields | Does |
| --- | --- | --- |
| `manifest` | `name`, `url`, `unless` (a `kind/name` that means "already there"), `wait` | `kubectl apply -f <url>` |
| `helm` | `name`, `repo`, `chart`, `version`, `namespace`, `set` (`{key: value}`), `wait` | `helm install` once |
| `adopt-crds` | `name`, `crds`, `release`, `namespace` | stamps Helm ownership so a cluster-bundled release (e.g. k3s' `traefik-crd`) adopts CRDs installed out of band |

`wait`: `{namespace, deployments: true}` waits for every deployment to be Available;
`{namespace, rollout: "ds/<name>"}` for one rollout.

## Placeholders

In any string of `engine_config`: `{{config:<key>}}` — a profile config key;
`{{config_repo:<key>}}` / `{{config_tag:<key>}}` — the repository and tag of an image ref
held in that key. In `values` only: `{{user:<name>.username|password}}`,
`{{secret:<name>}}`, `{{app_port}}` — filled at `up` from `credentials.env`; the rendered
values (`$QI_ENV_DIR/values.json`) are mode 600 and never printed.

## Diagnosis (read-only)

`k3s kubectl get pods -A`, `k3s kubectl -n <ns> describe pod <p>`, `k3s kubectl -n <ns>
logs <p>`, `helm -n <ns> status <release>`, `/var/log/k3s.log`.
