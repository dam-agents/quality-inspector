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
cmds="$(bash "$SCRIPTS/egress-rules.sh" --kit)"
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
R
))"
assert_eq "every request meets its expected verdict" "" "$verdicts"

# A GitHub Enterprise Server target: the API under /api/v3, GraphQL at /api/graphql.
printf -- '- target_repo: ghe.acme.com/acme/widgets\n' > "$WORK_DIR/CONFIG.md"
ghes="$(bash "$SCRIPTS/egress-rules.sh")"
for want in '--host ghe.acme.com --method GET --path "/api/v3/repos/acme/widgets/issues*" --yes' \
            '--host ghe.acme.com --path "/api/graphql*" --verdict deny --yes' \
            '--host raw.ghe.acme.com --path "/acme/widgets/*" --verdict deny --yes'; do
  printf '%s\n' "$ghes" | grep -qF -- "$want" || { echo "  assertion failed: GHES rule: $want"; FAILED=1; }
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
  *"--jq .id"*) echo 42; exit 0 ;;
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

out="$(probe)"
assert_eq "every surface refused" "" "$(printf '%s\n' "$out" | grep -v '^ok ')"
printf '%s\n' "$out" | grep -qF 'ok boundary:repos/acme/widgets/issues/7/timeline refused' \
  || { echo "  assertion failed: {issue} resolves to a real issue"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok boundary:repositories/1/contents/ refused' \
  || { echo "  assertion failed: a repository by number probed"; FAILED=1; }
grep -qE '(^| )repos/acme/widgets( |$)' "$STUB_DIR/gh.calls" \
  && { echo "  assertion failed: a probe read GET /repos/<T>, not an issues endpoint"; FAILED=1; }
printf '%s\n' "$out" | grep -qF 'ok boundary:graphql refused' || { echo "  assertion failed: graphql probed"; FAILED=1; }

out="$(STUB_OPEN='^repos/.*/contents/$|archive/' STUB_404='timeline$' STUB_HELD='gitlab' probe)"
assert_eq "an open surface fails" "2" "$(printf '%s\n' "$out" | grep -c '^fail ')"
printf '%s\n' "$out" | grep -q '^warn boundary:repos/acme/widgets/issues/7/timeline answered HTTP 404' \
  || { echo "  assertion failed: a 404 is no proof of a deny"; FAILED=1; }
printf '%s\n' "$out" | grep -q '^warn boundary:https://gitlab.com/ request held' \
  || { echo "  assertion failed: a held request warns"; FAILED=1; }

exit $FAILED
