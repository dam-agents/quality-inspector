#!/usr/bin/env bash
# scripts/features.mjs: the registry's writes (add creates, a member as one or two arguments, no
# duplicate, alias, rename, merge, drop), refusals that leave the file as it was, resolve (exact by
# a whole name or alias, accents and case ignored; ranked; none), only recurring tiers run, the tags,
# check, and record (a feature run's results per item, member criteria only, explorations out).
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
W="$WORK_DIR"
F() { node "$SCRIPTS/features.mjs" "$@"; }
printf '| tests/issue-42.e2e.ts | 42 | regression | a | 2026-10-03T08:12:40Z |\n| tests/issue-51.e2e.ts | 51 | promotable | b | - |\n| tests/scenario-7.e2e.ts | S-7 | exploratory | c | - |\n| tests/profile-chat.e2e.ts | P-chat | quarantined | d | 2026-10-05T03:00:00Z |\n' >> "$W/SUITE.md"

out="$(F check)"; assert "check: no registry yet is fine" '.ok and (.warnings | length == 1)' "$out"
out="$(F add model-switch '#42' AC-1 --name Model switching)"; assert "add: creates the feature" '.added' "$out"
out="$(F add model-switch '#42 AC-1')"; assert "add: the same member twice is one" '.added == false' "$out"
F add model-switch '#51' >/dev/null; F add model-switch S-7 >/dev/null; F add model-switch P-chat >/dev/null
F alias model-switch 'Změna modelu' >/dev/null; F alias model-switch 'změna MODELU' >/dev/null
F add slack-reply S-7 --name Reply in Slack >/dev/null
assert_eq "the file: sorted rows, members and aliases" \
  '| model-switch | Model switching | Změna modelu | #42 AC-1, #51, S-7, P-chat |' "$(grep '^| model-switch' "$W/FEATURES.md" | sed 's/ | [0-9T:Z-]* |$/ |/')"
grep -q '^| feature | name | aliases | members | updated_utc |$' "$W/FEATURES.md" || { echo "  header missing"; FAILED=1; }

before="$(cat "$W/FEATURES.md")"
F add 'Bad Id' '#42' 2>/dev/null; assert_eq "a bad id: exit 2" 2 "$?"
F add model-switch '#42 EX-1' 2>/dev/null; assert_eq "an exploration is no member: exit 2" 2 "$?"
F alias model-switch 'a | b' 2>/dev/null; assert_eq "a pipe in an alias: exit 2" 2 "$?"
F remove nope '#42' 2>/dev/null; assert_eq "an unknown feature: exit 2" 2 "$?"
assert_eq "refusals leave the file as it was" "$before" "$(cat "$W/FEATURES.md")"

out="$(F resolve zmena modelu)"
assert "resolve: a whole alias, accents and case ignored, is exact" '.match == "exact" and (.features | length == 1) and .features[0].id == "model-switch"' "$out"
assert "resolve: only regression and promotable members run" '.features[0].runnable == ["#42 AC-1","#51"]
  and ([.features[0].skipped[] | .ref + "=" + .reason] == ["S-7=tier exploratory","P-chat=tier quarantined"])' "$out"
assert "resolve: the tags of the runnable files" '.features[0].tags == ["--tag","issue-42","--tag","issue-51"]' "$out"
assert "resolve: a part of a name is ranked" '.match == "ranked" and .features[0].id == "model-switch" and .features[0].score < 1' "$(F resolve model)"
assert "resolve: nothing alike is none" '.match == "none" and .features == []' "$(F resolve billing export)"

out="$(F check)"; assert "check: well-formed, with warnings for members that do not run" '.ok and (.warnings | length == 3)' "$out"
printf '| broken | row |\n' >> "$W/FEATURES.md"
assert "check: a malformed row is a problem" '.ok == false' "$(F check)"
printf '%s\n' "$before" > "$W/FEATURES.md"

# record: a feature run's raw results, keyed by item; a member criterion only; an exploration never.
mkdir -p "$W/suite/.e2e/runs/feature-model-switch-c3-1200"
cat > "$W/suite/.e2e/runs/feature-model-switch-c3-1200/report.json" <<'J'
{"run":{"results":[
 {"tags":["issue-42","ac-1"],"status":"passed","attempts":[{}]},
 {"tags":["issue-42","ac-2"],"status":"failed","attempts":[{"error":{"message":"not a member"}}]},
 {"tags":["issue-51","ac-1"],"status":"failed","attempts":[{"error":{"message":"expected  \n Models"}}]},
 {"tags":["issue-51","ac-3"],"status":"timedOut","attempts":[{}]},
 {"tags":["issue-51-ex","ex-1"],"status":"failed","attempts":[{}]}]}}
J
out="$(F record feature-model-switch-c3-1200 model-switch --build c3)"
assert "record: member criteria only, statuses, the message one line" '.results == {"issue-42/AC-1":{"status":"passed","error":null},"issue-51/AC-1":{"status":"failed","error":"expected Models"},"issue-51/AC-3":{"status":"blocked","error":null}}' "$out"
assert "record: written under work/reruns/feature-<id>/" '.feature == "model-switch" and .build == "c3"' "$(cat "$W/reruns/feature-model-switch/feature-model-switch-c3-1200.json")"
F record feature-missing model-switch --build c3 2>/dev/null; assert_eq "record: no such run, exit 2" 2 "$?"

out="$(F merge slack-reply model-switch)"
assert "merge: members joined, the old name an alias, the old feature gone" '.members == ["#42 AC-1","#51","S-7","P-chat"]' "$out"
grep -q '^| slack-reply' "$W/FEATURES.md" && { echo "  merge left the old feature"; FAILED=1; }
grep -q 'Reply in Slack' "$W/FEATURES.md" || { echo "  merge lost the old name"; FAILED=1; }
assert "remove a member" '.removed' "$(F remove model-switch S-7)"
assert "drop a feature" '.dropped' "$(F drop model-switch)"
assert "nothing left" '.features == []' "$(F list)"
exit $FAILED
