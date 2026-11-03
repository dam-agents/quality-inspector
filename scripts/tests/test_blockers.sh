#!/usr/bin/env bash
# scripts/blockers.mjs: open (the same cause again is a hit, a build id or count does not make a new
# cause), the backoff and what releases a row early (CONFIG.md, the profile, the credentials file), the
# notices (opened, resolved, never twice), the operator's retry and close (direct session only), the
# refusals and check; then the pre-flight's hold of the work — issues, reports, queued scenarios, the
# nightly replay and the modes that install — and the audit's `blockers` check.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
W="$WORK_DIR"
B() { node "$SCRIPTS/blockers.mjs" "$@"; }
export QI_WORDS_DIR="$SANDBOX"   # stands for /tmp (lib/words.mjs)
S() { local f; f="$(mktemp "$SANDBOX/quality-inspector-signature.XXXXXX")"; printf '%s' "$*" > "$f"; echo "$f"; }
# A scheduled run's transcript: retry and close are refused there.
export CLAUDE_CONFIG_DIR="$SANDBOX/claude" CLAUDE_CODE_SESSION_ID=s1
mkdir -p "$CLAUDE_CONFIG_DIR/projects/p"; TR="$CLAUDE_CONFIG_DIR/projects/p/s1.jsonl"
printf '{"type":"user","message":{"content":"QA issues run.\\n<qi-scheduled-run>issues</qi-scheduled-run>\\n{}"}}\n' > "$TR"
# set_cell <B-k> <column, 1-based> <value>: one cell of the register, as an old run left it.
set_cell() { awk -v id="$1" -v c="$2" -v v="$3" 'BEGIN { FS = OFS = "|" } $2 == " " id " " { $(c + 1) = " " v " " } { print }' "$W/BLOCKERS.md" > "$W/b.tmp" && mv "$W/b.tmp" "$W/BLOCKERS.md"; }

assert "check: no register yet is fine" '.ok' "$(B check)"
assert "status: no register, nothing held" '.open == 0 and .held == [] and .env == null and .delivery == null and .tests == {}' "$(B status)"

out="$(B open --scope env --owner profile --stage up --build 0.0.0-main.9556 --signature-file "$(S 'helm: virtualization.runner.resources.limits.memory is required')")"
assert "open: B-1, one hit, its notes file named" '.id == "B-1" and .opened and .hits == 1 and .notes == "work/blockers/B-1.md"' "$out"
out="$(B open --scope env --owner profile --stage up --build 0.0.0-main.9562 --signature-file "$(S 'helm:  Virtualization.runner.resources.limits.memory is required')")"
assert "the same cause on another build: a hit of B-1" '.id == "B-1" and (.opened | not) and .hits == 2' "$out"
assert "the row: the newest build, two hits" '.blockers[0] | .build == "0.0.0-main.9562" and .hits == 2 and .state == "open" and .told == "-"' "$(B list)"

st="$(B status)"
assert "status: B-1 holds the environment" '.open == 1 and .env == "B-1" and (.held | map(.id)) == ["B-1"] and .released == []' "$st"
assert "an owner other than the agent: the opened notice is due" '(.notices | map({id, kind})) == [{"id":"B-1","kind":"opened"}]' "$st"
assert "told: opened" '.told == "opened"' "$(B told B-1)"
B told B-1 >/dev/null 2>&1; assert_eq "told again: no notice due, exit 2" 2 "$?"
assert "no notice due any more" '.notices == []' "$(B status)"

# The backoff: 2^(hits-1) hours less a quarter of an hour, at most a week for the profile.
r="$(B list | jq -r '.blockers[0] | [.last_utc, .retry_utc] | @tsv')"
gap=$(( $(date -u -d "$(cut -f2 <<<"$r")" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$(cut -f2 <<<"$r")" +%s) \
      - $(date -u -d "$(cut -f1 <<<"$r")" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$(cut -f1 <<<"$r")" +%s) ))
assert_eq "two hits: retry after 1 h 45 min" 6300 "$gap"

# Released early once CONFIG.md changes; held again after the next hit.
echo '- e2e_model: claude-sonnet-5' >> "$W/CONFIG.md"
assert "a changed CONFIG.md releases B-1" '.env == null and .released[0].id == "B-1" and .released[0].reason == "changed: config"' "$(B status)"
B hit B-1 --build 0.0.0-main.9567 >/dev/null
assert "the next hit holds it again" '.env == "B-1"' "$(B status)"
echo '# Stub' >> "$QI_PROFILE_DIR/SKILL.md"
assert "a changed profile file releases it" '.released[0].reason == "changed: profile"' "$(B status)"
B hit B-1 --build 0.0.0-main.9567 >/dev/null
mkdir -p "$W/env"; printf 'E2E_X_PASSWORD=abcdefgh\n' > "$W/env/credentials.env"
assert "a new credentials file releases it" '.released[0].reason == "changed: credentials"' "$(B status)"
B hit B-1 --build 0.0.0-main.9567 >/dev/null
# The retry time passed: released.
set_cell B-1 12 "$(iso_ago 5)"
assert "past its retry time: released" '.env == null and .released[0].reason == "retry time"' "$(B status)"

# An agent-owned cause is told only once it struck twice.
B open --scope delivery --owner agent --stage upload --build c1 --signature-file "$(S 'video/webm served application/octet-stream (artifact 3f5b354a)')" >/dev/null
assert "an agent's first hit: held, no notice" '.delivery == "B-2" and ([.notices[] | select(.id == "B-2")] == [])' "$(B status)"
out="$(B open --scope delivery --owner agent --stage upload --build c2 --signature-file "$(S 'video/webm served application/octet-stream (artifact 86caaf0b)')")"
assert "another artifact id, the same cause" '.id == "B-2" and .hits == 2' "$out"
assert "struck twice: the notice is due" '[.notices[] | select(.id == "B-2") | .kind] == ["opened"]' "$(B status)"
B resolve B-2 >/dev/null
assert "resolved before it was told: no notice" '[.notices[] | select(.id == "B-2")] == [] and .delivery == null' "$(B status)"

# Tests: one row stops several recurring tests; another scope or cause is its own row.
B open --scope tests --test P-agent-files --test '#4548' --owner profile --stage replay --build c3 --signature-file "$(S 'no node advertises devices.kubevirt.io/kvm')" >/dev/null
out="$(B open --scope tests --test S-8 --owner profile --stage adopt --build c4 --signature-file "$(S 'No node advertises devices.kubevirt.io/kvm')")"
assert "the same cause for another test: merged into B-3" '.id == "B-3" and .hits == 2' "$out"
assert "B-3 holds all three tests" '.tests == {"P-agent-files":"B-3","#4548":"B-3","S-8":"B-3"}' "$(B status)"
out="$(B open --scope env --owner unknown --stage up --build c4 --signature-file "$(S 'no node advertises devices.kubevirt.io/kvm')")"
assert "the same words in another scope: a row of its own" '.id == "B-4" and .opened' "$out"
B resolve B-1 >/dev/null
assert "resolved after it was told: the resolved notice" '[.notices[] | select(.id == "B-1") | .kind] == ["resolved"]' "$(B status)"
B told B-1 >/dev/null
assert "told resolved: no notice" '[.notices[] | select(.id == "B-1")] == []' "$(B status)"

# The operator's words only.
before="$(cat "$W/BLOCKERS.md")"
B retry B-4 >/dev/null 2>&1; assert_eq "retry in a scheduled run: exit 2" 2 "$?"
B close B-4 >/dev/null 2>&1; assert_eq "close in a scheduled run: exit 2" 2 "$?"
assert_eq "nothing was written" "$before" "$(cat "$W/BLOCKERS.md")"
printf '{"type":"user","message":{"content":"retry B-4"}}\n' > "$TR"
assert "retry in the direct session: released now" '.id == "B-4"' "$(B retry B-4)"
assert "B-4 no longer holds" '.env == null and ([.released[] | select(.id == "B-4")] | length) == 1' "$(B status)"
assert "close in the direct session" '.state == "closed"' "$(B close B-4)"

# Refusals leave the file as it was.
before="$(cat "$W/BLOCKERS.md")"
B open --scope disk --owner agent --stage up --build c5 --signature-file "$(S x)" 2>/dev/null; assert_eq "an unknown scope: exit 2" 2 "$?"
B open --scope env --owner nobody --stage up --build c5 --signature-file "$(S x)" 2>/dev/null; assert_eq "an unknown owner: exit 2" 2 "$?"
B open --scope tests --owner agent --stage up --build c5 --signature-file "$(S x)" 2>/dev/null; assert_eq "a tests scope without its tests: exit 2" 2 "$?"
B open --scope env --test '#1' --owner agent --stage up --build c5 --signature-file "$(S x)" 2>/dev/null; assert_eq "tests on another scope: exit 2" 2 "$?"
B open --scope env --owner agent --stage up --build c5 2>/dev/null; assert_eq "no signature file: exit 2" 2 "$?"
printf x > "$SANDBOX/quality-inspector-signature.txt"
B open --scope env --owner agent --stage up --build c5 --signature-file "$SANDBOX/quality-inspector-signature.txt" 2>/dev/null; assert_eq "a fixed signature path: exit 2" 2 "$?"
B hit B-2 --build c5 2>/dev/null; assert_eq "a hit of a resolved row: exit 2" 2 "$?"
B hit B-9 --build c5 2>/dev/null; assert_eq "an unknown id: exit 2" 2 "$?"
assert_eq "refusals leave the file as it was" "$before" "$(cat "$W/BLOCKERS.md")"
echo 1 > "$W/BLOCKERS.md.lock"
B resolve B-3 2>/dev/null; assert_eq "a held lock: exit 1" 1 "$?"
rm -f "$W/BLOCKERS.md.lock"

assert "check: the register is well-formed" '.ok' "$(B check)"
set_cell B-3 2 disk
assert "check: a malformed row is named" '(.ok | not) and (.problems | any(test("B-3: scope")))' "$(B check)"
# ---------------------------------------------------------------- the pre-flight holds the work
rm -f "$W/BLOCKERS.md"
printf '{"type":"user","message":{"content":"QA issues run.\\n<qi-scheduled-run>issues</qi-scheduled-run>\\n{}"}}\n' > "$TR"
cat > "$STUB_DIR/issues.json" <<'J'
[{"number":7,"title":"Rename","body":"## Done when\n- the new name shows","labels":[{"name":"qa:ready"}]},
 {"number":8,"title":"Pending","body":"b","labels":[]},
 {"number":9,"title":"Orphan","body":"b","labels":[{"name":"qa:ready"}]}]
J
. "$SCRIPTS/lib/state.sh"
h8="$(text_hash "$(issue_spec_text "Pending" "b")")"
h9="$(text_hash "$(issue_spec_text "Orphan" "b")")"
printf '| 8 | %s | c | b | failed | report_pending | %s |\n| 9 | %s | c | b | - | in_progress | %s |\n' "$h8" "$(iso_ago 60)" "$h9" "$(iso_ago 400)" >> "$W/QA.md"
PF() { bash "$SCRIPTS/preflight.sh" "$@"; }
out="$(PF issues)"
assert "no blocker: the issue, the report and the takeover are due" '([.issues_due[] | {issue, kind}] | sort_by(.issue)) == [{"issue":7,"kind":"first"},{"issue":9,"kind":"takeover"}] and (.reports_due | map(.issue)) == [8] and .blockers == {"held":[],"released":[],"notices":[]}' "$out"

printf -- '- scenario_discovery: propose\n' >> "$W/CONFIG.md"
B open --scope env --owner profile --stage up --build 0.0.0-main.bbb2222 --signature-file "$(S 'helm: a value is required')" >/dev/null
out="$(PF issues)"
assert "an env blocker holds the new test, names itself; the takeover still ends its row" \
  '(.issues_due | map({issue, kind})) == [{"issue":9,"kind":"takeover"}] and (.issues_waiting[] | select(.issue == 7) | .reason | test("^blocker B-1 \\(profile, up: helm: a value is required\\) until "))' "$out"
assert "the report is not an install: still due" '(.reports_due | map(.issue)) == [8]' "$out"
assert "the worklist names the held row and the notice due" '(.blockers.held | map(.id)) == ["B-1"] and (.blockers.notices | map({id, kind})) == [{"id":"B-1","kind":"opened"}]' "$out"
sed -i.bak '/^| 9 /d' "$W/QA.md" && rm -f "$W/QA.md.bak"; jq -c 'map(select(.number != 9))' "$STUB_DIR/issues.json" > "$W/i.tmp" && mv "$W/i.tmp" "$STUB_DIR/issues.json"
B open --scope delivery --owner platform --stage upload --build 0.0.0-main.bbb2222 --signature-file "$(S 'video served application/octet-stream')" >/dev/null
out="$(PF issues)"
assert "a delivery blocker holds the report; the opened notices still wake the run" '.reports_due == [] and .issues_due == [] and .nothing_to_do == false and .title == "Report blocker B-1 · Report blocker B-2"' "$out"
B told B-1 >/dev/null; B told B-2 >/dev/null
out="$(PF issues)"
assert "all held and told: nothing to do, a cheap idle hour" '.nothing_to_do == true and (.issues_waiting | map(.issue) | index(7)) != null' "$out"
out="$(PF discovery)"
assert "discovery does not install while env is held" '.nothing_to_do == true and (.logs | any(test("does not install here: blocker B-1")))' "$out"
grep -q 'skip=held blocker=B-1' "$W/DISCOVERY.log"; assert_eq "its log line" 0 "$?"
out="$(PF security)"
assert "nor does the security run" '.nothing_to_do == true and (.blockers.held | map(.id) | index("B-1")) != null' "$out"
set_cell B-1 12 "$(iso_ago 5)"
out="$(PF issues)"
assert "past its retry time: the test is due again, the release logged" '(.issues_due | map(.issue)) == [7] and (.blockers.released | map(.id)) == ["B-1"] and (.logs | any(test("blocker B-1 .* released \\(retry time\\)")))' "$out"
B resolve B-1 >/dev/null

# The nightly replay: a held test is not run; with none left, the night is idle.
mkdir -p "$W/suite/tests"
printf '// AC-1 begin\nawait expect(x).toBeVisible();\n// AC-1 end\n' > "$W/suite/tests/issue-7.e2e.ts"
cp "$W/suite/tests/issue-7.e2e.ts" "$W/suite/tests/issue-12.e2e.ts"
h="$(bash "$SCRIPTS/check-asserts.sh" --hash "$W/suite/tests/issue-7.e2e.ts")"
printf '| tests/issue-7.e2e.ts | 7 | regression | %s | 2026-10-01T00:00:00Z |\n| tests/issue-12.e2e.ts | 12 | regression | %s | 2026-10-01T00:00:00Z |\n' "$h" "$h" >> "$W/SUITE.md"
B open --scope tests --test '#12' --owner profile --stage replay --build 0.0.0-main.bbb2222 --signature-file "$(S 'the dialog needs a linked Slack account')" >/dev/null
out="$(PF regression)"
assert "a held test is not replayed, the other one is" '.nothing_to_do == false and .tests == ["tests/issue-7.e2e.ts"] and .held_tests == [{"test":"tests/issue-12.e2e.ts","id":"#12","blocker":"B-3"}]' "$out"
B hit B-3 --build 0.0.0-main.bbb2222 --test '#7' >/dev/null
out="$(PF regression)"
assert "every test held: an idle night" '.nothing_to_do == true and (.held_tests | map(.id)) == ["#7","#12"]' "$out"
grep -q 'skip=held tests=2' "$W/REGRESSION.log"; assert_eq "the night's log line" 0 "$?"

# The audit: a cause open over a week, a notice not given.
set_cell B-3 10 2026-01-02T03:00:00Z
out="$(HOME="$SANDBOX" PF audit | jq -c '.checks[] | select(.id == "blockers")')"
assert "audit: an old blocker and an untold notice warn" '.status == "warn" and (.detail | test("B-3 open since 2026-01-02 \\(profile\\)")) and (.detail | test("B-3: the opened notice was not given"))' "$out"
set_cell B-3 2 disk
out="$(HOME="$SANDBOX" PF audit | jq -c '.checks[] | select(.id == "blockers")')"
assert "audit: a malformed register fails" '.status == "fail" and (.detail | test("B-3: scope"))' "$out"
exit $FAILED
