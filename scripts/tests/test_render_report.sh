#!/usr/bin/env bash
# render-report.mjs: every tested AC gets its video and captioned screenshot; the setup test never appears.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
R="$SANDBOX/runs"
mk_run() { # <label> <ac-1 status>
  local d="$R/$1/artifacts/web/t1/default/attempt-0"
  mkdir -p "$d/video" "$d/screenshots" "$R/$1/artifacts/web/setup/default/attempt-0/video"
  printf 'webm' > "$d/video/video.webm"; printf 'png' > "$d/screenshots/001-AC-1.png"
  printf 'webm' > "$R/$1/artifacts/web/setup/default/attempt-0/video/video.webm"
  cat > "$R/$1/report.json" <<J
{"run":{"results":[
 {"titlePath":["the owner signs in"],"tags":[],"status":"passed","attempts":[{"artifacts":[{"id":"s:0","kind":"video","path":"web/setup/default/attempt-0/video/video.webm","producer":{"kind":"attempt"}}],"steps":[]}]},
 {"titlePath":["#42 AC-1: renamed"],"tags":["issue-42","ac-1"],"status":"$2","attempts":[{"durationMs":900,
  "error":$( [ "$2" = failed ] && echo '{"code":"ASSERTION_FAILED","message":"expected visible"}' || echo null ),
  "artifacts":[{"id":"a:0","kind":"screenshot","path":"web/t1/default/attempt-0/screenshots/001-AC-1.png","producer":{"kind":"step","stepId":"x:1"}},
               {"id":"a:1","kind":"video","path":"web/t1/default/attempt-0/video/video.webm","producer":{"kind":"attempt"}}],
  "steps":[{"id":"x:0","api":"app.open","label":"/","status":"passed","durationMs":10,"artifacts":[]},
           {"id":"x:1","api":"app.screenshot","label":"AC-1: the renamed agent","status":"passed","durationMs":20,"artifacts":["a:0"]}]}]}]}}
J
}
mk_run cand passed; mk_run base failed
cat > "$SANDBOX/v.json" <<'J'
{"issue":42,"title":"Rename <b>","ac_hash":"abc","candidate":"c1","baseline":"b1","candidate_run":"cand","baseline_run":"base",
 "verdict":"verified","acs":[{"id":"AC-1","name":"renamed","then":"the new name shows","testable":true,"verdict":"verified"},
 {"id":"AC-2","name":"internal","testable":false,"verdict":"not-testable"}]}
J
out="$(QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/v.json" "$SANDBOX/out")"
assert "two videos, two screenshots" '.videos == 2 and .screenshots == 2' "$out"
h="$(cat "$SANDBOX/out/index.html")"
case "$h" in *'<video controls'*'poster="media/'*) ;; *) echo "  no video with a poster"; FAILED=1;; esac
case "$h" in *'AC-1: the renamed agent'*) ;; *) echo "  screenshot caption missing"; FAILED=1;; esac
case "$h" in *'Rename &lt;b&gt;'*) ;; *) echo "  title not escaped"; FAILED=1;; esac
case "$h" in *ASSERTION_FAILED*) ;; *) echo "  baseline error missing"; FAILED=1;; esac
[ "$(ls "$SANDBOX/out/media" | wc -l | tr -d ' ')" = 4 ] || { echo "  expected exactly the two AC-1 videos and screenshots (setup test must not be published)"; FAILED=1; }
grep -q '| AC-1 | renamed | passed | failed | verified |' "$SANDBOX/out/comment.md" || { echo "  comment row missing"; FAILED=1; }
exit $FAILED
