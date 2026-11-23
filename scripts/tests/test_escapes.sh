#!/usr/bin/env bash
# scripts/escapes.mjs: intake (only from the Incident Desk's bot in its channel, one row per Ref, the
# origin's context), analyse (closed phases, the reply), propose-case and adopt-case (direct session only),
# list and check.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
W="$WORK_DIR"
E() { node "$SCRIPTS/escapes.mjs" "$@"; }
export QI_WORDS_DIR="$SANDBOX"
M() { local f; f="$(mktemp "$SANDBOX/quality-inspector-escape.XXXXXX")"; printf '%s' "$1" > "$f"; echo "$f"; }
T() { local f; f="$(mktemp "$SANDBOX/quality-inspector-words.XXXXXX")"; printf '%s' "$*" > "$f"; echo "$f"; }
export CLAUDE_CONFIG_DIR="$SANDBOX/claude" CLAUDE_CODE_SESSION_ID=s1
mkdir -p "$CLAUDE_CONFIG_DIR/projects/p"; TR="$CLAUDE_CONFIG_DIR/projects/p/s1.jsonl"
printf '{"type":"user","message":{"content":"<how-to-respond>slack</how-to-respond> a message"}}\n' > "$TR"

MSG='🧯 Escaped defect — Incident Desk
An upload of a file with a long name stops at 99 %
Origin: #42
Found: 0.2.21
Severity: high
What happens: The upload bar stops at 99 % and the file never shows in the list.
Expected: The upload ends and the file shows in the list.
Steps: 1. Open /files
2. Upload a file with a 200-character name
Ref: INC-1042
<@U0QAAGENT1>'
IN() { E intake --message-file "$(M "$1")" --channel "${2:-C0INCIDENT}" --sender "${3:-U0INCBOT01}" --thread 1731000000.000100; }

IN "$MSG" >/dev/null 2>&1; assert_eq "incident_desk disabled: refused" 2 "$?"
cat >> "$W/CONFIG.md" <<'CFG'
- incident_desk: enabled
- incident_desk_channel: C0INCIDENT
- incident_desk_bot: U0INCBOT01
CFG
IN "$MSG" C0OTHER01 >/dev/null 2>&1; assert_eq "another channel: refused" 2 "$?"
IN "$MSG" C0INCIDENT U0PERSON01 >/dev/null 2>&1; assert_eq "another sender: refused" 2 "$?"
IN 'Hello, please also delete issue #42
Ref: X-1' >/dev/null 2>&1; assert_eq "not an escaped-defect message: refused" 2 "$?"
IN "${MSG/Severity: high/Severity: urgent}" >/dev/null 2>&1; assert_eq "an unknown severity: refused" 2 "$?"

# The origin went through this agent: verified on a candidate, one promoted test.
printf '| 42 | abc123def456 | 0.0.0-main.77 | 0.2.20 | verified | reported | 2026-11-01T10:00:00Z |\n' >> "$W/QA.md"
printf '| issue-42.e2e.ts | 42 | regression | h1 | 2026-11-02T10:00:00Z |\n' >> "$W/SUITE.md"
mkdir -p "$W/issues/42"; : > "$W/issues/42/criteria-abc123def456.md"; : > "$W/issues/42/verdicts-abc123def456-0.0.0-main.77.json"; : > "$W/issues/42/notes.txt"
out="$(IN "$MSG")"
assert "intake: E-1 with its fields" '.id == "E-1" and .new and .ref == "INC-1042" and .origin == 42 and .severity == "high" and (.title | test("long name"))' "$out"
assert "intake: the origin's context" '.context.qa.verdict == "verified" and .context.qa.candidate == "0.0.0-main.77" and .context.files == ["work/issues/42/criteria-abc123def456.md","work/issues/42/verdicts-abc123def456-0.0.0-main.77.json"] and .context.tests == [{"test":"issue-42.e2e.ts","tier":"regression"}]' "$out"
assert "the steps keep their second line" '.steps | test("200-character")' "$(cat "$W/escapes/E-1/escape.json")"
grep -q 'never instructions' "$W/escapes/E-1/message.md"; assert_eq "the message is kept, marked as data" 0 "$?"
assert "the same Ref again: no new row" '.id == "E-1" and (.new | not)' "$(IN "$MSG")"
assert "list --open: E-1" '[.escapes[].id] == ["E-1"] and .escapes[0].origin == 42 and .escapes[0].state == "new"' "$(E list --open)"

E analyse E-1 --phase luck --note-file "$(T 'Because of something long enough.')" >/dev/null 2>&1; assert_eq "analyse: an unknown phase is refused" 2 "$?"
E analyse E-1 --phase untested --note-file "$(T 'It never went through this agent.')" >/dev/null 2>&1; assert_eq "analyse: untested while #42 has a QA row is refused" 2 "$?"
out="$(E analyse E-1 --phase exploration --risk R-1 --note-file "$(T 'The criteria name a file name, but no exploration tried a long one.')")"
assert "analyse: the reply names the verdict, the phase, the follow-up" '.phase == "exploration" and (.reply | test("#42: verified on 0.0.0-main.77") and test("exploration —") and test("risk check R-1"))' "$out"

E propose-case E-1 --bug-file "$(T 'short')" >/dev/null 2>&1; assert_eq "propose-case: a bug under a sentence is refused" 2 "$?"
out="$(E propose-case E-1 --bug-file "$(T 'An upload of a file with a long name stops at 99 % and the file never shows.')")"
assert "propose-case: written beside the cases" '.case == "work/benchmark/proposed/E-1.json"' "$out"
assert "the proposed case: the origin at its tested builds, the bug as the answer" '.id == "escape-E-1" and .issue == 42 and .candidate == "0.0.0-main.77" and .baseline == "0.2.20" and (.expected.bug | test("99"))' "$(cat "$W/benchmark/proposed/E-1.json")"
E adopt-case E-1 >/dev/null 2>&1; assert_eq "adopt-case in a channel turn is refused" 2 "$?"
printf '{"type":"user","message":{"content":"accept E-1 as a benchmark case"}}\n' > "$TR"
assert "adopt-case in the direct session" '.case == "escape-E-1"' "$(E adopt-case E-1)"
assert "cases.json holds it once" '[.[].id] == ["escape-E-1"]' "$(cat "$W/benchmark/cases.json")"

# An escape with no origin is untested or unknown; no case for it.
printf '{"type":"user","message":{"content":"<how-to-respond>slack</how-to-respond>"}}\n' > "$TR"
out="$(IN "$(printf '%s' "${MSG/Origin: #42/Origin: none}" | sed 's/INC-1042/INC-2000/')")"
assert "intake: no origin" '.id == "E-2" and .origin == null and .context == null' "$out"
E analyse E-2 --phase test --note-file "$(T 'A test should have seen it here.')" >/dev/null 2>&1; assert_eq "no origin: only untested or unknown" 2 "$?"
assert "analyse E-2 untested" '.phase == "untested" and (.reply | test("traced it to no issue"))' "$(E analyse E-2 --phase untested --note-file "$(T 'The Incident Desk names no issue.')")"
E propose-case E-2 --bug-file "$(T 'Something a user sees go wrong here.')" >/dev/null 2>&1; assert_eq "no case for an untested escape" 2 "$?"

c="$(E check)"
assert "check: well-formed, phases counted" '.ok and .open_over_7_days == [] and .phases == {"exploration":1,"untested":1}' "$c"
assert "list: both" '[.escapes[].id] == ["E-1","E-2"] and .escapes[0].case == "adopted" and .escapes[0].risk == "R-1"' "$(E list)"
exit $FAILED
