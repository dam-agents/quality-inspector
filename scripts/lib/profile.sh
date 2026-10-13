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

# Run a profile command with the contract's environment. Its exit code is returned.
profile_run() { # <bin> [args…]
  local dir bin="$1"; shift
  dir="$(profile_dir)" || { echo "profile not installed (config key 'profile')" >&2; return 3; }
  [ -x "$dir/bin/$bin" ] || { echo "profile has no executable bin/$bin" >&2; return 3; }
  local work="${WORK:-${WORK_DIR:-$HOME/work}}"
  ( cd "$work" 2>/dev/null || cd /
    QI_WORK="$work" QI_ENV_DIR="$work/env" QI_PROFILE_CONFIG="$(profile_config)" \
    QI_CANDIDATE_CHANNEL="$(cfg candidate_channel)" QI_BASELINE_CHANNEL="${QI_BASELINE_OVERRIDE:-$(cfg baseline_channel)}" \
      "$dir/bin/$bin" "$@" )
}

# The black-box probes: one "gh <api-path>" or "url <url>" per line, each of which must be
# refused (docs/black-box.md). The provider's own list, then the profile's additions.
boundary_targets() { # <owner/repo>
  local r="$1" dir p
  printf '%s\n' "gh repos/$r/contents/" "gh repos/$r/pulls?per_page=1" "gh repos/$r/commits?per_page=1" \
    "gh repos/$r/git/refs/heads" "gh repos/$r/issues/1/timeline" \
    "url https://raw.githubusercontent.com/$r/HEAD/README.md" "url https://codeload.github.com/$r/tar.gz/HEAD"
  dir="$(profile_dir)" || return 0
  jq -r '.boundary.github_paths[]? // empty' "$dir/profile.json" | while read -r p; do printf 'gh repos/%s/%s\n' "$r" "${p#/}"; done
  jq -r '.boundary.urls[]? // empty' "$dir/profile.json" | sed "s|{repo}|$r|g; s|^|url |"
}
