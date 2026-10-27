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

# transcript_operator_words <transcript.jsonl>: prints the text of the session's newest prompt
# when the operator wrote it — a prompt that holds no frame (a scheduled run continued from the
# UI, or the operator's own dashboard button beside it) — or fails. A prompt is the same closed
# set of line shapes as above, a harness `isMeta` line with no origin left out. Only a closed
# set of prompts is the operator's: a `user` line whose `origin` is absent or of kind `human`,
# and a `queued_command` with `commandMode` `prompt`, no `isMeta` and such an origin. Any other
# prompt — a sub-agent's hand-back (`peer`), a task notification — has another author, and so
# has a line that does not parse or does not have the shape: after one there are no words
# (docs/persistence.md → Handoff).
transcript_operator_words() {
  local f="${1:-}" out
  [ -n "$f" ] && [ -r "$f" ] || return 1
  out="$(jq -Rr '
    def human: .origin == null or ((.origin | type) == "object" and .origin.kind == "human");
    (fromjson? // "unparsable") as $l
    | try (
        if ($l | type) != "object" then {bad: true}
        elif $l.type == "user" and $l.isCompactSummary != true then
          ($l.message.content
           | if type == "string" then {text: .}
             elif type == "array" and all(.[]; .type != "tool_result") then {text: (map(select(.type == "text") | .text) | join("\n"))}
             else empty end)
          | if ($l | human | not) then {bad: true} elif $l.isMeta == true then empty else . end
        elif $l.type == "attachment" and $l.attachment.type == "queued_command" then
          if $l.isMeta != true and ($l.attachment | .commandMode == "prompt" and .isMeta != true and human)
          then {text: ($l.attachment.prompt | tostring)} else {bad: true} end
        else empty end
      ) catch {bad: true}
    | tojson' "$f" 2>/dev/null | tail -1 | jq -r --arg s "$SCHEDULED_FRAME" --arg v "$ARTIFACT_VIEWER_FRAME" '
      select(.bad != true and (.text | type) == "string")
      | .text | select(contains($s) or contains("<how-to-respond>") or contains($v) | not)' 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
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
