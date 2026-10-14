#!/usr/bin/env bash
# env.sh — the product environment inside this agent's VM. The lock is the core's; every
# other command is the profile's bin/env (docs/profile-contract.md → The bin/ contract).
# The agent calls it; the pre-flight never does. docs/nested-env.md.
#
#   env.sh lock <owner> | unlock <owner>     one run at a time (exit 1 when a live holder has it;
#                                            lib/lock.sh); unlock refuses while an `up` still runs
#   env.sh init | up <build> | reset | status | down    → the profile
#                                            (`up` first checks min_free_disk_gi and keeps its
#                                            result in work/env/UP for `wait`)
#   env.sh wait [<seconds>]      block until the `up` started in the background ends (default 540 s,
#                                under the harness's 10-minute tool limit): exit 0 it succeeded,
#                                3 it still runs (call again), 1 it failed or died
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
. "$SCRIPT_DIR/lib/lock.sh" || { echo "cannot source lib/lock.sh" >&2; exit 1; }
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi
export LOG_JOB="${LOG_JOB:-env}"

LOCK_TTL_MIN="$(cfg lock_ttl_min)"; case "$LOCK_TTL_MIN" in (''|*[!0-9]*) LOCK_TTL_MIN=180;; esac
ME="${CLAUDE_CODE_SESSION_ID:-}"
UPF="$ENVD/UP"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Ours: this session holds it, or — when either side has no session id — the same owner.
lock_mine() { # <held> <session> <owner>
  [ -n "$ME" ] && [ "$2" = "$ME" ] && return 0
  [ "$1" = "$3" ] && { [ -z "$ME" ] || [ "$2" = - ]; }
}
cmd_lock() {
  local owner="${1:?owner}" state held ts sess
  mkdir -p "$ENVD"
  lock_mutex "$ENVD/LOCK.mutex" || { echo "env: another run is taking the lock right now" >&2; exit 1; }
  trap 'rmdir "$ENVD/LOCK.mutex" 2>/dev/null' EXIT
  [ -f "$ENVD/LOCK" ] && read -r held ts sess _ < "$ENVD/LOCK"
  if [ -n "${held:-}" ] && ! lock_mine "$held" "${sess:--}" "$owner"; then
    read -r state held ts sess <<<"$(lock_state "$ENVD/LOCK" "$LOCK_TTL_MIN")"
    case "$state" in
      (live) echo "env: locked by $held since $ts — its session is running" >&2; exit 1;;
      (held) echo "env: locked by $held since $ts" >&2; exit 1;;
      (dead|stale) logev warn env_lock_takeover "$state environment lock of $held ($ts) taken over by $owner";;
    esac
  fi
  printf '%s %s %s\n' "$owner" "$(now)" "$ME" > "$ENVD/LOCK.tmp" && mv -f "$ENVD/LOCK.tmp" "$ENVD/LOCK"
}
up_running() { local st b ts x; [ -f "$UPF" ] && read -r st b ts x < "$UPF" && [ "$st" = running ] && kill -0 "$x" 2>/dev/null; }
cmd_unlock() {
  local owner="${1:?owner}" held ts sess
  [ -f "$ENVD/LOCK" ] || return 0
  read -r held ts sess _ < "$ENVD/LOCK"
  lock_mine "$held" "${sess:--}" "$owner" || return 0
  up_running && { echo "env: an install still runs — env.sh wait until it ends, then unlock" >&2; exit 1; }
  rm -f "$ENVD/LOCK"
  return 0
}

delegate() { # <cmd> [args]
  mkdir -p "$ENVD" && chmod 700 "$ENVD"
  local t0; t0="$(date -u +%s)"
  profile_run env "$@"; local rc=$?
  case "$rc" in
    (0) [ "$1" = up ] && logev info env_up "product at build ${2:-?} took_s=$(( $(date -u +%s) - t0 ))"
        [ "$1" = reset ] && logev info env_reset "product data wiped" ;;
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

# up <build>, its result kept for `wait`: `running <build> <ISO> <pid>`, then `done <build> <ISO> <exit>`.
cmd_up() {
  local rc
  mkdir -p "$ENVD"
  printf 'running %s %s %s\n' "$1" "$(now)" "$$" > "$UPF"
  ( disk_gate && delegate up "$1" ); rc=$?
  printf 'done %s %s %s\n' "$1" "$(now)" "$rc" > "$UPF"
  return "$rc"
}
cmd_wait() { # [<seconds>]
  local max="${1:-540}" end st b ts x
  case "$max" in (''|*[!0-9]*) max=540;; esac
  end=$(( $(date -u +%s) + max ))
  while :; do
    { [ -f "$UPF" ] && read -r st b ts x < "$UPF"; } || { echo "env: no install was started" >&2; return 1; }
    case "$st" in
      (done) [ "$x" = 0 ] && { echo "env: $b is up ($ts)" >&2; return 0; }
             echo "env: the install of $b failed (exit $x, $ts) — docs/nested-env.md → Failures" >&2; return 1;;
      (running) kill -0 "$x" 2>/dev/null || { echo "env: the install of $b (started $ts) died without a result" >&2; return 1; };;
      (*) echo "env: unreadable work/env/UP" >&2; return 1;;
    esac
    [ "$(date -u +%s)" -lt "$end" ] || { echo "env: $b still installing (since $ts) — run env.sh wait again" >&2; return 3; }
    sleep 5
  done
}

case "${1:-}" in
  between) [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: $0 between <from> <to>" >&2; exit 1; }; cmd_between "$2" "$3" ;;
  lock)   cmd_lock "${2:-}" ;;
  unlock) cmd_unlock "${2:-}" ;;
  init|reset|status|down) delegate "$1" ;;
  up)     [ -n "${2:-}" ] || { echo "usage: $0 up <build>" >&2; exit 2; }; cmd_up "$2" ;;
  wait)   cmd_wait "${2:-}" ;;
  *) echo "usage: $0 lock <owner>|unlock <owner>|init|up <build>|wait [<seconds>]|reset|status|down|between <from> <to>" >&2; exit 2 ;;
esac
