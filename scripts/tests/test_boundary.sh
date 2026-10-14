#!/usr/bin/env bash
# The black-box boundary: the rules egress-rules.sh prints hold under the platform's rule
# matching, and the probes tell a refusal from a reachable or unproven surface.
. "$(dirname "$0")/lib.sh"
seed_work
ROOT="$(cd "$SCRIPTS/.." && pwd)"

# ---------------------------------------------------------------- the rules
cat > "$QI_PROFILE_DIR/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "egress":[{"host":"github.com","method":"GET","path":"/cert-manager/cert-manager/releases/*","why":"manifest"},
           {"host":"*.quay.io","method":"GET","why":"image layers"}]}
J
printf -- '- profile_source_path: /qa/\n- work_repo: acme/widgets-qa\n' >> "$WORK_DIR/CONFIG.md"
export QI_DEFINITION_REPO=github.com/acme/quality-inspector
cmds="$(bash "$SCRIPTS/egress-rules.sh" --kit --source acme/profiles)"
assert_eq "the commands start with the AGENT guard" ': "${AGENT:?set AGENT to this agent'"'"'s name}"' "$(printf '%s\n' "$cmds" | head -1)"
printf '%s\n' "$cmds" | grep -qxF 'dam network create "$AGENT" --host "*.gitlab.com" --path "/*" --verdict deny --yes' \
  || { echo "  assertion failed: wildcard kit host quoted"; FAILED=1; }
printf '%s\n' "$cmds" | grep -qxF 'dam network create "$AGENT" --host "*.quay.io" --method GET --yes  # image layers' \
  || { echo "  assertion failed: profile egress line"; FAILED=1; }

# A model of the platform's match (egress-rules-repository findMatch): the exact host,
# then *.parent, then *; a named method over *; a path over *; the longer path; '*' in a
# pattern is SQL LIKE '%' (a literal '%' is one too, '_' any one character). The `trusted` preset and the
# GitHub connection hold host-wide allows on these hosts before the kit's rules land.
verdicts="$(printf '%s\n' "$cmds" | node -e '
const lines = require("fs").readFileSync(0, "utf8").split("\n").filter(l => l.startsWith("dam network create"));
const arg = (l, f) => { const m = l.match(new RegExp(f + " (\"[^\"]*\"|\\S+)")); return m ? m[1].replace(/"/g, "") : null; };
const rules = lines.map(l => ({ host: arg(l, "--host"), method: arg(l, "--method") || "*",
  path: arg(l, "--path") || "*", verdict: arg(l, "--verdict") || "allow" }));
for (const h of ["github.com", "api.github.com", "codeload.github.com", "raw.githubusercontent.com",
                 "objects.githubusercontent.com", "gitlab.com", "codeberg.org", "registry.npmjs.org"])
  rules.push({ host: h, method: "*", path: "*", verdict: "allow" });
const like = p => new RegExp("^" + [...p].map(c => c === "*" || c === "%" ? ".*" : c === "_" ? "." : c.replace(/[.+?^${}()|[\]\\\/]/g, "\\$&")).join("") + "$", "s");
const rank = (r, host) => [r.host === host ? 0 : r.host === "*" ? 2 : 1, r.method === "*" ? 1 : 0, r.path === "*" ? 1 : 0, -r.path.length];
function decide(method, url) {
  const u = new URL(url), host = u.hostname, path = u.pathname + u.search;
  const cands = host.includes(".") ? [host, "*." + host.slice(host.indexOf(".") + 1), "*"] : [host, "*"];
  const hits = rules.filter(r => cands.includes(r.host) && (r.method === method || r.method === "*") && like(r.path).test(path));
  hits.sort((a, b) => { const x = rank(a, host), y = rank(b, host); for (let i = 0; i < 4; i++) if (x[i] !== y[i]) return x[i] - y[i]; return 0; });
  return hits.length ? hits[0].verdict : "hold";
}
for (const l of require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n")) {
  const [want, method, url] = l.split(" ");
  const got = decide(method, url);
  if (got !== want) console.log(`${method} ${url}: want ${want}, got ${got}`);
}' <(cat <<'R'
allow GET https://api.github.com/repos/acme/widgets/issues?labels=qa:ready&state=all&per_page=100
allow GET https://api.github.com/repos/acme/widgets/issues/7
allow GET https://api.github.com/repos/acme/widgets/issues/7/comments?per_page=100
allow POST https://api.github.com/repos/acme/widgets/issues/7/comments
allow DELETE https://api.github.com/repos/acme/widgets/issues/7/labels/qa%3Aretest
deny DELETE https://api.github.com/repos/acme/widgets/issues/7/labels/qa%3Aready
deny GET https://api.github.com/repos/acme/widgets/issues/7/timeline
deny GET https://api.github.com/repos/acme/widgets/issues/7/events?per_page=1
deny GET https://api.github.com/repos/acme/widgets/issues/events
deny GET https://api.github.com/repos/acme/widgets/contents/README.md
deny GET https://api.github.com/repos/acme/widgets/tarball/main
deny GET https://api.github.com/repos/acme/widgets/pulls/3
deny HEAD https://api.github.com/repos/acme/widgets/issues/7/timeline
deny POST https://api.github.com/graphql
deny GET https://api.github.com/search/code?q=repo:acme/widgets+x
deny GET https://api.github.com/repositories/42/contents/
allow GET https://api.github.com/user
allow GET https://api.github.com/repos/acme/profiles/tarball/v1
allow GET https://codeload.github.com/acme/profiles/legacy.tar.gz/v1
deny GET https://codeload.github.com/acme/widgets/legacy.tar.gz/main
deny GET https://github.com/acme/widgets.git/info/refs?service=git-upload-pack
deny GET https://github.com/acme/widgets/archive/HEAD.tar.gz
allow GET https://github.com/acme/quality-inspector.git/info/refs?service=git-upload-pack
allow POST https://github.com/acme/quality-inspector.git/git-receive-pack
allow POST https://api.github.com/repos/acme/quality-inspector/pulls
allow GET https://api.github.com/repos/acme/widgets/contents/qa?ref=0123abc
allow GET https://api.github.com/repos/acme/widgets/contents/qa?ref=HEAD
allow GET https://api.github.com/repos/acme/widgets/contents/qa/qi-profile-stub?ref=0123abc
allow GET https://api.github.com/repos/acme/widgets/contents/qa/qi-profile-stub/SKILL.md?ref=0123abc
deny GET https://api.github.com/repos/acme/widgets/contents?ref=0123abc
deny GET https://api.github.com/repos/acme/widgets/contents/qa-internal/notes.md
deny GET https://api.github.com/repos/ACME/Widgets/contents/src/index.ts
deny GET https://api.github.com/repos/someone/widgets/contents/src/index.ts
deny GET https://api.github.com/repos/acme/other/tarball/main
deny GET https://api.github.com/orgs/acme/repos
deny GET https://codeload.github.com/ACME/widgets/tar.gz/main
deny GET https://codeload.github.com/someone/widgets/tar.gz/main
deny GET https://github.com/ACME/Widgets/archive/HEAD.tar.gz
deny GET https://github.com/someone/widgets/blob/main/src/index.ts
allow GET https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.yaml
deny GET https://raw.githubusercontent.com/acme/widgets/HEAD/README.md
deny GET https://gitlab.com/acme/widgets
deny GET https://registry.gitlab.com/v2/
deny GET https://api.bitbucket.org/2.0/repositories
deny GET https://codeberg.org/
allow GET https://registry.npmjs.org/@acme%2fe2e
allow GET https://cdn01.quay.io/layer
deny GET https://api.github.com/search/commits?q=repo:acme/widgets+x
deny GET https://api.github.com/gists/0123abc
deny GET https://gist.github.com/someone/0123abc
deny GET https://gist.githubusercontent.com/someone/0123abc/raw/app.ts
deny GET https://bitbucket.org/acme/widgets/src/main/
deny GET https://gitea.com/acme/widgets
deny GET https://dev.azure.com/acme/widgets/_git/widgets
deny GET https://acme.visualstudio.com/widgets/_git/widgets
deny GET https://sourcegraph.com/search?q=repo:acme/widgets
deny GET https://git.sr.ht/~acme/widgets
allow GET https://api.github.com/repos/acme/widgets-qa
allow GET https://github.com/acme/widgets-qa.git/info/refs?service=git-receive-pack
allow POST https://github.com/acme/widgets-qa.git/git-receive-pack
deny GET https://api.github.com/repos/acme/widgets-qa/contents/QA.md
deny GET https://github.com/acme/widgets-qa/blob/main/QA.md
deny GET https://github.com/acme/widgets-qa2.git/info/refs?service=git-upload-pack
deny GET https://api.github.com/repos/acme/widgets-qa2
R
))"
assert_eq "every request meets its expected verdict" "" "$verdicts"

# The target is never a --source: a profile there gets its directory, not the repository.
bash "$SCRIPTS/egress-rules.sh" --source ACME/Widgets >/dev/null 2>&1
assert_eq "a source naming the target is refused" "2" "$?"

# work_repo is never the target, in any spelling: egress-rules.sh prints nothing, the verifier fails.
printf -- '- target_repo: acme/widgets\n- work_repo: github.com/ACME/Widgets\n' > "$WORK_DIR/CONFIG.md"
bash "$SCRIPTS/egress-rules.sh" >/dev/null 2>&1
assert_eq "a work_repo naming the target is refused" "1" "$?"
bash "$SCRIPTS/verify-onboarding.sh" --config 2>/dev/null | grep -q '^FAIL cfg:work_repo — is the target repository' \
  || { echo "  assertion failed: verify-onboarding --config fails a work_repo that is the target"; FAILED=1; }
printf -- '- target_repo: acme/widgets\n- work_repo: https://github.com/acme/widgets-qa\n' > "$WORK_DIR/CONFIG.md"
bash "$SCRIPTS/verify-onboarding.sh" --config 2>/dev/null | grep -q "^FAIL cfg:work_repo — 'https://github.com/acme/widgets-qa' is not \[host/\]owner/repo" \
  || { echo "  assertion failed: verify-onboarding --config fails a work_repo that is a URL"; FAILED=1; }

# A GitHub Enterprise Server target: the API under /api/v3 on the same host, which is
# deny-by-default as a whole; the definition on github.com gets nothing there, and a
# --source gets its archive paths there too.
printf -- '- target_repo: ghe.acme.com/acme/widgets\n' > "$WORK_DIR/CONFIG.md"
ghes="$(bash "$SCRIPTS/egress-rules.sh" --source acme/profiles)"
for want in '--host ghe.acme.com --method GET --path "/api/v3/repos/acme/widgets/issues*" --yes' \
            '--host ghe.acme.com --path "/*" --verdict deny --yes' \
            '--host raw.ghe.acme.com --path "/*" --verdict deny --yes' \
            '--host ghe.acme.com --method GET --path "/api/v3/repos/acme/profiles/*" --yes' \
            '--host ghe.acme.com --method GET --path "/_codeload/acme/profiles/*" --yes' \
            '--host codeload.ghe.acme.com --method GET --path "/acme/profiles/*" --yes'; do
  printf '%s\n' "$ghes" | grep -qF -- "$want" || { echo "  assertion failed: GHES rule: $want"; FAILED=1; }
done
printf '%s\n' "$ghes" | grep -q 'quality-inspector' && { echo "  assertion failed: no definition rule on another host"; FAILED=1; }

# A profile_source_path that is not a plain directory path never becomes an allow.
for bad in 'qa*' '*' '.' 'qa/../src' 'qa?x' 'qa%2f..'; do
  printf -- '- target_repo: acme/widgets\n- profile_source_path: %s\n' "$bad" > "$WORK_DIR/CONFIG.md"
  bash "$SCRIPTS/egress-rules.sh" >/dev/null 2>&1
  assert_eq "egress-rules.sh refuses profile_source_path '$bad'" "2" "$?"
done
printf -- '- target_repo: acme/widgets\n- profile_source_path: qa*\n' > "$WORK_DIR/CONFIG.md"
bash "$SCRIPTS/verify-onboarding.sh" --config 2>/dev/null | grep -q '^FAIL cfg:profile_source_path ' \
  || { echo "  assertion failed: verify-onboarding --config fails a pattern in profile_source_path"; FAILED=1; }
printf -- '- target_repo: acme/widgets\n- profile_source_path: .claude/skills\n' > "$WORK_DIR/CONFIG.md"
bash "$SCRIPTS/egress-rules.sh" | grep -qF -- '--path "/repos/acme/widgets/contents/.claude/skills/*"' \
  || { echo "  assertion failed: a dot-leading directory name is a plain path"; FAILED=1; }

# This definition's repository from the forms an origin takes.
defn() ( . "$SCRIPTS/lib/config.sh"; . "$SCRIPTS/lib/boundary.sh"; QI_DEFINITION_REPO="$1" _bb_definition )
for o in git@github.com:acme/quality-inspector.git https://x:y@github.com/acme/quality-inspector.git \
         ssh://git@github.com/acme/quality-inspector https://github.com/acme/quality-inspector/; do
  assert_eq "the definition's repository from origin $o" "github.com acme/quality-inspector" "$(defn "$o")"
done
printf -- '- target_repo: acme/widgets\n- profile_source_path: qa\n' > "$WORK_DIR/CONFIG.md"

# --------------------------------------------------------------- the probes
BIN="$SANDBOX/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'S'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >> "$STUB_DIR/gh.calls"
case "$args" in
  *"--jq .[0].number"*) echo 7; exit 0 ;;
  *"contents/qa?ref=HEAD --jq"*) printf 'dir\tqa/p\t0\n'; exit 0 ;;
  *"contents/qa/p?ref=HEAD --jq"*) [ -n "${STUB_LIST_FAIL:-}" ] && exit 1; printf 'file\tqa/p/SKILL.md\t10\nfile\tqa/p/link\t34\n'; exit 0 ;;
  *"contents/qa/p/SKILL.md?ref=HEAD --jq"*) echo "file 10"; exit 0 ;;
  *"contents/qa/p/link?ref=HEAD --jq"*) echo "file ${STUB_LINK_SIZE:-34}"; exit 0 ;;
esac
path="${*: -1}"; case "$args" in *graphql*) path=graphql;; esac
if [ -n "${STUB_OPEN:-}" ] && printf '%s' "$path" | grep -qE "$STUB_OPEN"; then echo "HTTP/2.0 200 OK"; exit 0; fi
if [ -n "${STUB_404:-}" ] && printf '%s' "$path" | grep -qE "$STUB_404"; then echo "HTTP/2.0 404 Not Found"; exit 1; fi
echo "HTTP/1.1 403 Forbidden"; exit 1
S
cat > "$BIN/curl" <<'S'
#!/usr/bin/env bash
url="${*: -1}"
if [ -n "${STUB_HELD:-}" ] && printf '%s' "$url" | grep -qE "$STUB_HELD"; then printf 'HTTP/1.1 000'; exit 28; fi
if [ -n "${STUB_OPEN:-}" ] && printf '%s' "$url" | grep -qE "$STUB_OPEN"; then printf 'HTTP/1.1 302'; exit 0; fi
printf 'HTTP/1.1 403'; exit 0
S
chmod +x "$BIN/gh" "$BIN/curl"
probe() { ( PATH="$BIN:$PATH"; . "$SCRIPTS/lib/config.sh"; . "$SCRIPTS/lib/profile.sh"; . "$SCRIPTS/lib/boundary.sh"
            CONFIG="$WORK_DIR/CONFIG.md" boundary_probe acme/widgets ); }

# The rules open the profile's directory as `qa?*` and `qa/*`, never `qa` alone: the stub
# opens only that shape, so a probe that asks for `contents/qa` itself is refused.
PROFILE_OPEN='contents/qa\?ref=HEAD$'
out="$(STUB_OPEN="$PROFILE_OPEN" probe)"
assert_eq "every surface refused" "" "$(printf '%s\n' "$out" | grep -v '^ok ')"
printf '%s\n' "$out" | grep -qF 'ok boundary:repos/ACME/WIDGETS/contents/ refused' \
  || { echo "  assertion failed: the target in the other case probed"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok boundary:repos/acme/widgets/contents/qa/%2e%2e refused' \
  || { echo "  assertion failed: an encoded dot segment out of the profile probed"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok profile_source repos/acme/widgets/contents/qa?ref=HEAD readable, every file its own' \
  || { echo "  assertion failed: the profile's directory must be readable"; FAILED=1; }
printf '%s\n' "$(probe)" | grep -q '^fail profile_source .*not readable (HTTP 403)' \
  || { echo "  assertion failed: a refused profile directory fails"; FAILED=1; }
printf '%s\n' "$(STUB_OPEN="$PROFILE_OPEN" STUB_LINK_SIZE=7907 probe)" \
  | grep -qF 'fail profile_source qa serves content from elsewhere in the repository (the contents API answers a symlink with its target): qa/p/link — ' \
  || { echo "  assertion failed: a symlink out of the profile's directory fails"; FAILED=1; }
printf '%s\n' "$(STUB_OPEN="$PROFILE_OPEN" STUB_LIST_FAIL=1 probe)" \
  | grep -q '^warn profile_source could not list or read qa/p — symlinks there are unchecked' \
  || { echo "  assertion failed: a failed listing warns instead of passing"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok boundary:repos/acme/widgets/issues/7/timeline refused' \
  || { echo "  assertion failed: {issue} resolves to a real issue"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok boundary:repositories/1/contents/ refused' \
  || { echo "  assertion failed: a repository by number probed"; FAILED=1; }
grep -qE '(^| )repos/acme/widgets( |$)' "$STUB_DIR/gh.calls" \
  && { echo "  assertion failed: a probe read GET /repos/<T>, not an issues endpoint"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok boundary:graphql refused' || { echo "  assertion failed: graphql probed"; FAILED=1; }

out="$(STUB_OPEN='^repos/.*/contents/$|archive/|contents/qa(/\.\.|\?ref=HEAD)$' STUB_404='timeline$' STUB_HELD='gitlab' probe)"
assert_eq "an open surface fails" "5" "$(printf '%s\n' "$out" | grep -c '^fail ')"
printf '%s\n' "$out" | grep -q '^fail boundary:repos/acme/widgets/contents/qa/\.\. .*dot segments' \
  || { echo "  assertion failed: a dot segment out of the profile names the gateway"; FAILED=1; }
printf '%s\n' "$out" | grep -q '^warn boundary:repos/acme/widgets/issues/7/timeline answered HTTP 404' \
  || { echo "  assertion failed: a 404 is no proof of a deny"; FAILED=1; }
printf '%s\n' "$out" | grep -q '^warn boundary:https://gitlab.com/ request held' \
  || { echo "  assertion failed: a held request warns"; FAILED=1; }

# The fix of a fail line: its own remedy where it carries one, else the printed rules.
fix() ( . "$SCRIPTS/lib/config.sh"; . "$SCRIPTS/lib/boundary.sh"; boundary_fix "$1" )
dot="$(printf '%s\n' "$out" | sed -n 's|^fail boundary:repos/acme/widgets/contents/qa/\.\. ||p')"
assert_eq "a dot-segment fail drops the profile allows, never re-applies them" \
  "empty profile_source_path, delete the profile allows, and report the gateway to the platform" "$(fix "$dot")"
assert_eq "a plain fail gets the printed rules" \
  "the operator applies the rules bash scripts/egress-rules.sh prints (docs/black-box.md → Egress rules)" \
  "$(fix "source surface reachable (HTTP 200)")"

# An invalid profile_source_path fails the probe, which then requests nothing in it.
printf -- '- target_repo: acme/widgets\n- profile_source_path: qa*\n' > "$WORK_DIR/CONFIG.md"
out="$(probe)"
printf '%s\n' "$out" | grep -qF "fail profile_source profile_source_path 'qa*' is not a plain directory path — " \
  || { echo "  assertion failed: an invalid profile_source_path fails the probe"; FAILED=1; }
printf '%s\n' "$out" | grep -q 'contents/qa\*' && { echo "  assertion failed: no probe inside an invalid profile_source_path"; FAILED=1; }

exit $FAILED
