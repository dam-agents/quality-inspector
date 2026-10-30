#!/usr/bin/env bash
# env.sh resume and the SessionStart hook (docs/nested-env.md → After a VM restart): after a boot,
# the build of the last successful `up` from before it comes back once, in the background, with
# its output in work/env/last-resume.log; nothing without such an up, after a failed one, after
# `down` or `reset`, or a second time in one boot. A run's `up` waits for a resume to end.
. "$(dirname "$0")/lib.sh"
seed_work
E="$WORK_DIR/env"; mkdir -p "$E"
cat > "$QI_PROFILE_DIR/bin/env" <<'S'
#!/usr/bin/env bash
echo "$1 ${2:-} start $(date +%s.%N)" >> "$STUB_DIR/calls"
[ "$1" = up ] && { echo "installing $2"; sleep "${STUB_UP_SLEEP:-0}"; [ -n "${STUB_UP_FAIL:-}" ] && exit "$STUB_UP_FAIL"; }
echo "$1 ${2:-} end $(date +%s.%N)" >> "$STUB_DIR/calls"
[ "$1" = status ] && echo '{"running":true,"build":"1.0.0","ui_http":"200"}'
exit 0
S
echo "- nested_target: vm" >> "$WORK_DIR/CONFIG.md"
echo vm > "$E/TARGET"
NOW="$(date -u +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
resume() { QI_BOOT_EPOCH="$1" bash "$SCRIPTS/env.sh" resume 2>/dev/null; }
settle() { local i; for i in $(seq 1 100); do grep -q '^running' "$E/RESUME" 2>/dev/null || return 0; sleep 0.2; done; }
ups() { cat "$STUB_DIR/calls" 2>/dev/null | grep -c "^up $1 start"; }

assert_eq "no up yet: nothing to resume" "" "$(resume "$NOW")"
[ -f "$E/RESUME" ] && { echo "  RESUME written without an up"; FAILED=1; }

printf 'done 1.0.0 %s 0 -\n' "$(iso $((NOW - 3600)))" > "$E/UP"
assert_eq "the up is from this boot: nothing" "" "$(resume $((NOW - 7200)))"

out="$(resume $((NOW - 60)))"
case "$out" in (*"brings build 1.0.0 back"*) ;; (*) echo "  no line for the session: '$out'"; FAILED=1;; esac
settle
assert_eq "the profile's up ran once at the same build" 1 "$(ups 1.0.0)"
read -r st b _ rc _ < "$E/RESUME"
assert_eq "RESUME records the result" "done 1.0.0 0" "$st $b $rc"
grep -q 'installing 1.0.0' "$E/last-resume.log" || { echo "  output not in last-resume.log"; FAILED=1; }
assert_eq "UP is left as the last up wrote it" "done 1.0.0" "$(cut -d' ' -f1,2 "$E/UP")"
assert_eq "an env_resume event" 2 "$(cat "$WORK_DIR"/logs/events-*.jsonl | jq -sc '[.[] | select(.event == "env_resume")] | length')"

assert_eq "a second session in the same boot: nothing" "" "$(resume $((NOW - 60)))"
settle; assert_eq "no second up" 1 "$(ups 1.0.0)"

later=$(( $(date -u +%s) + 5 ))
resume "$later" >/dev/null; settle
assert_eq "the next boot resumes again" 2 "$(ups 1.0.0)"

later=$((later + 5))
bash "$SCRIPTS/env.sh" down >/dev/null 2>&1; sleep 1
assert_eq "after down: nothing" "" "$(resume "$later")"
QI_BOOT_EPOCH=$((later - 100)) bash "$SCRIPTS/env.sh" up 1.1.0 >/dev/null 2>&1
assert_eq "an up after the down turns it on again" 1 "$(resume $((later + 5)) | grep -c 'brings build 1.1.0 back')"
settle

bash "$SCRIPTS/env.sh" reset >/dev/null 2>&1
assert_eq "after reset: nothing" "" "$(resume $((later + 10)))"

printf 'done 1.2.0 %s 1 -\n' "$(iso $((NOW - 3600)))" > "$E/UP"; rm -f "$E/RESUME"
assert_eq "a failed up: nothing" "" "$(resume $((later + 10)))"

# A run's up waits for the resume: the two installs never overlap.
printf 'done 1.0.0 %s 0 -\n' "$(iso $((NOW - 3600)))" > "$E/UP"; rm -f "$E/RESUME"; : > "$STUB_DIR/calls"
STUB_UP_SLEEP=2 resume $((later + 20)) >/dev/null
sleep 0.5
bash "$SCRIPTS/env.sh" up 2.0.0 >/dev/null 2>&1; assert_eq "the run's up succeeds" 0 "$?"
r_end="$(awk '$1 == "up" && $2 == "1.0.0" && $3 == "end" {print $4}' "$STUB_DIR/calls")"
u_start="$(awk '$1 == "up" && $2 == "2.0.0" && $3 == "start" {print $4}' "$STUB_DIR/calls")"
assert_eq "the run's up starts after the resume ended" 1 "$(awk -v a="$r_end" -v b="$u_start" 'BEGIN {print (a != "" && b != "" && b >= a) ? 1 : 0}')"

# A failing resume: env_failed names its log, RESUME records the exit, the next up is not blocked.
printf 'done 1.0.0 %s 0 -\n' "$(iso $((NOW - 3600)))" > "$E/UP"; rm -f "$E/RESUME"
boot=$(( $(date -u +%s) - 1 ))
STUB_UP_FAIL=7 resume "$boot" >/dev/null; settle
read -r st b _ rc _ < "$E/RESUME"
assert_eq "a failed resume records its exit" "done 1.0.0 7" "$st $b $rc"
assert_eq "a failed resume logs env_failed" 1 "$(cat "$WORK_DIR"/logs/events-*.jsonl | jq -sc '[.[] | select(.event == "env_failed" and (.msg | test("resume of build 1.0.0 exited 7 .*last-resume.log")))] | length')"
assert_eq "no second resume in that boot" "" "$(resume "$boot")"; settle

# A resume past the limit: the next up stops it, records 143, logs it, and then runs.
printf 'done 1.0.0 %s 0 -\n' "$(iso $((NOW - 3600)))" > "$E/UP"; rm -f "$E/RESUME"; : > "$STUB_DIR/calls"
STUB_UP_SLEEP=60 resume $((later + 50)) >/dev/null
read -r _ _ _ rpid _ < "$E/RESUME"
QI_RESUME_WAIT_S=1 bash "$SCRIPTS/env.sh" up 2.0.0 >/dev/null 2>&1; assert_eq "the up after a stopped resume succeeds" 0 "$?"
kill -0 "$rpid" 2>/dev/null && { echo "  the resume still runs"; FAILED=1; kill "$rpid" 2>/dev/null; }
read -r st b _ rc _ < "$E/RESUME"
assert_eq "a stopped resume records 143" "done 1.0.0 143" "$st $b $rc"
assert_eq "the stop is logged" 1 "$(cat "$WORK_DIR"/logs/events-*.jsonl | jq -sc '[.[] | select(.event == "env_resume" and (.msg | test("stopped: after")))] | length')"
assert_eq "the run's up ran" 1 "$(ups 2.0.0)"

# reset and down run in the foreground: they stop a running resume at once, and turn it off.
for c in reset down; do
  printf 'done 1.0.0 %s 0 -\n' "$(iso $((NOW - 3600)))" > "$E/UP"; rm -f "$E/RESUME"
  STUB_UP_SLEEP=60 resume $((later + 60)) >/dev/null
  read -r _ _ _ rpid _ < "$E/RESUME"; t0=$(date -u +%s)
  bash "$SCRIPTS/env.sh" "$c" >/dev/null 2>&1
  assert_eq "$c returns at once during a resume" 1 "$(( $(date -u +%s) - t0 < 5 ? 1 : 0 ))"
  kill -0 "$rpid" 2>/dev/null && { echo "  $c: the resume still runs"; FAILED=1; kill "$rpid" 2>/dev/null; }
  assert_eq "$c turns the resume off" off "$(cut -d' ' -f1 "$E/RESUME")"
done
assert_eq "both stops are logged" 2 "$(cat "$WORK_DIR"/logs/events-*.jsonl | jq -sc '[.[] | select(.event == "env_resume" and (.msg | test("stopped: a (reset|down)")))] | length')"

# No target recorded (env.sh keep or release removed it): nothing resumed, nothing installed.
printf 'done 1.0.0 %s 0 -\n' "$(iso $((NOW - 3600)))" > "$E/UP"; rm -f "$E/RESUME" "$E/TARGET"; : > "$STUB_DIR/calls"
resume $((later + 70)) >/dev/null; settle
assert_eq "no target: exit 4" "done 1.0.0 4" "$(cut -d' ' -f1,2,4 "$E/RESUME")"
assert_eq "no target: no up" 0 "$(ups 1.0.0)"
echo vm > "$E/TARGET"

# A running record from before this boot is dead, even when its pid is alive (reused after a restart).
sleep 30 & alive=$!
printf 'running 1.0.0 %s %s\n' "$(iso $((NOW - 3600)))" "$alive" > "$E/RESUME"; : > "$STUB_DIR/calls"
t0=$(date -u +%s)
QI_BOOT_EPOCH=$((NOW - 60)) bash "$SCRIPTS/env.sh" up 2.1.0 >/dev/null 2>&1; assert_eq "the up after an old running record succeeds" 0 "$?"
assert_eq "it does not wait for the old pid" 1 "$(( $(date -u +%s) - t0 < 5 ? 1 : 0 ))"
kill -0 "$alive" 2>/dev/null; assert_eq "the old pid's process is not signalled" 0 "$?"
kill "$alive" 2>/dev/null

# The hook: input discarded, the line on stdout, exit 0; registered once by install.sh.
printf 'done 1.0.0 %s 0 -\n' "$(iso $((NOW - 3600)))" > "$E/UP"; rm -f "$E/RESUME"
out="$(echo '{"hook_event_name":"SessionStart","source":"resume"}' | QI_BOOT_EPOCH=$((later + 30)) bash "$SCRIPTS/hooks/resume.sh")"
assert_eq "the hook exits 0" 0 "$?"
case "$out" in (*"brings build 1.0.0 back"*) ;; (*) echo "  the hook printed '$out'"; FAILED=1;; esac
settle
bash "$SCRIPTS/hooks/install.sh" >/dev/null 2>&1
assert "SessionStart hook registered once" '[.hooks.SessionStart[] | .hooks[] | select(.command == "\"$HOME\"/scripts/hooks/resume.sh")] | length == 1' "$(cat "$QI_CLAUDE_SETTINGS")"
bash "$SCRIPTS/hooks/install.sh" --check-resume >/dev/null; assert_eq "--check-resume passes" 0 "$?"
jq 'del(.hooks.SessionStart)' "$QI_CLAUDE_SETTINGS" > "$SANDBOX/s" && mv "$SANDBOX/s" "$QI_CLAUDE_SETTINGS"
bash "$SCRIPTS/hooks/install.sh" --check-resume >/dev/null; assert_eq "--check-resume flags a missing hook" 1 "$?"

exit "$FAILED"
