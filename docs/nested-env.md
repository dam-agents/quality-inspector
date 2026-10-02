# The nested platform

The system under test runs inside this agent's own VM: k3s, its prerequisites, and the
published chart at the version under test. Everything is driven by
`scripts/env.sh` (usage in its header); this file is the why and the recovery path.

## Shape

- **vm backend only.** The agent runs as root in a microVM, so it can start k3s
  (`k3s server`, state under the home volume — it survives restarts, processes do not).
  A container-backend agent cannot host it; `verify-onboarding.sh --live` fails there.
- **Prerequisites** — cert-manager, the Gateway API CRDs, Istio ambient (base, istiod,
  cni, ztunnel) — install once, at the pinned config versions, and are never upgraded by
  `env.sh up`. Changing a version key means `env.sh down`, deleting the k3s state
  (operator decision), and a fresh `up`.
- **The chart** is pulled at the exact version, its `crds/` applied server-side first,
  then `helm upgrade --install` with `work/env/values.yaml` (seeded by `env.sh init`:
  `localhost:4444`, a QA terms text, a generated Keycloak admin and test-user password in
  `work/env/credentials.env`). That values file is the chart's documented operator
  interface; edit it only from `helm show values <chart_ref> --version <v>`.
- **Mock harness.** With `mock_image` set, `up` adds a `mock` harness template so tests
  can create agents that answer without a model. Without it, nested agents cannot run.
- **One user of the environment at a time** — `env.sh lock <owner>` / `unlock`; the
  pre-flight treats a live lock as an idle occurrence.

## Tools

kubectl and k3s come with the image; helm does not, so `env.sh up` installs
`helm_version` into `~/.local/bin` on first use. Use `k3s kubectl` and that helm for
diagnosis — read-only commands (`get`, `describe`, `logs`) are fine at any time.

## Network

The VM reaches the outside only through the paired gateway. `env.sh` passes the agent's
`HTTPS_PROXY` to k3s's containerd and exempts the cluster ranges, so images pull from the
registry through the gateway; pods inside the nested cluster have **no** direct egress,
which is why nested agents need the mock harness. The hosts this needs are listed in
README → Black-box boundary.

## Switching versions

Upgrades go forward only. To run an older chart (the baseline) after a newer one, always
`env.sh reset` first — a downgrade over a newer database is undefined. The red-green order
in [issue-qa.md](issue-qa.md) step 6 is built around that.

## Failures

An `env.sh` exit 1 or a failing smoke run is an **environment failure**, never a
verdict. Before giving up on the entry:

1. `bash "$HOME/scripts/env.sh" status`, then `k3s kubectl get pods -A | grep -v Running`.
2. One repair attempt that the evidence supports: a crash-looping pod's logs, a pending
   pod's events, `env.sh reset` + `up` for a release stuck mid-upgrade.
3. Still failing → abort the entry ([issue-qa.md](issue-qa.md) step 4) with the
   evidence in the log. A cause you reproduced goes to `work/LESSONS.md` with its
   evidence; a definition bug is the audit's to file.

Never "fix" the product inside the nested cluster (patching deployments, editing its
database) to make a test pass — that tests your patch, not the build.
