#!/usr/bin/env bash
# profile.sh — find the product profile and call it per docs/profile-contract.md.
# Sourced after lib/config.sh (needs cfg) by every script that touches the product.

# The profile's directory, or nothing when it is not installed.
profile_dir() {
  local name="${QI_PROFILE:-$(cfg profile)}" d
  if [ -n "${QI_PROFILE_DIR:-}" ]; then printf '%s\n' "$QI_PROFILE_DIR"; return; fi
  [ -n "$name" ] || return 1
  for d in "$HOME/.agents/skills/$name" "$HOME/.claude/skills/$name"; do
    [ -f "$d/profile.json" ] && { printf '%s\n' "$d"; return; }
  done
  return 1
}

# One JSON object of the profile's config keys: `- profile.<key>:` in CONFIG.md, else the default.
profile_config() {
  local dir; dir="$(profile_dir)" || { echo '{}'; return; }
  local k out='{}' v
  for k in $(jq -r '.config // {} | keys[]' "$dir/profile.json" 2>/dev/null); do
    v="$(cfg "profile\\.$k")"
    [ -n "$v" ] || v="$(jq -r --arg k "$k" '.config[$k].default // ""' "$dir/profile.json")"
    out="$(jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' <<<"$out")"
  done
  printf '%s\n' "$out"
}

# A manifest field (jq path), e.g. profile_field '.app.url'.
profile_field() { local dir; dir="$(profile_dir)" || return 1; jq -r "$1 // empty" "$dir/profile.json"; }

# The executable for one command: the profile's own bin/<cmd>, else its engine's
# (engines/<engine>/bin/<cmd> in this definition). Nothing when neither exists.
profile_bin() { # <cmd>
  local dir eng core
  dir="$(profile_dir)" || return 1
  [ -x "$dir/bin/$1" ] && { printf '%s\n' "$dir/bin/$1"; return; }
  eng="$(jq -r '.engine // empty' "$dir/profile.json" 2>/dev/null)"
  core="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  [ -n "$eng" ] && [ -x "$core/engines/$eng/bin/$1" ] && { printf '%s\n' "$core/engines/$eng/bin/$1"; return; }
  return 1
}

# The agent's own model connection, lent to the nested product (lend_model: enabled) as its
# placeholder only — `platform:conn:<id>`, which the gateway swaps for the key on the way
# out; the key never enters the VM. Prints `<key>|<kind>|<base url>`, or `||` when off or
# when this agent has no connection to lend. kind: api-key | oauth | auth-token | bedrock
# | unknown — from which variable the platform gives the agent's own harness.
model_env() {
  [ "$(cfg lend_model)" = enabled ] && [ -n "${PLATFORM_PROVIDER:-}" ] || { echo '||'; return 0; }
  local f="$HOME/.platform/runtime-env.json" keys kind base
  keys="$(jq -r --arg id "$PLATFORM_PROVIDER" '.providers[]? | select(.id == $id) | .env // {} | keys[]' "$f" 2>/dev/null)"
  case "$keys" in
    (*CLAUDE_CODE_OAUTH_TOKEN*) kind=oauth;; (*AWS_BEARER_TOKEN_BEDROCK*) kind=bedrock;;
    (*ANTHROPIC_AUTH_TOKEN*) kind=auth-token;; (*ANTHROPIC_API_KEY*) kind=api-key;; (*) kind=unknown;;
  esac
  base="$(jq -r --arg id "$PLATFORM_PROVIDER" '.providers[]? | select(.id == $id) | .env.ANTHROPIC_BASE_URL // empty' "$f" 2>/dev/null)"
  printf 'platform:conn:%s|%s|%s\n' "$PLATFORM_PROVIDER" "$kind" "$base"
}

# The agent's own model connection for the suite's agent steps (docs/test-authoring.md →
# Model access), as `<variable>=<value>` lines to export: the Anthropic variables the platform
# gives this harness. Their credential values are the connection's placeholder, which the
# gateway swaps for the key on the way out — on an agent that injects only addressed
# requests (kit.yaml → requireConnectionAddress) a request without one gets no credential.
# From the environment, else from the runtime env of PLATFORM_PROVIDER; nothing when this
# agent has no Anthropic-compatible connection.
MODEL_AUTH_VARS="ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN"
model_auth() {
  local v f="$HOME/.platform/runtime-env.json"
  for v in $MODEL_AUTH_VARS; do
    [ -n "${!v:-}" ] || continue
    for v in ANTHROPIC_BASE_URL $MODEL_AUTH_VARS; do [ -n "${!v:-}" ] && printf '%s=%s\n' "$v" "${!v}"; done
    return 0
  done
  [ -n "${PLATFORM_PROVIDER:-}" ] && [ -f "$f" ] || return 0
  jq -r --arg id "$PLATFORM_PROVIDER" --arg vars "ANTHROPIC_BASE_URL $MODEL_AUTH_VARS" '
    ($vars | split(" ")) as $want
    | .providers[]? | select(.id == $id) | .env // {} | to_entries[]
    | select((.key | IN($want[])) and (.value | type == "string") and .value != "") | "\(.key)=\(.value)"' "$f" 2>/dev/null
}

# One agent step's model call, sent as work/suite/e2e.config.ts sends it — the same
# endpoint, credential header and e2e_model (verify-onboarding.sh → model_provider). Prints
# `<http code|none>|<base>|<variable>|<model>|<provider's error message>`; `none` =
# no model connection, nothing sent.
model_probe() {
  local ma base var="" model out code err v h=()
  ma="$(model_auth)"
  _ma() { printf '%s\n' "$ma" | sed -n "s/^$1=//p" | head -1; }
  base="$(_ma ANTHROPIC_BASE_URL)"; base="${base%/}"; base="${base:-https://api.anthropic.com}"
  case "$base" in (*/v1) ;; (*) base="$base/v1";; esac
  model="$(cfg e2e_model)"; model="${model:-claude-sonnet-5}"
  for v in $MODEL_AUTH_VARS; do [ -n "$(_ma "$v")" ] && { var="$v"; break; }; done
  case "$var" in
    (ANTHROPIC_AUTH_TOKEN) h=(-H "Authorization: Bearer $(_ma "$var")");;
    (ANTHROPIC_API_KEY) h=(-H "x-api-key: $(_ma "$var")");;
    (CLAUDE_CODE_OAUTH_TOKEN) h=(-H "Authorization: Bearer $(_ma "$var")" -H 'anthropic-beta: oauth-2025-04-20');;
    (*) printf 'none|%s||%s|\n' "$base" "$model"; return 0;;
  esac
  out="$(mktemp "${TMPDIR:-/tmp}/quality-inspector-model.XXXXXX")" \
    || { printf '000|%s|%s|%s|cannot create a temporary file\n' "$base" "$var" "$model"; return 0; }
  code="$(curl -s -o "$out" -w '%{http_code}' --max-time 60 "$base/messages" "${h[@]}" \
          -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
          -d "$(jq -cn --arg m "$model" '{model: $m, max_tokens: 1, messages: [{role: "user", content: "ping"}]}')" 2>/dev/null)"
  err="$(jq -r '.error.message? // .error? // empty | tostring | gsub("\\s+"; " ")' "$out" 2>/dev/null | head -c 160)"
  rm -f "$out"
  printf '%s|%s|%s|%s|%s\n' "${code:-000}" "$base" "$var" "$model" "$err"
}

# Run a profile command with the contract's environment. Its exit code is returned.
profile_run() { # <bin> [args…]
  local dir exe bin="$1" mk mkind mbase; shift
  dir="$(profile_dir)" || { echo "profile not installed (config key 'profile')" >&2; return 3; }
  exe="$(profile_bin "$bin")" || { echo "profile has no bin/$bin and its engine none either" >&2; return 3; }
  local work="${WORK:-${WORK_DIR:-$HOME/work}}"
  IFS='|' read -r mk mkind mbase <<<"$(model_env)"
  ( cd "$work" 2>/dev/null || cd /
    QI_WORK="$work" QI_ENV_DIR="$work/env" QI_PROFILE_CONFIG="$(profile_config)" QI_PROFILE_DIR="$dir" \
    QI_ENGINE_CONFIG="$(jq -c '.engine_config // {}' "$dir/profile.json")" \
    QI_CANDIDATE_CHANNEL="$(cfg candidate_channel)" QI_BASELINE_CHANNEL="${QI_BASELINE_OVERRIDE:-$(cfg baseline_channel)}" \
    QI_MODEL_KEY="$mk" QI_MODEL_KIND="$mkind" QI_MODEL_BASE_URL="$mbase" \
      "$exe" "$@" )
}

# The e2e roles a credentials.env provides (docs/profile-contract.md → The `bin/` contract):
# each non-empty E2E_USER_<ROLE>_USERNAME, with `export` and one layer of quotes allowed. A
# sorted JSON array of lowercase names — never a value; `[]` when the file is missing.
provided_roles() { # <credentials.env>
  [ -f "$1" ] || { echo '[]'; return; }
  awk '/^(export[ \t]+)?E2E_USER_[A-Z0-9_]+_USERNAME=/ {
    k = $0; sub(/^export[ \t]+/, "", k); v = substr(k, index(k, "=") + 1); sub(/=.*/, "", k)
    gsub(/^["\047]|["\047][ \t]*$/, "", v); if (v == "") next
    sub(/^E2E_USER_/, "", k); sub(/_USERNAME$/, "", k); print tolower(k) }' "$1" | jq -R . | jq -sc 'unique'
}

# The product team's scenarios (docs/profile-contract.md → `scenarios/`): one line
# `<slug>\t<spec_hash>\t<path>` per `scenarios/<slug>.md` of the profile, sorted by slug.
# A slug is [a-z0-9] then [a-z0-9-], at most 48 characters; any other name, a symlink, a
# non-regular file or one over 64 KiB is skipped with a line on stderr. Needs lib/state.sh
# (text_hash). Nothing when the profile has no scenarios/.
PROFILE_SCENARIO_MAX_BYTES=65536
profile_scenarios() {
  local dir f base slug size
  dir="$(profile_dir)" || return 0
  [ -d "$dir/scenarios" ] && [ ! -L "$dir/scenarios" ] || return 0
  for f in "$dir"/scenarios/*.md; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base="$(basename "$f")"; slug="${base%.md}"
    if ! printf '%s' "$slug" | grep -qE '^[a-z0-9][a-z0-9-]{0,47}$'; then
      echo "profile scenario '$base' skipped: the name is not <slug>.md ([a-z0-9-], at most 48)" >&2; continue
    fi
    if [ -L "$f" ] || [ ! -f "$f" ]; then echo "profile scenario '$base' skipped: not a regular file" >&2; continue; fi
    size="$(wc -c < "$f" | tr -d ' ')"
    if [ "$size" -gt "$PROFILE_SCENARIO_MAX_BYTES" ]; then
      echo "profile scenario '$base' skipped: $size bytes, over $PROFILE_SCENARIO_MAX_BYTES" >&2; continue
    fi
    printf '%s\t%s\t%s\n' "$slug" "$(text_hash "$(cat "$f")")" "$f"
  done | sort
}
