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
# Words reach the script only through a file (docs/features.md): T <words> writes it and prints its path.
T() { local f; f="$(mktemp "$SANDBOX/quality-inspector-words.XXXXXX")"; printf '%s' "$*" > "$f"; echo "$f"; }
R() { F resolve --file "$(T "$@")"; }
printf '| tests/issue-42.e2e.ts | 42 | regression | a | 2026-10-03T08:12:40Z |\n| tests/issue-51.e2e.ts | 51 | promotable | b | - |\n| tests/scenario-7.e2e.ts | S-7 | exploratory | c | - |\n| tests/profile-chat.e2e.ts | P-chat | quarantined | d | 2026-10-05T03:00:00Z |\n' >> "$W/SUITE.md"

out="$(F check)"; assert "check: no registry yet is fine" '.ok and (.warnings | length == 1)' "$out"
out="$(F add model-switch '#42' AC-1 --name-file "$(T Model switching)")"; assert "add: creates the feature" '.added' "$out"
out="$(F add model-switch '#42 AC-1')"; assert "add: the same member twice is one" '.added == false' "$out"
F add model-switch '#51' >/dev/null; F add model-switch S-7 >/dev/null; F add model-switch P-chat >/dev/null
F alias model-switch --file "$(T "Změna modelu")" >/dev/null; F alias model-switch --file "$(T "změna MODELU")" >/dev/null
F add slack-reply S-7 --name-file "$(T "Reply in Slack")" >/dev/null
assert_eq "the file: sorted rows, members and aliases" \
  '| model-switch | Model switching | Změna modelu | #42 AC-1, #51, S-7, P-chat |' "$(grep '^| model-switch' "$W/FEATURES.md" | sed 's/ | [0-9T:Z-]* |$/ |/')"
grep -q '^| feature | name | aliases | members | updated_utc |$' "$W/FEATURES.md" || { echo "  header missing"; FAILED=1; }

before="$(cat "$W/FEATURES.md")"
F add 'Bad Id' '#42' 2>/dev/null; assert_eq "a bad id: exit 2" 2 "$?"
F add model-switch '#42 EX-1' 2>/dev/null; assert_eq "an exploration is no member: exit 2" 2 "$?"
F alias model-switch --file "$(T "a | b")" 2>/dev/null; assert_eq "a pipe in an alias: exit 2" 2 "$?"
F alias model-switch "it's" 2>/dev/null; assert_eq "words on the command line are refused: exit 2" 2 "$?"
F alias model-switch --file "$SANDBOX/quality-inspector-words.none00" 2>/dev/null; assert_eq "an unreadable words file: exit 2" 2 "$?"
F add 'Bad Id' '#42' --name-file "$(T Name)" 2>/dev/null; assert_eq "a bad id with a words file: exit 2" 2 "$?"
assert_eq "refusals leave the file as it was" "$before" "$(cat "$W/FEATURES.md")"
ls "$SANDBOX" | grep -qE '^quality-inspector-words\.[A-Za-z0-9]{6}$' && { echo "  a refused call left its words file"; FAILED=1; }
# One file per call: a fixed, shared name is refused and left alone; the call's own file is removed once read.
printf 'Shared' > "$SANDBOX/quality-inspector-words.txt"
F alias model-switch --file "$SANDBOX/quality-inspector-words.txt" 2>/dev/null; assert_eq "a fixed words path: exit 2" 2 "$?"
[ -e "$SANDBOX/quality-inspector-words.txt" ] || { echo "  a refused words file was removed"; FAILED=1; }
rm -f "$SANDBOX/quality-inspector-words.txt"
wf="$(T Model picker)"; F alias model-switch --file "$wf" >/dev/null
[ -e "$wf" ] && { echo "  a words file stayed after its call"; FAILED=1; }
before="$(cat "$W/FEATURES.md")"
F remove nope '#42' 2>/dev/null; assert_eq "an unknown feature: exit 2" 2 "$?"
assert_eq "an unknown feature leaves the file as it was" "$before" "$(cat "$W/FEATURES.md")"
[ -e "$W/FEATURES.md.lock" ] && { echo "  a refused write left its lock"; FAILED=1; }
ls "$W" | grep -q '\.tmp$' && { echo "  a write left a temp file"; FAILED=1; }
# The mutex: a live lock holds a writer off (exit 1, nothing written); one over a minute old is a dead writer's.
echo 1 > "$W/FEATURES.md.lock"
F add model-switch '#77' 2>/dev/null; assert_eq "a held lock: exit 1" 1 "$?"
assert_eq "a held lock: nothing written" "$before" "$(cat "$W/FEATURES.md")"
touch -t 202601010000 "$W/FEATURES.md.lock"
assert "a lock over a minute old is taken over" '.added' "$(F add model-switch '#77')"
F remove model-switch '#77' >/dev/null
[ -e "$W/FEATURES.md.lock" ] && { echo "  a write left its lock"; FAILED=1; }
# Six writers at once over a stale lock: each one's member is kept, no lock or set-aside file stays.
touch "$W/FEATURES.md.lock"; touch -t 202601010000 "$W/FEATURES.md.lock"
for k in 1 2 3 4 5 6; do F add race "#9$k" >/dev/null & done; wait
assert "concurrent writers over a stale lock lose no update" '.features[] | select(.id == "race") | (.members | sort) == ["#91","#92","#93","#94","#95","#96"]' "$(F list)"
ls -a "$W" | grep -qE '\.(lock|aside|tmp)$|\.aside' && { echo "  a lock, a set-aside or a temp file stayed: $(ls -a "$W")"; FAILED=1; }
F drop race >/dev/null
# A writer releases only its own lock: one whose token changed under it stays.
out="$(node --input-type=module -e 'import { withMutex } from "'"$SCRIPTS"'/lib/mutex.mjs"; import { writeFileSync, readFileSync } from "node:fs";
const l = process.argv[1]; withMutex(l, () => writeFileSync(l, "other 1\n")); process.stdout.write(readFileSync(l, "utf8"));' "$W/own.lock" 2>&1)"
assert_eq "a lock that is no longer the writer's own stays" "other 1" "$out"
rm -f "$W/own.lock"

out="$(R zmena modelu)"
assert "resolve: a whole alias, accents and case ignored, is exact" '.match == "exact" and (.features | length == 1) and .features[0].id == "model-switch"' "$out"
assert "resolve: only regression and promotable members run" '.features[0].runnable == ["#42 AC-1","#51"]
  and ([.features[0].skipped[] | .ref + "=" + .reason] == ["S-7=tier exploratory","P-chat=tier quarantined"])' "$out"
assert "resolve: the tags of the runnable files" '.features[0].tags == ["--tag","issue-42","--tag","issue-51"]' "$out"
assert "resolve: a part of a name is ranked" '.match == "ranked" and .features[0].id == "model-switch" and .features[0].score < 1' "$(R model)"
assert "resolve: nothing alike is none" '.match == "none" and .features == []' "$(R billing export)"

F resolve zmena modelu 2>/dev/null; assert_eq "resolve: words on the command line are refused" 2 "$?"
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
