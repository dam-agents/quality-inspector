#!/usr/bin/env bash
# Nested credentials never remain in run artefacts: suite.sh masks them, the audit finds leftovers.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
export HOME="$SANDBOX/home"; mkdir -p "$HOME" "$WORK_DIR/env" "$SANDBOX/bin"
PW='p@ss.w*rd[1]$x\y'   # regex metacharacters and a backslash (JSON-escaped in report.json)
SEC='adm1n-s3cret-Value'
printf "E2E_USER_OWNER_USERNAME=owner-name\nE2E_USER_OWNER_PASSWORD='%s'\nQI_SECRET_ADMIN=%s\n" "$PW" "$SEC" > "$WORK_DIR/env/credentials.env"
RUNS="$WORK_DIR/suite/.e2e/runs"
leaks() { grep -rlF -e "$PW" -e "$SEC" -e 'p@ss.w*rd[1]$x\\y' "$RUNS" 2>/dev/null; }
audit() { bash "$SCRIPTS/preflight.sh" audit 2>/dev/null | jq -c '.checks[] | select(.id == "secrets_in_runs")'; }

# A raw run as e2e leaves it: the password in run.log, an agent.act param and a trace file.
plant() { # <dir>
  mkdir -p "$1/trace"
  printf 'typing %s for owner-name\n' "$PW" > "$1/run.log"
  jq -n --arg p "$PW" '{run:{status:"passed",exitCode:0,summary:{},results:[{titlePath:["the owner signs in"],tags:[],status:"passed",
    attempts:[{steps:[{api:"agent.act",label:"sign in",params:{password:$p},status:"passed"}]}]}]}}' > "$1/report.json"
  printf '# actions\nsecret %s\n' "$SEC" > "$1/trace/actions.md"
  printf 'webm %s' "$PW" > "$1/video.webm"
}
plant "$RUNS/raw"
c="$(audit)"
assert "unmasked run fails the audit" '.status == "fail" and (.detail | test("raw/run.log")) and (.detail | test("3 file"))' "$c"
case "$c" in *"$SEC"*|*'p@ss'*) echo "  audit detail prints a credential value"; FAILED=1;; esac

node "$SCRIPTS/lib/secrets.mjs" mask "$WORK_DIR/env/credentials.env" "$RUNS/raw"
[ -z "$(leaks | grep -v 'video.webm$')" ] || { echo "  a text file still holds a credential: $(leaks)"; FAILED=1; }
jq -e '.run.results[0].attempts[0].steps[0].params.password == "***"' "$RUNS/raw/report.json" >/dev/null \
  || { echo "  report.json not masked or no longer valid JSON"; FAILED=1; }
grep -q 'owner-name' "$RUNS/raw/run.log" || { echo "  a non-secret value was masked"; FAILED=1; }
grep -qF "$PW" "$RUNS/raw/video.webm" || { echo "  a binary file was rewritten"; FAILED=1; }
rm -f "$RUNS/raw/video.webm"
assert "masked run passes the audit" '.status == "ok"' "$(audit)"

# suite.sh run end to end with a stub e2e: artefacts and the summary on stdout are masked.
mkdir -p "$WORK_DIR/suite/node_modules/e2e"
cat > "$SANDBOX/bin/npx" <<'S'
#!/usr/bin/env bash
out=; while [ $# -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
mkdir -p "$out/trace"
jq -n --arg p "$E2E_USER_OWNER_PASSWORD" '{run:{status:"failed",exitCode:1,summary:{},results:[{titlePath:["login as " + $p],tags:[],status:"failed",
  attempts:[{error:{code:"X"},steps:[{api:"agent.act",label:("type " + $p),params:{p:$p},status:"failed"}]}]}]}}' > "$out/report.json"
printf 'token %s\n' "$QI_SECRET_ADMIN" > "$out/trace/step.txt"
echo "e2e: filled password $E2E_USER_OWNER_PASSWORD"
printf '%s' "${QI_PROFILE_CONFIG:-}" > "$out/../profile-config.json"
exit 1
S
chmod +x "$SANDBOX/bin/npx"
s="$(PATH="$SANDBOX/bin:$PATH" bash "$SCRIPTS/suite.sh" run stubbed 2>/dev/null)"
assert "summary is printed and masked" '.label == "stubbed" and .results[0].title == "login as ***"' "$s"
case "$s" in *'p@ss'*) echo "  summary leaks the password"; FAILED=1;; esac
grep -q 'filled password \*\*\*' "$RUNS/stubbed/run.log" || { echo "  run.log not masked"; FAILED=1; }
assert "a run has the profile's config, resolved" '.image == "stub/img"' "$(cat "$RUNS/profile-config.json")"
[ -z "$(leaks)" ] || { echo "  suite.sh left a credential in: $(leaks)"; FAILED=1; }
assert "audit stays ok after a real run" '.status == "ok"' "$(audit)"
s2="$(bash "$SCRIPTS/suite.sh" summary stubbed 2>/dev/null)"
assert "summary subcommand is masked" '.results[0].title == "login as ***"' "$s2"

# A value too short to mask safely is reported, never replaced.
printf 'E2E_USER_X_PASSWORD=ab\n' > "$SANDBOX/short.env"
assert "short value is counted as unmaskable" '.unmaskable == 1 and .files == []' \
  "$(node "$SCRIPTS/lib/secrets.mjs" scan "$SANDBOX/short.env" "$RUNS")"
exit $FAILED
