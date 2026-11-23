#!/usr/bin/env bash
# preflight.sh audit: the `escapes` and `risks` checks (docs/escapes.md, docs/risks.md) — ok with no file
# yet; warn for an escape not analysed over 7 days, an observe rule ready for the operator, a rule no
# issue met in 90 days and old lessons; fail for a malformed register.
. "$(dirname "$0")/lib.sh"
command -v node >/dev/null || { echo "  node missing"; exit 1; }
seed_work
echo '[]' > "$STUB_DIR/issues.json"
export HOME="$SANDBOX"
W="$WORK_DIR"
chk() { bash "$SCRIPTS/preflight.sh" audit | jq -c '[.checks[] | select(.id == "escapes" or .id == "risks")] | map({(.id): {status, detail}}) | add'; }

out="$(chk)"
assert "no registers yet: both ok" '.escapes.status == "ok" and .risks.status == "ok" and (.escapes.detail | test("none yet"))' "$out"

E_HEAD='| id | ref | origin | severity | received_utc | thread | state | phase | risk | case | analysed_utc |'
printf '%s\n%s\n%s\n%s\n' '# Escaped defects' "$E_HEAD" '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |' \
  '| E-1 | INC-1 | #42 | high | 2026-01-01T00:00:00Z | 1.2 | new | - | - | - | - |' > "$W/ESCAPES.md"
assert "an escape not analysed over 7 days: warn" '.escapes.status == "warn" and (.escapes.detail | test("E-1"))' "$(chk)"
sed -i.bak 's/| new | - | - | - | - |/| analysed | test | - | - | 2026-01-02T00:00:00Z |/' "$W/ESCAPES.md"
assert "analysed: ok, by phase" '.escapes.status == "ok" and (.escapes.detail | test("test 1"))' "$(chk)"
sed -i.bak 's/| high |/| urgent |/' "$W/ESCAPES.md"
assert "a malformed row: fail" '.escapes.status == "fail" and (.escapes.detail | test("severity"))' "$(chk)"

R_HEAD='| id | mode | triggers | check | source | added_utc | runs | observations | last_utc | last_ref |'
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s\n%s\n%s\n%s\n' '# Risks' "$R_HEAD" '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |' \
  "| R-1 | observe | word:upload | Given a long file name, when the user uploads it, the file shows. | E-1 | $now | 0 | 0 | - | - |" > "$W/RISKS.md"
assert "a fresh rule: ok" '.risks.status == "ok"' "$(chk)"
printf '%s\n' "| R-2 | observe | word:share link | Given a removed link, when a visitor opens it, an error page shows. | operator | $now | 6 | 0 | $now | #7 EX-1 |" >> "$W/RISKS.md"
assert "an observe rule with 6 runs and no observation: retire it" '.risks.status == "warn" and (.risks.detail | test("R-2 ran 6× with 0 observations: retire it"))' "$(chk)"
printf -- '- 2020-01-01 env: an old lesson\n' > "$W/LESSONS.md"
assert "old lessons are named" '.risks.detail | test("1 lines of work/LESSONS.md")' "$(chk)"
printf '%s\n' '| R-3 | loud | word:x | y | nobody | x | 0 | 0 | - | - |' >> "$W/RISKS.md"
assert "a malformed rule: fail" '.risks.status == "fail" and (.risks.detail | test("R-3"))' "$(chk)"
exit $FAILED
