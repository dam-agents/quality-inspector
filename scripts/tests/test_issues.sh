#!/usr/bin/env bash
# preflight.sh issues: due detection, skips, lock takeover, gating and error fallback.
. "$(dirname "$0")/lib.sh"
. "$SCRIPTS/lib/state.sh"
seed_work 5
cat > "$STUB_DIR/issues.json" <<'J'
[{"number":7,"title":"Rename keeps sessions","body":"Intro\n\n## Done when\n\n- the agent keeps its sessions\n\n## Notes\nignore","labels":[{"name":"qa:ready"}]},
 {"number":8,"title":"Second","body":"no section here","labels":[{"name":"qa:ready"},{"name":"qa:retest"}]},
 {"number":9,"title":"A PR","body":"x","labels":[],"pull_request":{"url":"u"}},
 {"number":10,"title":"Done already","body":"## Done when\nok","labels":[]},
 {"number":11,"title":"Changed","body":"## Done when\nnew text","labels":[]},
 {"number":12,"title":"Running","body":"b","labels":[]},
 {"number":13,"title":"Stale","body":"b","labels":[]},
 {"number":14,"title":"Pending","body":"b","labels":[]}]
J
h10="$(text_hash "$(issue_spec_text "Done already" "## Done when
ok")")"
h14="$(text_hash "$(issue_spec_text "Pending" "b")")"
{
  echo "| 8 | x | c | b | verified | reported | $(iso_ago 60) |"
  echo "| 10 | $h10 | c | b | verified | reported | $(iso_ago 60) |"
  echo "| 11 | 000000000000 | c | b | failed | reported | $(iso_ago 60) |"
  echo "| 12 | x | c | b | - | in_progress | $(iso_ago 20) |"
  echo "| 13 | x | c | b | - | in_progress | $(iso_ago 400) |"
  echo "| 14 | $h14 | c | b | failed | report_pending | $(iso_ago 60) |"
} >> "$WORK_DIR/QA.md"

out="$(bash "$SCRIPTS/preflight.sh" issues)"
assert "valid object, work to do" '.mode=="issues" and .nothing_to_do==false' "$out"
assert "candidate is newest main tag" '.candidate=="0.0.0-main.bbb2222"' "$out"
assert "baseline is newest release" '.baseline=="0.2.19"' "$out"
assert "PRs are filtered" '[.issues_due[].issue] | index(9) == null' "$out"
assert "new issue is first" '.issues_due[] | select(.issue==7) | .kind=="first" and .has_done_when==true' "$out"
assert "retest label wins over a reported row" '.issues_due[] | select(.issue==8) | .kind=="retest" and .retest_label_present==true' "$out"
assert "unchanged reported issue skipped" '[.issues_due[].issue] | index(10) == null' "$out"
assert "changed text is due" '.issues_due[] | select(.issue==11) | .kind=="ac_changed"' "$out"
assert "fresh lock skipped" '[.issues_due[].issue] | index(12) == null' "$out"
assert "stale silent lock taken over" '.issues_due[] | select(.issue==13) | .kind=="takeover" and .takeover==true' "$out"
assert "pending report only redelivered" '.reports_due == [{"issue":14}] and ([.issues_due[].issue] | index(14) == null)' "$out"

# the Done-when section alone defines the hash: editing other prose changes nothing
a="$(text_hash "$(issue_spec_text t "x
## Done when
- a
## Other
1")")"
b="$(text_hash "$(issue_spec_text t "y
## Done when
-   a
## Other
2")")"
assert_eq "hash ignores prose outside Done when and whitespace" "$a" "$b"

# a live holder of the nested environment makes the occurrence idle
mkdir -p "$WORK_DIR/env"; echo "regression $(iso_ago 5)" > "$WORK_DIR/env/LOCK"
out="$(bash "$SCRIPTS/preflight.sh" issues)"
assert "busy environment is idle" '.nothing_to_do==true and (.error // "") == ""' "$out"
rm -f "$WORK_DIR/env/LOCK"

# the cap defers the rest
seed_work 1
out="$(bash "$SCRIPTS/preflight.sh" issues)"
assert "cap of one" '(.issues_due | length) == 1 and (.logs | map(select(test("deferred"))) | length) >= 1' "$out"

# failures are reported as errors, never as an empty worklist
out="$(STUB_GH_FAIL=1 bash "$SCRIPTS/preflight.sh" issues)"
assert "gh failure is an error" '.nothing_to_do==true and (.error | test("listing failed"))' "$out"
out="$(STUB_CURL_FAIL=1 bash "$SCRIPTS/preflight.sh" issues)"
assert "registry failure is an error" '(.error | test("chart versions"))' "$out"
: > "$WORK_DIR/CONFIG.md"
out="$(bash "$SCRIPTS/preflight.sh" issues)"
assert "missing target is an error" '(.error | test("target_repo"))' "$out"
grep -q 'ERROR:' "$WORK_DIR/ISSUES.log" || { echo "  ISSUES.log has no ERROR line"; FAILED=1; }
exit $FAILED
