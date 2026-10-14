#!/usr/bin/env bash
# scripts/hooks/policy.sh against policy-fixtures.jsonl (every rule id has a deny fixture;
# removing a denial fails here), plus the settings merge and its check (install.sh).
. "$(dirname "$0")/lib.sh"
HOOK="$SCRIPTS/hooks/policy.sh"; DEF="$(cd "$SCRIPTS/.." && pwd)"
export HOME="$SANDBOX/home"; mkdir -p "$HOME" "$WORK_DIR/env"
# profile_source_path opens the egress for the platform and the probe, never for a tool call.
printf -- '- target_repo: acme/widgets\n- profile_source_path: qa\n- lock_ttl_min: 180\n' > "$WORK_DIR/CONFIG.md"
pd="$SANDBOX/profile"; mkdir -p "$pd"; export QI_PROFILE_DIR="$pd"
cat > "$pd/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "boundary":{"urls":["https://docs.internal.example/{repo}/architecture/"],"packages":["@acme"]}}
J
[ -x "$HOOK" ] || { echo "  $HOOK is not executable"; exit 1; }

n=0
while IFS= read -r fx; do
  [ -n "$fx" ] || continue
  fx="$(printf '%s' "$fx" | sed -e "s|@WORK@|$WORK_DIR|g" -e "s|@HOME@|$HOME|g" -e "s|@DEF@|$DEF|g")"
  name="$(jq -r .name <<<"$fx")"; want="$(jq -r .expect <<<"$fx")"; rule="$(jq -r '.rule // ""' <<<"$fx")"
  case "$(jq -r '.mode // "direct"' <<<"$fx")" in
    (scheduled) printf 'scheduled %s -\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK_DIR/env/RUN_MODE";;
    (stale) printf 'scheduled %s -\n' "$(iso_ago 400)" > "$WORK_DIR/env/RUN_MODE"; touch -t 202001010000 "$WORK_DIR/env/RUN_MODE";;
    (*) rm -f "$WORK_DIR/env/RUN_MODE";;
  esac
  # A channel turn's transcript holds the platform's Slack frame; a direct one does not.
  case "$(jq -r '.mode // "direct"' <<<"$fx")" in
    (channel) printf '{"type":"user","message":{"content":"<how-to-respond>\\nreply …\\n</how-to-respond>"}}\n' > "$SANDBOX/transcript.jsonl";;
    (*) printf '{"type":"user","message":{"content":"promote #7"}}\n' > "$SANDBOX/transcript.jsonl";;
  esac
  call="$(jq -c --arg w "$WORK_DIR" --arg t "$SANDBOX/transcript.jsonl" '{session_id:"test", cwd:(.input.cwd // $w), hook_event_name:"PreToolUse",
            transcript_path:$t, tool_name:.tool, tool_input:(.input | del(.cwd))}' <<<"$fx")"
  err="$(printf '%s' "$call" | "$HOOK" 2>&1 >/dev/null)"; rc=$?
  case "$want:$rc" in
    (allow:0) ;;
    (deny:2) case "$err" in (*"($rule)"*) ;; (*) echo "  $name: denied by the wrong rule: $err"; FAILED=1;; esac;;
    (*) echo "  $name: expected $want, exit $rc ${err:+— $err}"; FAILED=1;;
  esac
  n=$((n + 1))
done < "$TESTS_DIR/policy-fixtures.jsonl"
[ "$n" -ge 20 ] || { echo "  only $n fixtures ran"; FAILED=1; }

ev="$(cat "$WORK_DIR"/logs/events-*.jsonl 2>/dev/null | jq -sc '[.[] | select(.event == "policy_denied")]')"
assert "every denial is logged" 'length > 20 and all(.msg | test("^tool=[A-Za-z]+ rule=[a-z-]+( at=[^ ]+)?$"))' "$ev"
assert "no query string reaches the log" 'all(.msg | test("[?]") | not)' "$ev"
printf 'not json' | "$HOOK" 2>/dev/null; assert_eq "unparsable input fails closed" 2 "$?"

# install.sh: merge keeps other keys, is idempotent, and its check sees a removal.
export QI_CLAUDE_SETTINGS="$HOME/.claude/settings.json"
bash "$SCRIPTS/hooks/install.sh" --check >/dev/null; assert_eq "check fails without settings" 1 "$?"
mkdir -p "$HOME/.claude"
echo '{"model":"x","permissions":{"deny":["Bash(rm -rf /:*)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}' > "$QI_CLAUDE_SETTINGS"
bash "$SCRIPTS/hooks/install.sh" >/dev/null && bash "$SCRIPTS/hooks/install.sh" >/dev/null
s="$(cat "$QI_CLAUDE_SETTINGS")"
assert "other keys kept" '.model == "x" and (.hooks.Stop | length) == 1 and (.permissions.deny | index("Bash(rm -rf /:*)")) == 0' "$s"
assert "registered once" '(.hooks.PreToolUse | length) == 1 and (.permissions.deny | length) == (.permissions.deny | unique | length)' "$s"
bash "$SCRIPTS/hooks/install.sh" --check >/dev/null; assert_eq "check passes after install" 0 "$?"
audit="$(bash "$SCRIPTS/preflight.sh" audit 2>/dev/null)"
assert "audit sees the hook" '.checks[] | select(.id == "policy_hook") | .status == "ok"' "$audit"
assert "audit warns on many refusals" '.checks[] | select(.id == "policy_denied") | .status == "warn" and (.detail | test("git-clean×[0-9]+"))' "$audit"
jq '.permissions.deny -= ["Bash(git clean:*)"]' "$QI_CLAUDE_SETTINGS" > "$SANDBOX/s" && mv "$SANDBOX/s" "$QI_CLAUDE_SETTINGS"
bash "$SCRIPTS/hooks/install.sh" --check >/dev/null; assert_eq "check sees a missing deny rule" 1 "$?"
exit $FAILED
