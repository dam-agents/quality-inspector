#!/usr/bin/env bash
# iface-snapshot.mjs + iface-diff.mjs + impact.mjs --iface: a CLI's --help and a served API
# description become a snapshot; two snapshots name removed commands, flags, endpoints and
# fields; a test naming one is impacted; a profile without interfaces is skipped.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
mkdir -p "$SANDBOX/bin"

# A stub CLI whose help differs by build (the snapshot hands the CLI none of our environment, so
# the build comes from a file): commander-style root, cobra-style subcommands.
{ echo '#!/usr/bin/env bash'; echo "STUB_BUILD=\"\$(cat '$SANDBOX/cli-build')\""; } > "$SANDBOX/bin/widgets"
cat >> "$SANDBOX/bin/widgets" <<'S'
[ -z "${E2E_USER_OWNER_PASSWORD:-}" ] || { echo "credentials leaked into the CLI"; exit 1; }
case "$*" in
  "--help") printf 'Usage: widgets [options] [command]\n\nOptions:\n  -V, --version   output the version number\n  -h, --help      display help\n\nCommands:\n  agents [options]  manage agents\n  help [command]    display help for command\n';;
  "agents --help")
    printf 'Manage agents\n\nUsage:\n  widgets agents [command]\n\nAvailable Commands:\n  list        list agents\n'
    [ "$STUB_BUILD" = old ] && printf '  rm          remove an agent\n'
    printf '\nFlags:\n  -h, --help   help for agents\n';;
  "agents list --help")
    printf 'Usage:\n  widgets agents list [flags]\n\nFlags:\n  --json         machine output\n'
    [ "$STUB_BUILD" = old ] && printf '  --limit <n>    at most n (see --json)\n'; true;;
  "agents rm --help") printf 'Usage:\n  widgets agents rm <name> [flags]\n\nFlags:\n  -f, --force   no confirmation\n';;
  *) echo "unknown command: $*" >&2; exit 1;;
esac
S
chmod +x "$SANDBOX/bin/widgets"

# The API description, served on 127.0.0.1 from a file that the test swaps between builds.
spec() { # <with-delete> <with-status>
  jq -nc --argjson del "$1" --argjson st "$2" '{openapi:"3.0.0",
    paths:({"/api/agents":{get:{responses:{"200":{content:{"application/json":{schema:{type:"array",items:{"$ref":"#/components/schemas/Agent"}}}}}}}},
            "/api/agents/{id}":({get:{responses:{"200":{content:{"application/json":{schema:{"$ref":"#/components/schemas/Agent"}}}}}}}
                                + (if $del then {delete:{responses:{"204":{description:"gone"}}}} else {} end))}),
    components:{schemas:{Agent:{type:"object",properties:({id:{type:"string"},name:{type:"string"}} + (if $st then {status:{type:"string"},owner:{type:"string"}} else {} end))}}}}' > "$SANDBOX/spec.json"
}
spec true true
node -e '
  const http = require("http"), fs = require("fs");
  const s = http.createServer((q, r) => { r.setHeader("content-type", "application/json"); r.end(fs.readFileSync(process.argv[1])); });
  s.listen(0, "127.0.0.1", () => fs.writeFileSync(process.argv[2], String(s.address().port)));
' "$SANDBOX/spec.json" "$SANDBOX/port" &
SRV=$!; disown "$SRV"
trap 'kill $SRV 2>/dev/null; rm -rf "$SANDBOX"' EXIT
for _ in $(seq 50); do [ -s "$SANDBOX/port" ] && break; sleep 0.1; done
PORT="$(cat "$SANDBOX/port")"
jq --arg u "http://127.0.0.1:$PORT" '.app.url = $u | .interfaces = {cli:"widgets", openapi:"/openapi.json"}' \
  "$QI_PROFILE_DIR/profile.json" > "$SANDBOX/p.json" && mv "$SANDBOX/p.json" "$QI_PROFILE_DIR/profile.json"

snap() { echo "$1" > "$SANDBOX/cli-build"; E2E_USER_OWNER_PASSWORD=secret PATH="$SANDBOX/bin:$PATH" node "$SCRIPTS/iface-snapshot.mjs" "b-$1" "$SANDBOX/inv/$1"; }
out="$(snap old)"
assert "old snapshot: four commands, three endpoints read" '.commands == 4 and .endpoints == 3 and .errors == []' "$out"
o="$(cat "$SANDBOX/inv/old/iface.json")"
assert "root and nested flags" '.cli.commands[""] == ["--help","--version","-V","-h"] and .cli.commands["agents list"] == ["--json","--limit"]' "$o"
assert "fields through \$ref and array items" '.api.endpoints["GET /api/agents"] == ["[].id","[].name","[].owner","[].status"]' "$o"
spec false false
snap new >/dev/null
ls /tmp/quality-inspector-iface-* >/dev/null 2>&1 && { echo "  the CLI's temporary HOME was left behind"; FAILED=1; }

d="$(node "$SCRIPTS/iface-diff.mjs" "$SANDBOX/inv/old/iface.json" "$SANDBOX/inv/new/iface.json")"
assert "removed command" '.commands_removed == [{"command":"agents rm"}] and .program == "widgets"' "$d"
assert "removed flag of a surviving command" '.flags_removed == [{"command":"agents list","flag":"--limit"}]' "$d"
assert "removed method of a surviving path" '.endpoints_removed == [{"endpoint":"DELETE /api/agents/{id}","path_remains":true}]' "$d"
assert "removed response fields" '[.fields_removed[].field] == ["[].owner","[].status","owner","status"] and .unchanged == false' "$d"
assert "self diff is empty" '.unchanged == true' "$(node "$SCRIPTS/iface-diff.mjs" "$SANDBOX/inv/old/iface.json" "$SANDBOX/inv/old/iface.json")"
assert "missing snapshot is skipped" '.skipped | test("no interface snapshot")' "$(node "$SCRIPTS/iface-diff.mjs" "$SANDBOX/inv/none/iface.json" "$SANDBOX/inv/new/iface.json")"
node "$SCRIPTS/iface-diff.mjs" "$SANDBOX/inv/old/iface.json" "$SANDBOX/inv/new/iface.json" --md | grep -q 'removed flag `--limit` of `widgets agents list`' \
  || { echo "  markdown summary missing the removed flag"; FAILED=1; }

printf '%s' "$d" > "$SANDBOX/iface-diff.json"
cat > "$SANDBOX/issue-1.e2e.ts" <<'T'
const r = await execa('widgets', ['agents', 'rm', name, '--force']);
await fetch(`${app.baseUrl}/api/agents/${id}`, { method: 'DELETE' });
// AC-1 begin
expect((await execa('widgets', ['agents', 'list', '--limit', '1'])).exitCode).toBe(0);
// AC-1 end
T
cat > "$SANDBOX/issue-2.e2e.ts" <<'T'
const body = await (await fetch(`${app.baseUrl}/api/agents`)).json();
// AC-1 begin
expect(body[0].owner).toBe('alice');
// AC-1 end
T
cat > "$SANDBOX/issue-3.e2e.ts" <<'T'
const res = await fetch(`${app.baseUrl}/api/agents/${id}`);
expect(res.status).toBe(200);
T
i="$(node "$SCRIPTS/impact.mjs" none --iface "$SANDBOX/iface-diff.json" "$SANDBOX/issue-1.e2e.ts" "$SANDBOX/issue-2.e2e.ts" "$SANDBOX/issue-3.e2e.ts")"
assert "command, flag and endpoint hit test 1" '.impacted[0].hits | map(.change) | (map(select(test("command \"widgets agents rm\""))) | length == 1) and (map(select(test("flag --limit"))) | length == 1) and (map(select(test("endpoint DELETE"))) | length == 1)' "$i"
assert "removed flag inside the AC block" '.impacted[0].hits | map(select(.change | test("--limit"))) | .[0].inAcBlock == true' "$i"
assert "removed field hits the test that calls its endpoint" '.impacted[1].test | endswith("issue-2.e2e.ts")' "$i"
assert "res.status on another endpoint and GET of a surviving path are clear" '.clear == ["'"$SANDBOX"'/issue-3.e2e.ts"]' "$i"

jq '.interfaces = {openapi:"https://elsewhere.example/openapi.json"}' "$QI_PROFILE_DIR/profile.json" > "$SANDBOX/p.json" && mv "$SANDBOX/p.json" "$QI_PROFILE_DIR/profile.json"
assert "an API description off the nested product is refused" '.errors | length == 1 and (.[0] | test("refusing"))' "$(node "$SCRIPTS/iface-snapshot.mjs" b-y "$SANDBOX/inv/y")"
jq 'del(.interfaces)' "$QI_PROFILE_DIR/profile.json" > "$SANDBOX/p.json" && mv "$SANDBOX/p.json" "$QI_PROFILE_DIR/profile.json"
assert "no interfaces -> skipped" '.skipped | test("no interfaces")' "$(node "$SCRIPTS/iface-snapshot.mjs" b-x "$SANDBOX/inv/x")"
[ -e "$SANDBOX/inv/x/iface.json" ] && { echo "  a skipped snapshot must write nothing"; FAILED=1; }
exit $FAILED
