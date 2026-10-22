#!/usr/bin/env bash
# kit.yaml's egress rules, read by the validator (a deny needs a path, or the apply fails)
# and by egress-rules.sh --kit, in any YAML style: quoted values, any key first, a trailing
# comment. And what egress-rules.sh lists without --kit, how each profile rule lands, and --egress.
. "$(dirname "$0")/lib.sh"
seed_work
DEF="$SANDBOX/def"; mkdir -p "$DEF/scripts"
cp -R "$SCRIPTS/lib" "$SCRIPTS/egress-rules.sh" "$SCRIPTS/validate-definition.sh" "$DEF/scripts/"
kit() { { printf '%s\n' 'schemaVersion: v1' 'id: quality-inspector' 'seed:' '  self: true' '  into: home' 'egressRules:'
          printf '%s\n' "$@"; printf '%s\n' 'resources:' '  cpu: "1"'; } > "$DEF/kit.yaml"; }
check() { bash "$DEF/scripts/validate-definition.sh" "$DEF" 2>/dev/null | grep 'kit.yaml egress denies'; }

kit '  - host: a.example' '    verdict: "deny"' \
    '  - verdict: deny' '    host: b.example' \
    '  - host: c.example' "    pathPattern: '*'" '    verdict: deny  # the whole host' \
    '  - host: d.example' '    pathPattern: "/*"' '    verdict: "deny"' \
    '  - pathPattern: "/x*"' '    host: e.example' '    verdict: deny' \
    '  - method: GET' '    host: f.example'
assert_eq "every pathless deny fails, whatever its style" "a.example b.example c.example" \
  "$(check | sed -n 's/^FAIL  kit.yaml egress denies without a path.*: //p')"
rules="$(bash "$DEF/scripts/egress-rules.sh" --kit --json | jq -r '.rules[] | select(.source == "kit") | "\(.verdict) \(.method) \(.host) \(.path) \(.how)"')"
assert_eq "--kit lists the kit's rules, by hand" "deny * a.example * by-hand
deny * b.example * by-hand
deny * c.example * by-hand
deny * d.example /* by-hand
deny * e.example /x* by-hand
allow GET f.example * by-hand" "$rules"
cmds="$(bash "$DEF/scripts/egress-rules.sh" --kit)"

kit '  - host: d.example' '    pathPattern: "/*"' '    verdict: "deny"' \
    '  - pathPattern: "/x*"' '    host: e.example' '    verdict: deny'
assert_eq "denies with a path pass" "PASS  kit.yaml egress denies each name a path" "$(check)"

# Without --kit the kit's rules are left out, and the output says when they are needed.
printf '%s\n' "$(bash "$DEF/scripts/egress-rules.sh")" | grep -q '^The kit.s rules (kit.yaml) are left out: .* run with --kit\.$' \
  || { echo "  assertion failed: the note about --kit"; FAILED=1; }
printf '%s\n' "$cmds" | grep -q 'are left out' && { echo "  assertion failed: no note with --kit"; FAILED=1; }

# Data, never commands: no line is a CLI command, values travel verbatim, and each profile
# rule says how it gets onto the agent — under a kit deny by hand (no prompt appears), a
# rule the kit already holds nothing, any other host through its approval prompt.
kit '  - host: g.example' '    pathPattern: "/*"' '    verdict: deny' \
    '  - host: g.example' '    method: GET' '    pathPattern: "/ok/v*/f.yaml"' \
    '  - host: "*.h.example"' '    pathPattern: "/*"' '    verdict: deny'
cat > "$QI_PROFILE_DIR/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "egress":[{"host":"cdn.example.com","method":"GET","path":"/a/*","why":"assets $(x)"},
           {"host":"g.example","method":"GET","path":"/other/*","why":"under the deny"},
           {"host":"g.example","method":"GET","path":"/ok/v1/f.yaml","why":"the kit's"},
           {"host":"x.h.example","method":"GET","why":"under the wildcard deny"},
           {"host":"g.example","verdict":"deny","path":"/bad/*"}]}
J
out="$(bash "$DEF/scripts/egress-rules.sh" --json)"
assert_eq "how each profile rule lands" "prompt cdn.example.com /a/* assets \$(x)
by-hand g.example /other/* under the deny
kit g.example /ok/v1/f.yaml the kit's
by-hand x.h.example * under the wildcard deny
by-hand g.example /bad/* " "$(jq -r '.rules[] | select(.source == "profile") | "\(.how) \(.host) \(.path) \(.why)"' <<<"$out")"
bash "$DEF/scripts/egress-rules.sh" | grep -E '(^| )(dam|curl|gh) ' && { echo "  assertion failed: no CLI command in the list"; FAILED=1; }
bash "$DEF/scripts/egress-rules.sh" | grep -qF '| prompt | allow | GET | `cdn.example.com` | `/a/*` | assets $(x) |' \
  || { echo "  assertion failed: the table row of a prompt rule"; FAILED=1; }

# Sandbox accounts (docs/black-box.md → Sandbox accounts): {profile.<key>} takes the
# instance's value; an unset or odd value refuses the rule; on a GitHub host only the
# closed set passes — a literal owner/repo, never the target's or the backup's; a GitHub
# App's endpoints are not in it. Under the kit's deny, an accepted one lands by hand.
kit '  - host: api.github.com' '    pathPattern: "/*"' '    verdict: deny' \
    '  - host: github.com' '    pathPattern: "/*"' '    verdict: deny'
cat > "$QI_PROFILE_DIR/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "config":{"sb_repo":{"default":""},"sb_odd":{"default":"a/../b"},"sb_target":{"default":"ACME/x"}},
 "egress":[{"host":"api.github.com","method":"POST","path":"/repos/{profile.sb_repo}/issues","why":"sandbox issue"},
           {"host":"api.github.com","method":"PATCH","path":"/repos/{profile.sb_repo}/issues/*","why":"close it"},
           {"host":"api.github.com","method":"POST","path":"/app/installations/*/access_tokens","why":"an App's token"},
           {"host":"api.github.com","method":"POST","path":"/repos/{profile.sb_odd}/issues","why":"dot segment"},
           {"host":"api.github.com","method":"POST","path":"/repos/{profile.sb_target}/issues","why":"the target's owner"},
           {"host":"api.github.com","method":"POST","path":"/repos/*/qa/issues","why":"wildcard owner"},
           {"host":"api.github.com","method":"POST","path":"/repos/my_org/qa/issues","why":"underscore"},
           {"host":"api.github.com","method":"POST","path":"/repos/sb/qa","why":"no rest"},
           {"host":"github.com","method":"GET","path":"/{profile.sb_repo}.git/info/refs?service=git-upload-pack","why":"clone"},
           {"host":"github.com","method":"POST","path":"/{profile.sb_repo}.git/git-upload-pack","why":"clone"},
           {"host":"github.com","method":"GET","path":"/{profile.sb_repo}/info/refs?service=git-receive-pack","why":"push, no .git"},
           {"host":"github.com","method":"POST","path":"/{profile.sb_repo}.git/git-receive-pack","why":"push"},
           {"host":"github.com","method":"POST","path":"/{profile.sb_repo}.git/info/refs?service=git-receive-pack","why":"wrong method"},
           {"host":"github.com","method":"*","path":"/{profile.sb_repo}.git/git-receive-pack","why":"any method"},
           {"host":"github.com","method":"GET","path":"/ACME/x.git/info/refs?service=git-upload-pack","why":"the target's owner"},
           {"host":"github.com","method":"POST","path":"/sb/qa/x/git-upload-pack","why":"a third segment"},
           {"host":"github.com","method":"POST","path":"/*/qa.git/git-upload-pack","why":"wildcard owner"},
           {"host":"github.com","method":"GET","path":"/login?*","why":"oauth: the login form"},
           {"host":"github.com","method":"POST","path":"/session","why":"oauth: the password"},
           {"host":"github.com","method":"GET","path":"/sessions/two-factor/app","why":"oauth: the TOTP page"},
           {"host":"github.com","method":"POST","path":"/sessions/two-factor","why":"oauth: the TOTP code"},
           {"host":"github.com","method":"GET","path":"/login/oauth/authorize?*","why":"oauth: the authorize page"},
           {"host":"github.com","method":"POST","path":"/login/oauth/authorize","why":"oauth: the consent"},
           {"host":"github.com","method":"POST","path":"/login/oauth/access_token","why":"oauth: the code exchange"},
           {"host":"github.com","method":"*","path":"/session","why":"oauth: any method"},
           {"host":"github.com","method":"GET","path":"/login*","why":"oauth: a wildcard path"},
           {"host":"github.com","method":"GET","path":"/login/oauth/*","why":"oauth: a wildcard tail"},
           {"host":"github.com","method":"GET","path":"/sessions/*","why":"oauth: a wildcard tail"},
           {"host":"github.com","method":"POST","path":"/login/oauth/authorize?*","why":"oauth: the consent with a query"},
           {"host":"github.com","method":"GET","path":"/settings/applications","why":"oauth: a settings page"},
           {"host":"api.github.com","method":"POST","path":"/login/oauth/access_token","why":"oauth: on the API host"},
           {"host":"github.com","method":"GET","path":"/sb/qa/*","why":"not the API"},
           {"host":"raw.githubusercontent.com","method":"GET","path":"/sb/qa/*","why":"raw"},
           {"host":"slack.com","method":"POST","path":"/api/*","why":"slack"}]}
J
printf -- '- profile.sb_repo: qa-sandbox/e2e-playground\n- work_repo: backup-org/qa-backup\n' >> "$WORK_DIR/CONFIG.md"
sb="$(bash "$DEF/scripts/egress-rules.sh" --json | jq -r '.rules[] | select(.source == "profile") | "\(.how) \(.method) \(.host) \(.path)"')"
assert_eq "sandbox rules: placeholders and the GitHub closed set" "by-hand POST api.github.com /repos/qa-sandbox/e2e-playground/issues
by-hand PATCH api.github.com /repos/qa-sandbox/e2e-playground/issues/*
refused POST api.github.com /app/installations/*/access_tokens
refused POST api.github.com /repos/{profile.sb_odd}/issues
refused POST api.github.com /repos/ACME/x/issues
refused POST api.github.com /repos/*/qa/issues
refused POST api.github.com /repos/my_org/qa/issues
refused POST api.github.com /repos/sb/qa
by-hand GET github.com /qa-sandbox/e2e-playground.git/info/refs?service=git-upload-pack
by-hand POST github.com /qa-sandbox/e2e-playground.git/git-upload-pack
by-hand GET github.com /qa-sandbox/e2e-playground/info/refs?service=git-receive-pack
by-hand POST github.com /qa-sandbox/e2e-playground.git/git-receive-pack
refused POST github.com /qa-sandbox/e2e-playground.git/info/refs?service=git-receive-pack
refused * github.com /qa-sandbox/e2e-playground.git/git-receive-pack
refused GET github.com /ACME/x.git/info/refs?service=git-upload-pack
refused POST github.com /sb/qa/x/git-upload-pack
refused POST github.com /*/qa.git/git-upload-pack
by-hand GET github.com /login?*
by-hand POST github.com /session
by-hand GET github.com /sessions/two-factor/app
by-hand POST github.com /sessions/two-factor
by-hand GET github.com /login/oauth/authorize?*
by-hand POST github.com /login/oauth/authorize
by-hand POST github.com /login/oauth/access_token
refused * github.com /session
refused GET github.com /login*
refused GET github.com /login/oauth/*
refused GET github.com /sessions/*
refused POST github.com /login/oauth/authorize?*
refused GET github.com /settings/applications
refused POST api.github.com /login/oauth/access_token
refused GET github.com /sb/qa/*
refused GET raw.githubusercontent.com /sb/qa/*
prompt POST slack.com /api/*" "$sb"
why="$(bash "$DEF/scripts/egress-rules.sh" --json | jq -r '.rules[] | select(.source == "profile" and .how == "refused") | .why' | head -3)"
printf '%s\n' "$why" | grep -q '^not /repos/<owner>/<repo>/<rest> — a profile defect' || { echo "  assertion failed: the refusal says why"; FAILED=1; }
printf '%s\n' "$why" | grep -q '^profile.sb_odd is unset or not a plain name' || { echo "  assertion failed: an odd placeholder value names its key"; FAILED=1; }
# The backup's owner, in another case, is refused as well.
sed -i.bak 's#^- profile.sb_repo: qa-sandbox/e2e-playground#- profile.sb_repo: Backup-Org/x#' "$WORK_DIR/CONFIG.md"
assert_eq "the work backup's owner is refused" "refused" \
  "$(bash "$DEF/scripts/egress-rules.sh" --json | jq -r '[.rules[] | select(.source == "profile" and .method == "POST" and (.path | endswith("/issues")))][0].how')"
sed -i.bak '/^- profile.sb_repo:/d; /^- work_repo:/d' "$WORK_DIR/CONFIG.md"

# A GitHub Enterprise Server target is one host for the API (under /api/v3) and the pages:
# each shape passes there as on github.com, and the API shape only under its prefix. Each
# accepted one lands by hand: the host's shared GitHub deny refuses it at once, no prompt.
cat > "$QI_PROFILE_DIR/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "egress":[{"host":"ghe.acme.io","method":"GET","path":"/login?*","why":"oauth"},
           {"host":"ghe.acme.io","method":"POST","path":"/session","why":"oauth"},
           {"host":"ghe.acme.io","method":"POST","path":"/sb/qa.git/git-upload-pack","why":"git"},
           {"host":"ghe.acme.io","method":"POST","path":"/api/v3/repos/sb/qa/issues","why":"api"},
           {"host":"ghe.acme.io","method":"POST","path":"/repos/sb/qa/issues","why":"api without its prefix"},
           {"host":"ghe.acme.io","method":"GET","path":"/sb/qa/blob/HEAD/x","why":"a page"},
           {"host":"ghe.acme.io","method":"POST","path":"/api/v3/repos/acme/x/issues","why":"the target's owner"},
           {"host":"ghe.acme.io","method":"POST","path":"/api/v3/repos/sb/qa","why":"api without its rest"}]}
J
ghes="$(QI_TARGET_REPO=ghe.acme.io/acme/widgets bash "$DEF/scripts/egress-rules.sh" --json | jq -r '.rules[] | select(.source == "profile") | "\(.how) \(.method) \(.path)"')"
assert_eq "GHES: the sandbox shapes on the one host, each by hand" "by-hand GET /login?*
by-hand POST /session
by-hand POST /sb/qa.git/git-upload-pack
by-hand POST /api/v3/repos/sb/qa/issues
refused POST /repos/sb/qa/issues
refused GET /sb/qa/blob/HEAD/x
refused POST /api/v3/repos/acme/x/issues
refused POST /api/v3/repos/sb/qa" "$ghes"
assert_eq "GHES: the reason names the API shape of the one host" \
  "not /api/v3/repos/<owner>/<repo>/<rest>, git's /<owner>/<repo>.git requests or the OAuth sign-in" \
  "$(QI_TARGET_REPO=ghe.acme.io/acme/widgets bash "$DEF/scripts/egress-rules.sh" --json | jq -r '.rules[] | select(.source == "profile" and .path == "/api/v3/repos/sb/qa") | .why | sub(" — a profile defect.*"; "")')"
# A ghe.com target: the API on api.<host>, the pages on <host>; each under its shared deny.
cat > "$QI_PROFILE_DIR/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "egress":[{"host":"acme.ghe.com","method":"GET","path":"/login?*","why":"oauth"},
           {"host":"acme.ghe.com","method":"GET","path":"/sb/qa.git/info/refs?service=git-upload-pack","why":"git"},
           {"host":"api.acme.ghe.com","method":"POST","path":"/repos/sb/qa/issues","why":"api"},
           {"host":"api.acme.ghe.com","method":"GET","path":"/login?*","why":"oauth on the API host"}]}
J
assert_eq "ghe.com: the sandbox shapes, each by hand" "by-hand GET acme.ghe.com /login?*
by-hand GET acme.ghe.com /sb/qa.git/info/refs?service=git-upload-pack
by-hand POST api.acme.ghe.com /repos/sb/qa/issues
refused GET api.acme.ghe.com /login?*" \
  "$(QI_TARGET_REPO=acme.ghe.com/acme/widgets bash "$DEF/scripts/egress-rules.sh" --json | jq -r '.rules[] | select(.source == "profile") | "\(.how) \(.method) \(.host) \(.path)"')"

# verify-onboarding.sh --egress: one GET per profile rule; a held request is a warning, a
# refused connection a FAIL naming the rule to add by hand, a 403 a warning (the gateway or
# the host itself), any other answer a pass; wildcard hosts and odd host names are skipped.
mkdir -p "$SANDBOX/egress-bin"
cat > "$SANDBOX/egress-bin/curl" <<'S'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  (https://held.example/*) printf 000; exit 28;;
  (https://refused.example/*) printf 000; exit 56;;
  (https://forbidden.example/*) printf 403; exit 0;;
  (https://open.example/a/qi-egress-check) printf 404; exit 0;;
  (https://typo.example/*) printf 000; exit 6;;
  (https://badcert.example/*) printf 000; exit 60;;
esac; done
printf 000; exit 7
S
chmod +x "$SANDBOX/egress-bin/curl"
cat > "$QI_PROFILE_DIR/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "egress":[{"host":"open.example","method":"GET","path":"/a/*","why":"assets"},
           {"host":"held.example","method":"GET","why":"charts"},
           {"host":"refused.example","method":"GET","path":"/r/*","why":"manifests"},
           {"host":"*.layers.example","method":"GET","why":"layers"},
           {"host":"up.example","method":"POST","why":"uploads"},
           {"host":"typo.example","method":"GET","why":"dns"},
           {"host":"badcert.example","method":"GET","why":"tls"},
           {"host":"forbidden.example","method":"GET","why":"bucket"},
           {"host":"u@evil.example/x?","method":"GET","why":"odd"}]}
J
eg="$(PATH="$SANDBOX/egress-bin:$PATH" bash "$SCRIPTS/verify-onboarding.sh" --egress 2>/dev/null | grep ' egress:')"
printf '%s\n' "$eg" | grep -q '^ok   egress:open.example — GET /a/\* passes (HTTP 404)$' || { echo "  assertion failed: an answered request passes"; FAILED=1; }
printf '%s\n' "$eg" | grep -q '^warn egress:held.example — held for approval' || { echo "  assertion failed: a held request warns"; FAILED=1; }
printf '%s\n' "$eg" | grep -q '^FAIL egress:refused.example — GET /r/\* refused at once (prompt) — fix: add an allow rule in the agent.s network settings: host refused.example, method GET, path /r/\*' \
  || { echo "  assertion failed: a refused request fails with the rule to add"; FAILED=1; }
printf '%s\n' "$eg" | grep -q '^warn egress:\*.layers.example — a wildcard host is not probed' || { echo "  assertion failed: a wildcard host is skipped"; FAILED=1; }
printf '%s\n' "$eg" | grep -q '^warn egress:up.example — POST \* is not probed' || { echo "  assertion failed: a non-GET rule is skipped"; FAILED=1; }
printf '%s\n' "$eg" | grep -q '^FAIL egress:typo.example — the host does not resolve (DNS) — fix: check the host name' || { echo "  assertion failed: a DNS failure is not an egress rule"; FAILED=1; }
printf '%s\n' "$eg" | grep -q '^FAIL egress:badcert.example — TLS to the host failed (curl exit 60) — fix: check the host name and its certificate' || { echo "  assertion failed: a TLS failure is not an egress rule"; FAILED=1; }
printf '%s\n' "$eg" | grep -q '^warn egress:forbidden.example — GET \* answered HTTP 403 — the gateway.s refusal, or the host.s own answer' \
  || { echo "  assertion failed: a 403 warns, naming both causes"; FAILED=1; }
printf '%s\n' "$eg" | grep -q '^FAIL egress:forbidden' && { echo "  assertion failed: a 403 is no FAIL"; FAILED=1; }
printf '%s\n' "$eg" | grep -q '^warn egress:u?evil.example?x? — not a plain host name — not probed' \
  || { echo "  assertion failed: an odd host name is not probed"; FAILED=1; }
printf '%s\n' "$eg" | grep -E 'egress:(typo|badcert)\.example.*add an allow rule' && { echo "  assertion failed: no allow rule for a DNS or TLS failure"; FAILED=1; }

exit $FAILED
