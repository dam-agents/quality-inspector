#!/usr/bin/env bash
# egress-rules.sh — list the egress rules this instance needs beyond the kit's
# (docs/black-box.md → Egress rules): the profile's `egress`, the work backup repository's
# (`work_repo`) and — for a target on GitHub Enterprise — the shared GitHub rules on that
# host. A github.com target needs nothing here: the kit's rules hold for every target.
# --kit adds the kit's own rules, for an agent created by hand or from a kit before 3.0.0.
#
# Data for the operator, never commands: each rule as host, method, path, verdict and why,
# and how it gets onto the agent —
#   prompt   no kit rule covers the host: the first request in a direct session is held
#            and the operator answers its approval prompt ("Allow permanently");
#            `verify-onboarding.sh --egress` makes that request. A wildcard host prompts
#            once per host it reaches.
#   by-hand  the operator adds it in the agent's network settings: it falls under a kit
#            deny (refused at once, no prompt ever appears), it is a deny, or it belongs to
#            a set that must land whole (the kit's own, the work backup, GitHub Enterprise).
#   kit      the kit already allows it — nothing to do.
# The black-box gate (scripts/preflight.sh) and `verify-onboarding.sh --live` prove them.
#
#   egress-rules.sh [--kit] [--json]

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/profile.sh" || { echo "cannot source lib/profile.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/boundary.sh" || { echo "cannot source lib/boundary.sh" >&2; exit 1; }

usage() { echo "usage: egress-rules.sh [--kit] [--json]" >&2; exit 2; }
KIT=0; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in (--kit) KIT=1;; (--json) JSON=1;; (*) usage;; esac
  shift
done
T="${QI_TARGET_REPO:-$(cfg target_repo)}"
W="$(cfg work_repo)"
[ -n "$W" ] && [ -n "$T" ] && [ "$(_bb_host "$W")/$(_bb_repo "$W" | tr 'A-Z' 'a-z')" = "$(_bb_host "$T")/$(_bb_repo "$T" | tr 'A-Z' 'a-z')" ] \
  && { echo "work_repo is the target repository — refused (docs/persistence.md → Backup & restore)" >&2; exit 1; }

NOTES=(); ROWS=()
note() { NOTES+=("$1"); }
row() { # <source> <verdict> <method> <host> <path> <how> [why]
  ROWS+=("$(jq -cn --arg s "$1" --arg v "$2" --arg m "$3" --arg h "$4" --arg p "$5" --arg how "$6" --arg w "${7:-}" \
    '{source: $s, verdict: $v, method: $m, host: $h, path: $p, how: $how, why: $w}')")
}

# Does a kit rule pattern cover a path? '*' is the only wildcard (SQL LIKE '%' on the platform).
_covers() { # <pattern> <path>
  local pat; pat="$(printf '%s' "$1" | sed 's/[][?\\]/\\&/g')"
  # shellcheck disable=SC2053
  [[ "$2" == $pat ]]
}
# Does a kit rule's host cover <host>: exact, `*.parent` for one more label, or `*`?
_host_covers() { # <rule host> <host>
  case "$1" in
    ("$2"|'*') return 0;;
    ('*.'*) local rest="${2#*.}"; [ "$rest" != "$2" ] && [ "*.$rest" = "$1" ];;
    (*) return 1;;
  esac
}
# How a profile rule gets onto the agent, against the kit's rules.
_how() { # <verdict> <method> <host> <path>
  local v m h p
  [ "$1" = deny ] && { echo by-hand; return; }
  while read -r v m h p; do
    [ "$v" = allow ] && [ "$h" = "$3" ] && { [ "$m" = "$2" ] || [ "$m" = '*' ]; } && [ "$4" != '*' ] && _covers "$p" "$4" \
      && { echo kit; return; }
  done < <(kit_rules)
  while read -r v m h p; do
    [ "$v" = deny ] && _host_covers "$h" "$3" && { [ "$4" = '*' ] || _covers "$p" "$4"; } && { echo by-hand; return; }
  done < <(kit_rules)
  echo prompt
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

if [ "$KIT" = 1 ]; then
  note "The kit's rules (kit.yaml) — already on an agent created from kit 3.0.0 or newer; a kit never updates an existing agent's rules."
  while read -r v m h p; do row kit "$v" "$m" "$h" "$p" by-hand; done < <(kit_rules)
else
  note "The kit's rules (kit.yaml) are left out: an agent created by hand or from a kit before 3.0.0 lacks them — run with --kit."
fi
if [ -z "$T" ]; then
  note "No target_repo yet — a GitHub Enterprise target's rules are listed once it is set."
elif [ "$(_bb_host "$T")" = github.com ]; then
  note "The target $T is on github.com: the kit's GitHub rules hold for it — nothing to add."
else
  H="$(_bb_host "$T")"
  note "The target $T is on $H: the shared GitHub rules on that host (docs/black-box.md → Egress rules), all of them."
  d=""; read -r dh dr < <(_bb_definition) && [ "$dh" = "$H" ] && d="$dr"
  while read -r v m h p; do row github "$v" "$m" "$h" "$p" by-hand; done < <(github_rules "$H" $d)
fi
if [ -n "$W" ]; then
  while read -r v m h p; do row work_repo "$v" "$m" "$h" "$p" by-hand "the work backup $W (git fetch and push)"; done < <(work_repo_rules)
fi
if dir="$(profile_dir)" && [ -f "$dir/profile.json" ]; then
  while IFS="$(printf '\t')" read -r v m h p why; do
    row profile "$v" "$m" "$h" "$p" "$(_how "$v" "$m" "$h" "$p")" "$why"
  done < <(jq -r '.egress[]? | [(.verdict // "allow"), (.method // "*"), .host, (.pathPattern // .path // "*"), (.why // "")] | @tsv' "$dir/profile.json")
else
  note "No profile installed — its egress is listed once it is."
fi

if [ "$JSON" = 1 ]; then
  { printf '%s\n' ${ROWS[@]+"${ROWS[@]}"}; } | jq -s --args '{rules: ., notes: $ARGS.positional}' ${NOTES[@]+"${NOTES[@]}"}
  exit 0
fi
printf '%s\n' ${NOTES[@]+"${NOTES[@]}"}
[ ${#ROWS[@]} -gt 0 ] || exit 0
echo
echo "| how | verdict | method | host | path | why |"
echo "| --- | --- | --- | --- | --- | --- |"
printf '%s\n' "${ROWS[@]}" | jq -r '"| \(.how) | \(.verdict) | \(.method) | `\(.host)` | `\(.path)` | \(.why | gsub("\\|"; "/")) |"'
echo
echo "prompt: approve its prompt when it appears (verify-onboarding.sh --egress asks for each one) · by-hand: add it in the agent's network settings, no prompt will appear · kit: nothing to do."
