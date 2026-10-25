#!/usr/bin/env bash
# env.sh up refuses below min_free_disk_gi (an env_failed event, exit 1) and goes ahead above it;
# a failed up keeps its output in work/env/last-up.log, and `wait` prints its end, credentials masked.
. "$(dirname "$0")/lib.sh"
seed_work
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/df" <<'S'
#!/usr/bin/env bash
[ -n "${STUB_DF_KB:-}" ] || exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 104857600 1 %s 50%% /home\n' "$STUB_DF_KB"
S
chmod +x "$SANDBOX/bin/df"
up() { PATH="$SANDBOX/bin:$PATH" STUB_DF_KB="$1" bash "$SCRIPTS/env.sh" up 1.0.0 2>"$SANDBOX/err" >/dev/null; echo $?; }
events() { cat "$WORK_DIR"/logs/events-*.jsonl 2>/dev/null | jq -sc "[.[] | select(.event == \"$1\")] | length"; }

assert_eq "5Gi free < default 10 -> refused" 1 "$(up $((5 * 1048576)))"
grep -q 'only 5Gi free.*min_free_disk_gi is 10' "$SANDBOX/err" || { echo "  no clear stderr reason: $(cat "$SANDBOX/err")"; FAILED=1; }
assert_eq "refusal logged as env_failed" 1 "$(events env_failed)"
assert_eq "20Gi free -> the profile's up runs" 0 "$(up $((20 * 1048576)))"
assert_eq "env_up logged" 1 "$(events env_up)"
echo "- min_free_disk_gi: 30" >> "$WORK_DIR/CONFIG.md"
assert_eq "configured 30 -> 20Gi refused" 1 "$(up $((20 * 1048576)))"
assert_eq "df unusable -> not blocked" 0 "$(up "")"

printf 'E2E_USER_OWNER_PASSWORD=owner-pass-1\n' > "$WORK_DIR/env/credentials.env"
cat > "$QI_PROFILE_DIR/bin/env" <<'S'
#!/usr/bin/env bash
[ "$1" = up ] || exit 0
echo "pulling stub/img:$2"; echo "login owner/owner-pass-1 refused" >&2; echo "image pull refused by the gateway" >&2; exit 4
S
assert_eq "a failing up exits with the profile's code" 4 "$(up "")"
assert_eq "its output is kept, mode 600" 600 "$(stat -c %a "$WORK_DIR/env/last-up.log" 2>/dev/null || stat -f %Lp "$WORK_DIR/env/last-up.log")"
grep -q 'image pull refused by the gateway' "$WORK_DIR/env/last-up.log" || { echo "  stderr not kept"; FAILED=1; }
bash "$SCRIPTS/env.sh" wait 1.0.0 5 >/dev/null 2>"$SANDBOX/err"; assert_eq "wait reports the failure" 1 "$?"
grep -q '| image pull refused by the gateway' "$SANDBOX/err" || { echo "  wait shows no output: $(cat "$SANDBOX/err")"; FAILED=1; }
grep -q 'owner-pass-1' "$SANDBOX/err" && { echo "  wait leaks a credential value"; FAILED=1; }
assert_eq "the event names the log" 1 "$(cat "$WORK_DIR"/logs/events-*.jsonl | jq -sc '[.[] | select(.event == "env_failed" and (.msg | test("exited 4 .*last-up.log")))] | length')"
assert_eq "a refusal starts the log anew" 1 "$(up $((5 * 1048576)))"
grep -q 'image pull refused' "$WORK_DIR/env/last-up.log" && { echo "  an earlier up's output kept"; FAILED=1; }
grep -q 'only 5Gi free' "$WORK_DIR/env/last-up.log" || { echo "  the refusal is not in the log"; FAILED=1; }
exit $FAILED
