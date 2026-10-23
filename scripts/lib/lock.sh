#!/usr/bin/env bash
# lock.sh — the environment lock, work/env/LOCK: one run at a time on the nested product
# (docs/nested-env.md → Shape). Sourced by scripts/env.sh and scripts/preflight.sh.
#
# One line: `<owner> <ISO since> [<session>]`, <session> being the holder's
# CLAUDE_CODE_SESSION_ID. The platform runtime says whether that session still runs a
# turn: running → the lock holds whatever its age; not running → it is free at once. A
# line without a session (older versions, a harness without the variable) or a runtime
# that does not answer falls back to age: free once older than lock_ttl_min.

# session_running <id>: 0 running a turn · 1 not running, or unknown to the runtime (an
# empty list) · 2 no runtime to ask, it did not answer, or it listed only other sessions.
# Only the entry whose id is <id> counts — never the first entry of the list.
session_running() {
  local out
  case "${1:-}" in (''|-|*[!A-Za-z0-9_-]*) return 2;; esac
  [ -n "${PLATFORM_RUNTIME_URL:-}" ] || return 2
  out="$(curl -fsS --max-time 5 --get --data-urlencode "input={\"sessionId\":\"$1\"}" \
    "$PLATFORM_RUNTIME_URL/api/trpc/sessions.list" 2>/dev/null)" || return 2
  case "$(printf '%s' "$out" | jq -r --arg id "$1" '.result.data.sessions
      | if type != "array" then "unknown"
        elif length == 0 then false
        else (map(select((.id // .sessionId) == $id)) | if length == 0 then "unknown" else (first | .running == true) end)
        end' 2>/dev/null)" in
    (true) return 0;; (false) return 1;; (*) return 2;;
  esac
}

_lock_epoch() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }

# lock_state <lock file> <ttl-min> → `<state> <owner> <since> <session>` ("-" for a missing
# field). state: free (no lock) · live (its session runs a turn) · dead (its session does
# not) · held (liveness unknown, younger than the TTL) · stale (liveness unknown, older).
lock_state() {
  local held="" ts="" sess="" age
  [ -f "$1" ] && read -r held ts sess _ < "$1" 2>/dev/null
  [ -n "$held" ] || { echo "free - - -"; return 0; }
  session_running "$sess"
  case $? in
    (0) echo "live $held ${ts:--} $sess"; return 0;;
    (1) echo "dead $held ${ts:--} $sess"; return 0;;
  esac
  age=$(( ($(date -u +%s) - $(_lock_epoch "${ts:-x}")) / 60 ))
  [ "$age" -lt "$2" ] && echo "held $held ${ts:--} ${sess:--}" || echo "stale $held ${ts:--} ${sess:--}"
}

# lock_excl <file>: create <file> holding this shell's pid, or fail at once when it exists. The
# shell's noclobber opens it with O_EXCL, so two callers never both take it. Never a mkdir:
# uutils' mkdir (Ubuntu 25.10+) checks, then creates, and counts a directory another caller
# made in between as its own — both callers win.
lock_excl() { ( set -C; printf '%s\n' "$$" > "$1" ) 2>/dev/null; }

# lock_mutex <file> [<tries>]: a short critical section around read-judge-write, a try every
# 0.1 s (default 50), so two runs never both judge a lock free; the holder removes <file>. A
# mutex older than a minute is a crash's leftover, a directory of a version before 3.10.1 too.
lock_mutex() {
  local i
  for i in $(seq 1 "${2:-50}"); do
    lock_excl "$1" && return 0
    [ -n "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rm -rf "$1"
    sleep 0.1
  done
  return 1
}
