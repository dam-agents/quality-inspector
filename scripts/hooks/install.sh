#!/usr/bin/env bash
# install.sh — register the policy hook (policy.sh, PreToolUse), the backup hook (backup.sh,
# Stop) and the static deny list in the harness's user settings (docs/black-box.md →
# Enforcement layers; docs/persistence.md → Backup & restore). The one home of the
# registration and its check.
#
#   install.sh           merge into $HOME/.claude/settings.json: created when missing, every
#                        other key kept, re-running changes nothing. Effective next session.
#   install.sh --check   read-only: exit 0 iff both hooks are registered and executable, hooks
#                        are not disabled, and every deny rule is present. One line on stdout.
#
# QI_CLAUDE_SETTINGS overrides the settings path (tests).

set -u
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="${QI_CLAUDE_SETTINGS:-${HOME:-/home/agent}/.claude/settings.json}"
HOOK_CMD='"$HOME"/scripts/hooks/policy.sh'
BACKUP_CMD='"$HOME"/scripts/hooks/backup.sh'
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

mkdir -p "$(dirname "$SETTINGS")" || { echo "cannot create $(dirname "$SETTINGS")" >&2; exit 1; }
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 || { echo "$SETTINGS is not a JSON object — left untouched; fix it by hand" >&2; exit 1; }
tmp="$SETTINGS.qi-tmp.$$"
jq --arg m "$MATCHER" --arg c "$HOOK_CMD" --arg b "$BACKUP_CMD" --argjson d "$DENY" '
  .hooks = (.hooks // {})
  | .hooks.PreToolUse = ([(.hooks.PreToolUse // [])[] | select(any(.hooks[]?; .command == $c) | not)]
                         + [{matcher: $m, hooks: [{type: "command", command: $c, timeout: 10}]}])
  | .hooks.Stop = ([(.hooks.Stop // [])[] | select(any(.hooks[]?; .command == $b) | not)]
                   + [{hooks: [{type: "command", command: $b, timeout: 30}]}])
  | .permissions = (.permissions // {})
  | .permissions.deny = ((.permissions.deny // []) as $have | $have + ($d - $have))' "$SETTINGS" > "$tmp" \
  && mv -f "$tmp" "$SETTINGS" || { rm -f "$tmp"; echo "merge into $SETTINGS failed" >&2; exit 1; }
chmod +x "$HERE/policy.sh" "$HERE/backup.sh" 2>/dev/null || true
echo "policy and backup hooks registered in $SETTINGS"
