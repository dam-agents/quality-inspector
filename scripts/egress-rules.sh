#!/usr/bin/env bash
# egress-rules.sh — print the `dam network create` commands this instance's black-box
# boundary needs (docs/black-box.md → Egress rules): the target's rules, the work backup
# repository's (`work_repo`) and the profile's `egress`. --kit adds the kit's own rules, which
# an agent created from a kit older than 2.11.0 (or by hand) lacks; --source allows one more
# skill source's repository on the target's GitHub host, which is otherwise deny-by-default.
# Prints only — the operator runs them, with AGENT set to this agent's name; the probes of
# `verify-onboarding.sh --live` then prove them.
#
#   egress-rules.sh [--kit] [--source <owner>/<repo>]…

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/profile.sh" || { echo "cannot source lib/profile.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/boundary.sh" || { echo "cannot source lib/boundary.sh" >&2; exit 1; }

usage() { echo "usage: egress-rules.sh [--kit] [--source <owner>/<repo>]…" >&2; exit 2; }
KIT=0; SOURCES=()
while [ $# -gt 0 ]; do
  case "$1" in
    (--kit) KIT=1;;
    (--source) [ $# -ge 2 ] || usage
      printf '%s' "$2" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || usage
      SOURCES+=("$2"); shift;;
    (*) usage;;
  esac
  shift
done
T="${QI_TARGET_REPO:-$(cfg target_repo)}"
[ -n "$T" ] || { echo "target_repo is not configured (work/CONFIG.md)" >&2; exit 1; }
for s in ${SOURCES[@]+"${SOURCES[@]}"}; do
  [ "$(_bb_lower "$s")" = "$(_bb_lower "$(_bb_repo "$T")")" ] && {
    echo "--source $s is the target: a profile there takes profile_source_path, never the whole repository" >&2; exit 2; }
done
PP="$(_bb_profile_path)"
[ -z "$PP" ] || _bb_profile_path_ok "$PP" || {
  echo "profile_source_path '$PP' is not a plain directory path (no * % ?, no . or .. segment): its allow would open more than the profile's directory" >&2; exit 2; }
W="$(cfg work_repo)"
[ -n "$W" ] && [ "$(_bb_host "$W")/$(_bb_repo "$W" | tr 'A-Z' 'a-z')" = "$(_bb_host "$T")/$(_bb_repo "$T" | tr 'A-Z' 'a-z')" ] \
  && { echo "work_repo is the target repository — refused (docs/persistence.md → Backup & restore)" >&2; exit 1; }

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
while read -r v m h p; do cmd "$v" "$m" "$h" "$p"; done < <(boundary_rules "$T" ${SOURCES[@]+"${SOURCES[@]}"})
_bb_definition >/dev/null || echo "# This definition's origin is unreadable: when it is on the target's host, allow its repository by hand (docs/black-box.md → Egress rules)."
if [ -n "$W" ]; then
  echo "# The work backup $W (docs/persistence.md → Backup & restore)."
  while read -r v m h p; do cmd "$v" "$m" "$h" "$p"; done < <(work_repo_rules)
fi
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
