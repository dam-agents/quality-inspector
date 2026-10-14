#!/usr/bin/env bash
# env.sh up refuses below min_free_disk_gi (an env_failed event, exit 1) and goes ahead above it.
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
exit $FAILED
