#!/usr/bin/env bash
# Property module (docs/property.md): the frozen file's closed vocabulary and its refusals, the
# assertions, the plan, and a real run against a local stub product — API, CLI, a 5xx, a flaky
# endpoint, a refused input, a leaked credential masked — with a small stand-in of fast-check
# (deterministic from the seed, greedy shrinking; the container has no npm). Then the design
# register merge of a property finding, its Design Desk message, and its issue draft.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
P="$SCRIPTS/property.mjs"
RULES="$SCRIPTS/lib/property-rules.mjs"

# ---------------------------------------------------------------- the rules (pure)
r="$(node --input-type=module -e "
import { validate, check, fill, fillPath, get, designRef } from '$RULES';
const ok = { build: 'c1', properties: [
  { id: 'PROP-1', kind: 'round-trip', statement: 's', source: 'q', input: { type: 'text', max: 20 },
    steps: [{ as: 'made', api: { method: 'POST', path: '/api/items', body: { name: '{input}' } } }, { as: 'back', cli: ['get', '{made.body.id}'] }],
    expect: [{ equal: ['back.body.name', '{input}'] }] },
  { id: 'PROP-2', kind: 'design', statement: 's', source: 'q', page: '/p', invariants: ['contrast'], vary: { width: [320, 800], zoom: [1, 2] } }] };
const bad = (mut) => { const d = structuredClone(ok); mut(d); return validate(d); };
const ctx = { input: 'x', stamp: 'st', made: { body: { id: 7, items: [{ n: 1 }, { n: 2 }], total: 3 } }, back: { status: 200, surface: 'api', body: { name: ' x ' } } };
console.log(JSON.stringify({
  valid: validate(ok),
  del: bad((d) => { d.properties[0].steps[0].api.method = 'DELETE'; }),
  danger: bad((d) => { d.properties[0].steps[0].api.path = '/api/items/remove'; }),
  dangerCli: bad((d) => { d.properties[0].steps[1].cli = ['delete', '{made.body.id}']; }),
  offsite: bad((d) => { d.properties[0].steps[0].api.path = '//evil.example/x'; }),
  scheme: bad((d) => { d.properties[0].steps[0].api.path = 'http://evil.example/x'; }),
  idem: bad((d) => { d.properties[0].kind = 'idempotent'; }),
  cross: bad((d) => { d.properties[0].kind = 'cross-surface'; d.properties[0].steps[1] = { as: 'back', api: { method: 'GET', path: '/x' } }; }),
  nosource: bad((d) => { delete d.properties[0].source; }),
  unknownref: bad((d) => { d.properties[0].expect = [{ equal: ['nope.body', '{input}'] }]; }),
  width: bad((d) => { d.properties[1].vary.width = [10, 99999]; }),
  inv: bad((d) => { d.properties[1].invariants = ['pretty']; }),
  dup: bad((d) => { d.properties[1].id = 'PROP-1'; }),
  eq: check({ equal: ['back.body.name', '{input}'] }, ctx),
  eqTrim: check({ equal: ['back.body.name', '{input}'], normalize: 'trim' }, ctx),
  sum: check({ sum: 'made.body.items[].n', equals: 'made.body.total' }, ctx),
  count: check({ count: 'made.body.items', equals: 'made.body.total' }, ctx),
  cmp: check({ compare: ['made.body.items[].n', '>=', 2] }, ctx),
  delta: check({ delta: ['made.body.total', 'made.body.items'], max: 0 }, ctx),
  ok: check({ ok: 'back' }, ctx),
  fillNum: fill({ id: '{made.body.id}', s: 'n-{stamp}' }, ctx),
  path: fillPath('/api/items/{input}/{made.body.id}', { ...ctx, input: 'a/b c' }),
  all: get({ a: [{ b: 1 }, { b: 2 }] }, '.a[].b'),
  ref: [designRef('/p', 'contrast', 'Save button 12'), designRef('/p', 'contrast', 'Save button 13'), designRef('/p', 'no-overlap', 'Save button 12')],
}));")"
assert "a valid file has no problems" '.valid == []' "$r"
assert "a delete is refused" '.del | map(select(test("never a delete"))) | length == 1' "$r"
assert "a destructive path is refused" '.danger | map(select(test("destructive"))) | length == 1' "$r"
assert "a destructive CLI argv is refused" '.dangerCli | map(select(test("destructive"))) | length == 1' "$r"
assert "a path off the product is refused" '(.offsite | length) == 1 and (.scheme | length) == 1' "$r"
assert "an idempotent property needs repeat and delta" '.idem | map(select(test("repeat 2..3 and a delta"))) | length == 1' "$r"
assert "a cross-surface property needs two surfaces" '.cross | map(select(test("two surfaces"))) | length == 1' "$r"
assert "a property needs its source" '.nosource | map(select(test("no source"))) | length == 1' "$r"
assert "an expect names an existing step" '.unknownref | map(select(test("names no step"))) | length == 1' "$r"
assert "design: width within the caps, invariants from the closed list" '(.width | length) == 1 and (.inv | length) == 1' "$r"
assert "ids are unique" '.dup | map(select(test("used twice"))) | length == 1' "$r"
assert "equal breaks on whitespace, holds with normalize trim" '(.eq | test("expected \"x\"")) and .eqTrim == null' "$r"
assert "sum, count and compare over [] paths" '.sum == null and (.count | test("has 2 items")) and (.cmp | test("is 1, expected >= 2"))' "$r"
assert "delta counts a list" '.delta == null' "$r"
assert "ok reads the status" '.ok == null' "$r"
assert "fill keeps a number a number, interpolates text" '.fillNum == {id:7, s:"n-st"}' "$r"
assert "a filled path segment is encoded" '.path == "/api/items/a%2Fb%20c/7"' "$r"
assert "[] collects every element" '.all == [1,2]' "$r"
assert "a Ref ignores digits in the element, differs by invariant" '.ref[0] == .ref[1] and .ref[0] != .ref[2] and (.ref[0] | test("^qi-prop-[0-9a-f]{10}$"))' "$r"

# ---------------------------------------------------------------- a stand-in of fast-check
mkdir -p "$SANDBOX/fc/node_modules/fast-check" "$SANDBOX/nofc"
echo '{"name":"fast-check","main":"index.js"}' > "$SANDBOX/fc/node_modules/fast-check/package.json"
cat > "$SANDBOX/fc/node_modules/fast-check/index.js" <<'JS'
// Deterministic from the seed; shrinking is greedy, path "i:k:k…" as fast-check's.
class Pre extends Error {}
const rng = (s) => () => { s |= 0; s = (s + 0x6d2b79f5) | 0; let t = Math.imul(s ^ (s >>> 15), 1 | s); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
const arb = (gen, shrink = () => []) => ({ gen, shrink, map(f) { return arb((r) => f(gen(r))); } });
const POOL = ['a', 'b', ' ', 'é', 'ש', '🙂'];
exports.string = ({ minLength = 0, maxLength = 10 } = {}) => arb((r) => {
  const n = minLength + Math.floor(r() * (Math.min(maxLength, minLength + 6) - minLength + 1));
  return Array.from({ length: n }, () => POOL[Math.floor(r() * POOL.length)]).join('');
}, (s) => (typeof s !== 'string' ? [] : [...new Set([s.length > minLength ? s.slice(1) : null, s.length > minLength ? s.slice(0, -1) : null, s.replace(/[^ a]/u, 'a')])].filter((x) => x !== null && x !== s)));
exports.integer = ({ min = -100, max = 100 } = {}) => arb((r) => min + Math.floor(r() * (max - min + 1)),
  (n) => (typeof n !== 'number' ? [] : [...new Set([Math.min(max, Math.max(min, 0)), Math.trunc(n / 2)])].filter((x) => x !== n && x >= min && x <= max)));
exports.constantFrom = (...xs) => arb((r) => xs[Math.floor(r() * xs.length)]);
exports.oneof = (...as) => { const list = as.map((a) => (a.arbitrary ? a : { arbitrary: a, weight: 1 })); const tot = list.reduce((s, a) => s + a.weight, 0);
  return arb((r) => { let x = r() * tot; for (const a of list) { if ((x -= a.weight) < 0) return a.arbitrary.gen(r); } return list[0].arbitrary.gen(r); },
    (v) => list.flatMap((a) => a.arbitrary.shrink(v))); };
exports.tuple = (...as) => arb((r) => as.map((a) => a.gen(r)), (v) => as.flatMap((a, i) => a.shrink(v[i]).map((x) => Object.assign([...v], { [i]: x }))));
exports.record = (o) => arb((r) => Object.fromEntries(Object.entries(o).map(([k, a]) => [k, a.gen(r)])),
  (v) => Object.entries(o).flatMap(([k, a]) => a.shrink(v[k]).map((x) => ({ ...v, [k]: x }))));
exports.pre = (c) => { if (!c) throw new Pre('pre'); };
exports.asyncProperty = (a, pred) => ({ a, pred });
exports.check = async ({ a, pred }, { numRuns = 100, seed = 0, path, endOnFailure, maxSkipsPerRun = 100 } = {}) => {
  const r = rng(seed); let runs = 0; let skips = 0;
  const fails = async (v) => { try { await pred(v); return null; } catch (e) { if (e instanceof Pre) return 'pre'; return e; } };
  if (path) {
    const [i, ...ks] = path.split(':').map(Number); let v; for (let n = 0; n <= i; n++) v = a.gen(r);
    for (const k of ks) v = a.shrink(v)[k];
    const e = await fails(v);
    return e && e !== 'pre' ? { failed: true, counterexample: [v], counterexamplePath: path, seed, numRuns: 1, numSkips: 0, numShrinks: 0, errorInstance: e } : { failed: false, numRuns: 1, numSkips: 0, seed };
  }
  for (let i = 0; runs < numRuns; i++) {
    if (skips > maxSkipsPerRun * numRuns) return { failed: true, counterexample: null, seed, numRuns: runs, numSkips: skips, errorInstance: new Error('too many pre-condition failures') };
    const v = a.gen(r); const e = await fails(v);
    if (e === 'pre') { skips++; continue; }
    runs++;
    if (!e) continue;
    let cur = v; let err = e; let p = String(i); let shrinks = 0;
    if (!endOnFailure) { let moved = true; while (moved) { moved = false; const cs = a.shrink(cur); for (let k = 0; k < cs.length; k++) { const e2 = await fails(cs[k]); if (e2 && e2 !== 'pre') { cur = cs[k]; err = e2; p += `:${k}`; shrinks++; moved = true; break; } } } }
    return { failed: true, counterexample: [cur], counterexamplePath: p, seed, numRuns: runs, numSkips: skips, numShrinks: shrinks, errorInstance: err };
  }
  return { failed: false, numRuns: runs, numSkips: skips, seed };
};
JS
export QI_FASTCHECK_FROM="$SANDBOX/fc/package.json"

# ---------------------------------------------------------------- the stub product
cat > "$SANDBOX/server.js" <<'JS'
const http = require('http'); const items = []; let flaky = 0;
const send = (r, code, o) => { r.statusCode = code; r.setHeader('content-type', 'application/json'); r.end(JSON.stringify(o)); };
const s = http.createServer((q, r) => {
  let body = ''; q.on('data', (c) => { body += c; }); q.on('end', () => {
    const j = (() => { try { return JSON.parse(body); } catch { return {}; } })();
    const u = new URL(q.url, 'http://x');
    if (q.method === 'POST' && u.pathname === '/api/items') {
      if (typeof j.name !== 'string' || !j.name.trim()) return send(r, 400, { error: 'name required' });
      items.push({ id: items.length + 1, name: j.name.trim() }); return send(r, 201, { id: items.length }); // the bug: trims
    }
    let m = /^\/api\/items\/(\d+)$/.exec(u.pathname);
    if (m) return items[m[1] - 1] ? send(r, 200, items[m[1] - 1]) : send(r, 404, {});
    if (u.pathname === '/api/items') return send(r, 200, { items, total: items.length });
    if (u.pathname === '/api/qty') return Number(j.qty) < 0 ? send(r, 500, {}) : send(r, 200, { qty: j.qty });
    if (u.pathname === '/api/never') return send(r, 422, { error: 'no' });
    if (u.pathname === '/api/flaky') return send(r, flaky++ === 0 ? 500 : 200, {});
    if (u.pathname === '/api/leak') return send(r, 200, { name: 'hunter22secret' });
    send(r, 404, {});
  });
});
s.listen(0, '127.0.0.1', () => require('fs').writeFileSync(process.argv[2], String(s.address().port)));
JS
node "$SANDBOX/server.js" "$SANDBOX/port" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$SANDBOX"' EXIT
for _ in $(seq 50); do [ -s "$SANDBOX/port" ] && break; sleep 0.1; done
PORT="$(cat "$SANDBOX/port")"; BASE="http://127.0.0.1:$PORT"
# The product's CLI (the profile's interfaces.cli): reads an item back as JSON from APP_URL.
mkdir -p "$SANDBOX/clibin"
cat > "$SANDBOX/clibin/widgets" <<'S'
#!/usr/bin/env bash
[ "$1" = get ] || exit 2
exec node -e 'fetch(process.env.APP_URL + "/api/items/" + process.argv[1]).then(async (r) => { if (!r.ok) process.exit(1); process.stdout.write(await r.text()); })' "$2"
S
chmod +x "$SANDBOX/clibin/widgets"
export PATH="$SANDBOX/clibin:$PATH"
jq '. + {interfaces:{cli:"widgets"}}' "$QI_PROFILE_DIR/profile.json" > "$SANDBOX/p.json" && mv "$SANDBOX/p.json" "$QI_PROFILE_DIR/profile.json"
mkdir -p "$WORK_DIR/env"; printf 'E2E_USER_OWNER_USERNAME=owner\nE2E_USER_OWNER_PASSWORD=hunter22secret\n' > "$WORK_DIR/env/credentials.env"

D="$WORK_DIR/property/c1"; mkdir -p "$D"
txt='{"type":"text","min":1,"max":12,"mix":["unicode","whitespace"]}'
jq -n --argjson t "$txt" '{build:"c1", properties:[
  {id:"PROP-1", kind:"round-trip", statement:"An item keeps its name", source:"SKILL.md", input:$t,
   steps:[{as:"made", api:{method:"POST", path:"/api/items", body:{name:"{input}"}}}, {as:"back", api:{method:"GET", path:"/api/items/{made.body.id}"}}],
   expect:[{equal:["back.body.name","{input}"]}]},
  {id:"PROP-2", kind:"cross-surface", statement:"The CLI shows the name the API saved, trimmed", source:"SKILL.md: names are trimmed", input:$t,
   steps:[{as:"made", api:{method:"POST", path:"/api/items", body:{name:"{input}"}}}, {as:"back", cli:["get","{made.body.id}"]}],
   expect:[{ok:"back"},{equal:["back.body.name","{input}"], normalize:"trim"}]},
  {id:"PROP-3", kind:"invariant", statement:"The total equals the items", source:"SKILL.md",
   steps:[{as:"list", api:{method:"GET", path:"/api/items"}}], expect:[{count:"list.body.items", equals:"list.body.total"},{compare:["list.body.total",">=",0]}]},
  {id:"PROP-4", kind:"invariant", statement:"Any quantity is answered without a server error", source:"API description",
   input:{type:"integer", min:-50, max:50}, steps:[{as:"q", api:{method:"POST", path:"/api/qty", body:{qty:"{input}"}}}], expect:[{ok:"q"}]},
  {id:"PROP-5", kind:"invariant", statement:"Never accepted", source:"x", steps:[{as:"n", api:{method:"POST", path:"/api/never", body:{v:"{input}"}}}], expect:[{ok:"n"}]},
  {id:"PROP-6", kind:"invariant", statement:"Flaky", source:"x", steps:[{as:"f", api:{method:"GET", path:"/api/items"}}, {as:"g", api:{method:"GET", path:"/api/flaky"}}], expect:[{ok:"g"}]},
  {id:"PROP-7", kind:"round-trip", statement:"Leaky", source:"x", input:$t,
   steps:[{as:"made", api:{method:"POST", path:"/api/items", body:{name:"{input}"}}}, {as:"back", api:{method:"GET", path:"/api/leak"}}], expect:[{equal:["back.body.name","{input}"]}]}]}' > "$D/properties.json"

# ---------------------------------------------------------------- plan, refusals
p="$(node "$P" "$D/properties.json" --build c1 --base "$BASE" --dry-run --seed 7)"
assert "dry-run: seed, runs from the registry default, surfaces" '.seed == 7 and .runs == 50 and (.properties | length) == 7 and .properties[1].surfaces == ["api","cli"]' "$p"
printf -- '- property_runs: 9\n- property_max_properties: 5\n' >> "$WORK_DIR/CONFIG.md"
p="$(node "$P" "$D/properties.json" --build c1 --base "$BASE" --dry-run)"
assert "config: runs and the property cap, the cut noted" '.runs == 9 and (.properties | length) == 5 and (.notes | map(select(test("the first 5"))) | length) == 1' "$p"
grep -v '^- property_max_properties' "$WORK_DIR/CONFIG.md" > "$SANDBOX/cfg" && cat "$SANDBOX/cfg" > "$WORK_DIR/CONFIG.md"
node "$P" "$D/properties.json" --build c1 --base http://staging.example.com --dry-run >/dev/null 2>&1
assert_eq "a non-local base is refused" 2 "$?"
o="$(node "$P" "$D/properties.json" --build c2 --base "$BASE" --dry-run)"; rc=$?
assert_eq "another build than the frozen one is refused" 2 "$rc"
jq '.properties[0].steps[0].api.method = "DELETE"' "$D/properties.json" > "$SANDBOX/bad.json"
o="$(node "$P" "$SANDBOX/bad.json" --build c1 --base "$BASE" --dry-run)"; rc=$?
assert_eq "an invalid file exits 2" 2 "$rc"
assert "with its problems" '.problems | map(select(test("PROP-1: step 1"))) | length == 1' "$o"
o="$(QI_FASTCHECK_FROM="$SANDBOX/nofc/package.json" node "$P" "$D/properties.json" --build c1 --base "$BASE" --skip-signin)"; rc=$?
assert_eq "no fast-check: the module failed (exit 3)" 3 "$rc"
assert "and says how to install it" '.error | test("suite.sh\" init")' "$o"
jq -n '{build:"c1", properties:[{id:"PROP-1", kind:"design", statement:"s", source:"q", page:"/", invariants:["contrast"]}]}' > "$SANDBOX/design.json"
o="$(QI_PLAYWRIGHT_FROM="$SANDBOX/nofc/package.json" node "$P" "$SANDBOX/design.json" --build c1 --base "$BASE" --skip-signin)"; rc=$?
assert_eq "a design property without a browser: exit 3" 3 "$rc"
[ ! -e "$WORK_DIR/property/c1/results.json" ]; assert_eq "nothing written on a failed start" 0 "$?"

# ---------------------------------------------------------------- a real run
o="$(node "$P" "$D/properties.json" --build c1 --base "$BASE" --skip-signin --seed 42 --runs 15)"; rc=$?
assert_eq "the run writes its results" 0 "$rc"
R="$(cat "$D/results.json")"
assert "summary counts" '.properties == 7 and .finding == 3 and .ok == 2 and .vacuous == 1 and .flaky == 1 and .seed == 42' "$o"
assert "results: the schema, the seed, every property" '.schema == "qi-property/v1" and .seed == 42 and .replay == false and (.properties | length) == 7' "$R"
assert "round-trip: the trim bug is a major finding, shrunk to one space and one letter" \
  '.properties[0] | .result == "finding" and .severity == "major" and .oracle == "assertion" and (.counterexample | test("^\\s.$|^.\\s$")) and .num_shrinks > 0' "$R"
assert "a finding carries its seed, path and replay command" '.properties[0] | .seed == 42 and (.path | test("^[0-9]+(:[0-9]+)+$")) and (.replay | test("--only PROP-1 --seed 42 --path "))' "$R"
assert "cross-surface through the CLI holds with trim" '.properties[1].result == "ok" and .properties[1].surfaces == ["api","cli"]' "$R"
assert "the invariant holds" '.properties[2].result == "ok"' "$R"
assert "a 5xx is no-server-error, shrunk to -1" '.properties[3] | .result == "finding" and .oracle == "no-server-error" and .counterexample == -1 and .severity == "major"' "$R"
assert "every input refused: vacuous" '.properties[4] | .result == "vacuous" and (.message | test("refused every"))' "$R"
assert "a failure that passes again: flaky, no severity" '.properties[5] | .result == "flaky" and .severity == null' "$R"
assert "no design finding from functional properties" '.findings == [] and .register == []' "$R"
grep -q hunter22secret "$D/results.json"; assert_eq "a credential value in an answer is masked" 1 "$?"
assert "the masked message is still there" '.properties[6].message | test("\\*\\*\\*")' "$R"

# replay: the shrunk input only, into its own file; results.json untouched
before="$(cksum < "$D/results.json")"
path="$(jq -r '.properties[3].path' <<<"$R")"
o="$(node "$P" "$D/properties.json" --build c1 --base "$BASE" --skip-signin --only PROP-4 --seed 42 --path "$path")"
assert "replay: the same counterexample breaks again" '.finding == 1 and .properties == 1' "$o"
assert "replay file, marked as a replay" '.replay == true and .properties[0].counterexample == -1' "$(cat "$D/results-replay-PROP-4.json")"
assert_eq "results.json untouched by a replay" "$before" "$(cksum < "$D/results.json")"
node "$P" "$D/properties.json" --build c1 --base "$BASE" --skip-signin --path 0:1 >/dev/null 2>&1
assert_eq "--path without --only is refused" 2 "$?"

# ---------------------------------------------------------------- design register and Design Desk
mkdir -p "$WORK_DIR/property/c2/shots"; : > "$WORK_DIR/property/c2/shots/001.png"
jq -n --arg att "$WORK_DIR/property/c2/shots/001.png" '{schema:"qi-property/v1", build:"c2", replay:false, seed:5,
  ran:[{id:"PROP-9", kind:"design", page:"/projects", invariants:["no-sideways-scroll","contrast"]}],
  properties:[{id:"PROP-9", kind:"design", statement:"The list holds its layout", result:"finding", severity:"major"}],
  findings:[{ref:"qi-prop-0123456789", check:"property", severity:"high", title:"The list holds its layout — no-sideways-scroll breaks on /projects",
    screen:"/projects", path:"/projects", what:"At 321 px wide: the page scrolls sideways", expected:"The page does not scroll sideways.", steps:["Open /projects 321 px wide."], build:"c2", attachment:$att}],
  register:[{property:"PROP-9", pattern:"/projects", invariant:"no-sideways-scroll", check:"overflow-x", severity:"major", target:"the page", detail:"420 px wider than the window",
    box:{x:0,y:0,w:741,h:50}, shot:"shots/001.png", sample:{width:321, zoom:1, text_length:0, locale:"ar"}, seed:5, path:"3:1"}]}' > "$WORK_DIR/property/c2/results.json"
m="$(node "$SCRIPTS/design-findings.mjs" merge --property "$WORK_DIR/property/c2/results.json" --no-render)"
REG="$(cat "$WORK_DIR/design/findings.json")"
assert "a property finding joins the register" '.findings | length == 1 and .[0].source == "property" and .[0].check == "property:no-sideways-scroll" and .[0].severity == "major" and .[0].status == "open" and .[0].viewport == "-"' "$REG"
assert "with its sample, seed and path" '.findings[0].property == {id:"PROP-9", sample:{width:321, zoom:1, text_length:0, locale:"ar"}, seed:5, path:"3:1"} and (.findings[0].saw | test("321 px wide"))' "$REG"
assert "recheck-plan points to the replay" '.sweep == null and (.note | test("Replay"))' "$(node "$SCRIPTS/design-findings.mjs" recheck-plan D-1)"
mkdir -p "$WORK_DIR/property/c3"
jq '.build = "c3" | .register = [] | .findings = [] | .properties[0].result = "ok"' "$WORK_DIR/property/c2/results.json" > "$WORK_DIR/property/c3/results.json"
node "$SCRIPTS/design-findings.mjs" merge --property "$WORK_DIR/property/c3/results.json" --no-render >/dev/null
assert "a later run that tried the invariant there resolves it" '.findings[0].status == "resolved" and .findings[0].resolved_build == "c3"' "$(cat "$WORK_DIR/design/findings.json")"
jq '.replay = true' "$WORK_DIR/property/c3/results.json" > "$SANDBOX/replay.json"
node "$SCRIPTS/design-findings.mjs" merge --property "$SANDBOX/replay.json" --no-render >/dev/null 2>&1
assert_eq "a replay file never merges" 2 "$?"
jq '.properties[0].result = "blocked" | .build = "c4"' "$WORK_DIR/property/c2/results.json" > "$SANDBOX/c4.json"
node "$SCRIPTS/design-findings.mjs" merge --property "$SANDBOX/c4.json" --no-render >/dev/null
assert "seen again: open" '.findings[0].status == "open" and .findings[0].resolved_build == null' "$(cat "$WORK_DIR/design/findings.json")"

printf -- '- design_desk_findings: enabled\n- design_desk_channel: C0123ABCD\n- design_desk_bot: U0123ABCD\n' >> "$WORK_DIR/CONFIG.md"
o="$(node "$SCRIPTS/design-outbox.mjs" plan "$WORK_DIR/property/c2/results.json")"
assert "the Design Desk takes Check: property" '.sending == true and (.due | length) == 1 and (.due[0].text | test("\nCheck: property\nSeverity: high\nRef: qi-prop-0123456789\n<@U0123ABCD>$"))' "$o"

# ---------------------------------------------------------------- an issue draft
o="$(node "$SCRIPTS/issue-draft.mjs" PROP-4 2>/dev/null)"
assert "create issue for PROP-<k>: a draft of that property" '.refs == ["PROP-4"] and .build == "c1" and .missing == []' "$o"
body="$(jq -r '.dir' <<<"$o")/body.md"
grep -q 'seed `42`' "$body"; assert_eq "the draft names the seed" 0 "$?"
grep -q 'Send `POST /api/qty`' "$body"; assert_eq "the draft names the step" 0 "$?"
grep -q 'smallest generated input that breaks it: `-1`' "$body"; assert_eq "the draft names the smallest input" 0 "$?"

exit $FAILED
