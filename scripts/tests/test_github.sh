#!/usr/bin/env bash
# scripts/github.sh — the agent's only road to GitHub: the target's issues endpoints alone,
# a pull request refused, writes only when comments are enabled.
. "$(dirname "$0")/lib.sh"
seed_work
G="$SCRIPTS/github.sh"
cat > "$STUB_DIR/issues.json" <<'J'
[{"number":7,"title":"Rename keeps sessions","body":"## Done when\n- x","state":"open","labels":[{"name":"qa:ready"}],"user":{"login":"alice"},"author_association":"MEMBER"},
 {"number":9,"title":"A PR","body":"x","labels":[{"name":"qa:ready"}],"pull_request":{"url":"u"}}]
J
echo '[{"id":1,"user":{"login":"qa-bot"},"created_at":"2026-10-01T00:00:00Z","body":"<!-- quality-inspector issue=7 -->"}]' > "$STUB_DIR/comments-7.json"

assert_eq "whoami" "qa-bot" "$(bash "$G" whoami)"
out="$(bash "$G" issue 7)"
assert "an issue, trimmed to its text, labels and author" '.number == 7 and .user == "alice" and .labels == ["qa:ready"] and (has("pull_request") | not)' "$out"
bash "$G" issue 9 >/dev/null 2>&1; assert_eq "a pull request is refused" 3 "$?"
bash "$G" issue 7x >/dev/null 2>&1; assert_eq "a non-number is a usage error" 2 "$?"
assert "comments, trimmed" '.[0].user == "qa-bot" and (.[0].body | contains("issue=7"))' "$(bash "$G" comments 7 2026-09-01T00:00:00Z)"
assert "list skips pull requests" 'map(.number) == [7]' "$(bash "$G" list)"
bash "$G" check; assert_eq "check reads the target's issues" 0 "$?"

echo body > "$SANDBOX/c.md"
bash "$G" comment 7 "$SANDBOX/c.md" >/dev/null 2>&1; assert_eq "no comment while comments are disabled" 3 "$?"
bash "$G" unlabel 7 >/dev/null 2>&1; assert_eq "no label removal while comments are disabled" 3 "$?"
printf -- '- issue_comments: enabled\n- retest_label: qa:retest\n' >> "$WORK_DIR/CONFIG.md"
: > "$STUB_DIR/gh.calls"
bash "$G" comment 7 "$SANDBOX/c.md" >/dev/null; assert_eq "comment posted" 0 "$?"
bash "$G" unlabel 7 >/dev/null; assert_eq "retest label removed" 0 "$?"
grep -qF -- "-X POST repos/acme/widgets/issues/7/comments -F body=@$SANDBOX/c.md" "$STUB_DIR/gh.calls" \
  || { echo "  assertion failed: the comment goes to the target's issue"; FAILED=1; }
grep -qF -- "-X DELETE repos/acme/widgets/issues/7/labels/qa%3Aretest" "$STUB_DIR/gh.calls" \
  || { echo "  assertion failed: only the retest label, URL-encoded"; FAILED=1; }

# Every request names the target's issues, or the identity.
grep -vE '(^| )repos/acme/widgets/issues([/?]| |$)|^api user|user --jq' "$STUB_DIR/gh.calls" \
  && { echo "  assertion failed: a request outside the target's issues"; FAILED=1; }

printf -- '- target_repo: acme/widgets/extra/x\n' > "$WORK_DIR/CONFIG.md"
bash "$G" issue 7 >/dev/null 2>&1; assert_eq "a malformed target is refused" 3 "$?"
: > "$WORK_DIR/CONFIG.md"
bash "$G" issue 7 >/dev/null 2>&1; assert_eq "no target, no request" 3 "$?"
exit $FAILED
