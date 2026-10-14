#!/usr/bin/env bash
# common.sh — the engine's resolved configuration, shared by every bin/ command.
# QI_ENGINE_CONFIG is the profile's engine_config; placeholders resolved once here.
ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine_config() {
  [ -n "${QI_ENGINE_CONFIG:-}" ] || { echo "helm-k3s: QI_ENGINE_CONFIG is empty (profile.json engine_config)" >&2; return 1; }
  printf '%s' "$QI_ENGINE_CONFIG" | node "$ENGINE_DIR/lib/render.mjs" config
}

# low <cmd…>: the nested product runs below the agent itself, and everything the command
# starts — k3s, containerd, every pod — inherits that. WORKAROUND for the platform runner,
# which restarts a guest whose agent runtime misses its 2 s health probe for 45 s: an
# install that keeps every vCPU busy can starve the runtime (seen on a sibling DAM agent).
# The real fix is CPU reserved for the runtime by the runner; delete this then. Idle CPU
# still goes to the product, so an uncontended install is as fast as before.
low() {
  if command -v ionice >/dev/null 2>&1; then nice -n 19 ionice -c 2 -n 7 "$@"; else nice -n 19 "$@"; fi
}
