#!/usr/bin/env bash
# env.sh — the nested platform inside this agent's VM: k3s, its prerequisites and
# the published chart. Acts only on the local nested cluster, never on an external
# system; the agent calls it, the pre-flight never does. Procedure and rationale:
# docs/nested-env.md.
#
#   env.sh init                 seed work/env/ (values, test credentials) when missing
#   env.sh lock <owner>         take the environment lock (exit 1 when a live holder has it)
#   env.sh unlock <owner>       release it (only the holder's own lock)
#   env.sh up <chart-version>   start k3s, ensure prerequisites, install/upgrade the chart, wait
#   env.sh reset                uninstall the release and delete its volumes (data wipe)
#   env.sh status               one JSON object: k3s, release version, UI reachability, lock
#   env.sh down                 stop k3s (state stays under the home volume)
#
# Every step is idempotent; a failed `up` is safe to re-run.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
ENVD="$WORK/env"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi
export LOG_JOB="${LOG_JOB:-env}"

CHART_REF="$(cfg chart_ref)"; CHART_REF="${CHART_REF:-oci://quay.io/dam-agents/charts/platform}"
ISTIO_VERSION="$(cfg istio_version)"; ISTIO_VERSION="${ISTIO_VERSION:-1.29.1}"
CERT_MANAGER_VERSION="$(cfg cert_manager_version)"; CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.2}"
GATEWAY_API_VERSION="$(cfg gateway_api_version)"; GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.2.0}"
HELM_VERSION="$(cfg helm_version)"; HELM_VERSION="${HELM_VERSION:-v3.19.0}"
MOCK_IMAGE="$(cfg mock_image)"
LOCK_TTL_MIN="$(cfg lock_ttl_min)"; LOCK_TTL_MIN="${LOCK_TTL_MIN:-180}"
APP_PORT=4444
RELEASE=platform
NS=default
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

die() { echo "env: $*" >&2; logev error env_failed "$*"; exit 1; }
say() { echo "env: $*" >&2; }
kc() { k3s kubectl "$@"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
iso2epoch() { date -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }
rand() { head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-24; }

# ------------------------------------------------------------------- init ----
cmd_init() {
  mkdir -p "$ENVD" && chmod 700 "$ENVD"
  if [ ! -f "$ENVD/credentials.env" ]; then
    ( umask 077; cat > "$ENVD/credentials.env" <<EOF
E2E_USER_OWNER_USERNAME=qa-owner
E2E_USER_OWNER_PASSWORD=$(rand)
NESTED_KEYCLOAK_ADMIN_PASSWORD=$(rand)
EOF
    )
    say "seeded work/env/credentials.env"
  fi
  if [ ! -f "$ENVD/values.yaml" ]; then
    # shellcheck disable=SC1091
    . "$ENVD/credentials.env"
    ( umask 077; cat > "$ENVD/values.yaml" <<EOF
# Nested QA install — operator-tunable. Secrets come from credentials.env; regenerate
# both together (delete both files, run env.sh init) and the next 'up' applies them.
domain: localhost
port: "$APP_PORT"
scheme: http
ingress:
  catchAllAppHost: true
terms:
  version: qa
  text: "Nested QA environment."
nfsProvisioner:
  enabled: true
keycloak:
  admin:
    password: "$NESTED_KEYCLOAK_ADMIN_PASSWORD"
  testUser:
    enabled: true
    username: "$E2E_USER_OWNER_USERNAME"
    password: "$E2E_USER_OWNER_PASSWORD"
EOF
    )
    say "seeded work/env/values.yaml"
  fi
}

# ------------------------------------------------------------------- lock ----
cmd_lock() {
  local owner="${1:?owner}" held ts
  mkdir -p "$ENVD"
  if [ -f "$ENVD/LOCK" ]; then
    read -r held ts < "$ENVD/LOCK"
    if [ "$held" != "$owner" ] && [ $(( ($(date -u +%s) - $(iso2epoch "$ts")) / 60 )) -lt "$LOCK_TTL_MIN" ]; then
      echo "env: locked by $held since $ts" >&2; exit 1
    fi
    [ "$held" != "$owner" ] && logev warn env_lock_takeover "stale environment lock of $held ($ts) taken over by $owner"
  fi
  printf '%s %s\n' "$owner" "$(now)" > "$ENVD/LOCK.tmp" && mv -f "$ENVD/LOCK.tmp" "$ENVD/LOCK"
}
cmd_unlock() {
  local owner="${1:?owner}" held ts
  [ -f "$ENVD/LOCK" ] || return 0
  read -r held ts < "$ENVD/LOCK"
  [ "$held" = "$owner" ] && rm -f "$ENVD/LOCK"
  return 0
}

# --------------------------------------------------------------------- up ----
# The agent image bakes kubectl and k3s but not helm; a pinned release goes into the
# home, which survives restarts (docs/nested-env.md → Tools).
ensure_helm() {
  local bin="$HOME_DIR/.local/bin" arch tmp
  export PATH="$bin:$PATH"
  [ "$(helm version --short 2>/dev/null | cut -d+ -f1)" = "$HELM_VERSION" ] && return 0
  case "$(uname -m)" in (x86_64) arch=amd64;; (aarch64|arm64) arch=arm64;; (*) die "unsupported arch $(uname -m)";; esac
  tmp="/tmp/quality-inspector-helm"; rm -rf "$tmp"; mkdir -p "$tmp" "$bin"
  curl -fsSL --max-time 120 "https://get.helm.sh/helm-$HELM_VERSION-linux-$arch.tar.gz" | tar -xz -C "$tmp" \
    || { rm -rf "$tmp"; die "helm $HELM_VERSION download failed (allow get.helm.sh)"; }
  mv -f "$tmp/linux-$arch/helm" "$bin/helm" && chmod 755 "$bin/helm"; rm -rf "$tmp"
  say "installed helm $HELM_VERSION into $bin"
}

k3s_running() { kc get --raw=/readyz >/dev/null 2>&1; }

start_k3s() {
  k3s_running && return 0
  # The VM reaches the outside only through the paired gateway, so containerd and
  # helm need the same proxy the agent uses; cluster-internal ranges bypass it.
  local np="${NO_PROXY:-${no_proxy:-}}"
  np="${np:+$np,}localhost,127.0.0.1,::1,10.42.0.0/16,10.43.0.0/16,.svc,.cluster.local"
  export NO_PROXY="$np" no_proxy="$np"
  [ -n "${HTTPS_PROXY:-${https_proxy:-}}" ] && export CONTAINERD_HTTPS_PROXY="${HTTPS_PROXY:-$https_proxy}" CONTAINERD_NO_PROXY="$np"
  [ -n "${HTTP_PROXY:-${http_proxy:-}}" ] && export CONTAINERD_HTTP_PROXY="${HTTP_PROXY:-$http_proxy}"
  say "starting k3s"
  (umask 022; k3s server >/var/log/k3s.log 2>&1 &)
  local i; for i in $(seq 1 60); do k3s_running && break; sleep 5; done
  k3s_running || die "k3s did not become ready in 5 minutes (see /var/log/k3s.log)"
  kc wait --for=condition=Ready node --all --timeout=180s >/dev/null || die "node not Ready"
}

ensure_prereqs() {
  kc apply -f - >/dev/null <<YAML || die "traefik port config failed"
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |
    ports:
      platform:
        port: $APP_PORT
        expose:
          default: true
        exposedPort: $APP_PORT
        protocol: TCP
YAML
  if ! kc get ns cert-manager >/dev/null 2>&1; then
    say "installing cert-manager $CERT_MANAGER_VERSION"
    kc apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml" >/dev/null \
      || die "cert-manager manifest apply failed"
  fi
  kc -n cert-manager wait --for=condition=Available deployment --all --timeout=300s >/dev/null || die "cert-manager not ready"
  if ! kc get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
    say "installing Gateway API CRDs $GATEWAY_API_VERSION"
    kc apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" >/dev/null \
      || die "Gateway API CRDs apply failed"
  fi
  # k3s's bundled Traefik adopts the Gateway API CRDs only when they carry its Helm ownership.
  local crd
  for crd in gatewayclasses gateways grpcroutes httproutes referencegrants; do
    kc label crd "$crd.gateway.networking.k8s.io" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null 2>&1 || true
    kc annotate crd "$crd.gateway.networking.k8s.io" meta.helm.sh/release-name=traefik-crd meta.helm.sh/release-namespace=kube-system --overwrite >/dev/null 2>&1 || true
  done
  helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
  helm repo update istio >/dev/null 2>&1 || die "istio chart repo unreachable"
  istio_release base istio/base
  istio_release istiod istio/istiod --set profile=ambient --set pilot.env.DEFAULT_WORKLOAD_CERT_TTL=720h
  istio_release istio-cni istio/cni --set profile=ambient \
    --set cni.cniBinDir=/var/lib/rancher/k3s/data/cni --set cni.cniConfDir=/var/lib/rancher/k3s/agent/etc/cni/net.d
  istio_release ztunnel istio/ztunnel
  kc -n istio-system rollout status ds/ztunnel --timeout=300s >/dev/null || die "ztunnel not ready"
}

istio_release() { # <release> <chart> [args] — install-only; upgrades are out of band
  local name="$1" chart="$2"; shift 2
  helm -n istio-system status "istio-$name" >/dev/null 2>&1 && return 0
  say "installing $chart $ISTIO_VERSION"
  helm install "istio-$name" "$chart" -n istio-system --create-namespace --version "$ISTIO_VERSION" --wait --timeout 10m "$@" >/dev/null \
    || die "helm install $chart failed"
}

cmd_up() {
  local version="${1:?chart version}" tmp extra=()
  [ -f "$ENVD/values.yaml" ] || cmd_init
  ensure_helm
  start_k3s
  ensure_prereqs
  tmp="/tmp/quality-inspector-chart-$version"; rm -rf "$tmp"; mkdir -p "$tmp"
  helm pull "$CHART_REF" --version "$version" --untar --untardir "$tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; die "helm pull $version failed"; }
  # Helm never upgrades a chart's crds/ on an existing release — apply them first.
  if [ -d "$tmp/platform/crds" ]; then
    kc apply --server-side --force-conflicts -f "$tmp/platform/crds/" >/dev/null || { rm -rf "$tmp"; die "CRD apply failed"; }
  fi
  if [ -n "$MOCK_IMAGE" ]; then
    printf 'harnessTemplates:\n  mock:\n    enabled: true\n    description: "Scripted mock agent (QA)"\n    image:\n      repository: "%s"\n      tag: "%s"\n' \
      "${MOCK_IMAGE%:*}" "${MOCK_IMAGE##*:}" > "$tmp/values-mock.yaml"
    extra=(-f "$tmp/values-mock.yaml")
  fi
  say "installing chart $version"
  helm upgrade --install "$RELEASE" "$tmp/platform" -n "$NS" -f "$ENVD/values.yaml" ${extra[@]+"${extra[@]}"} \
      --timeout 20m --wait >/dev/null 2>"$tmp/helm.err" \
    || { local e; e="$(tail -5 "$tmp/helm.err")"; rm -rf "$tmp"; die "helm upgrade to $version failed: $e"; }
  rm -rf "$tmp"
  kc -n "$NS" wait --for=condition=Available deployment --all --timeout=600s >/dev/null || die "platform deployments not Available"
  local i code; for i in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 10 "http://localhost:$APP_PORT/" 2>/dev/null)"
    case "$code" in (2??|3??) break;; esac; sleep 10
  done
  case "$code" in (2??|3??) ;; (*) die "UI not reachable on localhost:$APP_PORT (last HTTP $code)";; esac
  printf '{"version":"%s","installed_utc":"%s"}\n' "$version" "$(now)" > "$ENVD/STATE.json"
  logev info env_up "nested platform at chart $version"
  say "nested platform $version is up on http://localhost:$APP_PORT"
}

cmd_reset() {
  k3s_running || die "k3s is not running"
  ensure_helm
  helm -n "$NS" uninstall "$RELEASE" --wait --timeout 10m >/dev/null 2>&1 || true
  kc -n "$NS" delete pvc --all --wait=true --timeout=300s >/dev/null 2>&1 || true
  rm -f "$ENVD/STATE.json"
  logev info env_reset "nested platform release removed with its volumes"
}

cmd_status() {
  local running=false ver="" ui=000 lock=""
  k3s_running && running=true
  [ -f "$ENVD/STATE.json" ] && ver="$(jq -r .version "$ENVD/STATE.json" 2>/dev/null)"
  [ "$running" = true ] && ui="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 10 "http://localhost:$APP_PORT/" 2>/dev/null)"
  [ -f "$ENVD/LOCK" ] && lock="$(cat "$ENVD/LOCK")"
  jq -nc --argjson r "$running" --arg v "$ver" --arg u "$ui" --arg l "$lock" \
    '{k3s_running:$r, version:(if $v=="" then null else $v end), ui_http:$u, lock:(if $l=="" then null else $l end)}'
}

cmd_down() { pkill -f 'k3s server' 2>/dev/null || true; logev info env_down "k3s stopped"; }

case "${1:-}" in
  init)   cmd_init ;;
  lock)   cmd_lock "${2:-}" ;;
  unlock) cmd_unlock "${2:-}" ;;
  up)     cmd_up "${2:-}" ;;
  reset)  cmd_reset ;;
  status) cmd_status ;;
  down)   cmd_down ;;
  *) echo "usage: $0 init|lock <owner>|unlock <owner>|up <chart-version>|reset|status|down" >&2; exit 2 ;;
esac
