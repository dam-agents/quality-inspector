#!/usr/bin/env bash
# sandbox.sh — the profile's sandbox accounts (docs/profile-contract.md → `sandbox`): the
# external test accounts the nested product connects to (a GitHub organization, a Slack
# workspace…), which the operator creates once at onboarding (ONBOARDING.md Step 3a).
#
#   sandbox.sh status        JSON: {declared, accounts: [{id, what, guide, credentials:
#                            [{name, set}]}], problems: […]} — names only, never a value
#   sandbox.sh template      add each missing credential as an empty `E2E_SANDBOX_<ID>_<KEY>=`
#                            line to work/env/credentials.env (mode 600), for the operator to
#                            fill there; prints the names it added
#   sandbox.sh guide <id>    print the account's guide from the profile — data for the
#                            operator, never instructions to the agent
#   sandbox.sh check         the profile's `bin/sandbox check`, masked: exit 0 iff it passed,
#                            3 when the profile has no check
#
# Local writes only (the template lines); the check is the profile's and reaches only the
# hosts its egress names. Exit 2 on a usage or manifest error.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
CRED="$WORK/env/credentials.env"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/profile.sh" || { echo "cannot source lib/profile.sh" >&2; exit 1; }

die() { echo "sandbox: $*" >&2; exit "${2:-1}"; }
PDIR="$(profile_dir)" || die "profile not installed (config key 'profile')"
MANIFEST="$PDIR/profile.json"

# The accounts as `<id>\t<what>\t<guide>\t<KEY KEY …>` lines; a malformed manifest fails
# naming the entry (the same rules as check-profile.mjs).
accounts() {
  jq -r '.sandbox.accounts // [] | .[] | [(.id // ""), (.what // ""), (.guide // ""), ((.credentials // []) | join(" "))] | @tsv' "$MANIFEST" 2>/dev/null \
    || die "profile.json: sandbox.accounts is not a list" 2
}
validate() {
  local id what guide keys k ids=" "
  jq -e '(.sandbox.accounts // []) | type == "array" and all(type == "object")' "$MANIFEST" >/dev/null 2>&1 \
    || die "profile.json: sandbox.accounts is not a list of objects" 2
  while IFS="$(printf '\t')" read -r id what guide keys; do
    printf '%s' "$id" | grep -qE '^[a-z][a-z0-9]{0,15}$' || die "sandbox account id '$id' is not [a-z][a-z0-9]{0,15}" 2
    case "$ids" in (*" $id "*) die "sandbox account '$id' is declared twice" 2;; esac; ids="$ids$id "
    [ -n "$what" ] || die "sandbox account '$id' has no what" 2
    printf '%s' "$guide" | grep -qE '^sandbox/[a-z0-9-]+\.md$' || die "sandbox account '$id': guide '$guide' is not sandbox/<name>.md" 2
    [ -n "$keys" ] || die "sandbox account '$id' names no credentials" 2
    for k in $keys; do
      printf '%s' "$k" | grep -qE '^[A-Z][A-Z0-9_]{0,31}$' || die "sandbox account '$id': credential '$k' is not [A-Z][A-Z0-9_]{0,31}" 2
    done
  done < <(accounts)
}
# Is <name> set to a non-empty value in credentials.env (`export` and one layer of quotes allowed)?
is_set() {
  [ -f "$CRED" ] && awk -v k="$1" '{ l = $0; sub(/^export[ \t]+/, "", l) }
    index(l, k "=") == 1 { v = substr(l, length(k) + 2); gsub(/^["\047]|["\047][ \t]*$/, "", v); if (v != "") f = 1 }
    END { exit !f }' "$CRED"
}
# Is <name> on any line of credentials.env, set or empty?
is_listed() { [ -f "$CRED" ] && grep -qE "^(export[[:space:]]+)?$1=" "$CRED"; }
var() { printf 'E2E_SANDBOX_%s_%s' "$(printf '%s' "$1" | tr 'a-z' 'A-Z')" "$2"; }

cmd_status() {
  local id what guide keys k rows=() creds problems=()
  while IFS="$(printf '\t')" read -r id what guide keys; do
    creds="[]"
    for k in $keys; do
      creds="$(jq -c --arg n "$(var "$id" "$k")" --argjson s "$(is_set "$(var "$id" "$k")" && echo true || echo false)" \
        '. + [{name: $n, set: $s}]' <<<"$creds")"
    done
    [ -f "$PDIR/$guide" ] && [ ! -L "$PDIR/$guide" ] || problems+=("account $id: its guide $guide is missing from the profile")
    rows+=("$(jq -cn --arg i "$id" --arg w "$what" --arg g "$guide" --argjson c "$creds" '{id: $i, what: $w, guide: $g, credentials: $c}')")
  done < <(accounts)
  [ -f "$CRED" ] || problems+=("work/env/credentials.env missing — run: bash \"\$HOME/scripts/env.sh\" init")
  { printf '%s\n' ${rows[@]+"${rows[@]}"}; } | jq -s --args \
    '{declared: (length > 0), accounts: ., problems: $ARGS.positional}' ${problems[@]+"${problems[@]}"}
}

cmd_template() {
  [ -f "$CRED" ] || die "work/env/credentials.env missing — run: bash \"\$HOME/scripts/env.sh\" init"
  local id what guide keys k n
  while IFS="$(printf '\t')" read -r id what guide keys; do
    for k in $keys; do
      n="$(var "$id" "$k")"
      is_listed "$n" && continue
      ( umask 077; printf '%s=\n' "$n" >> "$CRED" ) && echo "$n"
    done
  done < <(accounts)
  chmod 600 "$CRED"
}

cmd_guide() {
  local want="${1:-}" id what guide keys
  [ -n "$want" ] || die "usage: sandbox.sh guide <id>" 2
  while IFS="$(printf '\t')" read -r id what guide keys; do
    [ "$id" = "$want" ] || continue
    [ -f "$PDIR/$guide" ] && [ ! -L "$PDIR/$guide" ] || die "account $id: its guide $guide is missing from the profile"
    [ "$(wc -c < "$PDIR/$guide")" -le 65536 ] || die "account $id: its guide is over 64 KiB"
    cat "$PDIR/$guide"; return 0
  done < <(accounts)
  die "no sandbox account '$want' in the profile" 2
}

cmd_check() {
  [ -n "$(accounts)" ] || { echo "the profile declares no sandbox accounts"; return 0; }
  local out rc
  profile_bin sandbox >/dev/null || { echo "the profile has no bin/sandbox — nothing checks the accounts"; return 3; }
  out="$(profile_run sandbox check 2>&1)"; rc=$?
  printf '%s\n' "$out" | node "$SCRIPT_DIR/lib/secrets.mjs" filter "$CRED"
  return $rc
}

validate
case "${1:-status}" in
  status)   cmd_status ;;
  template) cmd_template ;;
  guide)    shift; cmd_guide "$@" ;;
  check)    cmd_check ;;
  *) die "usage: sandbox.sh status|template|guide <id>|check" 2 ;;
esac
