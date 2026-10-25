#!/usr/bin/env bash
# report-media.mjs: a rendered report becomes one file. Public: each media file it names is listed,
# with the content type its upload sends, its uploaded artifact's address is recorded by content and
# type (an untyped one is uploaded again; one whose served type differs is not recorded), and the
# page links the addresses — never
# a relative media/ link; a file without an address writes nothing. Private: screenshots, then the
# candidate's video go into the page as data: URIs within the page budget; what does not fit is a
# line that says so; a trace is never inlined. A reference outside media/ is refused.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
R="$SANDBOX/runs"
mk_run() { # <label> <status>
  local d="$R/$1/artifacts/web/t1/default/attempt-0"
  mkdir -p "$d/video" "$d/screenshots" "$d/trace"
  { printf '%s' "$1"; head -c 3000 /dev/zero | tr '\0' v; } > "$d/video/video.webm"; printf 'png-%s' "$1" > "$d/screenshots/001-AC-1.png"; printf 'zip-%s' "$1" > "$d/trace/trace.zip"
  cat > "$R/$1/report.json" <<J
{"run":{"results":[{"titlePath":["#42 AC-1: renamed"],"tags":["issue-42","ac-1"],"status":"$2","attempts":[{"durationMs":900,"error":null,
  "artifacts":[{"id":"a:0","kind":"screenshot","path":"web/t1/default/attempt-0/screenshots/001-AC-1.png","producer":{"kind":"step","stepId":"x:1"}},
               {"id":"a:1","kind":"video","path":"web/t1/default/attempt-0/video/video.webm","producer":{"kind":"attempt"}},
               {"id":"a:2","kind":"trace","path":"web/t1/default/attempt-0/trace/trace.zip","producer":{"kind":"attempt"}}],
  "steps":[{"id":"x:1","api":"app.screenshot","label":"AC-1: the renamed agent","status":"passed","durationMs":20,"artifacts":["a:0"]}]}]}]}}
J
}
mk_run cand passed; mk_run base failed
cat > "$SANDBOX/v.json" <<'J'
{"issue":42,"title":"Rename","ac_hash":"abc","candidate":"c1","baseline":"b1","candidate_run":"cand","baseline_run":"base",
 "verdict":"verified","acs":[{"id":"AC-1","name":"renamed","then":"the new name shows","testable":true,"verdict":"verified"}]}
J
D="$SANDBOX/issues/42/report-abc-c1"; mkdir -p "$SANDBOX/issues/42"
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/v.json" "$D" >/dev/null || { echo "  render failed"; exit 1; }
M="$SCRIPTS/report-media.mjs"

list="$(node "$M" list "$D")"
assert "list: every media file the page names, none uploaded yet" '(.media | length) == 6 and all(.media[]; .url == null and (.path | startswith("media/")) and (.sha256 | test("^[0-9a-f]{64}$")))' "$list"
assert "list: each file carries the type it is uploaded with" '[.media[] | {e: (.path | split(".") | last), t: .content_type}] | unique == [{e:"png",t:"image/png"},{e:"webm",t:"video/webm"},{e:"zip",t:"application/zip"}]' "$list"
out="$(node "$M" publish "$D" public)"; rc=$?
assert_eq "public without addresses fails" 1 "$rc"
assert "… and names what is missing, writing nothing" '.file == null and (.missing | length) == 6' "$out"
[ -f "$D/publish.html" ] && { echo "  a public page was written with media missing"; FAILED=1; }

node "$M" set "$D" media/nope.webm https://share.example/a/Abc 1 >/dev/null 2>&1; assert_eq "set: an unknown file is refused" 2 "$?"
first="$(jq -r '.media[0].path' <<<"$list")"
node "$M" set "$D" "$first" http://share.example/a/Abc 1 >/dev/null 2>&1; assert_eq "set: not https is refused" 2 "$?"
node "$M" set "$D" "$first" 'https://share.example/a/Abc?x=1' 1 >/dev/null 2>&1; assert_eq "set: a query is refused" 2 "$?"
# The served-type gate: another type than the file's records nothing; the same type, parameters aside, records.
png="$(jq -r '[.media[] | select(.content_type == "image/png")][0].path' <<<"$list")"
out="$(node "$M" set "$D" "$png" https://share.example/a/Bad 1 --served-type application/octet-stream)"; rc=$?
assert_eq "set: a served type other than the file's fails" 1 "$rc"
assert "… names both types and records nothing" '.url == null and .content_type == "image/png" and .served_type == "application/octet-stream"' "$out"
[ -f "$SANDBOX/issues/42/media-urls.json" ] && { echo "  a rejected address was recorded"; FAILED=1; }
node "$M" set "$D" "$png" https://share.example/a/Abc 1 --served-type >/dev/null 2>&1; assert_eq "set: --served-type without a type is usage" 2 "$?"
assert "set: the served type matches without its parameters" '.url == "https://share.example/a/Ok/raw?v=1"' "$(node "$M" set "$D" "$png" https://share.example/a/Ok 1 --served-type 'Image/PNG; charset=binary')"
rm -f "$SANDBOX/issues/42/media-urls.json"
k=0; for p in $(jq -r '.media[].path' <<<"$list"); do k=$((k + 1)); node "$M" set "$D" "$p" "https://share.example/a/S$k" 2 >/dev/null; done
assert "the addresses are kept by content and type beside the report" '[.[]] | length == 6 and all(.url | test("^https://share.example/a/S[0-9]/raw\\?v=2$")) and all(.content_type | test("^(image/png|video/webm|application/zip)$"))' "$(cat "$SANDBOX/issues/42/media-urls.json")"
out="$(node "$M" publish "$D" public)"
assert "public: every reference linked, the page typed as HTML" '.linked == 6 and .inlined == 0 and .left_out == [] and .content_type == "text/html; charset=utf-8"' "$out"
grep -q '"media/' "$D/publish.html" && { echo "  public page still has a relative media/ link"; FAILED=1; }
grep -q 'src="https://share.example/a/S[0-9]/raw?v=2"' "$D/publish.html" || { echo "  public page lacks an absolute media address"; FAILED=1; }
cmp -s "$D/index.html" "$D/publish.html" && { echo "  index.html was changed in place"; FAILED=1; }
grep -q '"media/' "$D/index.html" || { echo "  index.html lost its media/ links"; FAILED=1; }
# A new render of the same evidence keeps the addresses: nothing to upload again.
QI_RUNS_ROOT="$R" node "$SCRIPTS/render-report.mjs" "$SANDBOX/v.json" "$D" >/dev/null
assert "a new revision with the same files uploads nothing" 'all(.media[]; .url != null)' "$(node "$M" list "$D")"

out="$(node "$M" publish "$D" private)"
assert "private: screenshots and videos inline, the trace left out" '.inlined == 4 and .left_out == ["media/42-ac-1-candidate-trace-trace.zip","media/42-ac-1-baseline-trace-trace.zip"]' "$out"
h="$(cat "$D/publish.html")"
grep -q '"media/' <<<"$h" && { echo "  private page still has a relative media/ link"; FAILED=1; }
case "$h" in *'<video controls preload="metadata" src="data:video/webm;base64,'*) ;; *) echo "  private page: no inline video"; FAILED=1;; esac
case "$h" in *'poster='*) echo "  private page: a poster repeats the screenshot"; FAILED=1;; esac
case "$h" in *'trace.zip (not in this private report)'*) ;; *) echo "  private page: the trace line is missing"; FAILED=1;; esac
# A small budget keeps the screenshots, then the candidate's video, and drops the baseline's.
size="$(wc -c < "$D/publish.html" | tr -d ' ')"
out="$(QI_REPORT_PAGE_MAX=$((size - 2000)) node "$M" publish "$D" private)"
assert "a budget drops the baseline video first" '.inlined == 3 and (.left_out | index("media/42-ac-1-baseline-video-video.webm")) != null and (.left_out | index("media/42-ac-1-candidate-video-video.webm")) == null' "$out"
case "$(cat "$D/publish.html")" in *'This private report has a size limit'*) ;; *) echo "  private page: no line for the dropped video"; FAILED=1;; esac

# An address recorded without its type (uploaded untyped, before 3.32.1) is no address: upload again.
cp "$SANDBOX/issues/42/media-urls.json" "$SANDBOX/urls.bak"
jq 'with_entries(.value |= .url)' "$SANDBOX/urls.bak" > "$SANDBOX/issues/42/media-urls.json"
assert "an untyped address is uploaded again" 'all(.media[]; .url == null)' "$(node "$M" list "$D")"
node "$M" publish "$D" public >/dev/null 2>&1; assert_eq "… and never linked" 1 "$?"
jq 'with_entries(.value.content_type = "application/x-www-form-urlencoded")' "$SANDBOX/urls.bak" > "$SANDBOX/issues/42/media-urls.json"
assert "an address of another type is uploaded again" 'all(.media[]; .url == null)' "$(node "$M" list "$D")"
mv "$SANDBOX/urls.bak" "$SANDBOX/issues/42/media-urls.json"
# A damaged address file is an error, not an empty one.
cp "$SANDBOX/issues/42/media-urls.json" "$SANDBOX/urls.bak"; echo '[1' > "$SANDBOX/issues/42/media-urls.json"
node "$M" list "$D" >/dev/null 2>&1; assert_eq "a damaged media-urls.json fails" 1 "$?"
mv "$SANDBOX/urls.bak" "$SANDBOX/issues/42/media-urls.json"
# The page may name media/ files only.
sed 's|src="media/42-ac-1-candidate-video-video.webm"|src="media/../../secret"|' "$D/index.html" > "$D/x" && mv "$D/x" "$D/index.html"
node "$M" publish "$D" private >/dev/null 2>&1; assert_eq "a reference out of media/ is refused" 2 "$?"
node "$M" publish "$D" >/dev/null 2>&1; assert_eq "usage" 2 "$?"
exit $FAILED
