#!/usr/bin/env bash
# precheck.sh — schedule Precheck adapter for quality-inspector.
#
# The platform runs `precheck.sh <mode>` before a scheduled fire and reads the EXIT
# CODE as the verdict — the way grep splits it:
#
#   0  -> run the turn. stdout (first 8 KiB) is appended to the task prompt.
#   1  -> decline this occurrence. No model is woken; stdout is discarded.
#   *  -> the Precheck itself broke: the platform runs the turn ANYWAY and records
#         the reason. Fail-open by design, so a typo exiting 127 cannot silence a
#         schedule for weeks while looking exactly like "nothing changed".
#
# So this script is nothing but the translation of preflight.sh's JSON into that
# code, and it is the only place that translation lives. preflight.sh keeps its own
# contract unchanged (one JSON object, exit 0) — it is still the fallback the agent
# runs itself when no Precheck is attached, or when this one broke.
#
# Runs under `bash -lc` with the work directory as cwd, a 2-minute deadline, and
# PLATFORM_SCHEDULE_ID / PLATFORM_FIRE_AT / PLATFORM_LAST_RUN_AT in the environment.
# PLATFORM_LAST_RUN_AT is the last fire that ACTUALLY RAN — declined occurrences do
# not move it, so it is the right "changed since?" watermark for a detection pass.

set -u
export LC_ALL=C

MODE="${1:-}"
HOME_DIR="${HOME:-/home/agent}"
PREFLIGHT="$HOME_DIR/scripts/preflight.sh"

# Only a schedule's prompt carries the frame, so the policy hook and the scripts tell a
# scheduled run from the operator's session by the session's own transcript, never by a
# clock (lib/channel.sh → transcript_is_scheduled; docs/persistence.md → Scheduled or direct
# session). It is printed first, before anything that could fail. `slack` is no schedule: its
# output is a tool result in a Slack turn, which the transcript tells apart by itself.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/channel.sh" 2>/dev/null \
  || SCHEDULED_FRAME='<qi-scheduled-run>' # lib/channel.sh missing: its value, so no run reads as direct
FRAME_LINE="$SCHEDULED_FRAME${MODE:-?}</qi-scheduled-run>"
[ "$MODE" = slack ] || printf '%s\n' "$FRAME_LINE"

# The platform appends at most 8 KiB of stdout to the prompt and truncates the rest.
# A worklist cut mid-JSON is worse than none — the turn would parse a fragment — so
# an oversized result is replaced by its logs plus an instruction to re-derive it.
MAX_CONTEXT=$((8192 - ${#FRAME_LINE} - 1))

allow() { [ -n "${1:-}" ] && printf '%s\n' "$1"; exit 0; }

[ -n "$MODE" ] || allow "precheck: no mode given — run the pre-flight yourself."

# `slack [<n>]` is no schedule and never declines — a person waits for the answer
# (docs/slack.md). It prints the pre-flight's `slack` JSON. The policy hook knows a Slack
# turn by itself; `slack <n>` adds the one issue a Slack-ordered "test #N" may deliver to:
# when slack_channel is set, the environment is free, the day's quota is left and the shell
# knows its session, it writes the marker `slack <ISO> - <n> <session>` and adds
# `"marked": <n>` to the JSON. The marker binds that session alone, for no set time.
if [ "$MODE" = slack ]; then
  out="$(bash "$PREFLIGHT" slack 2>/dev/null)"
  printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 || allow '{"mode":"slack","error":"the pre-flight failed"}'
  n="${2:-}"
  [ -n "$n" ] || allow "$out"
  case "$n" in ([1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]|[1-9][0-9][0-9][0-9][0-9]|[1-9][0-9][0-9][0-9][0-9][0-9]) ;;
    (*) allow "$(printf '%s' "$out" | jq -c '. + {error: "precheck slack <n>: <n> is not an issue number", marked: null}')";; esac
  if printf '%s' "$out" | jq -e '.channel != null and .environment.busy == false and .quota_left > 0' >/dev/null 2>&1; then
    d="${WORK_DIR:-$HOME_DIR/work}/env"; s="${CLAUDE_CODE_SESSION_ID:-}"
    case "$s" in (''|*[!A-Za-z0-9_-]*) allow "$(printf '%s' "$out" | jq -c '. + {marked: null}')";; esac
    mkdir -p "$d" 2>/dev/null && printf 'slack %s - %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$n" "$s" > "$d/RUN_MODE" 2>/dev/null \
      && allow "$(printf '%s' "$out" | jq -c --argjson n "$n" '. + {marked: $n}')"
  fi
  allow "$(printf '%s' "$out" | jq -c '. + {marked: null}')"
fi

# The audit always runs and its task runs the pre-flight itself (its probes take most of
# the two minutes); the Precheck is there only for the frame.
[ "$MODE" = audit ] && allow ""

# A missing or unrunnable pre-flight degrades to a slower run, never a skipped one:
# the same fallback the agent-side contract states for non-JSON output.
[ -f "$PREFLIGHT" ] || allow "precheck: $PREFLIGHT is missing — fall back to the manual procedure in docs/."

OUT="$(bash "$PREFLIGHT" "$MODE" 2>/dev/null)" \
  || allow "precheck: the pre-flight exited non-zero for mode '$MODE' — fall back to the manual procedure in docs/."

# One jq exec decides everything: an unparsable result is a broken pre-flight (allow),
# a reported `error` is a failed READ (allow — see below), nothing_to_do is a decline.
VERDICT="$(printf '%s' "$OUT" | jq -r '
  if (.error // "") != "" then "allow-error"
  elif .nothing_to_do == true then "decline"
  else "allow" end' 2>/dev/null)"

case "$VERDICT" in
  decline)
    # Nothing to do and the pre-flight is sure of it. Cheapest possible occurrence.
    exit 1
    ;;
  allow | allow-error)
    # allow-error is deliberate: a pre-flight that could not even list has NOT
    # answered "nothing changed". Declining would hide an outage inside the decline
    # counter, where it reads exactly like a quiet week. The turn runs, sees the
    # error field, and reports it — a failed read is never an answer.
    if [ "${#OUT}" -le "$MAX_CONTEXT" ]; then
      printf '%s\n' "$OUT"
    else
      printf '%s' "$OUT" | jq -r '
        "The pre-flight worklist for mode \"" + (.mode // "?") + "\" is too large to inline.",
        "Re-run it yourself: bash \"$HOME/scripts/preflight.sh\" " + (.mode // ""),
        "",
        "Its log lines:",
        ((.logs // []) | .[])' 2>/dev/null \
        || printf 'precheck: the worklist exceeded %s bytes — re-run bash "$HOME/scripts/preflight.sh" %s yourself.\n' "$MAX_CONTEXT" "$MODE"
    fi
    exit 0
    ;;
  *)
    # Not JSON at all. Same fallback as a missing script.
    allow "precheck: the pre-flight emitted no parsable JSON for mode '$MODE' — fall back to the manual procedure in docs/."
    ;;
esac
