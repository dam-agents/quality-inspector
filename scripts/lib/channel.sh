#!/usr/bin/env bash
# channel.sh — is this session a channel turn? (docs/persistence.md → Scheduled or direct
# session). Sourced by scripts/hooks/policy.sh and lib/config.sh (live_cdp). Pure bash + jq.

# transcript_is_channel <transcript.jsonl>: 0 when a prompt line holds the platform's Slack
# frame `<how-to-respond>`, or its frame of a prompt sent from a button of a shared
# interactive artifact by a viewer (`<viewer> sent this from a button on the interactive
# artifact "…"` — docs/modules.md → Control). Anyone in a bound conversation, or anyone the
# operator shared the dashboard with, speaks there, never the operator.
# The frame counts in a prompt line only: a tool result (a Read of docs/persistence.md, an
# issue body), a tool's progress, a compaction summary or the agent's own message quoting it
# is data. A line that holds the frame but does not parse fails closed. The frame stays in a
# session continued from the UI, so that session stays non-direct.
ARTIFACT_VIEWER_FRAME=' sent this from a button on the interactive artifact '   # no quote: the transcript is JSON-escaped
transcript_is_channel() {
  local hits out
  [ -n "${1:-}" ] || return 1
  hits="$(grep -F -e '<how-to-respond>' -e "$ARTIFACT_VIEWER_FRAME" "$1" 2>/dev/null)" || return 1
  out="$(printf '%s\n' "$hits" | jq -Rr --arg v "$ARTIFACT_VIEWER_FRAME" '(fromjson? // "unparsable") as $l
    | if ($l | type) != "object" then "y"
      elif ($l.type == "assistant" or $l.type == "progress" or $l.isCompactSummary == true) then empty
      else ($l | del(.toolUseResult)
            | (if (.message.content | type) == "array" then .message.content |= map(select(.type != "tool_result")) else . end)
            | tojson | select(contains("<how-to-respond>") or contains($v)) | "y")
      end' 2>/dev/null)" || out=y
  [ -n "$out" ]
}

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
