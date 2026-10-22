#!/usr/bin/env bash
# egress-rules.sh — list the egress rules this instance needs beyond the kit's
# (docs/black-box.md → Egress rules): the profile's `egress`, the work backup repository's
# (`work_repo`) and — for a target on GitHub Enterprise — the shared GitHub rules on that
# host. A github.com target needs nothing here: the kit's rules hold for every target.
# --kit adds the kit's own rules, for an agent created by hand or from a kit before 3.0.0.
#
# Data for the operator, never commands: each rule as host, method, path, verdict and why,
# and how it gets onto the agent —
#   prompt   no kit rule covers the host: the first request in a direct session is held
#            and the operator answers its approval prompt ("Allow permanently");
#            `verify-onboarding.sh --egress` makes that request. A wildcard host prompts
#            once per host it reaches.
#   by-hand  the operator adds it in the agent's network settings: it falls under a deny of
#            the kit or of a GitHub Enterprise target's shared rules (refused at once, no
#            prompt ever appears), it is a deny, or it belongs to
#            a set that must land whole (the kit's own, the work backup, GitHub Enterprise).
#   kit      the kit already allows it — nothing to do.
#   refused  never to be added: a profile allow on a GitHub host outside the closed set
#            below, or a `{profile.<key>}` placeholder whose value is unset or not a plain
#            name. verify-onboarding.sh fails on it; it is a profile defect.
# A profile rule may name `{profile.<key>}` in its host or path — the instance's value of that
# profile key (a sandbox account's organization or repository, docs/profile-contract.md →
# `sandbox`). On a GitHub host (github.com, *.github.com, *.githubusercontent.com, the
# target's host) a profile allow passes only on the API host as /repos/<owner>/<repo>/<rest>
# (/api/v3/repos/… on a GitHub Enterprise Server, one host for both), <rest> not empty, or
# on the web host as one of git's four smart-HTTP requests to
# /<owner>/<repo>[.git]/ with its own method (GET info/refs?service=git-upload-pack|
# git-receive-pack, POST git-upload-pack|git-receive-pack) — owner and repository literal
# [A-Za-z0-9.-], the owner never the target's or the work backup's: a sandbox repository the
# nested product writes to with a token scoped to it — or, on the web host, one of the exact
# requests of the OAuth sign-in a sandbox user connects GitHub through (_github_oauth below;
# docs/black-box.md → Sandbox accounts).
# The black-box gate (scripts/preflight.sh) and `verify-onboarding.sh --live` prove them.
#
#   egress-rules.sh [--kit] [--json]

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/profile.sh" || { echo "cannot source lib/profile.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/boundary.sh" || { echo "cannot source lib/boundary.sh" >&2; exit 1; }

usage() { echo "usage: egress-rules.sh [--kit] [--json]" >&2; exit 2; }
KIT=0; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in (--kit) KIT=1;; (--json) JSON=1;; (*) usage;; esac
  shift
done
T="${QI_TARGET_REPO:-$(cfg target_repo)}"
W="$(cfg work_repo)"
[ -n "$W" ] && [ -n "$T" ] && [ "$(_bb_host "$W")/$(_bb_repo "$W" | tr 'A-Z' 'a-z')" = "$(_bb_host "$T")/$(_bb_repo "$T" | tr 'A-Z' 'a-z')" ] \
  && { echo "work_repo is the target repository — refused (docs/persistence.md → Backup & restore)" >&2; exit 1; }

NOTES=(); ROWS=()
note() { NOTES+=("$1"); }
row() { # <source> <verdict> <method> <host> <path> <how> [why]
  ROWS+=("$(jq -cn --arg s "$1" --arg v "$2" --arg m "$3" --arg h "$4" --arg p "$5" --arg how "$6" --arg w "${7:-}" \
    '{source: $s, verdict: $v, method: $m, host: $h, path: $p, how: $how, why: $w}')")
}

# Does a kit rule pattern cover a path? '*' is the only wildcard (SQL LIKE '%' on the platform).
_covers() { # <pattern> <path>
  local pat; pat="$(printf '%s' "$1" | sed 's/[][?\\]/\\&/g')"
  # shellcheck disable=SC2053
  [[ "$2" == $pat ]]
}
# Does a kit rule's host cover <host>: exact, `*.parent` for one more label, or `*`?
_host_covers() { # <rule host> <host>
  case "$1" in
    ("$2"|'*') return 0;;
    ('*.'*) local rest="${2#*.}"; [ "$rest" != "$2" ] && [ "*.$rest" = "$1" ];;
    (*) return 1;;
  esac
}
# Is <host> one of GitHub's, or the target's?
_github_host() { # <host>
  local th; th="$(_bb_host "${T:-x/y}")"
  case "$1" in
    (github.com|*.github.com|*.githubusercontent.com|githubusercontent.com) return 0;;
    ("$th"|"api.$th") return 0;;
  esac
  return 1
}
# The OAuth sign-in through which a sandbox user connects GitHub to the nested product, on
# the web host: the login form, the password, the two-factor (TOTP) page and its answer, the
# authorize page and its consent, and the product's server-side code exchange — each one
# exact path with its one method. Only the login form (its return_to) and the authorize page
# take a query, and a query never changes the page GitHub serves; no path names an owner or
# a repository, and a redirect to one meets the host's deny. '_' in access_token is a pattern
# wildcard: it also opens /login/oauth/access?token, a page that does not exist.
_github_oauth() { # <method> <path>
  case "$1 $2" in
    ('GET /login'|'GET /login?*'|'POST /session') return 0;;
    ('GET /sessions/two-factor/app'|'POST /sessions/two-factor') return 0;;
    ('GET /login/oauth/authorize?*'|'POST /login/oauth/authorize'|'POST /login/oauth/access_token') return 0;;
  esac
  return 1
}
# Why a profile allow on a GitHub host is refused; nothing when it is in the closed set.
_github_refusal() { # <method> <host> <path>
  local web api pre="" is_api=0 is_web=0 o r rest="" lo
  web="$(_bb_host "${T:-x/y}")"; api="$(_bb_api_host "$web")"
  # A GitHub Enterprise Server is one host for both: its API under /api/v3, its pages beside it.
  case "$2" in (api.github.com) is_api=1;; (github.com) is_web=1;; esac
  [ "$2" = "$api" ] && { is_api=1; pre="$(_bb_api_prefix "$web")"; }
  [ "$2" = "$web" ] && is_web=1
  [ "$is_api$is_web" = 00 ] && { echo "a GitHub host other than its API"; return; }
  if [ "$is_api" = 1 ]; then
    case "$3" in ("$pre"/repos/*/*/?*) rest="${3#"$pre"/repos/}";; esac
  fi
  if [ -z "$rest" ] && [ "$is_web" = 1 ]; then
    # The OAuth sign-in of a sandbox user: no owner, no repository, so nothing more to check.
    _github_oauth "$1" "$3" && return 0
    # git over smart HTTP: the four requests of a clone and a push, each with its own method.
    rest="${3#/}"
    case "${rest#*/*/}:$1" in
      ('info/refs?service=git-upload-pack:GET'|'git-upload-pack:POST') ;;
      ('info/refs?service=git-receive-pack:GET'|'git-receive-pack:POST') ;;
      (*) rest="";;
    esac
  fi
  if [ -z "$rest" ]; then
    if [ "$is_web" = 1 ]; then echo "a GitHub host other than its API, but for git's /<owner>/<repo>.git requests and the OAuth sign-in"
    else echo "not $pre/repos/<owner>/<repo>/<rest>"; fi
    return
  fi
  o="${rest%%/*}"; rest="${rest#*/}"; r="${rest%%/*}"
  for lo in "$o" "$r"; do
    case "$lo" in (''|.|..|*[!A-Za-z0-9.-]*) echo "owner and repository must be literal [A-Za-z0-9.-] names"; return;; esac
  done
  lo="$(_bb_lower "$o")"
  [ -n "${T:-}" ] && [ "$lo" = "$(_bb_lower "$(_bb_repo "$T" | cut -d/ -f1)")" ] && { echo "the owner is the target's"; return; }
  [ -n "${W:-}" ] && [ "$lo" = "$(_bb_lower "$(_bb_repo "$W" | cut -d/ -f1)")" ] && { echo "the owner is the work backup's"; return; }
  return 0
}
# `{profile.<key>}` in a host or path, replaced by the instance's value; fails naming the key
# when the value is unset or not a plain name ([A-Za-z0-9.-] segments joined by '/').
PCFG=""
_subst() { # <text>
  local t="$1" k v
  while [[ "$t" =~ \{profile\.([a-z0-9_]+)\} ]]; do
    k="${BASH_REMATCH[1]}"
    [ -n "$PCFG" ] || PCFG="$(profile_config)"
    v="$(jq -r --arg k "$k" '.[$k] // ""' <<<"$PCFG")"
    printf '%s' "$v" | grep -qE '^[A-Za-z0-9.-]+(/[A-Za-z0-9.-]+)*$' && ! printf '%s' "/$v/" | grep -qE '/\.\.?/' \
      || { echo "profile.$k"; return 1; }
    t="${t//\{profile.$k\}/$v}"
  done
  printf '%s\n' "$t"
}
# How a profile rule gets onto the agent, against the rules that land beside it: the kit's
# and, for a GitHub Enterprise target, the shared GitHub rules on its host (GHR, by hand).
_how() { # <verdict> <method> <host> <path>
  local src v m h p s best=-1 win=""
  [ "$1" = deny ] && { echo by-hand; return; }
  _github_host "$3" && [ -n "$(_github_refusal "$2" "$3" "$4")" ] && { echo refused; return; }
  # The rule the platform would pick on this exact host: a named method over '*', then the
  # longer path; a deny wins a tie. Only a kit allow picked so covers it — a longer deny
  # beside a shorter kit allow (`/repos/*/*/*` beside `/repos/*/*`) refuses the request.
  if [ "$4" != '*' ]; then
    while read -r src v m h p; do
      [ "$h" = "$3" ] && { [ "$m" = "$2" ] || [ "$m" = '*' ]; } && _covers "$p" "$4" || continue
      s=${#p}; [ "$m" = '*' ] || s=$((s + 100000))
      if [ "$s" -gt "$best" ] || { [ "$s" = "$best" ] && [ "$v" = deny ]; }; then best=$s; win="$src $v"; fi
    done < <(_landed_rules)
    [ "$win" = "kit allow" ] && { echo kit; return; }
  fi
  while read -r src v m h p; do
    [ "$v" = deny ] && _host_covers "$h" "$3" && { [ "$4" = '*' ] || _covers "$p" "$4"; } && { echo by-hand; return; }
  done < <(_landed_rules)
  echo prompt
}
GHR=""
# The kit's rules and GHR, each line "<kit|github> <verdict> <method> <host> <path pattern>".
_landed_rules() { kit_rules | sed 's/^/kit /'; [ -z "$GHR" ] || printf '%s\n' "$GHR" | sed 's/^/github /'; }

# kit.yaml's egressRules as "<verdict> <method> <host> <path pattern>" lines; a key counts
# on the item's "- " line too, quoted or not, before a trailing comment — as the
# validator's kit check reads it.
kit_rules() {
  sed -n '/^egressRules:/,/^[a-z]/p' "$SCRIPT_DIR/../kit.yaml" 2>/dev/null | awk '
    function val(s) { sub(/^[^:]*:[[:space:]]*/, "", s); sub(/[[:space:]]+#.*$/, "", s); gsub(/["\047]/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function emit() { if (h != "") print v, m, h, p }
    /^  - / { emit(); h = ""; m = "*"; p = "*"; v = "allow" }
    /^(  - |    )host:/ { h = val($0) }
    /^(  - |    )method:/ { m = val($0) }
    /^(  - |    )pathPattern:/ { p = val($0) }
    /^(  - |    )verdict:/ { v = val($0) }
    END { emit() }'
}

if [ "$KIT" = 1 ]; then
  note "The kit's rules (kit.yaml) — already on an agent created from kit 3.0.0 or newer; a kit never updates an existing agent's rules."
  while read -r v m h p; do row kit "$v" "$m" "$h" "$p" by-hand; done < <(kit_rules)
else
  note "The kit's rules (kit.yaml) are left out: an agent created by hand or from a kit before 3.0.0 lacks them — run with --kit."
fi
if [ -z "$T" ]; then
  note "No target_repo yet — a GitHub Enterprise target's rules are listed once it is set."
elif [ "$(_bb_host "$T")" = github.com ]; then
  note "The target $T is on github.com: the kit's GitHub rules hold for it — nothing to add."
else
  H="$(_bb_host "$T")"
  note "The target $T is on $H: the shared GitHub rules on that host (docs/black-box.md → Egress rules), all of them."
  d=""; read -r dh dr < <(_bb_definition) && [ "$dh" = "$H" ] && d="$dr"
  GHR="$(github_rules "$H" $d)"
  [ -z "$GHR" ] || while read -r v m h p; do row github "$v" "$m" "$h" "$p" by-hand; done <<<"$GHR"
fi
if [ -n "$W" ]; then
  while read -r v m h p; do row work_repo "$v" "$m" "$h" "$p" by-hand "the work backup $W (git fetch and push)"; done < <(work_repo_rules)
fi
if dir="$(profile_dir)" && [ -f "$dir/profile.json" ]; then
  while IFS="$(printf '\t')" read -r v m h p why; do
    k=""
    if ! h2="$(_subst "$h")"; then k="$h2"; elif ! p2="$(_subst "$p")"; then k="$p2"; fi
    if [ -n "$k" ]; then
      row profile "$v" "$m" "$h" "$p" refused "$k is unset or not a plain name — set it in work/CONFIG.md (ONBOARDING.md Step 3)"; continue
    fi
    how="$(_how "$v" "$m" "$h2" "$p2")"
    [ "$how" = refused ] && why="$(_github_refusal "$m" "$h2" "$p2") — a profile defect: report it to the profile's repository (docs/black-box.md → Sandbox accounts)"
    row profile "$v" "$m" "$h2" "$p2" "$how" "$why"
  done < <(jq -r '.egress[]? | [(.verdict // "allow"), (.method // "*"), .host, (.pathPattern // .path // "*"), (.why // "")] | @tsv' "$dir/profile.json")
else
  note "No profile installed — its egress is listed once it is."
fi

if [ "$JSON" = 1 ]; then
  { printf '%s\n' ${ROWS[@]+"${ROWS[@]}"}; } | jq -s --args '{rules: ., notes: $ARGS.positional}' ${NOTES[@]+"${NOTES[@]}"}
  exit 0
fi
printf '%s\n' ${NOTES[@]+"${NOTES[@]}"}
[ ${#ROWS[@]} -gt 0 ] || exit 0
echo
echo "| how | verdict | method | host | path | why |"
echo "| --- | --- | --- | --- | --- | --- |"
printf '%s\n' "${ROWS[@]}" | jq -r '"| \(.how) | \(.verdict) | \(.method) | `\(.host)` | `\(.path)` | \(.why | gsub("\\|"; "/")) |"'
echo
echo "prompt: approve its prompt when it appears (verify-onboarding.sh --egress asks for each one) · by-hand: add it in the agent's network settings, no prompt will appear · kit: nothing to do · refused: never add it (its why says what is wrong)."
