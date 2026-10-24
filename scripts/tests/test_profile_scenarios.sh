#!/usr/bin/env bash
# The profile's scenarios/: scenarios.sh adopt (verbatim copy per spec_hash, P-<slug> rows) and
# the regression pre-flight's profile_scenarios (new, changed, retired, the nightly cap, deferred[]
# by name), and scenarios.sh queue (the same order, with titles).
. "$(dirname "$0")/lib.sh"
seed_work
sc="$QI_PROFILE_DIR/scenarios"; mkdir -p "$sc"
today="$WORK_DIR/logs/events-$(date -u +%Y-%m-%d).jsonl"
printf '# Sign-in\n\n## AC-1 — Owner signs in\nGiven the sign-in page\nWhen the owner signs in\nThen the dashboard shows\n' > "$sc/sign-in.md"
printf '# Agent\n\n## AC-1 — Create\nGiven …\nWhen …\nThen the agent is listed  \n' > "$sc/create-agent.md"
printf 'x\n' > "$sc/Bad_Name.md"
ln -s /etc/hosts "$sc/linked.md"

# preflight: no regression tests, but two scenarios to adopt -> due
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "new scenarios, no regression-tier test: due, replay nothing" '.nothing_to_do == false and .replay == false and .profile_scenarios.files == 2
  and (.profile_scenarios.adopt | map(.id)) == ["P-create-agent","P-sign-in"] and (.profile_scenarios.adopt | map(.kind) | unique) == ["new"]
  and .profile_scenarios.retire == [] and .channel == null' "$out"
assert "a bad name and a symlink are skipped with a warning" '(.logs | map(select(test("Bad_Name.md.*skipped"))) | length) == 1
  and (.logs | map(select(test("linked.md.*not a regular file"))) | length) == 1' "$out"
[ -z "$(ls "$WORK_DIR/.cache"/profile-scenarios.* 2>/dev/null)" ] || { echo "  temporary stderr file left behind"; FAILED=1; }

# adopt: a byte-for-byte copy of the file, kept per spec_hash
a="$(bash "$SCRIPTS/scenarios.sh" adopt create-agent)"
assert "adopt names the id, hash and copy" '.id == "P-create-agent" and .slug == "create-agent" and (.spec_hash | test("^[0-9a-f]{12}$"))
  and .source == ("scenarios/P-create-agent/source-" + .spec_hash + ".md") and .previous_spec_hash == null' "$a"
h1="$(printf '%s' "$a" | jq -r .spec_hash)"
cmp -s "$sc/create-agent.md" "$WORK_DIR/scenarios/P-create-agent/source-$h1.md" || { echo "  the copy is not verbatim"; FAILED=1; }
grep -q '"event":"scenario_adopt"' "$today" || { echo "  no scenario_adopt event"; FAILED=1; }
bash "$SCRIPTS/scenarios.sh" adopt missing >/dev/null 2>&1; assert_eq "a missing file is refused" 1 "$?"
bash "$SCRIPTS/scenarios.sh" adopt ../etc >/dev/null 2>&1; assert_eq "a path is not a slug" 2 "$?"
bash "$SCRIPTS/scenarios.sh" set P-create-agent source=profile status=reported spec_hash="$h1" verdict=passed >/dev/null
bash "$SCRIPTS/scenarios.sh" set P-Bad source=profile status=reported >/dev/null 2>&1; assert_eq "an uppercase P- id is refused" 2 "$?"
bash "$SCRIPTS/scenarios.sh" set P-sign-in source=profile status=rejected spec_hash="$(bash "$SCRIPTS/scenarios.sh" adopt sign-in | jq -r .spec_hash)" >/dev/null

out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "adopted and rejected texts are settled -> idle" '.nothing_to_do == true' "$out"

# a reflow is not a change; a new word is
printf '# Agent\n\n## AC-1 — Create\nGiven …\nWhen …\nThen the agent is listed\n' > "$sc/create-agent.md"
assert "whitespace only -> still idle" '.nothing_to_do == true' "$(bash "$SCRIPTS/preflight.sh" regression)"
printf '# Agent\n\n## AC-1 — Create\nGiven …\nWhen …\nThen the agent is listed as Running\n' > "$sc/create-agent.md"
mkdir -p "$WORK_DIR/suite/tests"; printf '// AC-1 begin\nawait expect(x).toBeVisible();\n// AC-1 end\n' > "$WORK_DIR/suite/tests/issue-7.e2e.ts"
echo "| tests/issue-7.e2e.ts | 7 | regression | $(bash "$SCRIPTS/check-asserts.sh" --hash "$WORK_DIR/suite/tests/issue-7.e2e.ts") | 2026-10-01T00:00:00Z |" >> "$WORK_DIR/SUITE.md"
echo "2026-10-01T03:00:00Z ran candidate=0.0.0-main.bbb2222 unchanged=1" >> "$WORK_DIR/REGRESSION.log"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "a changed text on a tested build: adopt it, replay nothing" '.nothing_to_do == false and .replay == false
  and .profile_scenarios.adopt == [{"id":"P-create-agent","slug":"create-agent","spec_hash":.profile_scenarios.adopt[0].spec_hash,"kind":"changed"}]' "$out"
a="$(bash "$SCRIPTS/scenarios.sh" adopt create-agent)"
assert "re-adopt names the previous hash" '.previous_spec_hash == "'"$h1"'" and .spec_hash != .previous_spec_hash' "$a"
[ -f "$WORK_DIR/scenarios/P-create-agent/source-$h1.md" ] || { echo "  the old verbatim copy is gone"; FAILED=1; }

# a failed adoption is retried on a new build only, after new and changed texts
bash "$SCRIPTS/scenarios.sh" set P-create-agent spec_hash="$(printf '%s' "$a" | jq -r .spec_hash)" status=reported verdict=failed >/dev/null
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "a failed adoption alone, same build -> idle" '.nothing_to_do == true' "$out"
echo '{"candidate":"0.0.0-main.ccc3333","baseline":"0.2.19"}' > "$STUB_DIR/versions.json"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert_eq "stdout is one JSON value" 1 "$(printf '%s' "$out" | jq -s length)"
assert "a new build retries it" '.replay == true and .profile_scenarios.adopt == [{"id":"P-create-agent","slug":"create-agent","spec_hash":.profile_scenarios.adopt[0].spec_hash,"kind":"retry"}]' "$out"
echo '{"candidate":"0.0.0-main.bbb2222","baseline":"0.2.19"}' > "$STUB_DIR/versions.json"

# a removed file is retired; a retired one that returns is new
rm "$sc/sign-in.md"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "a removed file is retired, a retry waits for a new build" '.profile_scenarios.retire == ["P-sign-in"] and .replay == false and .profile_scenarios.adopt == []' "$out"
bash "$SCRIPTS/scenarios.sh" set P-sign-in status=retired >/dev/null
printf '# Sign-in again\n' > "$sc/sign-in.md"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "a retired scenario that returns is new" '.profile_scenarios.adopt | map(select(.id == "P-sign-in")) | .[0].kind == "new"' "$out"

# the nightly cap, the channel, the switch
for i in 1 2 3 4; do printf '# S%s\n' "$i" > "$sc/extra-$i.md"; done
echo '- max_scenarios_per_run: 2' >> "$WORK_DIR/CONFIG.md"
echo '- regression_channel: C0123ABCD' >> "$WORK_DIR/CONFIG.md"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "at most max_scenarios_per_run adoptions, the rest deferred by name: texts first, then the retry" '(.profile_scenarios.adopt | map(.id)) == ["P-extra-1","P-extra-2"]
  and (.profile_scenarios.deferred | map(.id + ":" + .kind)) == ["P-extra-3:new","P-extra-4:new","P-sign-in:new","P-create-agent:retry"]
  and (.logs | map(select(test("4 profile scenario\\(s\\) deferred \\(max_scenarios_per_run: 2; .*\\): P-extra-3, P-extra-4, P-sign-in, P-create-agent$"))) | length) == 1
  and .channel == "C0123ABCD"' "$out"
q="$(bash "$SCRIPTS/scenarios.sh" queue)"
assert "queue: the same order, with each file's title and the cap" '.cap == 2 and .files == 6
  and (.queue | map(.id)) == ["P-extra-1","P-extra-2","P-extra-3","P-extra-4","P-sign-in","P-create-agent"]
  and (.queue[0] | .title == "S1" and .kind == "new") and (.queue[4].title == "Sign-in again") and .retire == []' "$q"
echo '- profile_scenarios: disabled' >> "$WORK_DIR/CONFIG.md"
echo "2026-10-02T03:00:00Z ran candidate=0.0.0-main.bbb2222 unchanged=1" >> "$WORK_DIR/REGRESSION.log"
out="$(bash "$SCRIPTS/preflight.sh" regression)"
assert "disabled: no profile scenarios, same build -> idle" '.nothing_to_do == true' "$out"
assert_eq "disabled: stdout is one JSON value" 1 "$(printf '%s' "$out" | jq -s length)"
assert_eq "disabled: the queue is null" null "$(bash "$SCRIPTS/scenarios.sh" queue)"
exit $FAILED
