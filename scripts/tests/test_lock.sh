#!/usr/bin/env bash
# The environment lock (lib/lock.sh, env.sh lock|unlock|wait): a running holder keeps it, a
# dead one loses it at once, an unanswerable runtime falls back to lock_ttl_min; the
# pre-flight reads the same states; `wait` reports the background install's own result.
. "$(dirname "$0")/lib.sh"
seed_work
mkdir -p "$SANDBOX/bin" "$WORK_DIR/env"
cat > "$SANDBOX/bin/curl" <<'S'
#!/usr/bin/env bash
case "$*" in (*/api/trpc/sessions.list*) ;; (*) exit 22;; esac
[ "${STUB_RUNTIME_DOWN:-0}" = 1 ] && exit 7
id="$(printf '%s' "$*" | sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p')"
[ "${STUB_UNFILTERED:-0}" = 1 ] && { printf '{"result":{"data":{"sessions":[{"id":"other","running":false}]}}}'; exit 0; }
case " ${STUB_RUNNING:-} " in
  (*" $id "*) printf '{"result":{"data":{"sessions":[{"id":"%s","running":true}]}}}' "$id";;
  (*) printf '{"result":{"data":{"sessions":[]}}}';;
esac
S
chmod +x "$SANDBOX/bin/curl"
export PATH="$SANDBOX/bin:$PATH" PLATFORM_RUNTIME_URL="http://runtime.test"
L="$WORK_DIR/env/LOCK"
lk() { local s="$1"; shift; CLAUDE_CODE_SESSION_ID="$s" bash "$SCRIPTS/env.sh" "$@" >/dev/null 2>"$SANDBOX/err"; echo $?; }
events() { cat "$WORK_DIR"/logs/events-*.jsonl 2>/dev/null | jq -sc "[.[] | select(.event == \"$1\")] | length"; }

assert_eq "a free lock is taken" 0 "$(lk sess-a lock issues)"
assert_eq "the line names owner, time and session" "issues sess-a" "$(awk '{print $1, $3}' "$L")"
assert_eq "its own session takes it again" 0 "$(lk sess-a lock issues)"
assert_eq "a running holder keeps it" 1 "$(STUB_RUNNING=sess-a lk sess-b lock regression)"
grep -q 'its session is running' "$SANDBOX/err" || { echo "  no 'running' reason: $(cat "$SANDBOX/err")"; FAILED=1; }
assert_eq "a dead holder loses it at once" 0 "$(STUB_RUNNING=sess-x lk sess-b lock regression)"
assert_eq "the new holder is written" "regression sess-b" "$(awk '{print $1, $3}' "$L")"
assert_eq "the takeover is logged" 1 "$(events env_lock_takeover)"
assert_eq "another session's unlock is a no-op" 0 "$(lk sess-a unlock regression)"
[ -f "$L" ] || { echo "  a foreign unlock removed the lock"; FAILED=1; }
assert_eq "own unlock" 0 "$(lk sess-b unlock regression)"
[ -f "$L" ] && { echo "  own unlock left the lock"; FAILED=1; }

# No runtime answer: age decides.
echo "issues $(iso_ago 20) sess-a" > "$L"
assert_eq "runtime down, young lock: busy" 1 "$(STUB_RUNTIME_DOWN=1 lk sess-b lock regression)"
echo "issues $(iso_ago 400) sess-a" > "$L"
assert_eq "runtime down, past the TTL: taken" 0 "$(STUB_RUNTIME_DOWN=1 lk sess-b lock regression)"
# A runtime that lists only other sessions says nothing about the holder: age decides.
echo "issues $(iso_ago 20) sess-a" > "$L"
assert_eq "only another session listed, young lock: busy" 1 "$(STUB_UNFILTERED=1 lk sess-b lock regression)"
# A line from before sessions: the same owner is re-entrant, another one waits for the TTL.
echo "issues $(iso_ago 20)" > "$L"
assert_eq "legacy line, same owner" 0 "$(lk sess-a lock issues)"
echo "issues $(iso_ago 20)" > "$L"
assert_eq "legacy line, other owner" 1 "$(lk sess-a lock regression)"
rm -f "$L"
[ -e "$WORK_DIR/env/LOCK.mutex" ] && { echo "  the mutex was left behind"; FAILED=1; }

# The mutex is a file created with O_EXCL (lock_take), never a mkdir: the uutils mkdir lets
# concurrent callers all succeed. A leftover older than a minute — also an older version's
# directory — is cleared.
. "$SCRIPTS/lib/lock.sh"
M="$SANDBOX/mutex"
lock_take "$M"; assert_eq "a free mutex is taken" 0 "$?"
lock_take "$M"; assert_eq "a held mutex is not taken again" 1 "$?"
lock_mutex "$M" 2; assert_eq "a young mutex makes lock_mutex give up" 1 "$?"
rm -f "$M"; mkdir "$M"; touch -t 202001010000 "$M"
lock_mutex "$M" 2; assert_eq "an old leftover directory is cleared, then taken" 0 "$?"
[ -f "$M" ] || { echo "  the mutex is not a file"; FAILED=1; }
for i in 1 2 3 4 5 6 7 8; do ( lock_take "$SANDBOX/race" && echo won ) & done > "$SANDBOX/race.out"; wait
assert_eq "of concurrent takers exactly one wins" 1 "$(grep -c won "$SANDBOX/race.out")"

# up keeps its result for wait; unlock refuses while an install still runs.
assert_eq "up through the profile" 0 "$(lk sess-a up 1.0.0)"
assert_eq "UP records the result and its session" "done 1.0.0 0 sess-a" "$(awk '{print $1, $2, $4, $5}' "$WORK_DIR/env/UP")"
grep -q 'took_s=' <<<"$(cat "$WORK_DIR"/logs/events-*.jsonl)" || { echo "  env_up carries no duration"; FAILED=1; }
assert_eq "wait after a successful up" 0 "$(lk sess-a wait 1.0.0 1)"
assert_eq "wait for another build" 1 "$(lk sess-a wait 2.0.0 1)"
assert_eq "wait from another session never reads this result" 1 "$(lk sess-b wait 1.0.0 1)"
echo "done 1.0.0 $(iso_ago 1) 1 sess-a" > "$WORK_DIR/env/UP"
assert_eq "wait after a failed up" 1 "$(lk sess-a wait 1.0.0 1)"
sleep 30 & bg=$!
echo "running 1.0.0 $(iso_ago 1) $bg sess-a" > "$WORK_DIR/env/UP"
assert_eq "wait while it runs: call again" 3 "$(lk sess-a wait 1.0.0 0)"
lk sess-a lock issues >/dev/null
assert_eq "unlock refused while it runs" 1 "$(lk sess-a unlock issues)"
kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null
assert_eq "wait on a dead install" 1 "$(lk sess-a wait 1.0.0 1)"
assert_eq "unlock once it is gone" 0 "$(lk sess-a unlock issues)"

# The pre-flight reads the same states.
echo "issues $(iso_ago 5) sess-a" > "$L"
out="$(STUB_RUNNING=sess-a bash "$SCRIPTS/preflight.sh" issues)"
assert "a running holder makes the occurrence idle" '.nothing_to_do == true and (.logs | map(select(test("its session is running"))) | length) == 1' "$out"
echo "| 7 | x | c | b | - | in_progress | $(iso_ago 5) |" >> "$WORK_DIR/QA.md"
echo '[{"number":7,"title":"T","body":"b","labels":[{"name":"qa:ready"}]}]' > "$STUB_DIR/issues.json"
out="$(STUB_RUNNING=sess-x bash "$SCRIPTS/preflight.sh" issues)"
assert "a dead holder: its fresh row is taken over" '.issues_due[] | select(.issue == 7) | .kind == "takeover"' "$out"

# Slack: the environment's state and today's quota (slack_tests_per_day, default 3).
echo "issues $(iso_ago 5) sess-a" > "$L"
d="$(date -u +%Y-%m-%d)"
for i in 1 2; do printf '{"ts":"%sT01:00:0%sZ","event":"slack_test","msg":"issue=%s"}\n' "$d" "$i" "$i" >> "$WORK_DIR/logs/events-$d.jsonl"; done
out="$(STUB_RUNNING=sess-a bash "$SCRIPTS/preflight.sh" slack)"
assert "slack: busy environment, one test left" '.mode == "slack" and .environment.busy == true and .environment.holder == "issues" and .tests_today == 2 and .quota_left == 1 and .channel == null' "$out"
printf -- '- slack_channel: C0123ABCD\n- slack_tests_per_day: 2\n' >> "$WORK_DIR/CONFIG.md"
out="$(STUB_RUNNING=sess-x bash "$SCRIPTS/preflight.sh" slack)"
assert "slack: a dead holder is not busy; quota spent" '.environment.busy == false and .environment.state == "dead" and .quota_left == 0 and .channel == "C0123ABCD"' "$out"
exit $FAILED
