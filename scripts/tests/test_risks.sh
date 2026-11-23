#!/usr/bin/env bash
# scripts/risks.mjs: add (observe by default; enforce only in the direct session), match (whole words in
# any case, labels, enforce first, the cap), hit, set (direct session only), the refusals, and check
# (ready, stale, old lessons).
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
W="$WORK_DIR"
R() { node "$SCRIPTS/risks.mjs" "$@"; }
export QI_WORDS_DIR="$SANDBOX"   # stands for /tmp (lib/words.mjs)
T() { local f; f="$(mktemp "$SANDBOX/quality-inspector-words.XXXXXX")"; printf '%s' "$*" > "$f"; echo "$f"; }
export CLAUDE_CONFIG_DIR="$SANDBOX/claude" CLAUDE_CODE_SESSION_ID=s1
mkdir -p "$CLAUDE_CONFIG_DIR/projects/p"; TR="$CLAUDE_CONFIG_DIR/projects/p/s1.jsonl"
scheduled() { printf '{"type":"user","message":{"content":"QA issues run.\\n<qi-scheduled-run>issues</qi-scheduled-run>\\n{}"}}\n' > "$TR"; }
direct() { printf '{"type":"user","message":{"content":"%s"}}\n' "$1" > "$TR"; }
scheduled

assert "check: no register yet is fine" '.ok and .ready == [] and .stale == []' "$(R check)"
out="$(R add --trigger-file "$(T $'word: upload\nlabel: area/files')" --check-file "$(T 'Given a file with a 200-character name, when the user uploads it, the upload ends and the file shows in the list.')" --source E-1)"
assert "add: R-1 in observe" '.id == "R-1" and .mode == "observe" and .triggers == ["word:upload","label:area/files"]' "$out"
f="$(T 'word: upload')"; R add --trigger-file "$f" --check-file "$(T 'Given a file with a 200-character name, when the user uploads it, the upload ends and the file shows in the list.')" --source E-2 >/dev/null 2>&1
assert_eq "the same check twice is refused" 2 "$?"
R add --trigger-file "$(T 'word: share link')" --check-file "$(T 'Given a shared folder, when the owner removes the link, the old link shows an error page to a visitor.')" --source operator --mode enforce >/dev/null 2>&1
assert_eq "enforce at once in a scheduled run is refused" 2 "$?"
direct "add a risk rule"
assert "enforce at once in the direct session" '.id == "R-2" and .mode == "enforce"' "$(R add --trigger-file "$(T 'word: share link')" --check-file "$(T 'Given a shared folder, when the owner removes the link, the old link shows an error page to a visitor.')" --source operator --mode enforce)"
scheduled
R add --trigger-file "$(T 'path: /x')" --check-file "$(T 'Given anything at all, when it happens, it works.')" --source operator >/dev/null 2>&1
assert_eq "an unknown trigger kind is refused" 2 "$?"
R add --trigger-file "$(T 'word: up')" --check-file "$(T 'Given anything at all, when it happens, it works.')" --source E-3 >/dev/null 2>&1
assert_eq "a trigger under 3 characters is refused" 2 "$?"
R add --trigger-file "$W/nope" --check-file "$(T 'x')" --source E-3 >/dev/null 2>&1
assert_eq "a file that is not the call's own mktemp is refused" 2 "$?"

m="$(R match --text-file "$(T 'Uploading big files: the UPLOAD stops. Also a Share  Link to the folder.')")"
assert "match: whole words, any case, spaces folded; enforce first" '[.risks[].id] == ["R-2","R-1"] and .risks[1].matched == "word:upload"' "$m"
assert "match: a word inside a longer word does not count" '.risks == []' "$(R match --text-file "$(T 'The uploads page and the reuploaded file.')")"
assert "match: a label" '[.risks[].id] == ["R-1"] and .risks[0].matched == "label:area/files"' "$(R match --text-file "$(T 'nothing here')" --label Area/Files)"
echo '- max_risk_checks_per_issue: 1' >> "$W/CONFIG.md"
assert "match: the cap, the rest left out" '[.risks[].id] == ["R-2"] and .left_out == ["R-1"] and .cap == 1' "$(R match --text-file "$(T 'upload and share link')")"
sed -i.bak 's/max_risk_checks_per_issue: 1/max_risk_checks_per_issue: 0/' "$W/CONFIG.md"
assert "match: 0 = none" '.risks == [] and .left_out == ["R-2","R-1"]' "$(R match --text-file "$(T 'upload and share link')")"

assert "hit: counts runs and observations" '.runs == 1 and .observations == 1' "$(R hit R-1 --result observation --ref '#42 EX-4')"
R hit R-1 --result fine --ref '#42 EX-4' >/dev/null 2>&1; assert_eq "hit: an unknown result is refused" 2 "$?"
R hit R-1 --result ok --ref 'S-4' >/dev/null 2>&1; assert_eq "hit: a ref that is no issue exploration is refused" 2 "$?"
for i in 1 2 3 4; do R hit R-1 --result ok --ref "#4$i EX-1" >/dev/null; done
assert "check: an observe rule with 5 runs is ready, to enforce" '.ok and .ready == [{"id":"R-1","runs":5,"observations":1,"suggest":"enforce"}]' "$(R check)"

R set R-1 enforce >/dev/null 2>&1; assert_eq "set in a scheduled run is refused" 2 "$?"
direct "enforce R-1"
assert "set in the direct session" '.mode == "retired"' "$(R set R-2 retired)"
R hit R-2 --result ok --ref '#42 EX-1' >/dev/null 2>&1; assert_eq "a retired rule takes no hit" 2 "$?"
assert "list --active leaves the retired out" '[.risks[].id] == ["R-1"]' "$(R list --active)"

# stale: an active rule no issue met in 90 days; old lessons
sed -i.bak 's/| R-1 | observe | \(.*\) | E-1 | [0-9TZ:-]* | 5 | 1 | [0-9TZ:-]* |/| R-1 | observe | \1 | E-1 | 2026-01-01T00:00:00Z | 5 | 1 | 2026-01-02T00:00:00Z |/' "$W/RISKS.md"
printf -- '- 2020-01-01 env: the install needs 8 GiB (evidence)\n- %s env: fresh lesson\nfree text\n' "$(date -u +%Y-%m-%d)" > "$W/LESSONS.md"
c="$(R check)"
assert "check: stale and old lessons" '.stale[0].id == "R-1" and .lessons_old == 1' "$c"
printf 'garbage\n' > "$W/RISKS.md"
R list >/dev/null 2>&1; assert_eq "a changed header is refused" 2 "$?"
assert "check: a changed header is a problem" '(.ok | not) and (.problems[0] | test("header"))' "$(R check)"
exit $FAILED
