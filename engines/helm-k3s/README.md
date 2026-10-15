# Engine `helm-k3s`

Runs a product that ships as a **Helm chart in an OCI registry** inside the inspector's VM:
k3s, the profile's prerequisites, then the chart at the build under test. A profile uses
it with `"engine": "helm-k3s"` and describes its product in `engine_config` — no scripts
of its own ([docs/profile-contract.md](../../docs/profile-contract.md) → Engines).

Needs a vm-backend agent (root), `k3s`, `curl`, `jq` and `node` in the image; installs
`helm` into `~/.local/bin`. k3s and helm run at the lowest CPU priority (`nice 19`, the
lowest best-effort I/O class), and so does everything they start — the product never
starves the agent's own runtime. `up` of the build already recorded in
`$QI_ENV_DIR/STATE.json`, with the same rendered values, returns as soon as the UI answers
(within 5 minutes — a restarted VM's cluster comes back from disk); anything else installs.

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
| `overlays` | `[{when: <config key>, values: {…}}]` — merged into `values` when that profile key is set; `when: "@model"` — while the agent lends its model |
| `max_pages` | quay pages to read at most (default 30) |

`bin/versions --between <from> <to>` (bisection) reads the same tag listing — tags only —
and returns the tags of the channel both builds match, in that channel's order.

## Prerequisites

| `kind` | Fields | Does |
| --- | --- | --- |
| `manifest` | `name`, `url` or `file` (a path inside the profile directory), `unless` (a `kind/name` that means "already there"), `wait` | `kubectl apply -f <url>`, or the file from `QI_PROFILE_DIR` |
| `helm` | `name`, `repo`, `chart`, `version`, `namespace`, `set` (`{key: value}`), `wait` | `helm install` once |
| `adopt-crds` | `name`, `crds`, `release`, `namespace` | stamps Helm ownership so a cluster-bundled release (e.g. k3s' `traefik-crd`) adopts CRDs installed out of band |

`wait`: `{namespace, deployments: true}` waits for every deployment to be Available;
`{namespace, rollout: "ds/<name>"}` for one rollout.

## Placeholders

In any string of `engine_config`: `{{config:<key>}}` — a profile config key;
`{{config_repo:<key>}}` / `{{config_tag:<key>}}` — the repository and tag of an image ref
held in that key. In `values` only: `{{user:<name>.username|password}}`,
`{{secret:<name>}}`, `{{app_port}}` — filled at `up` from `credentials.env`;
`{{model:key|kind|base_url}}` — the lent model ([docs/profile-contract.md](../../docs/profile-contract.md)
→ The `bin/` contract), empty when not lent; `{{proxy:https|http|no}}` — the gateway proxy
for pods that must reach the outside (the lent model's host), `no` with the cluster's own
ranges added; `{{gateway_ca}}` — the PEM of the CA the gateway presents (the file
`NODE_EXTRA_CA_CERTS` or `SSL_CERT_FILE` names), empty when neither does. The rendered
values (`$QI_ENV_DIR/values.json`) are mode 600 and never printed.

## Check

`bin/check` validates `engine_config` offline, for the profile checker: the keys above,
the channels and their defaults, the owner account, each prerequisite's fields (a manifest `file` must exist in the profile), `app_port`
against the profile's `app.url`, and every placeholder rendered with throw-away
credentials — once with the config defaults and no lent model, once with every overlay
switched on. An overlay's `when` must be a profile config key or `"@model"`; the second
render sets a throw-away `QI_MODEL_KEY`, so a `"@model"` overlay and its `{{model:*}}`
placeholders are rendered too.

## Diagnosis (read-only)

`k3s kubectl get pods -A`, `k3s kubectl -n <ns> describe pod <p>`, `k3s kubectl -n <ns>
logs <p>`, `helm -n <ns> status <release>`, `/var/log/k3s.log`.
