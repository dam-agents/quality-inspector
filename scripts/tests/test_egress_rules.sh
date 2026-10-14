#!/usr/bin/env bash
# kit.yaml's egress rules, read by the validator (a deny needs a path, or the apply fails)
# and by egress-rules.sh --kit, in any YAML style: quoted values, any key first, a trailing
# comment. And what egress-rules.sh prints without --kit, and for an unsafe profile value.
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
cmds="$(bash "$DEF/scripts/egress-rules.sh" --kit)"
for want in 'dam network create "$AGENT" --host a.example --verdict deny --yes' \
            'dam network create "$AGENT" --host b.example --verdict deny --yes' \
            'dam network create "$AGENT" --host c.example --verdict deny --yes' \
            'dam network create "$AGENT" --host e.example --path "/x*" --verdict deny --yes' \
            'dam network create "$AGENT" --host f.example --method GET --yes'; do
  printf '%s\n' "$cmds" | grep -qxF -- "$want" || { echo "  assertion failed: --kit prints: $want"; FAILED=1; }
done

kit '  - host: d.example' '    pathPattern: "/*"' '    verdict: "deny"' \
    '  - pathPattern: "/x*"' '    host: e.example' '    verdict: deny'
assert_eq "denies with a path pass" "PASS  kit.yaml egress denies each name a path" "$(check)"

# Without --kit the kit's rules are left out, and the output says when they are needed.
printf '%s\n' "$(bash "$DEF/scripts/egress-rules.sh")" | grep -q '^# The kit.s rules (kit.yaml) are left out: .* run with --kit\.$' \
  || { echo "  assertion failed: the note about --kit"; FAILED=1; }
printf '%s\n' "$cmds" | grep -q 'are left out' && { echo "  assertion failed: no note with --kit"; FAILED=1; }

# The operator runs the output in a shell: a profile value that could expand there is skipped.
cat > "$QI_PROFILE_DIR/profile.json" <<'J'
{"schema":"qi-profile/v1","product":"Stub","app":{"url":"http://localhost:8080"},
 "egress":[{"host":"cdn.example.com","method":"GET","path":"/a/*","why":"assets $(x)"},
           {"host":"evil.example.com","path":"/x$(touch /tmp/quality-inspector-x)"},
           {"host":"evil`id`.example.com"}]}
J
out="$(bash "$DEF/scripts/egress-rules.sh")"
printf '%s\n' "$out" | grep -qxF 'dam network create "$AGENT" --host cdn.example.com --method GET --path "/a/*" --yes  # assets $(x)' \
  || { echo "  assertion failed: a safe profile entry is printed"; FAILED=1; }
assert_eq "an unsafe profile entry is skipped" "2" "$(printf '%s\n' "$out" | grep -c '^# Skipped: .*evil')"
printf '%s\n' "$out" | sed 's/  # .*$//' | grep -E '^dam .*(\$\(|`)' \
  && { echo "  assertion failed: no command holds an expansion"; FAILED=1; }

exit $FAILED
