#!/usr/bin/env bash
# trace.sh — Claude Code hook: the harness's own record of every turn and every failed tool
# call, in work/logs/ (docs/logging.md → Harness trace). Registered by scripts/hooks/install.sh
# for UserPromptSubmit, PostToolUse, PostToolUseFailure, Stop and StopFailure.
#
# It never influences the model or the turn: it prints nothing (a UserPromptSubmit hook's
# stdout would join the prompt) and always exits 0. The harness runs it, so a model that forgets
# to log, or a turn that dies mid-pipeline, still leaves its trace. No line holds a prompt, a
# command or a tool's input: a prompt is its size and a 12-hex sha256, a failure its tool, exit
# code and a short excerpt of the error, masked (lib/secrets.mjs, then log.sh).
#
#   UserPromptSubmit    turn_start kind=<scheduled|channel|direct>[ schedule=<id>] bytes=<n> sha=<hex12>
#                       — first a turn_end status=interrupted for a turn of this session that never stopped
#   PostToolUse         counts the call
#   PostToolUseFailure  counts it, and logs tool_failed (warn) tool=<name>[ code=<exit>][ interrupt=1][ agent=<type>]
#                       ms=<n> err=<excerpt> — a Bash exit 1 with no output (grep without a match, a
#                       false test) is only counted
#   Stop, StopFailure   turn_end status=<ok|the API error> kind=<kind> secs=<n> tools=<n> failed=<n>
#
# The job of every line is the turn's: the schedule's mode for a scheduled turn (`preflight.sh
# <mode>` in its prompt), `channel`, else `session`. A turn's state is work/env/turns/<session>
# (pod-local, never backed up): the line `<start epoch|-> <job> <kind>`, then one byte per tool
# call — `.` done, `x` failed.

set -u
export LC_ALL=C
trap 'exit 0' EXIT

IN="$(cat 2>/dev/null)"
command -v jq >/dev/null 2>&1 || exit 0
SCRIPT_DIR="$(cd "${BASH_SOURCE[0]%/*}/.." 2>/dev/null && pwd)" || exit 0
WORK="${WORK_DIR:-${HOME:-/home/agent}/work}"
TURNS="$WORK/env/turns"
EXCERPT=160   # characters of a failure's error kept in tool_failed

VARS="$(printf '%s' "$IN" | jq -r '
  def s: if . == null then "" elif type == "string" then . else tostring end | @sh;
  "EVENT=\(.hook_event_name | s) SESSION=\(.session_id | s) TOOL=\(.tool_name | s)",
  "AGENT=\(.agent_type | s) INTERRUPT=\(.is_interrupt | s) MS=\(.duration_ms | s)",
  "ERR=\(.error | s)"' 2>/dev/null)" || exit 0
eval "$VARS"
case "$SESSION" in (''|*[!A-Za-z0-9_-]*) exit 0;; esac
STATE="$TURNS/$SESSION"
export LOG_RUN_ID="$SESSION"

ev() { # <job> <level> <event> <msg>
  ( export LOG_JOB="$1"; . "$SCRIPT_DIR/log.sh" && logev "$2" "$3" "$4" ) >/dev/null 2>&1
}
iso2epoch() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }
sha12() { { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | cut -c1-12; }

end_turn() { # <status> — the state file's turn_end, then the file goes
  local start="" job="" kind="" calls failed secs=- level=info
  [ -f "$STATE" ] || return 0
  read -r start job kind < "$STATE" 2>/dev/null
  calls="$(tail -n +2 "$STATE" 2>/dev/null | tr -cd '.x')"
  failed="${calls//[!x]/}"
  case "$start" in (''|*[!0-9]*) ;; (*) secs=$(( $(date -u +%s) - start ));; esac
  case "$1" in (ok) ;; (interrupted) level=warn;; (*) level=error;; esac
  ev "${job:-session}" "$level" turn_end \
    "status=$1 kind=${kind:--} secs=$secs tools=${#calls} failed=${#failed}"
  rm -f "$STATE"
}

count() { # <byte> — a call of a turn whose start this hook did not see still counts
  mkdir -p "$TURNS" 2>/dev/null || return 0
  [ -f "$STATE" ] || printf -- '- session -\n' > "$STATE"
  printf '%s\n' "$1" >> "$STATE"
}

case "$EVENT" in
  (UserPromptSubmit)
    if [ -f "$STATE" ]; then   # a turn that never reached Stop: an interrupt, or a start this hook missed
      read -r s _ < "$STATE" 2>/dev/null
      if [ "${s:--}" = - ]; then rm -f "$STATE"; else end_turn interrupted; fi
    fi
    PROMPT="$(printf '%s' "$IN" | jq -j '.prompt // "" | tostring' 2>/dev/null)"
    . "$SCRIPT_DIR/lib/channel.sh" 2>/dev/null
    kind=direct job=session sched=""
    case "$PROMPT" in
      (*'<how-to-respond>'*) kind=channel job=channel;;
      (*"${ARTIFACT_VIEWER_FRAME:-<no viewer frame>}"*) kind=channel job=channel;;
      (*)
        # a schedule's task names `preflight.sh <mode>`, and its Precheck wrote
        # `scheduled <ISO> <schedule id>` right before the turn
        read -r rk riso rid _ < "$WORK/env/RUN_MODE" 2>/dev/null
        if [[ "$PROMPT" =~ preflight\.sh\"?\ +([a-z]+) ]] && [ "${rk:-}" = scheduled ] \
           && [ $(( $(date -u +%s) - $(iso2epoch "${riso:-x}") )) -lt 900 ]; then
          kind=scheduled job="${BASH_REMATCH[1]}" sched="${rid:--}"
        fi;;
    esac
    mkdir -p "$TURNS" 2>/dev/null && printf '%s %s %s\n' "$(date -u +%s)" "$job" "$kind" > "$STATE"
    ev "$job" info turn_start \
      "kind=$kind${sched:+ schedule=${sched//[!A-Za-z0-9_.-]/}} bytes=${#PROMPT} sha=$(printf '%s' "$PROMPT" | sha12)"
    ;;
  (PostToolUse) count . ;;
  (PostToolUseFailure)
    count x
    code="" body="$ERR"
    if [[ "$ERR" =~ ^Exit\ code\ ([0-9]+) ]]; then code="${BASH_REMATCH[1]}"; body="${ERR#Exit code $code}"; fi
    body="$(printf '%s' "$body" | tr -s '\r\n\t ' '    ' | sed -e 's/^ //' -e 's/ $//')"
    [ "$TOOL" = Bash ] && [ "$code" = 1 ] && [ -z "$body" ] && exit 0
    if [ -n "$body" ] && [ -s "$WORK/env/credentials.env" ]; then
      body="$(printf '%s' "$body" | node "$SCRIPT_DIR/lib/secrets.mjs" filter "$WORK/env/credentials.env" 2>/dev/null)" || body="(unmasked error withheld)"
    fi
    read -r _ job _ < "$STATE" 2>/dev/null
    ev "${job:-session}" warn tool_failed \
      "tool=${TOOL:-?}${code:+ code=$code}$([ "$INTERRUPT" = true ] && echo ' interrupt=1')${AGENT:+ agent=${AGENT//[^A-Za-z0-9_.:-]/}} ms=${MS:--} err=${body:0:$EXCERPT}"
    ;;
  (Stop) end_turn ok ;;
  (StopFailure) end_turn "$(printf '%s' "${ERR:-unknown}" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-40)" ;;
esac
exit 0
