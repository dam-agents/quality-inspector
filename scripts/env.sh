#!/usr/bin/env bash
# env.sh — the product environment inside this agent's VM. The lock is the core's; every
# other command is the profile's bin/env (docs/profile-contract.md → The bin/ contract).
# The agent calls it; the pre-flight never does. docs/nested-env.md.
#
#   env.sh lock <owner> | unlock <owner>     one run at a time (exit 1 when a live holder has it)
#   env.sh init | up <build> | reset | status | down    → the profile
#                                            (`up` first checks min_free_disk_gi)
#   env.sh between <from> <to>   read-only: the profile's `bin/versions --between` — a JSON
#                                array of builds between the two, oldest first; exit 2 when
#                                the profile does not implement it (no array), 1 when it
#                                cannot look (docs/triage.md → Order of work, step 6)
#
# Every command is idempotent; a failed `up` is safe to re-run.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
ENVD="$WORK/env"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/profile.sh" || { echo "cannot source lib/profile.sh" >&2; exit 1; }
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi
export LOG_JOB="${LOG_JOB:-env}"

LOCK_TTL_MIN="$(cfg lock_ttl_min)"; LOCK_TTL_MIN="${LOCK_TTL_MIN:-180}"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
iso2epoch() { date -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }

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

delegate() { # <cmd> [args]
  mkdir -p "$ENVD" && chmod 700 "$ENVD"
  profile_run env "$@"; local rc=$?
  case "$rc" in
    (0) [ "$1" = up ] && logev info env_up "product at build ${2:-?}"; [ "$1" = reset ] && logev info env_reset "product data wiped" ;;
    (*) logev error env_failed "profile bin/env $1 exited $rc" ;;
  esac
  return "$rc"
}

cmd_between() { # <from> <to>
  local out rc
  out="$(profile_run versions --between "$1" "$2")"; rc=$?
  [ "$rc" = 2 ] && { echo "env: the profile cannot list builds between two builds" >&2; return 2; }
  [ "$rc" = 0 ] || { echo "env: bin/versions --between exited $rc" >&2; return 1; }
  printf '%s' "$out" | jq -ce 'if type == "array" then . else error("not an array") end' 2>/dev/null \
    || { echo "env: bin/versions ignores --between (no JSON array) — treated as not implemented" >&2; return 2; }
}

# An install needs room for images and data: refuse `up` below min_free_disk_gi free on
# the home volume — an environment failure, never a verdict. Unmeasurable → go ahead.
disk_gate() {
  local min free
  min="$(cfg min_free_disk_gi)"; case "$min" in (''|*[!0-9]*) min=10;; esac
  free="$(df -Pk "$HOME_DIR" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print int($4/1048576)}')"
  [ -n "$free" ] || { echo "env: free disk space not measurable — continuing" >&2; return 0; }
  [ "$free" -ge "$min" ] && return 0
  echo "env: only ${free}Gi free on the home volume, min_free_disk_gi is $min — free space before an install (docs/nested-env.md → Failures)" >&2
  logev error env_failed "up refused: ${free}Gi free on the home volume, below min_free_disk_gi $min"
  exit 1
}

case "${1:-}" in
  between) [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: $0 between <from> <to>" >&2; exit 1; }; cmd_between "$2" "$3" ;;
  lock)   cmd_lock "${2:-}" ;;
  unlock) cmd_unlock "${2:-}" ;;
  init|reset|status|down) delegate "$1" ;;
  up)     [ -n "${2:-}" ] || { echo "usage: $0 up <build>" >&2; exit 2; }; disk_gate; delegate up "$2" ;;
  *) echo "usage: $0 lock <owner>|unlock <owner>|init|up <build>|reset|status|down|between <from> <to>" >&2; exit 2 ;;
esac
