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
[ "$1" = up ] && { echo "installing $2"; sleep "${STUB_UP_SLEEP:-0}"; }
echo "$1 ${2:-} end $(date +%s.%N)" >> "$STUB_DIR/calls"
[ "$1" = status ] && echo '{"running":true,"build":"1.0.0","ui_http":"200"}'
exit 0
S
echo "- nested_target: vm" >> "$WORK_DIR/CONFIG.md"
NOW="$(date -u +%s)"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
resume() { QI_BOOT_EPOCH="$1" bash "$SCRIPTS/env.sh" resume 2>/dev/null; }
settle() { local i; for i in $(seq 1 100); do grep -q '^running' "$E/RESUME" 2>/dev/null || return 0; sleep 0.2; done; }
ups() { grep -c "^up $1 start" "$STUB_DIR/calls" 2>/dev/null || echo 0; }

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
