#!/usr/bin/env bash
# egress-rules.sh — print the `dam network create` commands this instance's black-box
# boundary needs (docs/black-box.md → Egress rules): the target's rules and the profile's
# `egress`. --kit adds the kit's own rules, which an agent created from a kit older than
# 2.11.0 (or by hand) lacks. Prints only — the operator runs them, with AGENT set to this
# agent's name; the probes of `verify-onboarding.sh --live` then prove them.
#
#   egress-rules.sh [--kit]

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/profile.sh" || { echo "cannot source lib/profile.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/boundary.sh" || { echo "cannot source lib/boundary.sh" >&2; exit 1; }

KIT=0
case "${1:-}" in (--kit) KIT=1;; ('') ;; (*) echo "usage: egress-rules.sh [--kit]" >&2; exit 2;; esac
T="${QI_TARGET_REPO:-$(cfg target_repo)}"
[ -n "$T" ] || { echo "target_repo is not configured (work/CONFIG.md)" >&2; exit 1; }

cmd() { # <verdict> <method> <host> <path pattern> [why]
  local c="dam network create \"\$AGENT\" --host"
  case "$3" in (*'*'*) c="$c \"$3\"";; (*) c="$c $3";; esac
  [ "$2" = '*' ] || c="$c --method $2"
  [ "$4" = '*' ] || c="$c --path \"$4\""
  [ "$1" = deny ] && c="$c --verdict deny"
  printf '%s --yes%s\n' "$c" "${5:+  # $5}"
}

# kit.yaml's egressRules as "<verdict> <method> <host> <path pattern>" lines; a key counts
# on the item's "- " line too, quoted or not, before a trailing comment — as the
# validator's kit check reads it.
kit_rules() {
  sed -n '/^egressRules:/,/^[a-z]/p' "$SCRIPT_DIR/../kit.yaml" 2>/dev/null | awk '
    function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); sub(/[[:space:]]+#.*$/, "", s); gsub(/["\047]/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function emit() { if (h != "") print v, m, h, p }
    /^  - / { emit(); h = ""; m = "*"; p = "*"; v = "allow" }
    /^(  - |    )host:/ { h = val($0) }
    /^(  - |    )method:/ { m = val($0) }
    /^(  - |    )pathPattern:/ { p = val($0) }
    /^(  - |    )verdict:/ { v = val($0) }
    END { emit() }'
}

echo ': "${AGENT:?set AGENT to this agent'"'"'s name}"'
if [ "$KIT" = 1 ]; then
  echo "# The kit's rules (kit.yaml) — already on an agent created from kit 2.11.0 or newer."
  while read -r v m h p; do cmd "$v" "$m" "$h" "$p"; done < <(kit_rules)
else
  echo "# The kit's rules (kit.yaml) are left out: an agent created by hand or from a kit before 2.11.0 lacks them — run with --kit."
fi
echo "# The target $T (docs/black-box.md → Egress rules)."
while read -r v m h p; do cmd "$v" "$m" "$h" "$p"; done < <(boundary_rules "$T")
if dir="$(profile_dir)" && [ -f "$dir/profile.json" ]; then
  echo "# The profile's egress ($(jq -r '.product // "profile"' "$dir/profile.json"))."
  jq -r '.egress[]? | [(.verdict // "allow"), (.method // "*"), .host, (.pathPattern // .path // "*"), (.why // "")] | @tsv' \
    "$dir/profile.json" | while IFS="$(printf '\t')" read -r v m h p why; do
      # The operator runs these lines in a shell: a value that could expand there is skipped.
      case "$v$m$h$p" in (*[!A-Za-z0-9._~*/%:?=\&+@,-]*)
        echo "# Skipped: the profile's egress entry for ${h//[!A-Za-z0-9.*-]/?} holds a shell character — check profile.json."; continue;; esac
      cmd "$v" "$m" "$h" "$p" "$why"
    done
else
  echo "# No profile installed — add its egress (profile.json) once it is."
fi
