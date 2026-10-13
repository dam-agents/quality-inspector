#!/usr/bin/env bash
# common.sh — the engine's resolved configuration, shared by every bin/ command.
# QI_ENGINE_CONFIG is the profile's engine_config; placeholders resolved once here.
ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine_config() {
  [ -n "${QI_ENGINE_CONFIG:-}" ] || { echo "helm-k3s: QI_ENGINE_CONFIG is empty (profile.json engine_config)" >&2; return 1; }
  printf '%s' "$QI_ENGINE_CONFIG" | node "$ENGINE_DIR/lib/render.mjs" config
}
