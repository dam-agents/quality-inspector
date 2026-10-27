#!/usr/bin/env bash
# The mark on an evidence screenshot (scripts/lib/shot-mark.mjs): a test's `[mark x,y,w,h;…]` label
# is split from its caption; the frame is drawn into the PNG, clipped at its edge, and a box fully
# off it or a file that is not a PNG gives no mark. render-report.mjs shows the test's marked still
# first with a red frame and without the label's geometry, draws the agent's `mark` as an orange
# frame only where the test left none, and proof.json names the marked still.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
LIB="$SCRIPTS/lib/shot-mark.mjs"
# A white 40×30 PNG (RGB or RGBA).
white() { node --input-type=module -e "import { encodePng } from '$LIB'; import { writeFileSync } from 'node:fs';
const bpp = $2 === 6 ? 4 : 3; writeFileSync('$1', encodePng({ w: 40, h: 30, bpp, color: $2, px: Buffer.alloc(40 * 30 * bpp, 255) }));"; }
# The colour of pixel x,y of a PNG as r,g,b.
pixel() { node --input-type=module -e "import { decodePng } from '$LIB'; import { readFileSync } from 'node:fs';
const i = decodePng(readFileSync('$1')); const o = ($3 * i.w + $2) * i.bpp; process.stdout.write([i.px[o], i.px[o + 1], i.px[o + 2]].join(','));"; }

white "$SANDBOX/rgb.png" 2; white "$SANDBOX/rgba.png" 6
r="$(node --input-type=module -e "import { splitMark, agentBoxes } from '$LIB';
process.stdout.write(JSON.stringify({ a: splitMark('AC-8: the failing check [mark 10,5,20,8;-4,0,6,6]'), b: splitMark('AC-1: plain [mark x]'),
  c: agentBoxes({ box: { x: 1.4, y: 2, w: 3, h: 4 } }), d: agentBoxes({ boxes: [{ x: 1, y: 1, w: 0, h: 3 }, null, { x: 'a' }] }), e: agentBoxes(null) }))")"
assert "a test's mark is split from its caption" '.a.label == "AC-8: the failing check" and .a.boxes == [{"x":10,"y":5,"w":20,"h":8},{"x":-4,"y":0,"w":6,"h":6}]' "$r"
assert "a malformed mark stays in the caption" '.b.label == "AC-1: plain [mark x]" and .b.boxes == []' "$r"
assert "the agent's box is rounded; an empty or a broken one is left out" '.c == [{"x":1,"y":2,"w":3,"h":4}] and .d == [] and .e == []' "$r"

draw() { node --input-type=module -e "import { drawMarks, AGENT_RGB } from '$LIB'; import { readFileSync, writeFileSync } from 'node:fs';
const o = drawMarks(readFileSync('$1'), $3, $4); if (o) writeFileSync('$2', o.png); process.stdout.write(String(o ? o.drawn : 0));"; }
assert_eq "an RGB PNG gets its frame" 1 "$(draw "$SANDBOX/rgb.png" "$SANDBOX/rgb-m.png" '[{x:10,y:10,w:10,h:6}]' undefined)"
assert_eq "the frame is red, outside the box" "230,0,0" "$(pixel "$SANDBOX/rgb-m.png" 8 12)"
assert_eq "the box itself stays readable" "255,255,255" "$(pixel "$SANDBOX/rgb-m.png" 14 12)"
assert_eq "an RGBA PNG gets the agent's orange frame, clipped at the edge" 1 "$(draw "$SANDBOX/rgba.png" "$SANDBOX/rgba-m.png" '[{x:-5,y:-5,w:10,h:10},{x:100,y:100,w:5,h:5}]' AGENT_RGB)"
assert_eq "the clipped frame is orange" "245,158,11" "$(pixel "$SANDBOX/rgba-m.png" 6 2)"
printf 'png' > "$SANDBOX/fake.png"
assert_eq "not a PNG: no mark" 0 "$(draw "$SANDBOX/fake.png" "$SANDBOX/fake-m.png" '[{x:1,y:1,w:2,h:2}]' undefined)"
assert_eq "a box fully off the screen: no mark" 0 "$(draw "$SANDBOX/rgb.png" "$SANDBOX/off.png" '[{x:50,y:50,w:2,h:2}]' undefined)"

# render-report.mjs: the test's marked still first, red, its caption without the geometry.
R="$SANDBOX/runs"; d="$R/cand/artifacts/web/t1/default/attempt-0"; mkdir -p "$d"
cp "$SANDBOX/rgb.png" "$d/001.png"; cp "$SANDBOX/rgb.png" "$d/002.png"
cat > "$R/cand/report.json" <<'J'
{"run":{"results":[{"titlePath":["#42 AC-1"],"tags":["issue-42","ac-1"],"status":"failed","attempts":[{"durationMs":900,"error":{"code":"ASSERTION_FAILED","message":"expected hidden"},
  "artifacts":[{"id":"a:0","kind":"screenshot","path":"web/t1/default/attempt-0/001.png","producer":{"kind":"step"}},{"id":"a:1","kind":"screenshot","path":"web/t1/default/attempt-0/002.png","producer":{"kind":"step"}}],
  "steps":[{"id":"x:1","api":"app.screenshot","label":"AC-1: the general page","status":"passed","artifacts":["a:0"]},
           {"id":"x:2","api":"expect","label":"Chat hidden","status":"failed","artifacts":[]},
           {"id":"x:3","api":"app.screenshot","label":"AC-1: the failing check [mark 10,10,10,6]","status":"passed","artifacts":["a:1"]}]}]}]}}
J
cat > "$SANDBOX/v.json" <<'J'
{"issue":42,"title":"Editors","ac_hash":"abc","candidate":"c1","baseline":"b1","candidate_run":"cand","baseline_run":null,"verdict":"failed",
 "acs":[{"id":"AC-1","name":"no chat","testable":true,"verdict":"failed","cause":"product","mark":{"box":{"x":1,"y":1,"w":4,"h":4},"saw":"the agent saw it"}}]}
J
out="$(QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/v.json" "$SANDBOX/out")" || { echo "  render-report failed: $out"; FAILED=1; }
h="$(cat "$SANDBOX/out/index.html")"
case "$h" in (*'[mark '*) echo "  the mark's geometry reached the page"; FAILED=1;; esac
case "$h" in (*'AC-1: the failing check — the red frame marks what the check found'*'AC-1: the general page'*) ;; (*) echo "  the test's marked still is not first, or its caption is wrong"; FAILED=1;; esac
case "$h" in (*"orange frame"*) echo "  the agent's mark was drawn where the test marked the still"; FAILED=1;; esac
case "$h" in (*'<li class="failed"><code>expect</code>'*'<code>app.screenshot</code> AC-1: the failing check <'*) ;; (*) echo "  the step list shows the label with its geometry"; FAILED=1;; esac
m="$(jq -r '.rows[0].shots[0].src' "$SANDBOX/out/proof.json")"
case "$m" in (*002.png) ;; (*) echo "  proof.json does not name the marked still: $m"; FAILED=1;; esac
assert_eq "the marked still in media/ carries the red frame" "230,0,0" "$(pixel "$SANDBOX/out/$m" 8 12)"
assert_eq "the run's own screenshot stays unmarked" "255,255,255" "$(pixel "$d/002.png" 8 12)"

# Without the test's mark: the agent's mark, orange, on the AC still, with its sentence.
jq '.run.results[0].attempts[0].steps |= map(select(.id != "x:3"))' "$R/cand/report.json" > "$SANDBOX/r.tmp" && mv "$SANDBOX/r.tmp" "$R/cand/report.json"
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/v.json" "$SANDBOX/out2" >/dev/null || FAILED=1
h="$(cat "$SANDBOX/out2/index.html")"
case "$h" in (*"AC-1: the orange frame is the agent&#39;s mark — the agent saw it"*'AC-1: the general page'*) ;; (*) echo "  the agent's mark is missing, or not first"; FAILED=1;; esac
m="$(jq -r '.rows[0].shots[0].src' "$SANDBOX/out2/proof.json")"
case "$m" in (*-agent-mark.png) ;; (*) echo "  proof.json does not name the agent's marked still: $m"; FAILED=1;; esac
assert_eq "the agent's frame is orange" "245,158,11" "$(pixel "$SANDBOX/out2/$m" 0 0)"
assert_eq "the AC still stays as it was" "255,255,255" "$(pixel "$SANDBOX/out2/media/$(ls "$SANDBOX/out2/media" | grep -- '-001\.png$')" 0 0)"

# A shot the agent names that does not exist, or a mark on a passing side: nothing is drawn.
jq '.acs[0].mark.shot = "AC-1: nothing like this"' "$SANDBOX/v.json" > "$SANDBOX/v2.json"
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/v2.json" "$SANDBOX/out3" >/dev/null || FAILED=1
case "$(cat "$SANDBOX/out3/index.html")" in (*"orange frame"*) echo "  a mark on a shot that does not exist was drawn"; FAILED=1;; esac
exit $FAILED
