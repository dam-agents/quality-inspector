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

# Regression mode: signals no test covers are listed under "What changed", escaped, with the new map's screenshot.
printf 'png' > "$SANDBOX/settings.png"
cat > "$SANDBOX/r.json" <<J
{"mode":"regression","candidate":"c2","candidate_run":"cand","verdict":"needs-review","acs":[],
 "context":{"previous":"c1","issues":[],"ui_diff":"No UI change between the two builds.","signals":{
  "console_errors_new":[{"route":"/settings","errors":["Error: <img onerror=x>"],"shot":"$SANDBOX/settings.png","verdict":"needs-review","explanation":"absent on c1"}],
  "failed_requests_new":[{"route":"/settings","requests":[{"method":"POST","path":"/api/keys/:id","status":500}],"verdict":"needs-review"}],
  "slower_pages":[],"slow_tests":[{"title":"#1 AC-1: slow","latest_ms":9000,"median_ms":4000,"verdict":"needs-review","explanation":"took 9000 ms, 2.3x its median of 4000 ms"}]}}}
J
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/r.json" "$SANDBOX/rout" >/dev/null
h="$(cat "$SANDBOX/rout/index.html")"
case "$h" in *'Signals no test covers'*'Error: &lt;img onerror=x&gt;'*'media/signal-1-settings.png'*'POST /api/keys/:id → 500'*'took 9000 ms'*) ;; *) echo "  signals list missing or unescaped"; FAILED=1;; esac
case "$h" in *'<img onerror'*) echo "  signal text not escaped"; FAILED=1;; esac
[ -f "$SANDBOX/rout/media/signal-1-settings.png" ] || { echo "  signal screenshot not copied"; FAILED=1; }
exit $FAILED
