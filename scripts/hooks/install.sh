#!/usr/bin/env bash
# install.sh — register the policy hook (policy.sh, PreToolUse), the backup hook (backup.sh,
# Stop), the trace hook (trace.sh) and the static deny list in the harness's user settings
# (docs/black-box.md → Enforcement layers; docs/persistence.md → Backup & restore;
# docs/logging.md → Harness trace). The one home of the registration and its checks.
#
#   install.sh                merge into $HOME/.claude/settings.json: created when missing, every
#                             other key kept, re-running changes nothing. Effective next session.
#   install.sh --check        read-only, the gate's: exit 0 iff the policy and backup hooks are
#                             registered and executable, hooks are not disabled, and every deny
#                             rule is present. One line on stdout.
#   install.sh --check-trace  read-only, the audit's: exit 0 iff the trace hook is registered for
#                             every event this harness has. One line on stdout.
#
# A harness before FAILURE_EVENTS_MIN (below) ignores the whole settings file over an event it does not
# know, so PostToolUseFailure and StopFailure are registered only on a harness that has them
# (`claude --version`); re-run this after a harness upgrade. QI_CLAUDE_SETTINGS overrides the
# settings path, QI_CLAUDE_VERSION the harness version (tests).

set -u
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="${QI_CLAUDE_SETTINGS:-${HOME:-/home/agent}/.claude/settings.json}"
HOOK_CMD='"$HOME"/scripts/hooks/policy.sh'
BACKUP_CMD='"$HOME"/scripts/hooks/backup.sh'
TRACE_CMD='"$HOME"/scripts/hooks/trace.sh'
TRACE_EVENTS='["UserPromptSubmit","PostToolUse","Stop"]'
FAILURE_EVENTS='["PostToolUseFailure","StopFailure"]'
FAILURE_EVENTS_MIN=2.1.101   # unknown hook events stopped voiding settings.json (Claude Code changelog)
MATCHER='Bash|Read|Glob|Grep|Write|Edit|MultiEdit|NotebookEdit|WebFetch|WebSearch'
# Defence in depth for what static patterns can express; policy.sh holds the full rules.
DENY='["Bash(git clean:*)","Bash(kubectl exec:*)","Bash(kubectl cp:*)","Bash(k3s kubectl exec:*)",
"Bash(k3s kubectl cp:*)","Bash(k3s ctr:*)","Bash(ctr:*)","Bash(crictl:*)",
"Bash(gh:*)","Bash(git clone:*)","Bash(git pull:*)","Bash(git push:*)","Bash(git ls-remote:*)",
"WebFetch(domain:github.com)","WebFetch(domain:api.github.com)","WebFetch(domain:gist.github.com)",
"WebFetch(domain:raw.githubusercontent.com)","WebFetch(domain:codeload.github.com)",
"Read(~/work/env/**/templates/**)","Read(//tmp/quality-inspector-chart-*/**)","Read(~/work/**/*.map)"]'

if [ "${1:-}" = --check ]; then
  for h in policy.sh backup.sh; do
    [ -x "$HERE/$h" ] && bash -n "$HERE/$h" 2>/dev/null \
      || { echo "scripts/hooks/$h is missing, not executable or has a syntax error"; exit 1; }
  done
  [ -f "$SETTINGS" ] || { echo "$SETTINGS missing"; exit 1; }
  why="$(jq -r --arg m "$MATCHER" --arg c "$HOOK_CMD" --arg b "$BACKUP_CMD" --argjson d "$DENY" '
    [ (if ([.hooks.PreToolUse[]? | select(.matcher == $m) | .hooks[]? | select(.type == "command" and .command == $c)]
           | length) == 0 then "policy hook not registered" else empty end),
      (if ([.hooks.Stop[]? | .hooks[]? | select(.type == "command" and .command == $b)]
           | length) == 0 then "backup hook not registered" else empty end),
      (if .disableAllHooks == true then "disableAllHooks is set" else empty end),
      (($d - (.permissions.deny // [])) | if length > 0 then "deny rules missing: " + join(", ") else empty end)
    ] | join("; ")' "$SETTINGS" 2>/dev/null)" || { echo "$SETTINGS is not valid JSON"; exit 1; }
  [ -z "$why" ] && { echo "policy and backup hooks registered, $(jq length <<<"$DENY") deny rules present"; exit 0; }
  echo "$why"; exit 1
fi

# The trace events this harness has: the failure events only from FAILURE_EVENTS_MIN on.
HARNESS="${QI_CLAUDE_VERSION:-$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1)}"
vge() { [ -n "$1" ] && [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]; }
if vge "$HARNESS" "$FAILURE_EVENTS_MIN"; then EVENTS="$(jq -c ". + $FAILURE_EVENTS" <<<"$TRACE_EVENTS")"; else EVENTS="$TRACE_EVENTS"; fi

if [ "${1:-}" = --check-trace ]; then
  [ -x "$HERE/trace.sh" ] && bash -n "$HERE/trace.sh" 2>/dev/null \
    || { echo "scripts/hooks/trace.sh is missing, not executable or has a syntax error"; exit 1; }
  missing="$(jq -r --arg c "$TRACE_CMD" --argjson e "$EVENTS" '
    [$e[] as $ev | select(([.hooks[$ev][]? | .hooks[]? | select(.type == "command" and .command == $c)] | length) == 0) | $ev]
    | join(", ")' "$SETTINGS" 2>/dev/null)" || { echo "$SETTINGS missing or not valid JSON"; exit 1; }
  [ -n "$missing" ] && { echo "trace hook not registered for $missing — run scripts/hooks/install.sh"; exit 1; }
  vge "$HARNESS" "$FAILURE_EVENTS_MIN" \
    || { echo "trace hook registered; Claude Code ${HARNESS:-of unknown version} predates $FAILURE_EVENTS_MIN, so failed tool calls and API-error stops are not traced"; exit 1; }
  echo "trace hook registered for $(jq -r 'join(", ")' <<<"$EVENTS")"; exit 0
fi

mkdir -p "$(dirname "$SETTINGS")" || { echo "cannot create $(dirname "$SETTINGS")" >&2; exit 1; }

# The platform writes this file too: take $SETTINGS.lock (text `<pid>:<word>`, an exclusive create)
# for the whole read-modify-write, the `{}` bootstrap included, and read only after it is held
# (dam docs/architecture/starter-kits.md → Kit Writes Into the Agent's Home). Wait up to
# QI_LOCK_WAIT seconds; break a lock older than 30 s whose holder is gone; release only our own.
LOCK="$SETTINGS.lock"; LOCK_TEXT="$$:quality-inspector"; tmp=""
lock_age() { local m; m="$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null)" || return 1; echo $(( $(date +%s) - m )); }
release() { [ -z "$tmp" ] || rm -f "$tmp"; [ "$(cat "$LOCK" 2>/dev/null)" = "$LOCK_TEXT" ] && rm -f "$LOCK"; return 0; }
trap release EXIT
deadline=$(( $(date +%s) + ${QI_LOCK_WAIT:-10} ))
until ( set -o noclobber; printf '%s' "$LOCK_TEXT" > "$LOCK" ) 2>/dev/null; do
  held="$(cat "$LOCK" 2>/dev/null)"; age="$(lock_age)" || continue   # gone between the create and the read: retry
  hpid="${held%%:*}"
  if [ "${age:-0}" -gt 30 ] && ! { [ -n "$hpid" ] && [ "$hpid" -eq "$hpid" ] 2>/dev/null && kill -0 "$hpid" 2>/dev/null; }; then
    [ "$(cat "$LOCK" 2>/dev/null)" = "$held" ] && rm -f "$LOCK"; continue
  fi
  [ "$(date +%s)" -lt "$deadline" ] || { echo "$LOCK is held by '$held' — $SETTINGS left untouched; run again" >&2; exit 1; }
  sleep 0.2
done
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 || { echo "$SETTINGS is not a JSON object — left untouched; fix it by hand" >&2; exit 1; }
tmp="$SETTINGS.qi-tmp.$$"
jq --arg m "$MATCHER" --arg c "$HOOK_CMD" --arg b "$BACKUP_CMD" --arg t "$TRACE_CMD" --argjson e "$EVENTS" \
   --argjson d "$DENY" '
  def drop($cmd): [.[] | select(any(.hooks[]?; .command == $cmd) | not)];
  .hooks = (.hooks // {})
  | .hooks.PreToolUse = ([(.hooks.PreToolUse // [])[] | select(any(.hooks[]?; .command == $c) | not)]
                         + [{matcher: $m, hooks: [{type: "command", command: $c, timeout: 10}]}])
  | .hooks.Stop = ([(.hooks.Stop // [])[] | select(any(.hooks[]?; .command == $b) | not)]
                   + [{hooks: [{type: "command", command: $b, timeout: 30}]}])
  | reduce $e[] as $ev (.; .hooks[$ev] = ((.hooks[$ev] // []) | drop($t)) + [{hooks: [{type: "command", command: $t, timeout: 10}]}])
  | if ($e | index("StopFailure")) then .hooks.StopFailure = ((.hooks.StopFailure // [] | drop($b)) + [{hooks: [{type: "command", command: $b, timeout: 30}]}]) else . end
  | .permissions = (.permissions // {})
  | .permissions.deny = ((.permissions.deny // []) as $have | $have + ($d - $have))' "$SETTINGS" > "$tmp" \
  && mv -f "$tmp" "$SETTINGS" || { echo "merge into $SETTINGS failed" >&2; exit 1; }
tmp=""; release
chmod +x "$HERE/policy.sh" "$HERE/backup.sh" "$HERE/trace.sh" 2>/dev/null || true
echo "policy, backup and trace hooks registered in $SETTINGS (trace: $(jq -r 'join(", ")' <<<"$EVENTS"))"
