#!/usr/bin/env bash
# changes.sh: the completed issues of the build window, and who may supersede a criterion.
. "$(dirname "$0")/lib.sh"
seed_work
cat > "$QI_PROFILE_DIR/bin/build-time" <<'S'
#!/usr/bin/env bash
case "$1" in (old) echo 2026-10-01T00:00:00Z;; (new) echo 2026-10-08T00:00:00Z;; (*) exit 1;; esac
S
c() { printf '{"number":%s,"title":"t%s","body":"## Done when\\n- x","labels":[],"state_reason":"%s","closed_at":"%s","user":{"login":"%s"},"author_association":"%s"}' "$@"; }
{
  echo "["
  c 1 1 completed 2026-10-02T00:00:00Z maint MEMBER; echo ","
  c 2 2 completed 2026-10-03T00:00:00Z stranger NONE; echo ","
  c 3 3 completed 2026-10-04T00:00:00Z stranger2 FIRST_TIMER; echo ","
  c 4 4 completed 2026-10-05T00:00:00Z stranger3 NONE; echo ","
  c 5 5 not_planned 2026-10-05T00:00:00Z maint OWNER; echo ","
  c 6 6 completed 2026-10-09T00:00:00Z maint OWNER
  echo "]"
} > "$STUB_DIR/issues.json"
echo '{"number":2,"closed_by":{"login":"maint"}}' > "$STUB_DIR/issue-2.json"      # a maintainer closed it
echo '{"number":3,"closed_by":{"login":"stranger2"}}' > "$STUB_DIR/issue-3.json"  # the author closed it
echo '{"number":4,"closed_by":null}' > "$STUB_DIR/issue-4.json"

out="$(bash "$SCRIPTS/changes.sh" old new)"
assert "only completed issues inside the window" '[.issues[].number] == [1,2,3,4]' "$out"
assert "author association and closer are reported" '.issues[] | select(.number==2) | .author_association=="NONE" and .closed_by=="maint" and .state_reason=="completed"' "$out"
assert "a maintainer author may supersede" '.issues[] | select(.number==1) | .may_supersede == true' "$out"
assert "an outsider closed by a maintainer may supersede" '.issues[] | select(.number==2) | .may_supersede == true' "$out"
assert "an outsider who closed their own issue may not" '.issues[] | select(.number==3) | .may_supersede == false' "$out"
assert "an outsider with no known closer may not" '.issues[] | select(.number==4) | .closed_by == null and .may_supersede == false' "$out"
exit $FAILED
