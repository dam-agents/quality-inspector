#!/usr/bin/env bash
# scripts/hooks/policy.sh against policy-fixtures.jsonl (every rule id has a deny fixture;
# removing a denial fails here), plus the settings merge and its check (install.sh).
. "$(dirname "$0")/lib.sh"
HOOK="$SCRIPTS/hooks/policy.sh"; DEF="$(cd "$SCRIPTS/.." && pwd)"
export HOME="$SANDBOX/home"; mkdir -p "$HOME" "$WORK_DIR/env"
printf -- '- target_repo: acme/widgets\n- lock_ttl_min: 180\n' > "$WORK_DIR/CONFIG.md"
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
  # `old-marker`: a direct session beside the fresh run marker of an earlier version — no clock decides.
  case "$(jq -r '.mode // "direct"' <<<"$fx")" in
    (old-marker) printf 'scheduled %s -\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK_DIR/env/RUN_MODE";;
    (*) rm -f "$WORK_DIR/env/RUN_MODE";;
  esac
  # `marker`: the run marker `precheck.sh slack <n>` writes; `qa`: the status of #12's work/QA.md row.
  rm -f "$WORK_DIR/QA.md"
  mk="$(jq -r '.marker // ""' <<<"$fx")"
  [ -n "$mk" ] && printf '%s\n' "$mk" | sed -e "s|@NOW@|$(date -u +%Y-%m-%dT%H:%M:%SZ)|" -e "s|@OLD@|$(iso_ago 400)|" > "$WORK_DIR/env/RUN_MODE"
  qa="$(jq -r '.qa // ""' <<<"$fx")"
  [ -n "$qa" ] && printf '| issue | ac_hash | candidate | baseline | verdict | status | updated_utc |\n| --- | --- | --- | --- | --- | --- | --- |\n| 12 | abc | c1 | b1 | verified | %s | %s |\n' \
    "$qa" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WORK_DIR/QA.md"
  # A scheduled run's transcript holds the Precheck's frame in a prompt, a channel turn's the
  # platform's Slack frame; a direct one neither. `quoted`: a direct session whose tool results,
  # progress, compaction summary and own messages quote the frame (a Read of
  # docs/persistence.md). `garbled`: a frame line that does not parse. `no-transcript`: the
  # transcript cannot be read — that counts as scheduled. `attached`: a direct session whose
  # harness attached files that spell both frames out (CLAUDE.md as `instructions`, an edited
  # docs/persistence.md, a hook's context, a request log) — not a prompt. `queued-*`: the frame
  # in a prompt that waited in the queue (a `queued_command` attachment) — a prompt.
  tr="$SANDBOX/transcript.jsonl"
  printf '{"type":"user","message":{"content":"promote #7"}}\n' > "$tr"
  case "$(jq -r '.mode // "direct"' <<<"$fx")" in
    (scheduled) printf '{"type":"user","message":{"content":"QA issues run.\\n<qi-scheduled-run>issues</qi-scheduled-run>\\n{}"}}\n' > "$tr";;
    (sched-quoted) printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"<qi-scheduled-run>issues</qi-scheduled-run>"}]}}\n' >> "$tr"
      printf '{"type":"assistant","message":{"content":[{"type":"text","text":"a schedule prompt opens with <qi-scheduled-run>"}]}}\n' >> "$tr";;
    (sched-garbled) printf 'not json <qi-scheduled-run>\n' >> "$tr";;
    (attached) jq -nc --rawfile c "$DEF/CLAUDE.md" --rawfile d "$DEF/docs/persistence.md" '
        {type:"attachment", attachment:{type:"instructions", files:[{path:"/home/agent/CLAUDE.md", type:"Project", content:($c + $d)}]},
          rendered:[{content:($c + $d)}], renderedRole:"user"},
        {type:"attachment", attachment:{type:"edited_text_file", filename:"/home/agent/docs/persistence.md", snippet:$d}, rendered:[{content:$d}], renderedRole:"user"},
        {type:"attachment", attachment:{type:"hook_additional_context", content:["<qi-scheduled-run>issues</qi-scheduled-run>"]}},
        {type:"api-request-blob", message:{content:("<how-to-respond>" + $d)}},
        {type:"last-prompt", lastPrompt:"<qi-scheduled-run>"}' >> "$tr";;
    (queued-sched) printf '{"type":"attachment","attachment":{"type":"queued_command","prompt":"QA issues run.\\n<qi-scheduled-run>issues</qi-scheduled-run>","commandMode":"prompt"}}\n' >> "$tr";;
    (queued-slack) printf '{"type":"attachment","attachment":{"type":"queued_command","prompt":"<how-to-respond>\\nreply …\\n</how-to-respond>","commandMode":"prompt"}}\n' >> "$tr";;
    (no-transcript) tr="$SANDBOX/missing.jsonl";;
    (channel) printf '{"type":"user","message":{"content":"<how-to-respond>\\nreply …\\n</how-to-respond>"}}\n' >> "$tr";;
    (quoted) jq -nc --rawfile d "$DEF/docs/persistence.md" '
        {type:"assistant", message:{content:[{type:"text", text:"the frame <how-to-respond> marks a channel turn"},
          {type:"tool_use", name:"Bash", input:{command:"grep -n \"<how-to-respond>\" scripts/hooks/policy.sh"}}]}},
        {type:"user", message:{content:[{type:"tool_result", content:$d}]}, toolUseResult:{type:"text", file:{content:$d}}},
        {type:"progress", data:{message:{content:[{type:"tool_result", content:"<how-to-respond>"}]}}},
        {type:"user", isCompactSummary:true, message:{content:"The session read the <how-to-respond> rule."}}' >> "$tr";;
    (garbled) printf 'not json <how-to-respond>\n' >> "$tr";;
    # The platform's frame of a prompt from a shared dashboard's button (a viewer, never the
    # operator); `viewer-quoted`: the same frame inside a tool result only.
    (viewer) printf '{"type":"user","message":{"content":"bob@example.com sent this from a button on the interactive artifact \\"QI\\" (id a1).\\nMessage: module stress per-build"}}\n' >> "$tr";;
    (viewer-quoted) printf '{"type":"user","message":{"content":[{"type":"tool_result","content":"x sent this from a button on the interactive artifact \\"QI\\" (id a1)."}]}}\n' >> "$tr";;
  esac
  call="$(jq -c --arg w "$WORK_DIR" --arg t "$tr" '{session_id:"test", cwd:(.input.cwd // $w), hook_event_name:"PreToolUse",
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
assert "other keys kept" '.model == "x" and .hooks.Stop[0].hooks[0].command == "true" and (.permissions.deny | index("Bash(rm -rf /:*)")) == 0' "$s"
assert "registered once" '(.hooks.PreToolUse | length) == 1 and (.hooks.Stop | length) == 2 and (.permissions.deny | length) == (.permissions.deny | unique | length)' "$s"
assert "backup hook on Stop, no matcher" '.hooks.Stop[1] | (has("matcher") | not) and .hooks[0].command == "\"$HOME\"/scripts/hooks/backup.sh"' "$s"
bash "$SCRIPTS/hooks/install.sh" --check >/dev/null; assert_eq "check passes after install" 0 "$?"
audit="$(bash "$SCRIPTS/preflight.sh" audit 2>/dev/null)"
assert "audit sees the hook" '.checks[] | select(.id == "policy_hook") | .status == "ok"' "$audit"
assert "audit warns on many refusals" '.checks[] | select(.id == "policy_denied") | .status == "warn" and (.detail | test("git-clean×[0-9]+"))' "$audit"
jq '.hooks.Stop |= .[:1]' "$QI_CLAUDE_SETTINGS" > "$SANDBOX/s" && cp "$QI_CLAUDE_SETTINGS" "$SANDBOX/full" && mv "$SANDBOX/s" "$QI_CLAUDE_SETTINGS"
assert_eq "check sees a missing backup hook" "backup hook not registered" "$(bash "$SCRIPTS/hooks/install.sh" --check)"
mv "$SANDBOX/full" "$QI_CLAUDE_SETTINGS"
jq '.permissions.deny -= ["Bash(git clean:*)"]' "$QI_CLAUDE_SETTINGS" > "$SANDBOX/s" && mv "$SANDBOX/s" "$QI_CLAUDE_SETTINGS"
bash "$SCRIPTS/hooks/install.sh" --check >/dev/null; assert_eq "check sees a missing deny rule" 1 "$?"
exit $FAILED
