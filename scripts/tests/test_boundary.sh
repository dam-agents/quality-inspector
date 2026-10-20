#!/usr/bin/env bash
# The black-box boundary: the rules egress-rules.sh lists hold under the platform's rule
# matching, and the probes tell a refusal from a reachable or unproven surface.
. "$(dirname "$0")/lib.sh"
seed_work
ROOT="$(cd "$SCRIPTS/.." && pwd)"

# ---------------------------------------------------------------- the rules
cat > "$QI_PROFILE_DIR/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "egress":[{"host":"get.helm.sh","method":"GET","why":"helm"},
           {"host":"*.quay.io","method":"GET","why":"image layers"}]}
J
printf -- '- work_repo: acme/widgets-qa\n' >> "$WORK_DIR/CONFIG.md"
export QI_DEFINITION_REPO=github.com/dam-agents/quality-inspector
cmds="$(bash "$SCRIPTS/egress-rules.sh" --kit --json)"
jq -e '.rules | any(.source == "kit" and .host == "*.gitlab.com" and .path == "/*" and .verdict == "deny")' >/dev/null <<<"$cmds" \
  || { echo "  assertion failed: wildcard kit host listed"; FAILED=1; }
jq -e '.rules | any(.source == "profile" and .host == "*.quay.io" and .method == "GET" and .how == "prompt" and .why == "image layers")' >/dev/null <<<"$cmds" \
  || { echo "  assertion failed: profile egress line"; FAILED=1; }

# A model of the platform's gate and match (ext-authz gate, egress-rules-repository
# findMatch): a path with a '.' or '..' segment (raw, %2e, with a ';' suffix) is denied
# first; the host compares in any case; then the exact host, *.parent, *; a named method
# over *; a path over *; the longer path, and two of equal length in no order — a tie between
# an allow and a deny is a failure. '*' in a pattern is SQL LIKE '%' (a literal '%' is one
# too, '_' any one character); on GitHub's hosts a deny matches in any case, an allow in
# exact case. The `trusted` preset and the GitHub connection hold host-wide
# allows on these hosts before the kit's rules land.
verdicts="$(printf '%s\n' "$cmds" | node -e '
const rules = JSON.parse(require("fs").readFileSync(0, "utf8")).rules
  .map(r => ({ host: r.host, method: r.method, path: r.path, verdict: r.verdict }));
for (const h of ["github.com", "api.github.com", "codeload.github.com", "raw.githubusercontent.com",
                 "objects.githubusercontent.com", "release-assets.githubusercontent.com", "gitlab.com", "codeberg.org", "registry.npmjs.org"])
  rules.push({ host: h, method: "*", path: "*", verdict: "allow" });
const like = (p, flags) => new RegExp("^" + [...p].map(c => c === "*" || c === "%" ? ".*" : c === "_" ? "." : c.replace(/[.+?^${}()|[\]\\\/]/g, "\\$&")).join("") + "$", flags);
const rank = (r, host) => [r.host === host ? 0 : r.host === "*" ? 2 : 1, r.method === "*" ? 1 : 0, r.path === "*" ? 1 : 0, -r.path.length];
const githubHost = h => ["github.com", "api.github.com", "codeload.github.com", "raw.githubusercontent.com"].includes(h) || h.endsWith(".ghe.com");
const dotSegment = p => p.split("?")[0].split(/\/|\\|%2f|%5c/i).some(s => [".", ".."].includes(s.replace(/%2e/gi, ".").split(";")[0]));
function decide(method, url) {
  const m = url.match(/^https:\/\/([^/]+)(\/.*)$/), host = m[1].toLowerCase(), path = m[2];
  if (dotSegment(path)) return "deny";
  const cands = host.includes(".") ? [host, "*." + host.slice(host.indexOf(".") + 1), "*"] : [host, "*"];
  const matches = r => like(r.path, "s").test(path) || (r.verdict === "deny" && githubHost(host) && like(r.path, "si").test(path));
  const hits = rules.filter(r => cands.includes(r.host) && (r.method === method || r.method === "*") && matches(r));
  hits.sort((a, b) => { const x = rank(a, host), y = rank(b, host); for (let i = 0; i < 4; i++) if (x[i] !== y[i]) return x[i] - y[i]; return 0; });
  if (!hits.length) return "hold";
  // Equal rank has no order on the platform: a tie between verdicts is a bug in the rules.
  const tie = hits.filter(h => rank(h, host).join() === rank(hits[0], host).join());
  if (new Set(tie.map(h => h.verdict)).size > 1) return "tie";
  return hits[0].verdict;
}
for (const l of require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n")) {
  const [want, method, url] = l.split(" ");
  const got = decide(method, url);
  if (got !== want) console.log(`${method} ${url}: want ${want}, got ${got}`);
}' <(cat <<'R'
allow GET https://api.github.com/repos/acme/widgets/issues?labels=qa:ready&state=all&per_page=100
allow GET https://api.github.com/repos/acme/widgets/issues/7
allow GET https://api.github.com/repos/acme/widgets/issues/7/comments?per_page=100&page=2
allow GET https://api.github.com/repos/other/repo/issues/7
allow POST https://api.github.com/repos/acme/widgets/issues/7/comments
allow DELETE https://api.github.com/repos/acme/widgets/issues/7/labels/qa%3Aretest
allow GET https://api.github.com/user
deny GET https://api.github.com/repos/acme/widgets/issues/7/timeline
deny GET https://api.github.com/repos/acme/widgets/issues/7/TIMELINE
deny GET https://api.github.com/repos/acme/widgets/issues/7/events?per_page=1
deny GET https://api.github.com/repos/acme/widgets/issues/events
deny HEAD https://api.github.com/repos/acme/widgets/issues/7
deny PATCH https://api.github.com/repos/acme/widgets/issues/7
deny GET https://api.github.com/repos/acme/widgets/contents/README.md
deny GET https://api.github.com/repos/acme/widgets/contents/README.md?x=/issues
deny GET https://api.github.com/repos/acme/widgets/contents/src/app.ts?ref=main&q=/issues/1/comments
deny GET https://api.github.com/repos/acme/widgets/git/blobs/abc?/issues
deny GET https://api.github.com/repos/acme/issues/contents/src/app.ts
deny GET https://api.github.com/repos/acme/issues/contents/src/app.ts?/issues
deny GET https://api.github.com/repos/acme/widgets%2Fcontents%2Fsrc%2Fapp.ts?/issues
deny GET https://api.github.com/repos/acme/widgets%2fcontents%2fsrc%2fapp.ts
deny GET https://api.github.com/repos/acme/widgets/tarball/main
deny GET https://api.github.com/repos/acme/widgets/zipball/main?/issues
deny GET https://api.github.com/repos/acme/widgets/pulls/3
deny GET https://api.github.com/repos/acme/widgets/pulls/3/files?/issues
deny GET https://api.github.com/repos/acme/widgets/commits/HEAD
deny GET https://api.github.com/repos/acme/widgets/compare/a...b
deny GET https://api.github.com/repos/acme/widgets/readme
deny GET https://api.github.com/repos/acme/widgets/git/trees/main?recursive=1
deny GET https://api.github.com/repos/acme/widgets/git/refs/heads
deny POST https://api.github.com/repos/acme/widgets/pulls?/issues/1/comments
deny POST https://api.github.com/repos/acme/widgets/git/refs?x=/issues/1/comments
deny DELETE https://api.github.com/repos/acme/widgets/git/refs/heads/main?/issues/1/labels/x
deny PUT https://api.github.com/repos/acme/widgets/contents/x
deny POST https://api.github.com/graphql
deny GET https://api.github.com/search/code?q=repo:acme/widgets+x
deny GET https://api.github.com/search/commits?q=repo:acme/widgets+x
deny GET https://api.github.com/search/issues?q=repo:acme/widgets
deny GET https://api.github.com/repositories/42/contents/
deny GET https://api.github.com/repositories/42/issues/7
deny GET https://api.github.com/gists/0123abc
deny GET https://api.github.com/orgs/acme/repos
deny GET https://API.GitHub.com/repos/acme/widgets/contents/src/index.ts
allow GET https://api.github.com/repos/acme/widgets/contents/.quality-inspector?ref=0123abc
allow GET https://api.github.com/repos/acme/widgets/contents/.quality-inspector/qi-profile-stub?ref=0123abc
allow GET https://api.github.com/repos/acme/widgets/contents/.quality-inspector/qi-profile-stub/SKILL.md?ref=0123abc
allow GET https://api.github.com/repos/acme/profiles/contents/.quality-inspector/qi-profile-stub/bin/env?ref=v1
deny GET https://api.github.com/repos/acme/widgets/contents/.quality-inspector
deny GET https://api.github.com/repos/acme/widgets/contents?ref=0123abc
deny GET https://api.github.com/repos/acme/widgets/contents/.quality-inspector-x/a.ts
deny GET https://api.github.com/repos/acme/widgets/contents/src/a.ts?x=/contents/.quality-inspector/y
deny GET https://api.github.com/repos/acme/widgets/contents/.quality-inspector/../src/index.ts?ref=0123abc
deny GET https://api.github.com/repos/acme/widgets/contents/.quality-inspector/%2e%2e/src/index.ts
deny GET https://api.github.com/repos/acme/widgets/contents/.quality-inspector/..;x/src/index.ts
deny GET https://api.github.com/repos/acme/widgets/contents/.quality-inspector%2F..%2Fsrc%2Findex.ts
deny GET https://api.github.com/repos/acme/widgets/contents/.QUALITY-INSPECTOR/x
allow GET https://api.github.com/repos/acme/widgets
allow GET https://api.github.com/repos/acme/widgets?x=1
allow GET https://api.github.com/repos/acme/widgets/git/refs/heads/main
allow GET https://api.github.com/repos/acme/widgets/git/refs/heads/feature/x
deny GET https://api.github.com/repos/acme/widgets/git/refs/tags/v1
deny GET https://api.github.com/repos/acme/widgets/commits/main?/git/refs/heads/x
deny GET https://api.github.com/repos/acme/widgets/branches
deny GET https://codeload.github.com/acme/widgets/legacy.tar.gz/main
deny GET https://codeload.github.com/acme/profiles/legacy.tar.gz/v1
deny GET https://github.com/acme/widgets.git/info/refs?service=git-upload-pack
deny GET https://github.com/acme/widgets/info/refs?service=git-upload-pack
deny GET https://github.com/acme/widgets/archive/HEAD.tar.gz
deny GET https://github.com/someone/widgets/blob/main/src/index.ts
allow GET https://github.com/dam-agents/quality-inspector.git/info/refs?service=git-upload-pack
allow GET https://github.com/dam-agents/quality-inspector/info/refs?service=git-upload-pack
allow POST https://github.com/dam-agents/quality-inspector.git/git-upload-pack
deny GET https://github.com/dam-agents/quality-inspector.git/info/refs?service=git-receive-pack
deny POST https://github.com/dam-agents/quality-inspector.git/git-receive-pack
deny GET https://github.com/dam-agents/quality-inspector/../../acme/widgets.git/info/refs?service=git-upload-pack
deny GET https://github.com/dam-agents/quality-inspector%2F..%2F..%2Facme%2Fwidgets/info/refs?service=git-upload-pack
deny POST https://api.github.com/repos/dam-agents/quality-inspector/pulls
allow GET https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.yaml
allow GET https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
allow GET https://release-assets.githubusercontent.com/github-production-release-asset/92313258/58a98734?sp=r&sig=x
deny GET https://github.com/cert-manager/cert-manager/releases/download/v1.15.0/cert-manager.crds.yaml
deny GET https://github.com/cert-manager/cert-manager/blob/master/cert-manager.yaml
deny GET https://github.com/cert-manager/cert-manager/archive/refs/tags/v1.15.0.tar.gz
deny GET https://github.com/acme/widgets/raw/main/src?/cert-manager/cert-manager/releases/download/v1/cert-manager.yaml
deny GET https://github.com/cert-manager/cert-manager/releases/download/v1/../../../../acme/widgets/raw/main/cert-manager.yaml
deny GET https://github.com/cert-manager/cert-manager/releases/download/v1/%2e%2e/%2e%2e/%2e%2e/%2e%2e/acme/widgets/raw/main/cert-manager.yaml
deny GET https://raw.githubusercontent.com/acme/widgets/HEAD/README.md
deny GET https://gitlab.com/acme/widgets
deny GET https://registry.gitlab.com/v2/
deny GET https://api.bitbucket.org/2.0/repositories
deny GET https://codeberg.org/
allow GET https://registry.npmjs.org/@acme%2fe2e
allow GET https://cdn01.quay.io/layer
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
R
))"
assert_eq "every request meets its expected verdict" "" "$verdicts"

# work_repo is never the target, in any spelling: egress-rules.sh prints nothing, the verifier fails.
printf -- '- target_repo: acme/widgets\n- work_repo: github.com/ACME/Widgets\n' > "$WORK_DIR/CONFIG.md"
bash "$SCRIPTS/egress-rules.sh" >/dev/null 2>&1
assert_eq "a work_repo naming the target is refused" "1" "$?"
bash "$SCRIPTS/verify-onboarding.sh" --config 2>/dev/null | grep -q '^FAIL cfg:work_repo — is the target repository' \
  || { echo "  assertion failed: verify-onboarding --config fails a work_repo that is the target"; FAILED=1; }
printf -- '- target_repo: acme/widgets\n- work_repo: https://github.com/acme/widgets-qa\n' > "$WORK_DIR/CONFIG.md"
bash "$SCRIPTS/verify-onboarding.sh" --config 2>/dev/null | grep -q "^FAIL cfg:work_repo — 'https://github.com/acme/widgets-qa' is not \[host/\]owner/repo" \
  || { echo "  assertion failed: verify-onboarding --config fails a work_repo that is a URL"; FAILED=1; }

# A GitHub Enterprise Server target: the shared rules on its host (the API under /api/v3 there),
# deny-by-default as a whole; the definition on github.com gets nothing there.
printf -- '- target_repo: ghe.acme.com/acme/widgets\n' > "$WORK_DIR/CONFIG.md"
ghes="$(bash "$SCRIPTS/egress-rules.sh" --json | jq -r '.rules[] | select(.source == "github") | "\(.how) \(.verdict) \(.method) \(.host) \(.path)"')"
for want in 'by-hand allow GET ghe.acme.com /api/v3/repos/*/*/issues*' \
            'by-hand deny GET ghe.acme.com /api/v3/repos/*/*/*/issues*' \
            'by-hand deny * ghe.acme.com /*' \
            'by-hand deny * raw.ghe.acme.com /*'; do
  printf '%s\n' "$ghes" | grep -qxF -- "$want" || { echo "  assertion failed: GHES rule: $want"; FAILED=1; }
done
printf '%s\n' "$ghes" | grep -q 'quality-inspector\*' && { echo "  assertion failed: no definition rule on another host"; FAILED=1; }
printf -- '- target_repo: acme/widgets\n' > "$WORK_DIR/CONFIG.md"
printf '%s\n' "$(bash "$SCRIPTS/egress-rules.sh")" | grep -q '^The target acme/widgets is on github.com: the kit.s GitHub rules hold for it — nothing to add\.$' \
  || { echo "  assertion failed: a github.com target needs no rule of its own"; FAILED=1; }

# This definition's repository from the forms an origin takes.
defn() ( . "$SCRIPTS/lib/config.sh"; . "$SCRIPTS/lib/boundary.sh"; QI_DEFINITION_REPO="$1" _bb_definition )
for o in git@github.com:acme/quality-inspector.git https://x:y@github.com/acme/quality-inspector.git \
         ssh://git@github.com/acme/quality-inspector https://github.com/acme/quality-inspector/; do
  assert_eq "the definition's repository from origin $o" "github.com acme/quality-inspector" "$(defn "$o")"
done
printf -- '- target_repo: acme/widgets\n' > "$WORK_DIR/CONFIG.md"

# --------------------------------------------------------------- the probes
BIN="$SANDBOX/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'S'
#!/usr/bin/env bash
args="$*"
printf '%s\n' "$args" >> "$STUB_DIR/gh.calls"
case "$args" in
  *"--jq .[0].number"*) echo 7; exit 0 ;;
  *"contents/.quality-inspector?ref=HEAD --jq"*) printf 'dir\t.quality-inspector/p\t0\n'; exit 0 ;;
  *"contents/.quality-inspector/p?ref=HEAD --jq"*) [ -n "${STUB_LIST_FAIL:-}" ] && exit 1; printf 'file\t.quality-inspector/p/SKILL.md\t10\nfile\t.quality-inspector/p/link\t34\n'; exit 0 ;;
  *"contents/.quality-inspector/p/SKILL.md?ref=HEAD --jq"*) echo "file 10"; exit 0 ;;
  *"contents/.quality-inspector/p/link?ref=HEAD --jq"*) echo "file ${STUB_LINK_SIZE:-34}"; exit 0 ;;
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

# The rules open the profile directory as `.quality-inspector?*` and `.quality-inspector/*`,
# never alone: the stub opens only that shape, so a probe that asks for it bare is refused.
PROFILE_OPEN='contents/\.quality-inspector\?ref=HEAD$'
out="$(STUB_OPEN="$PROFILE_OPEN" probe)"
assert_eq "every surface refused" "" "$(printf '%s\n' "$out" | grep -v '^ok ')"
printf '%s\n' "$out" | grep -qF 'ok boundary:repos/ACME/WIDGETS/contents/ refused' \
  || { echo "  assertion failed: the target in the other case probed"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok boundary:repos/acme/widgets/contents/.quality-inspector/%2e%2e refused' \
  || { echo "  assertion failed: an encoded dot segment out of the profile probed"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok profile_source repos/acme/widgets/contents/.quality-inspector?ref=HEAD every file its own' \
  || { echo "  assertion failed: the profile's directory must be readable"; FAILED=1; }
printf '%s\n' "$(probe)" | grep -q '^warn profile_source .*answered HTTP 403' \
  || { echo "  assertion failed: a refused profile directory warns"; FAILED=1; }
printf '%s\n' "$(STUB_404='contents/\.quality-inspector\?ref=HEAD$' probe)" | grep -qF 'ok profile_source the target holds no .quality-inspector directory' \
  || { echo "  assertion failed: a target without a profile directory passes"; FAILED=1; }
for shape in 'contents/README.md?x=/issues' 'contents/README.md?x=/contents/.quality-inspector/x' 'acme%2Fwidgets%2Fcontents%2FREADME.md' 'tarball/HEAD'; do
  printf '%s\n' "$out" | grep -qF "ok boundary:repos/acme/${shape#acme%2F}" || printf '%s\n' "$out" | grep -qF "ok boundary:repos/$shape" || printf '%s\n' "$out" | grep -qF "ok boundary:repos/acme/widgets/${shape%%\?*}" \
    || { echo "  assertion failed: a wildcard shape probed: $shape"; FAILED=1; }
done
printf '%s\n' "$out" | grep -qF 'ok boundary:https://github.com/acme/widgets.git/info/refs refused' \
  || { echo "  assertion failed: a git fetch of the target probed"; FAILED=1; }
printf '%s\n' "$(STUB_OPEN="$PROFILE_OPEN" STUB_LINK_SIZE=7907 probe)" \
  | grep -qF 'fail profile_source .quality-inspector serves content from elsewhere in the repository (the contents API answers a symlink with its target): .quality-inspector/p/link — ' \
  || { echo "  assertion failed: a symlink out of the profile's directory fails"; FAILED=1; }
printf '%s\n' "$(STUB_OPEN="$PROFILE_OPEN" STUB_LIST_FAIL=1 probe)" \
  | grep -q '^warn profile_source could not list or read .quality-inspector/p — symlinks there are unchecked' \
  || { echo "  assertion failed: a failed listing warns instead of passing"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok boundary:repos/acme/widgets/issues/7/timeline refused' \
  || { echo "  assertion failed: {issue} resolves to a real issue"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok boundary:repos/acme/widgets/issues/7/TIMELINE refused' \
  || { echo "  assertion failed: the case-blind GitHub deny probed"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok boundary:repositories/1/contents/ refused' \
  || { echo "  assertion failed: a repository by number probed"; FAILED=1; }
grep -qE '(^| )repos/acme/widgets( |$)' "$STUB_DIR/gh.calls" \
  && { echo "  assertion failed: a probe read GET /repos/<T>, not an issues endpoint"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok boundary:graphql refused' || { echo "  assertion failed: graphql probed"; FAILED=1; }

out="$(STUB_OPEN='^repos/.*/contents/$|archive/|contents/\.quality-inspector(/\.\.|\?ref=HEAD)$' STUB_404='timeline$' STUB_HELD='gitlab' probe)"
assert_eq "an open surface fails" "5" "$(printf '%s\n' "$out" | grep -c '^fail ')"
printf '%s\n' "$out" | grep -q '^fail boundary:repos/acme/widgets/contents/\.quality-inspector/\.\. .*dot segments' \
  || { echo "  assertion failed: a dot segment out of the profile names the gateway"; FAILED=1; }
printf '%s\n' "$out" | grep -q '^warn boundary:repos/acme/widgets/issues/7/timeline answered HTTP 404' \
  || { echo "  assertion failed: a 404 is no proof of a deny"; FAILED=1; }
printf '%s\n' "$out" | grep -q '^warn boundary:https://gitlab.com/ request held' \
  || { echo "  assertion failed: a held request warns"; FAILED=1; }

# The fix of a fail line: its own remedy where it carries one, else the printed rules.
fix() ( . "$SCRIPTS/lib/config.sh"; . "$SCRIPTS/lib/boundary.sh"; boundary_fix "$1" )
dot="$(printf '%s\n' "$out" | sed -n 's|^fail boundary:repos/acme/widgets/contents/\.quality-inspector/\.\. ||p')"
assert_eq "a dot-segment fail names the gateway, never re-applies rules" \
  "report the gateway to the platform" "$(fix "$dot")"
assert_eq "a plain fail points at the kit's rules" \
  "the agent's egress lacks the kit's GitHub rules: recreate it from the kit, or have the operator add what bash scripts/egress-rules.sh --kit lists in the agent's network settings (docs/black-box.md → Egress rules)" \
  "$(fix "source surface reachable (HTTP 200)")"
case_fail="$(STUB_OPEN="$PROFILE_OPEN|TIMELINE\$" probe | sed -n 's|^fail boundary:repos/acme/widgets/issues/7/TIMELINE ||p')"
assert_eq "a deny in exact case only names the platform, never re-applies the rules" \
  "report the gateway to the platform (dam-agents/dam#4909)" "$(fix "$case_fail")"

exit $FAILED
