#!/usr/bin/env bash
# suite.sh run keeps its result for `wait`: 3 while it runs, 0 with the summary once done,
# 1 for another session's run, a run never started, a failed one, or one that died.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
export HOME="$SANDBOX/home"; mkdir -p "$HOME" "$WORK_DIR/env" "$SANDBOX/bin" "$WORK_DIR/suite/node_modules/e2e"
printf 'E2E_USER_OWNER_USERNAME=owner-name\nE2E_USER_OWNER_PASSWORD=owner-pass-1\n' > "$WORK_DIR/env/credentials.env"
STATE="$WORK_DIR/suite/.e2e/state"
# A stub e2e that runs until $SANDBOX/go exists, then writes a passed report.
cat > "$SANDBOX/bin/npx" <<S
#!/usr/bin/env bash
out=; while [ \$# -gt 0 ]; do [ "\$1" = --output ] && out="\$2"; shift; done
while [ ! -e "$SANDBOX/go" ]; do sleep 0.2; done
mkdir -p "\$out"
jq -n '{run:{status:"passed",exitCode:0,summary:{},results:[{titlePath:["P-day AC-6: the post"],tags:[],status:"passed",attempts:[{steps:[]}]}]}}' > "\$out/report.json"
S
chmod +x "$SANDBOX/bin/npx"
export CLAUDE_CODE_SESSION_ID=sess-a

PATH="$SANDBOX/bin:$PATH" bash "$SCRIPTS/suite.sh" run long >/dev/null 2>&1 &
bg=$!
for _ in $(seq 50); do [ -f "$STATE/long" ] && break; sleep 0.1; done
bash "$SCRIPTS/suite.sh" wait long 1 >/dev/null 2>&1; assert_eq "a running run waits with 3" 3 "$?"
CLAUDE_CODE_SESSION_ID=sess-b bash "$SCRIPTS/suite.sh" wait long 1 >/dev/null 2>&1
assert_eq "another session's run is not this one's" 1 "$?"
touch "$SANDBOX/go"
s="$(bash "$SCRIPTS/suite.sh" wait long 30 2>/dev/null)"; rc=$?
assert_eq "a finished run exits 0" 0 "$rc"
assert "wait prints the run's summary" '.label == "long" and .results[0].status == "passed"' "$s"
wait "$bg"

bash "$SCRIPTS/suite.sh" wait never 1 >/dev/null 2>&1; assert_eq "a run never started fails" 1 "$?"
bash "$SCRIPTS/suite.sh" wait 2>/dev/null; assert_eq "wait needs a label" 2 "$?"

# A run that dies (its pid gone, no `done` line) and one that failed (no report).
printf 'running dead 2026-10-23T08:00:00Z 999999 sess-a\n' > "$STATE/dead"
bash "$SCRIPTS/suite.sh" wait dead 1 >/dev/null 2>&1; assert_eq "a run that died fails" 1 "$?"
rm -f "$SANDBOX/bin/npx"; printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/npx"; chmod +x "$SANDBOX/bin/npx"
PATH="$SANDBOX/bin:$PATH" bash "$SCRIPTS/suite.sh" run broken >/dev/null 2>&1
bash "$SCRIPTS/suite.sh" wait broken 1 >/dev/null 2>&1; assert_eq "a run without a report fails" 1 "$?"
read -r st _ _ x _ < "$STATE/broken"
assert_eq "its state says done with the exit code" "done 1" "$st $x"
exit $FAILED
