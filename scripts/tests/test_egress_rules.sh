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

# verify-onboarding.sh --egress: one GET per profile rule; a held request is a warning, a
# refusal a FAIL naming the rule to add by hand, any answer a pass; wildcard hosts are skipped.
mkdir -p "$SANDBOX/egress-bin"
cat > "$SANDBOX/egress-bin/curl" <<'S'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in
  (https://held.example/*) printf 000; exit 28;;
  (https://refused.example/*) printf 403; exit 0;;
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
           {"host":"badcert.example","method":"GET","why":"tls"}]}
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
printf '%s\n' "$eg" | grep -E 'egress:(typo|badcert)\.example.*add an allow rule' && { echo "  assertion failed: no allow rule for a DNS or TLS failure"; FAILED=1; }

exit $FAILED
