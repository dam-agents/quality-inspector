#!/usr/bin/env bash
# channel.sh — what kind of session is this? (docs/persistence.md → Scheduled or direct
# session). Sourced by scripts/hooks/policy.sh, lib/config.sh (direct_session, live_cdp) and
# scripts/precheck.sh (the frame it prints). Pure bash + jq.
#
# The kind is read from the session's own transcript, never from a clock. A frame counts in a
# prompt only — a closed set of line shapes: the content of a `user` line other than its tool
# results and a compaction summary, and the prompt of a `queued_command` attachment. Every
# other line is not a prompt and is never read: a tool result (a Read of docs/persistence.md,
# an issue body), the agent's own message, progress, a file the harness attaches (CLAUDE.md as
# `instructions`, an edited file), a hook's context, a request log. The limit: a frame the
# platform delivered in any other shape is not seen. A line that holds a frame but does not
# parse counts. A frame stays in a session continued from the UI, so that session keeps its kind.

# The platform's frames of a prompt someone other than the operator sent (a channel turn):
# a Slack message (`<how-to-respond>`), and a press of a shared interactive artifact's button
# by a viewer (`<viewer> sent this from a button on the interactive artifact "…"` —
# docs/modules.md → Control). Anyone in a bound conversation, or anyone the operator shared
# the dashboard with, speaks there, never the operator.
ARTIFACT_VIEWER_FRAME=' sent this from a button on the interactive artifact '   # no quote: the transcript is JSON-escaped
# The Precheck's frame: the first line it prints, which the platform appends to a scheduled
# task's prompt (scripts/precheck.sh). Only a schedule's prompt carries it.
SCHEDULED_FRAME='<qi-scheduled-run>'

# transcript_prompt_has <transcript.jsonl> <frame>…: 0 when a prompt line holds one of the frames.
transcript_prompt_has() {
  local f="${1:-}" hits out x; local -a pat=()
  [ -n "$f" ] || return 1
  shift
  for x in "$@"; do pat+=(-e "$x"); done
  hits="$(grep -F "${pat[@]}" "$f" 2>/dev/null)" || return 1
  out="$(printf '%s\n' "$hits" | jq -Rr '$ARGS.positional as $fr | (fromjson? // "unparsable") as $l
    | if ($l | type) != "object" then "y"
      else (if $l.type == "user" and $l.isCompactSummary != true then
              ($l.message.content | if type == "array" then map(select(.type != "tool_result")) else . end)
            elif $l.type == "attachment" and $l.attachment.type == "queued_command" then $l.attachment.prompt
            else empty end)
           | tojson | select(. as $t | any($fr[]; . as $x | $t | contains($x))) | "y"
      end' --args "$@" 2>/dev/null)" || out=y
  [ -n "$out" ]
}

# transcript_is_channel <transcript.jsonl>: 0 in a Slack turn or a dashboard viewer's turn.
transcript_is_channel() { transcript_prompt_has "${1:-}" '<how-to-respond>' "$ARTIFACT_VIEWER_FRAME"; }

# transcript_is_scheduled <transcript.jsonl>: 0 in a scheduled run (its prompt holds the
# Precheck's frame).
transcript_is_scheduled() { transcript_prompt_has "${1:-}" "$SCHEDULED_FRAME"; }

# session_transcript: prints the transcript of the session this shell runs in — the
# CLAUDE_CODE_SESSION_ID file under the Claude config's projects/ — or fails.
session_transcript() {
  local id="${CLAUDE_CODE_SESSION_ID:-}" f
  case "$id" in (''|*[!A-Za-z0-9_-]*) return 1;; esac
  for f in "${CLAUDE_CONFIG_DIR:-${HOME:-/home/agent}/.claude}"/projects/*/"$id".jsonl; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}
