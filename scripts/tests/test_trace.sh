#!/usr/bin/env bash
# scripts/hooks/trace.sh: turn_start / tool_failed / turn_end from the harness's hook input —
# silent, never a prompt or a credential; install.sh registers it per harness version; the
# audit's trace_hooks, unfinished_runs and tool_failures read what it wrote (docs/logging.md →
# Harness trace).
. "$(dirname "$0")/lib.sh"
seed_work
echo '[]' > "$STUB_DIR/issues.json"
export HOME="$SANDBOX"
HOOK="$SCRIPTS/hooks/trace.sh"
day="$(date -u +%Y-%m-%d)"
LOG="$WORK_DIR/logs/events-$day.jsonl"
hook() { # <event> <session> [jq object merged into the input]
  local x="${3:-}" out; [ -n "$x" ] || x='{}'
  out="$(jq -nc --arg e "$1" --arg s "$2" --argjson x "$x" '{hook_event_name:$e, session_id:$s} + $x' | "$HOOK")"
  local rc=$?; [ -z "$out" ] || { echo "  assertion failed: $1 printed '$out'"; FAILED=1; }
  [ "$rc" = 0 ] || { echo "  assertion failed: $1 exited $rc"; FAILED=1; }
}
events() { jq -sc --arg e "$1" '[.[] | select(.event == $e)]' "$LOG" 2>/dev/null; }

# A channel turn: one call done, a grep without a match (counted only), one real failure.
printf 'E2E_USER_ALICE_PASSWORD=hunter2-sekret\n' > "$WORK_DIR/env/credentials.env"
hook UserPromptSubmit sess-a '{"prompt":"<how-to-respond>please test the login of alice</how-to-respond>"}'
hook PostToolUse sess-a '{"tool_name":"Read"}'
hook PostToolUseFailure sess-a '{"tool_name":"Bash","error":"Exit code 1","duration_ms":4}'
hook PostToolUseFailure sess-a '{"tool_name":"Bash","error":"Exit code 22\ncurl: (22) 401 for alice:hunter2-sekret token ghp_abcdefghijklmnopqrstuvwxyz0123","duration_ms":812,"agent_type":"general-purpose"}'
hook Stop sess-a
s="$(events turn_start)"
assert "a channel turn starts, its prompt only as size and hash" \
  'length == 1 and .[0].job == "channel" and .[0].run == "sess-a" and (.[0].msg | test("^kind=channel bytes=[0-9]+ sha=[0-9a-f]{12}$"))' "$s"
f="$(events tool_failed)"
assert "a failure logs once, with tool, code, agent and duration — the benign exit 1 only counts" \
  'length == 1 and .[0].level == "warn" and (.[0].msg | test("^tool=Bash code=22 agent=general-purpose ms=812 err=curl: \\(22\\) 401"))' "$f"
assert "the error's credential value and token are masked" \
  '(.[0].msg | test("hunter2|ghp_[a-z]") | not)' "$f"
# A token that the 160-character cut would split is masked first, never cut.
pad="$(printf 'x%.0s' $(seq 140))"
hook PostToolUseFailure sess-cut "$(jq -nc --arg e "Exit code 22
$pad ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" '{tool_name:"Bash", error:$e}')"
assert "a token at the excerpt's cut is masked, never cut" \
  '[.[] | select(.run == "sess-cut")] | length == 1 and (.[0].msg | test("ghp_") | not) and (.[0].msg | test("err=x{140} gh[*]_MASK"))' "$(events tool_failed)"
e="$(events turn_end)"
assert "the turn ends with its counts" '.[0].msg | test("^status=ok kind=channel secs=[0-9]+ tools=3 failed=2$")' "$e"
assert "no line holds the prompt" '[.[] | .msg | test("login of alice")] | any | not' "$(jq -sc . "$LOG")"
[ -e "$WORK_DIR/env/turns/sess-a" ] && { echo "  assertion failed: the turn's state outlived its end"; FAILED=1; }

# A scheduled turn takes its job from the Precheck's frame in its prompt;
# a prompt that follows a turn that never stopped closes it as interrupted; an API error ends one.
hook UserPromptSubmit sess-b '{"prompt":"QA issues run. Run the pre-flight first.\n<qi-scheduled-run>issues</qi-scheduled-run>\n{\"mode\":\"issues\"}"}'
hook PostToolUse sess-b '{"tool_name":"Bash"}'
hook UserPromptSubmit sess-b '{"prompt":"go on"}'
hook StopFailure sess-b '{"error":"rate_limit"}'
s="$(events turn_start | jq -c '[.[] | select(.run == "sess-b")]')"
assert "a scheduled turn names its job; a later prompt in it is direct" \
  '.[0].job == "issues" and (.[0].msg | test("^kind=scheduled bytes=")) and .[1].job == "session" and (.[1].msg | test("^kind=direct "))' "$s"
e="$(events turn_end | jq -c '[.[] | select(.run == "sess-b")]')"
assert "the unstopped turn ends interrupted (warn), the API error as its status (error)" \
  '.[0].level == "warn" and (.[0].msg | test("^status=interrupted kind=scheduled secs=[0-9]+ tools=1 failed=0$"))
   and .[1].level == "error" and (.[1].msg | test("^status=rate_limit kind=direct "))' "$e"

# Calls of a turn whose start it missed still count; bad input is silent and exits 0.
hook PostToolUse sess-c '{"tool_name":"Read"}'
hook Stop sess-c
assert "a turn without a seen start ends with secs=-" \
  '[.[] | select(.run == "sess-c")] | .[0].msg | test("^status=ok kind=- secs=- tools=1 failed=0$")' "$(events turn_end)"
out="$(printf 'not json' | "$HOOK")"; assert_eq "unparsable input exits 0" 0 "$?"; assert_eq "and prints nothing" "" "$out"
hook Stop '../evil'
assert_eq "a session id that is not a name writes nothing" 0 "$(find "$WORK_DIR/env" -name '*evil*' | wc -l | tr -d ' ')"

# install.sh: the failure events only on a harness that has them; the trace check names the gap.
export QI_CLAUDE_SETTINGS="$SANDBOX/trace-settings.json"
QI_CLAUDE_VERSION=2.1.90 bash "$SCRIPTS/hooks/install.sh" >/dev/null
st="$(cat "$QI_CLAUDE_SETTINGS")"
assert "an old harness gets no event it would void the settings over" \
  '(.hooks | has("PostToolUseFailure") or has("StopFailure") | not) and (.hooks.UserPromptSubmit | length) == 1 and (.hooks.Stop | length) == 2' "$st"
o="$(QI_CLAUDE_VERSION=2.1.90 bash "$SCRIPTS/hooks/install.sh" --check-trace)"; assert_eq "the trace check flags the old harness" 1 "$?"
case "$o" in (*"predates 2.1.101"*) ;; (*) echo "  assertion failed: check-trace said '$o'"; FAILED=1;; esac
QI_CLAUDE_VERSION=2.1.160 bash "$SCRIPTS/hooks/install.sh" >/dev/null && QI_CLAUDE_VERSION=2.1.160 bash "$SCRIPTS/hooks/install.sh" >/dev/null
st="$(cat "$QI_CLAUDE_SETTINGS")"
assert "a current harness gets every trace event once, and the backup on StopFailure too" \
  '([.hooks.UserPromptSubmit, .hooks.PostToolUse, .hooks.PostToolUseFailure] | map(length) == [1,1,1])
   and (.hooks.Stop | length) == 2 and (.hooks.StopFailure | map(.hooks[0].command) | sort) == ["\"$HOME\"/scripts/hooks/backup.sh","\"$HOME\"/scripts/hooks/trace.sh"]' "$st"
QI_CLAUDE_VERSION=2.1.160 bash "$SCRIPTS/hooks/install.sh" --check-trace >/dev/null; assert_eq "the trace check passes" 0 "$?"
bash "$SCRIPTS/hooks/install.sh" --check >/dev/null; assert_eq "the gate's check is unchanged by the trace hook" 0 "$?"
jq '.hooks.PostToolUse = []' "$QI_CLAUDE_SETTINGS" > "$SANDBOX/s" && mv "$SANDBOX/s" "$QI_CLAUDE_SETTINGS"
o="$(QI_CLAUDE_VERSION=2.1.160 bash "$SCRIPTS/hooks/install.sh" --check-trace)"
assert_eq "the trace check names a missing event" "trace hook not registered for PostToolUse — run scripts/hooks/install.sh" "$o"
bash "$SCRIPTS/hooks/install.sh" --check >/dev/null; assert_eq "while the gate still passes" 0 "$?"

# The audit: a clean week is ok; then a turn that never ended, an issue left mid-pipeline in a
# session that logged no error, an API-error stop and a loop of one failing command.
export QI_CLAUDE_SETTINGS="$SANDBOX/claude-settings.json" QI_CLAUDE_VERSION=2.1.160
bash "$SCRIPTS/hooks/install.sh" >/dev/null
rm -f "$LOG"
hook UserPromptSubmit ok-1 '{"prompt":"hi"}'; hook PostToolUse ok-1 '{"tool_name":"Read"}'; hook Stop ok-1
chk() { jq -c --arg id "$1" '.checks[] | select(.id == $id)' <<<"$audit"; }
audit="$(bash "$SCRIPTS/preflight.sh" audit 2>/dev/null)"
assert "trace hooks ok" '.status == "ok"' "$(chk trace_hooks)"
assert "a clean week: unfinished_runs ok" '.status == "ok"' "$(chk unfinished_runs)"
assert "a clean week: tool_failures ok, counted" '.status == "ok" and .detail == "0 failed tool calls in 1 turns"' "$(chk tool_failures)"
assert "the week's turns in stats" '.stats.turns_7d | .turns == 1 and .by_kind.direct == 1 and .tool_calls == 1 and .tool_failures == 0' "$audit"

old="$(iso_ago 300)"
ev() { jq -nc --arg ts "$old" --arg r "$1" --arg j "$2" --arg l "$3" --arg e "$4" --arg m "$5" \
  '{ts:$ts, run:$r, job:$j, level:$l, event:$e, msg:$m}' >> "$LOG"; }
ev crashed-run-1 issues info turn_start "kind=scheduled bytes=10 sha=abcdefabcdef"
ev crashed-run-1 issues info issue_start "issue=12 kind=first"
ev crashed-run-1 issues info issue_milestone "issue=12 step=freeze"
ev done-run-2 issues info turn_start "kind=scheduled bytes=10 sha=abcdefabcdef"
ev done-run-2 issues info issue_start "issue=13 kind=first"
ev done-run-2 issues info issue_done "issue=13 verdict=verified minutes=20 model_steps=80"
ev done-run-2 issues info turn_end "status=ok kind=scheduled secs=1200 tools=90 failed=0"
ev api-run-3 regression info turn_start "kind=scheduled bytes=10 sha=abcdefabcdef"
ev api-run-3 regression error turn_end "status=rate_limit kind=scheduled secs=60 tools=4 failed=0"
for i in 1 2 3 4 5; do ev loop-run-4 session warn tool_failed "tool=Bash code=2 ms=1$i err=env.sh: build 0.2.$i not found"; done
audit="$(bash "$SCRIPTS/preflight.sh" audit 2>/dev/null)"
u="$(chk unfinished_runs)"
assert "the crashed turn, its open issue (silent) and the API error warn" \
  '.status == "warn" and (.detail | test("1 turn\\(s\\) never ended: issues crashed- \\(silent: no error logged\\)"))
   and (.detail | test("work left mid-pipeline: #12 in crashed- \\(silent"))
   and (.detail | test("#13") | not) and (.detail | test("API error \\(rate_limit×1\\)"))' "$u"
assert "the loop warns, one signature across build numbers" \
  '.status == "warn" and (.detail | test("^5 failed tool calls in 4 turns \\(Bash×5\\) — loops: Bash×5 in loop-run: env.sh: build N.N.N not found$"))' "$(chk tool_failures)"
assert "the API error joins the failures' signatures" \
  '[.failures[] | select(.signature | startswith("turn_end: status=rate_limit"))] | length == 1' "$audit"
exit $FAILED
