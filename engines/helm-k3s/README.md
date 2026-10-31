# Engine `helm-k3s`

Runs a product that ships as a **Helm chart in an OCI registry** on its node (the inspector's
VM, or a platform Environment that runs the product): k3s, the profile's prerequisites, then
the chart at the build under test. A profile uses
it with `"engine": "helm-k3s"` and describes its product in `engine_config` — no scripts
of its own ([docs/profile-contract.md](../../docs/profile-contract.md) → Engines).

Needs a vm-backend agent (root), `k3s`, `curl`, `jq` and `node` in the image; installs
`helm` into `~/.local/bin`. k3s and helm run at the lowest CPU priority (`nice 19`, the
lowest best-effort I/O class), and so does everything they start — the product never
starves the agent's own runtime. `up` of the build already recorded in
`$QI_ENV_DIR/STATE.json`, with the same rendered values, returns as soon as the UI answers
(within 5 minutes — a restarted VM's cluster comes back from disk); anything else installs.
`reset` uninstalls the release, deletes its volumes and removes every image no container
uses, so it is also the repair for a full disk. **Limit:** the prune also removes an image only
a short-lived pod uses (the local-path provisioner's helper, for one); the next such pod
pulls it again, so its registry must be reachable unless k3s keeps it pinned.

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
| `overlays` | `[{when: <config key>, values: {…}}]` — merged into `values` when that profile key is set; `when: "@model"` — while the agent lends its model; `when: "@sandbox:<id>"` — while every `E2E_SANDBOX_<ID>_*` line of `credentials.env` is filled; `when: "@environment"` — while the product runs in a platform Environment; `tags` (a regex) — only for a build whose tag matches it, the builds that understand the overlay's values |
| `max_pages` | quay pages to read at most (default 30) |
| `resolve_max_tags` | newest tags per channel `bin/versions --resolve` looks at (default 50) |
| `prune_below_gi` | after an `up`, the images no container uses (earlier builds') are removed while the k3s data volume has less free than this, in Gi (default 20); `reset` always removes them |
| `kvm` | `true` — the product's pods open `/dev/kvm` from a user namespace (a VM runner) — see below |
| `host_dirs` | absolute node directories the chart hands such pods as `hostPath` volumes — see below |
| `environment_bridge` | `{image, port}` — the host-name bridge of an install in a platform Environment — see below |

`bin/versions --between <from> <to>` (bisection) reads the same tag listing — tags only —
and returns the tags of the channel both builds match, in that channel's order.

`bin/versions --resolve <build>` maps a build id the product itself reports (its usage data,
[docs/ux-signals.md](../../docs/ux-signals.md)) to a chart tag: the tag itself when it is one (a
release `1.4.0`), else the newest tag of a channel, the candidate channel first, whose chart's
`appVersion` equals it (a main build `0.2.25-dev-1a2b3c4d5e6f` → `0.0.0-main.312`). It reads
`appVersion` from each tag's manifest and config blob — the Chart.yaml Helm stores there — over
the registry's `/v2`, the requests `helm pull` makes for an install, so it needs no egress of its
own; at most `resolve_max_tags` tags per channel, each read once (`$QI_ENV_DIR/app-versions.json`).
No match → exit 1, never a near build; a listing or a chart's metadata it could not read → exit 3.

## Prerequisites

| `kind` | Fields | Does |
| --- | --- | --- |
| `manifest` | `name`, `url` or `file` (a path inside the profile directory), `unless` (a `kind/name` that means "already there"), `wait` | `kubectl apply -f <url>`, or the file from `QI_PROFILE_DIR` |
| `helm` | `name`, `repo`, `chart`, `version`, `namespace`, `set` (`{key: value}`), `wait` | `helm install` once |
| `adopt-crds` | `name`, `crds`, `release`, `namespace` | stamps Helm ownership so a cluster-bundled release (e.g. k3s' `traefik-crd`) adopts CRDs installed out of band |

The kit already opens cert-manager's `cert-manager.yaml` and Gateway API's `standard-install.yaml`
release files on `github.com` (any `v*` tag), so a `manifest` from either needs no `egress` entry;
any other `url` does.

`wait`: `{namespace, deployments: true}` waits for every deployment to be Available;
`{namespace, rollout: "ds/<name>"}` for one rollout.

## KVM

The device comes from the platform that hosts the node (nested virtualization), never from
the engine; the profile ships the cluster's device plugin as a `manifest` prerequisite and
names its resource in `values`. The node is this VM or the platform Environment that runs the
product. An Environment gets the device on the same terms as this VM: with `kvm: true`, `env.sh up`
uses an Environment only when this VM has `/dev/kvm` and the Environment has it too; else the
product stays in this VM under `nested_target: auto`, and `up` fails under `environment`
([docs/nested-env.md](../../docs/nested-env.md) → **Where the product runs**). With `kvm: true`, `up`:

- opens `/dev/kvm` to all (`0666`) every time: in a user namespace the device keeps its
  host owner unmapped, so a `0660 root:kvm` device opens for nobody. No `/dev/kvm` is a
  warning, not a failure: the product installs, its VMs do not start, and `status` says
  `"kvm": false` (`true` when the device is there; absent without `kvm`).
- moves the kubelet's root to `~/.local/share/kubelet` when `/var/lib/kubelet` is on an
  overlay (an agent VM's root is one): runc cannot idmap a volume whose source is on an overlay,
  so a user-namespace pod's emptyDirs fail to mount. A drop-in in
  `/etc/rancher/k3s/config.yaml.d/` does it; a k3s already running on the old root is
  stopped once (with its pods' shims, mounts and iptables rules) and started again.

Each `host_dirs` entry on an overlay, and not yet a mount point, gets
`~/.local/share/host<path>` bind-mounted over it at every `up` (a bind mount does not
outlive a boot of the node) — `<path>` the whole path with `-` doubled and `/` made `-`
(`/var/lib/vm-images` → `host-var-lib-vm--images`), so no two entries share a source; what
it held before is copied over first, and a pod that started on the overlay directory is
deleted, so its controller starts it again on the mount. `bin/check` refuses an entry listed
twice, and one that is or lies under a directory the system or the engine owns (`/`, `/var`,
`/var/lib`, `/etc`, `/usr`, `/home`, `/root`, `/dev`, `/run`, `/tmp`, `/var/lib/rancher`,
`/var/lib/kubelet`, `/var/lib/cni`, …).

k3s listens on its config's port, unless its data dir holds a cluster made on another port
(its stored kubeconfigs name it): then on that one, as k3s exits when they disagree.

## Environment

In a platform Environment ([docs/nested-env.md](../../docs/nested-env.md) → Where the product
runs) `bin/env` runs there over the Environment Link with `QI_NESTED_TARGET=environment` and
`QI_ENV_ENDPOINTS` (`{endpoint: url}`, the addresses the profile's `environment.endpoints`
got). The same engine installs the same chart; on top:

- the `"@environment"` overlay applies, where `{{env_url:<endpoint>}}` (no trailing `/`) and
  `{{env_scheme}}` give the product its public addresses;
- Traefik's `app` entrypoint trusts forwarded headers (`forwardedHeaders.insecure`): only the
  Environment's loopback reaches it, through the gate and the bridge;
- with `environment_bridge: {image, port}`, an Envoy on the node's network listens on
  `port` — every endpoint's port in `environment.endpoints` — and passes each request to
  `app_port` with its host set from `X-Forwarded-Host` and the public scheme and port named,
  as the gate relays with `Host: 127.0.0.1:<port>` while the ingress routes by host name.
  `port` differs from `app_port`, which stays the one the agent's forward reaches.

## Placeholders

In any string of `engine_config`: `{{config:<key>}}` — a profile config key;
`{{config_repo:<key>}}` / `{{config_tag:<key>}}` — the repository and tag of an image ref
held in that key. In `values` only: `{{user:<name>.username|password}}`,
`{{secret:<name>}}`, `{{sandbox:<id>.<NAME>}}` (a sandbox account's `E2E_SANDBOX_<ID>_<NAME>`,
[docs/profile-contract.md](../../docs/profile-contract.md) → `sandbox`), `{{app_port}}` — filled at `up` from `credentials.env`;
`{{model:key|kind|base_url}}` — the lent model ([docs/profile-contract.md](../../docs/profile-contract.md)
→ The `bin/` contract), empty when not lent; `{{proxy:https|http|no}}` — the gateway proxy
for pods that must reach the outside (the lent model's host), `no` with the cluster's own
ranges added; `{{gateway_ca}}` — the PEM of the CA the gateway presents (the file
`NODE_EXTRA_CA_CERTS` or `SSL_CERT_FILE` names), empty when neither does; `{{env_url:<endpoint>}}`, `{{env_scheme}}` — see **Environment**; `{{gateway_ip}}` — the
gateway's IPv4 address, which the VM's DNS gives for every public name, for a product whose
own egress policy must name it (a nested platform's gateways); rendering fails when it does not
resolve. The rendered
values (`$QI_ENV_DIR/values.json`) are mode 600 and never printed.

## Check

`bin/check` validates `engine_config` offline, for the profile checker: the keys above,
the channels and their defaults, the owner account, each prerequisite's fields (a manifest `file` must exist in the profile), `app_port`
against the profile's `app.url`, and every placeholder rendered with throw-away
credentials — once with the config defaults and no lent model, once with every overlay
switched on. An overlay's `when` must be a profile config key, `"@model"`, `"@environment"`
or `"@sandbox:<id>"`; the second render sets a throw-away `QI_MODEL_KEY` and sandbox
credentials and runs as in an Environment (each of the profile's `environment.endpoints` at a
throw-away address), so those overlays and their `{{model:*}}`, `{{sandbox:*}}` and
`{{env_url:*}}` placeholders are rendered too. `environment_bridge` needs an image and a port
other than `app_port`, the port of every `environment.endpoints` entry.

## Diagnosis (read-only)

`k3s kubectl get pods -A`, `k3s kubectl -n <ns> describe pod <p>`, `k3s kubectl -n <ns>
logs <p>`, `helm -n <ns> status <release>`, `/var/log/k3s.log` — in a platform Environment
each as `ssh env-<name> '<command>'`, and `k3s kubectl …` as `ssh env-<name> bash qi/kubectl.sh …`
(a plain ssh shell there can miss `k3s` on its PATH).
