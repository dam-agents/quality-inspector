#!/usr/bin/env bash
# env.sh in a platform Environment (docs/nested-env.md → Where the product runs, Kept for a
# person): the choice, the run over `ssh env-<name>`, the forward, keep / extend / release /
# kept, and platform-env.mjs against a stub of the platform's MCP tools.
. "$(dirname "$0")/lib.sh"
seed_work

# The platform's Environment tools: a JSON-RPC stub with a cap of 2, its state in a file.
H="$SANDBOX/home"; mkdir -p "$H/.platform"
cat > "$SANDBOX/mcp.mjs" <<'JS'
import { createServer } from 'node:http';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
const [stateF, portF] = process.argv.slice(2);
const load = () => (existsSync(stateF) ? JSON.parse(readFileSync(stateF, 'utf8')) : []);
const srv = createServer((req, res) => {
  let body = ''; req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const { params: { name, arguments: a } } = JSON.parse(body);
    let envs = load(), out, err;
    if (name === 'list_environments') out = envs;
    else if (name === 'create_environment') {
      if (a.name.endsWith('-full')) err = 'the storage pool is at its limit, maximum capacity reached';
      else if (envs.length >= 2) err = `this agent already holds ${envs.length} Environments, the most it may; delete one first`;
      else { envs.push({ name: a.name, endpoints: a.endpoints.map((e) => ({ ...e, url: `https://${e.name}-${a.name}.env.test` })), expires: a.expires, start: a.start }); out = envs.at(-1); }
    } else if (name === 'update_environment') { const e = envs.find((x) => x.name === a.name); if (e) { e.expires = a.expires; out = e; } else err = 'no such Environment'; }
    else if (name === 'delete_environment') { envs = envs.filter((x) => x.name !== a.name); out = { deleted: a.name }; }
    writeFileSync(stateF, JSON.stringify(envs));
    const result = err ? { isError: true, content: [{ type: 'text', text: err }] } : { content: [{ type: 'text', text: JSON.stringify(out) }] };
    res.setHeader('content-type', 'text/event-stream');
    res.end(`event: message\ndata: ${JSON.stringify({ jsonrpc: '2.0', id: 1, result })}\n\n`);
  });
});
srv.listen(0, '127.0.0.1', () => writeFileSync(portF, String(srv.address().port)));
JS
ST="$SANDBOX/envs.json"; node "$SANDBOX/mcp.mjs" "$ST" "$SANDBOX/mcp.port" & MCP=$!
trap 'kill $MCP 2>/dev/null; pkill -f "$SANDBOX/fwd-sleep" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
for _ in $(seq 1 50); do [ -s "$SANDBOX/mcp.port" ] && break; sleep 0.1; done
echo "{\"url\":\"http://127.0.0.1:$(cat "$SANDBOX/mcp.port")/mcp\",\"headers\":{\"authorization\":\"Bearer stub\"}}" > "$H/.platform/platform-mcp-entry.json"

# ssh: an Environment is a home of its own under $SANDBOX/envs/<name>; -N (the forward) sleeps.
B="$SANDBOX/bin"; mkdir -p "$B"
cat > "$B/ssh" <<'S'
#!/usr/bin/env bash
echo "ssh $*" >> "$SANDBOX/ssh.log"
fwd=0
while [ $# -gt 0 ]; do case "$1" in (-o|-L) shift 2;; (-N) fwd=1; shift;; (-*) shift;; (*) break;; esac; done
host="$1"; shift
[ -e "$SANDBOX/ssh-down" ] && exit 255
[ -e "$SANDBOX/ssh-hang" ] && [ "$fwd" = 0 ] && exec sleep 300
[ "$fwd" = 1 ] && exec -a "$SANDBOX/fwd-sleep" sleep 300
mkdir -p "$SANDBOX/envs/${host#env-}"; cd "$SANDBOX/envs/${host#env-}" || exit 1
# /dev/kvm there is $SANDBOX/env-kvm, for every Environment.
cmd="$*"; HOME="$PWD" bash -c "${cmd//\/dev\/kvm/$SANDBOX/env-kvm}"
S
printf '#!/usr/bin/env bash\nexit 0\n' > "$B/curl"
chmod +x "$B"/*
export SANDBOX
# This VM's /dev/kvm (environment.sh → KVM_DEV): absent until a test makes it.
export QI_KVM_DEVICE="$SANDBOX/vm-kvm"

# A profile whose bin/env records where it ran and with what.
pd="$QI_PROFILE_DIR"
jq '. + {environment: {endpoints: [{name: "app", port: 4400}, {name: "keycloak", port: 4400}], account: "viewer"}}' "$pd/profile.json" > "$pd/p.tmp" && mv "$pd/p.tmp" "$pd/profile.json"
cat > "$pd/bin/env" <<'S'
#!/usr/bin/env bash
echo "$1 ${2:-} target=${QI_NESTED_TARGET:-vm} eps=${QI_ENV_ENDPOINTS:-} model=${QI_MODEL_KEY:-} home=$HOME" >> "$QI_ENV_DIR/calls"
case "$1" in
  init) mkdir -p "$QI_ENV_DIR"; printf 'E2E_USER_OWNER_USERNAME=qa-owner\nE2E_USER_OWNER_PASSWORD=pw1\nE2E_USER_VIEWER_USERNAME=qa-viewer\nE2E_USER_VIEWER_PASSWORD=pw2\n' > "$QI_ENV_DIR/credentials.env";;
  up) [ "${STUB_UP_FAIL:-0}" = 1 ] && exit 1; echo "{\"build\":\"$2\"}" > "$QI_ENV_DIR/STATE.json";;
  status) echo '{"running":true,"build":"x","ui_http":"200"}';;
esac
S
chmod +x "$pd/bin/env"
E() { PATH="$B:$PATH" HOME="$H" bash "$SCRIPTS/env.sh" "$@"; }
EH() { PATH="$B:$PATH" HOME="$H" node "$SCRIPTS/lib/platform-env.mjs" "$@"; }

# platform-env.mjs: the tools answer; a name outside qi-… is refused before any call.
EH available; assert_eq "platform-env: available" 0 "$?"
EH delete other-env 2>/dev/null; assert_eq "platform-env: only qi-… names" 2 "$?"

# nested_target: vm keeps the product here.
echo "- nested_target: vm" >> "$WORK_DIR/CONFIG.md"
E init 2>/dev/null; E up 1.0.0 2>"$SANDBOX/err" >/dev/null; assert_eq "vm: up succeeds" 0 "$?"
grep -q "runs in this VM (nested_target is vm)" "$SANDBOX/err" || { echo "  vm: the reason is said: $(cat "$SANDBOX/err")"; FAILED=1; }
assert "vm: where" '.target == "vm"' "$(E where)"
grep -q "^up 1.0.0 target=vm" "$WORK_DIR/env/calls" || { echo "  vm: bin/env ran here"; FAILED=1; }

# auto, lend_model on → this VM, with the reason.
sed -i.bak 's/^- nested_target: vm$/- nested_target: auto/' "$WORK_DIR/CONFIG.md"
echo "- lend_model: enabled" >> "$WORK_DIR/CONFIG.md"
E up 1.0.0 2>"$SANDBOX/err" >/dev/null
grep -q "lend_model is enabled" "$SANDBOX/err" || { echo "  lend_model: stays in this VM: $(cat "$SANDBOX/err")"; FAILED=1; }
sed -i.bak '/^- lend_model:/d' "$WORK_DIR/CONFIG.md"

# auto, the profile sets kvm, this VM has no /dev/kvm → this VM, with the reason (an
# Environment gets the device only where this VM has it).
jq '.engine_config = ((.engine_config // {}) + {kvm: true})' "$pd/profile.json" > "$pd/p.tmp" && mv "$pd/p.tmp" "$pd/profile.json"
E up 1.0.0 2>"$SANDBOX/err" >/dev/null; assert_eq "kvm, none here: up succeeds" 0 "$?"
grep -q "runs in this VM (the profile sets kvm, and this VM has no /dev/kvm" "$SANDBOX/err" \
  || { echo "  kvm, none here: stays in this VM: $(cat "$SANDBOX/err")"; FAILED=1; }
assert "kvm, none here: where" '.target == "vm"' "$(E where)"
assert "kvm, none here: no Environment made" 'length == 0' "$(cat "$ST")"
# … this VM has it, the Environment not → the Environment is deleted, this VM runs the product.
touch "$QI_KVM_DEVICE"; : > "$WORK_DIR/env/calls"
E up 1.0.0 2>"$SANDBOX/err" >/dev/null; assert_eq "kvm, none there: up succeeds" 0 "$?"
grep -q "runs in this VM (the profile sets kvm, and Environment qi-[0-9-]* has no /dev/kvm)" "$SANDBOX/err" \
  || { echo "  kvm, none there: back to this VM: $(cat "$SANDBOX/err")"; FAILED=1; }
assert "kvm, none there: where" '.target == "vm"' "$(E where)"
assert "kvm, none there: the Environment is deleted" 'length == 0' "$(cat "$ST")"
grep -q "^up 1.0.0 target=vm" "$WORK_DIR/env/calls" || { echo "  kvm, none there: bin/env ran here"; FAILED=1; }
# … the link does not answer the check → up fails, and the Environment stays (no delete on doubt).
touch "$SANDBOX/ssh-down"; : > "$WORK_DIR/env/calls"
E up 1.0.0 2>"$SANDBOX/err" >/dev/null; assert_eq "kvm, no answer: up fails" 1 "$?"
grep -q "did not answer the /dev/kvm check (3 tries)" "$SANDBOX/err" || { echo "  kvm, no answer: the reason is said: $(cat "$SANDBOX/err")"; FAILED=1; }
assert "kvm, no answer: the Environment stays" 'length == 1' "$(cat "$ST")"
assert "kvm, no answer: it stays the active one" '.target == "environment"' "$(E where)"
grep -q "^up 1.0.0" "$WORK_DIR/env/calls" && { echo "  kvm, no answer: nothing runs in this VM"; FAILED=1; }
rm -f "$SANDBOX/ssh-down"
# … a link that hangs: each try is cut at its time bound, and the same no-answer path follows.
touch "$SANDBOX/ssh-hang"; t0=$(date +%s)
QI_KVM_PROBE_S=1 E up 1.0.0 2>"$SANDBOX/err" >/dev/null; assert_eq "kvm, hung link: up fails" 1 "$?"
[ $(( $(date +%s) - t0 )) -lt 60 ] || { echo "  kvm, hung link: the tries are time-bound"; FAILED=1; }
grep -q "did not answer the /dev/kvm check (3 tries)" "$SANDBOX/err" || { echo "  kvm, hung link: the reason is said: $(cat "$SANDBOX/err")"; FAILED=1; }
assert "kvm, hung link: the Environment stays" 'length == 1' "$(cat "$ST")"
rm -f "$SANDBOX/ssh-hang"
# … both have it → that Environment.
touch "$SANDBOX/env-kvm"
E up 1.0.0 2>"$SANDBOX/err" >/dev/null; assert_eq "kvm in both: up succeeds" 0 "$?"
w="$(E where)"; assert "kvm in both: an Environment" '.target == "environment" and (.name | startswith("qi-"))' "$w"
grep -q "runs in Environment" "$SANDBOX/err" || { echo "  kvm in both: the Environment is said: $(cat "$SANDBOX/err")"; FAILED=1; }
E release "$(jq -r .name <<<"$w")" >/dev/null 2>&1
rm -f "$SANDBOX/env-kvm"
jq 'del(.engine_config.kvm)' "$pd/profile.json" > "$pd/p.tmp" && mv "$pd/p.tmp" "$pd/profile.json"

# auto → a new Environment: bin/env runs there with its addresses, never the lent model; a forward.
: > "$WORK_DIR/env/calls"
E up 1.0.0 2>"$SANDBOX/err" >/dev/null; assert_eq "environment: up succeeds" 0 "$?"
w="$(E where)"
assert "environment: where" '.target == "environment" and (.name | startswith("qi-")) and .url == ("https://app-" + .name + ".env.test") and .forward' "$w"
n="$(jq -r .name <<<"$w")"
grep -q "^down " "$WORK_DIR/env/calls" || { echo "  moving to an Environment stops the product here"; FAILED=1; }
c="$(cat "$SANDBOX/envs/$n/qi/env/calls" 2>/dev/null)"
grep -q "^up 1.0.0 target=environment eps={\"app\":\"https://app-$n.env.test\",\"keycloak\":\"https://keycloak-$n.env.test\"} model= home=$SANDBOX/envs/$n" <<<"$c" \
  || { echo "  bin/env runs in the Environment with its addresses: $c"; FAILED=1; }
assert_eq "the credentials are copied over" "$(cat "$WORK_DIR/env/credentials.env")" "$(cat "$SANDBOX/envs/$n/qi/env/credentials.env")"
assert_eq "the copy is private" 700 "$(stat -c %a "$SANDBOX/envs/$n/qi/env" 2>/dev/null || stat -f %Lp "$SANDBOX/envs/$n/qi/env")"
assert "created with the profile's endpoints, a boot start and two days" '.[0].start == "bash $HOME/qi/boot.sh" and .[0].expires == "2d" and ([.[0].endpoints[].name] == ["app","keycloak"])' "$(cat "$ST")"
grep -q -- "-L 127.0.0.1:8080:127.0.0.1:8080 env-$n" "$SANDBOX/ssh.log" || { echo "  the forward keeps app.url's port"; FAILED=1; }
assert "status: from the Environment, with target" '.running and .target == "environment" and .environment == "'"$n"'"' "$(E status)"
# boot.sh brings the recorded build back.
( cd "$SANDBOX/envs/$n" && HOME="$PWD" bash qi/boot.sh ) && grep -q "^up 1.0.0 target=environment" "$SANDBOX/envs/$n/qi/env/calls" \
  || { echo "  boot.sh brings the recorded build up"; FAILED=1; }
# kubectl.sh: `k3s kubectl` there with run.sh's PATH set-up (a plain ssh shell can miss k3s),
# which the security run's deployment checks use, the namespace quoted.
grep -qF '/usr/local/bin/mise env -s bash' "$SANDBOX/envs/$n/qi/kubectl.sh" || { echo "  kubectl.sh sets the PATH first"; FAILED=1; }
mkdir -p "$SANDBOX/k3s"; printf '#!/usr/bin/env bash\necho "k3s $*"\n' > "$SANDBOX/k3s/k3s"; chmod +x "$SANDBOX/k3s/k3s"
assert_eq "kubectl.sh runs k3s kubectl there" "k3s kubectl get pods -n a b -o json" \
  "$(PATH="$B:$SANDBOX/k3s:$PATH" ssh -o BatchMode=yes "env-$n" bash qi/kubectl.sh get pods -n "'a b'" -o json)"
grep -qF "\`env-\${where[1]}\`, 'bash', 'qi/kubectl.sh']" "$SCRIPTS/security-checks.mjs" \
  || { echo "  the deployment checks reach k3s through qi/kubectl.sh in an Environment"; FAILED=1; }
# A second up reuses it.
E up 1.0.1 2>/dev/null >/dev/null
assert_eq "the active Environment is reused" "$n" "$(E where | jq -r .name)"

# keep: a row with the account's username (never a password); the next up makes a new one.
k="$(E keep issue-7 2>/dev/null)"
assert "keep: the row" '.name == "'"$n"'" and .label == "issue-7" and .build == "1.0.1" and .account == "qa-viewer" and (.url | startswith("https://app-")) and (.expires_utc | test("^20"))' "$k"
grep -q pw2 "$WORK_DIR/ENVIRONMENTS.json" && { echo "  a kept row never holds a password"; FAILED=1; }
assert "keep: extended 3 days" 'any(.[]; .name == "'"$n"'" and .expires == "3d")' "$(cat "$ST")"
assert "keep: no active Environment" '.target == "vm"' "$(E where)"
E keep issue-8 2>/dev/null; assert_eq "keep: nothing active → refused" 1 "$?"
assert "extend: more days" '.label == "issue-7"' "$(E extend issue-7 5 2>/dev/null)"
assert "extend: the platform's expiry" 'any(.[]; .name == "'"$n"'" and .expires == "5d")' "$(cat "$ST")"

# At the cap (2) a new run releases the oldest kept one first.
E up 2.0.0 2>/dev/null >/dev/null; n2="$(E where | jq -r .name)"
E keep issue-9 >/dev/null 2>&1
sleep 1
EH create qi-x-full '{"endpoints":[{"name":"app","port":4400}]}' 2>/dev/null; assert_eq "another refusal that names a limit is no cap" 1 "$?"
E up 3.0.0 2>"$SANDBOX/err" >/dev/null; assert_eq "at the cap: up succeeds" 0 "$?"
grep -q "releasing the oldest kept one, $n" "$SANDBOX/err" || { echo "  at the cap the oldest kept goes: $(cat "$SANDBOX/err")"; FAILED=1; }
assert "kept: the oldest is gone" 'map(.name) == ["'"$n2"'"] and .[0].exists' "$(E kept)"

# release by label; a failed up in an Environment is an exit 1.
E release issue-9 >/dev/null 2>&1; assert "release: gone" 'length == 0' "$(E kept)"
assert "release: the platform deleted it" 'all(.[]; .name != "'"$n2"'")' "$(cat "$ST")"
STUB_UP_FAIL=1 E up 3.0.1 >/dev/null 2>&1; assert_eq "a failed install there fails" 1 "$?"

# down closes the forward only; back to nested_target: vm deletes the active Environment.
E down; assert "down: no forward" '.forward == false' "$(E where)"
a="$(E where | jq -r .name)"
sed -i.bak 's/^- nested_target: auto$/- nested_target: vm/' "$WORK_DIR/CONFIG.md"
E up 3.0.2 2>/dev/null >/dev/null
assert "back to vm: the active Environment is deleted" 'all(.[]; .name != "'"$a"'")' "$(cat "$ST")"
assert "back to vm: where" '.target == "vm"' "$(E where)"

# The platform's tools not answering → this VM, with the reason.
sed -i.bak 's/^- nested_target: vm$/- nested_target: auto/' "$WORK_DIR/CONFIG.md"
mv "$H/.platform/platform-mcp-entry.json" "$H/.platform/off.json"
E up 3.0.3 2>"$SANDBOX/err" >/dev/null
grep -q "the platform's Environments do not answer" "$SANDBOX/err" || { echo "  no tools: this VM with the reason: $(cat "$SANDBOX/err")"; FAILED=1; }

# nested_target: environment never falls back to this VM: up fails with the reason.
sed -i.bak 's/^- nested_target: auto$/- nested_target: environment/' "$WORK_DIR/CONFIG.md"
: > "$WORK_DIR/env/calls"
E up 3.0.4 2>"$SANDBOX/err" >/dev/null; assert_eq "environment: no Environment → up fails" 1 "$?"
grep -q "nested_target is environment, and no Environment runs the product: the platform's Environments do not answer" "$SANDBOX/err" \
  || { echo "  environment: the reason is said: $(cat "$SANDBOX/err")"; FAILED=1; }
grep -q "^up 3.0.4" "$WORK_DIR/env/calls" && { echo "  environment: nothing runs in this VM"; FAILED=1; }
# … nor when the profile sets kvm and this VM has no /dev/kvm: up fails with that reason.
mv "$H/.platform/off.json" "$H/.platform/platform-mcp-entry.json"
jq '.engine_config = ((.engine_config // {}) + {kvm: true})' "$pd/profile.json" > "$pd/p.tmp" && mv "$pd/p.tmp" "$pd/profile.json"
rm -f "$QI_KVM_DEVICE"
E up 3.0.5 2>"$SANDBOX/err" >/dev/null; assert_eq "environment, kvm, none here: up fails" 1 "$?"
grep -q "nested_target is environment, and no Environment runs the product: the profile sets kvm, and this VM has no /dev/kvm" "$SANDBOX/err" \
  || { echo "  environment, kvm, none here: the reason is said: $(cat "$SANDBOX/err")"; FAILED=1; }
grep -q "^up 3.0.5" "$WORK_DIR/env/calls" && { echo "  environment, kvm, none here: nothing runs in this VM"; FAILED=1; }
# … nor when the Environment has no /dev/kvm: it is deleted, and up fails with that reason.
touch "$QI_KVM_DEVICE"
E up 3.0.6 2>"$SANDBOX/err" >/dev/null; assert_eq "environment, kvm, none there: up fails" 1 "$?"
grep -q "nested_target is environment, and no Environment runs the product: the profile sets kvm, and Environment qi-[0-9-]* has no /dev/kvm" "$SANDBOX/err" \
  || { echo "  environment, kvm, none there: the reason is said: $(cat "$SANDBOX/err")"; FAILED=1; }
grep -q "^up 3.0.6" "$WORK_DIR/env/calls" && { echo "  environment, kvm, none there: nothing runs in this VM"; FAILED=1; }
assert "environment, kvm, none there: the Environment is deleted" 'length == 0' "$(cat "$ST")"
assert "environment, kvm, none there: where" '.target == "vm"' "$(E where)"

exit $FAILED
