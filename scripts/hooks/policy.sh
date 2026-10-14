#!/usr/bin/env bash
# policy.sh — Claude Code PreToolUse hook: the harness half of the trust boundary
# (docs/black-box.md → Enforcement layers). Registered by scripts/hooks/install.sh.
#
# Contract: one tool-call JSON on stdin ({session_id, cwd, tool_name, tool_input, …}).
# Exit 0 = no objection (the normal permission flow continues); exit 2 = blocked, the one
# stderr line goes to the model. Any other exit would be a NON-blocking error, so every
# path below ends in 0 or 2. Pure bash + jq, no network, no model. Fails closed: no jq or
# unparsable input → deny. It matches command TEXT — it stops mistakes and injected
# instructions; the egress rules stay the boundary against a deliberate bypass.
#
# <T> = target_repo (QI_TARGET_REPO wins); "scheduled" = a fresh work/env/RUN_MODE
# (docs/persistence.md → Scheduled or direct session). Every rule id below has a deny
# fixture in scripts/tests/policy-fixtures.jsonl; the validator fails without one.
#
#   rule             tools                 denies
#   gh-api-path      Bash                  a GitHub API path under /repos/<T>/ other than issues, issues/<n>,
#                                          issues/<n>/comments, issues/<n>/labels/<l> — so contents (the
#                                          profile dir included), pulls, commits, git/, compare, branches,
#                                          actions, releases, issue timeline and events; via `gh api` or a
#                                          URL on the API host. An owner/repo given as a variable counts as <T>;
#                                          with no target configured every repository does.
#   gh-graphql       Bash                  `gh api graphql` (the issues REST endpoints are the only reads)
#   gh-search        Bash                  `gh api search/code|commits` naming <T>
#   gh-cli           Bash                  `gh pr|repo|release|run|workflow|browse|gist|search|cache|…` naming <T>
#   raw-host         Bash WebFetch WebSearch  raw.githubusercontent.com
#   codeload         Bash WebFetch WebSearch  codeload.<github host>/<T>
#   repo-web         Bash WebFetch WebSearch  <github host>/<T> — web pages, git clone/fetch over https or ssh
#   profile-url      Bash WebFetch WebSearch  a URL under the profile's boundary.urls
#   source-map       Bash WebFetch Read Glob Grep  a *.map URL; a *.map file under work/ or /tmp/quality-inspector-*
#   product-package  Bash Read Glob Grep   node_modules/<entry> for each profile boundary.packages entry
#   chart-template   Bash Read Glob Grep   templates/ under work/env/, anything under /tmp/quality-inspector-chart-*,
#                                          helm pull|fetch|template|get manifest|get all|show values|show all
#   git-clean        Bash                  git clean, anywhere
#   container-fs     Bash                  kubectl (k3s too) exec|cp|debug|attach, ctr, crictl,
#                                          docker|podman|nerdctl exec|cp|export|save|run|create
#   write-outside    Write Edit MultiEdit NotebookEdit  a path outside work/, /tmp/quality-inspector-*
#                                          and — in a direct session — the definition's .gitignore allowlist
#   run-mode         Write Edit …          work/env/RUN_MODE (only the Precheck writes it)
#   scheduled-def    Write Edit … (sched.) definition files and work/CONFIG.md
#   scheduled-git    Bash (scheduled)      git commit, git push, gh pr create|merge, and a `gh api` write
#                                          (a method other than GET, or a field or --input) whose endpoint
#                                          is not under the target's issues — so a pull request over REST too
#   policy-tamper    Bash (scheduled)      any command naming RUN_MODE, scripts/hooks/ or .claude/settings
#
# Every denial logs one `policy_denied` event (scripts/log.sh): `tool=<name> rule=<id>`
# plus `at=<host/path or file>` — never a full command or a query string.

set -u
export LC_ALL=C
# A crash would exit 1, which Claude Code treats as "proceed" — turn it into a denial.
trap 'rc=$?; case $rc in (0|2) ;; (*) echo "policy: denied (hook-error): the policy hook failed (exit $rc)" >&2; exit 2;; esac' EXIT

DEF_ROOT="$(cd "${BASH_SOURCE[0]%/*}/../.." 2>/dev/null && pwd)"
SCRIPT_DIR="$DEF_ROOT/scripts"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
TOOL="?"; SESSION=""

deny() { # <rule> <where> <reason>
  printf 'policy: denied (%s): %s — docs/black-box.md → Enforcement layers\n' "$1" "$3" >&2
  local at="${2%%[?#]*}"; at="${at//[[:space:]]/}"; at="${at:0:200}"
  ( export LOG_RUN_ID="${LOG_RUN_ID:-$SESSION}"
    . "$SCRIPT_DIR/log.sh" && logev warn policy_denied "tool=$TOOL rule=$1${at:+ at=$at}" ) >/dev/null 2>&1
  exit 2
}

command -v jq >/dev/null 2>&1 || { echo "policy: denied (no-jq): the policy hook needs jq" >&2; exit 2; }
VARS="$(jq -r '
  def s: if . == null then "" elif type == "string" then . else tostring end | @sh;
  "TOOL=\(.tool_name | s) SESSION=\(.session_id | s) CWD=\(.cwd | s)",
  "CMD=\(.tool_input.command | s) FPATH=\((.tool_input.file_path // .tool_input.notebook_path) | s)",
  "GPATH=\(.tool_input.path | s) GPAT=\(.tool_input.pattern | s) GGLOB=\(.tool_input.glob | s)",
  "URL=\(.tool_input.url | s) QUERY=\(((.tool_input.query // "") + " " + ((.tool_input.allowed_domains // []) | join(" "))) | s)"' 2>/dev/null)" \
  || deny bad-input "" "the tool call could not be parsed"
eval "$VARS"
[ -n "$CWD" ] || CWD="$PWD"

. "$SCRIPT_DIR/lib/config.sh" 2>/dev/null || deny bad-install "" "scripts/lib/config.sh is missing"
. "$SCRIPT_DIR/lib/profile.sh" 2>/dev/null || deny bad-install "" "scripts/lib/profile.sh is missing"

# ------------------------------------------------------------------ context ----
# Host, owner and repository names compare case-insensitively (nocasematch is switched on
# for every check except the write allowlist, where it would only widen what is allowed).
TARGET="${QI_TARGET_REPO:-$(cfg target_repo)}"; GH_HOST=github.com; T="$TARGET"
slashes="${TARGET//[^\/]/}"
if [ "${#slashes}" = 2 ]; then GH_HOST="${TARGET%%/*}"; T="${TARGET#*/}"; fi
[ "$GH_HOST" = github.com ] && API_HOST=api.github.com || API_HOST="$GH_HOST"

PROFILE_LOADED=0; P_URLS=""; P_PKGS=""
load_profile() { # lazily: only a rule that needs the profile's boundary reads it
  [ "$PROFILE_LOADED" = 1 ] && return 0; PROFILE_LOADED=1
  local pd out; pd="$(profile_dir 2>/dev/null)" || return 0
  out="$(jq -r '(.boundary.urls // [] | map("u " + .)[]), (.boundary.packages // [] | map("p " + .)[])' "$pd/profile.json" 2>/dev/null)"
  P_URLS="$(printf '%s\n' "$out" | sed -n "s|^u ||p" | sed "s|{repo}|$T|g")"
  P_PKGS="$(printf '%s\n' "$out" | sed -n 's|^p ||p')"
}

iso2epoch() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }
SCHED=""
scheduled() { # a RUN_MODE written (content time) or touched (mtime) within lock_ttl_min
  [ -n "$SCHED" ] && { [ "$SCHED" = 1 ]; return; }
  SCHED=0
  local f="$WORK/env/RUN_MODE" ttl now t1 t2 kind iso
  [ -e "$f" ] || return 1
  ttl="$(cfg lock_ttl_min)"; case "$ttl" in (''|*[!0-9]*) ttl=180;; esac
  now="$(date -u +%s)"
  read -r kind iso _ < "$f" 2>/dev/null; t1="$(iso2epoch "${iso:-x}")"
  t2="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)"
  [ "$t2" -gt "$t1" ] 2>/dev/null && t1="$t2"
  [ $(( now - t1 )) -lt $(( ttl * 60 )) ] && SCHED=1
  [ "$SCHED" = 1 ]
}

# Lexical normalization into $N: ~, relative to cwd, . and .. collapsed (no symlinks).
norm() {
  local p="$1" seg; local -a st=()
  case "$p" in ("~") p="$HOME_DIR";; ("~/"*) p="$HOME_DIR/${p#\~/}";; esac
  case "$p" in (/*) ;; (*) p="$CWD/$p";; esac
  local IFS=/; set -f
  for seg in $p; do
    case "$seg" in (''|.) ;; (..) [ ${#st[@]} -gt 0 ] && unset "st[$(( ${#st[@]} - 1 ))]";; (*) st[${#st[@]}]="$seg";; esac
  done; set +f
  N=""; for seg in ${st[@]+"${st[@]}"}; do N="$N/$seg"; done
  N="${N:-/}"
}
norm "$WORK"; WORK="$N"
under() { case "$1" in ("$2"|"$2"/*) return 0;; esac; return 1; }
in_tmp_qi() { case "$1" in (/tmp/quality-inspector-*|/private/tmp/quality-inspector-*) return 0;; esac; return 1; }

# ------------------------------------------------------------- path rules ----
check_read_path() { # <normalized path or path/glob>
  local p="$1" e
  case "$p" in (*/node_modules/*)
    load_profile
    for e in $P_PKGS; do
      case "$p" in (*/node_modules/"$e"|*/node_modules/"$e"/*) deny product-package "$p" "files of the product's installed packages are off limits";; esac
    done;; esac
  if under "$p" "$WORK/env"; then case "$p" in (*/templates|*/templates/*) deny chart-template "$p" "deployment templates are off limits";; esac; fi
  case "$p" in (/tmp/quality-inspector-chart-*|/private/tmp/quality-inspector-chart-*) deny chart-template "$p" "the pulled chart is off limits";; esac
  if under "$p" "$WORK" || in_tmp_qi "$p"; then
    case "$p" in (*.map) deny source-map "$p" "source maps are off limits";; esac
  fi
  return 0
}

# --------------------------------------------------------------- URL rules ----
repo_is_target() { # <owner> <repo>
  [ -z "$T" ] && return 0
  [[ "$1/$2" == "$T" ]] && return 0
  case "$1$2" in (*'$'*|*'{'*|*'*'*) return 0;; esac
  return 1
}
RE_ISSUES='^issues(/[^/]+(/comments|/labels/[^/]+)?)?$'
rest_allowed() { # <path after owner/repo>
  local r="${1%%[?#]*}"; r="${r%/}"; r="${r#/}"
  case "/$r/" in (*/timeline/*|*/events/*) return 1;; esac
  [[ "$r" =~ $RE_ISSUES ]]
}
# Every `repos/<a>/<b>[/rest]` in a text addressed to the GitHub API.
RE_REPOS='repos/([^/[:space:]"'"'"'?#]+)/([^/[:space:]"'"'"'?#]+)(/[^[:space:]"'"'"'#]*)?'
check_repo_paths() { # <text>
  local s="$1" a b rest m
  while [[ "$s" =~ $RE_REPOS ]]; do
    m="${BASH_REMATCH[0]}"; a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
    s="${s#*"$m"}"
    # `repos/$T/issues/…` — one variable holding owner/repo
    case "$a" in (*'$'*|*'{'*) rest_allowed "$b$rest" && continue;; esac
    repo_is_target "$a" "$b" || continue
    rest_allowed "$rest" || deny gh-api-path "$API_HOST/repos/$a/$b$rest" "only the target's issues endpoints may be requested"
  done
  return 0
}
check_url() { # <host> <path> <url without scheme>
  local h="$1" p="$2" u
  h="${h##*@}"; h="${h%%:*}"
  case "$h" in (raw.githubusercontent.com) deny raw-host "$h$p" "raw.githubusercontent.com is off limits";; esac
  case "$h" in (codeload.github.com|codeload."$GH_HOST")
    [ -z "$T" ] && deny codeload "$h$p" "codeload is off limits without a configured target"
    case "$p" in (/"$T"|/"$T"/*) deny codeload "$h$p" "the target's archives are off limits";; esac;; esac
  if [[ "$h" == "$API_HOST" || "$h" == api.github.com ]]; then
    check_repo_paths "$p"
    case "$p" in (/search/code*|/search/commits*|/api/v3/search/code*|/api/v3/search/commits*)
      [ -z "$T" ] || case "$3" in (*"$T"*) deny gh-search "$h${p%%\?*}" "searching the target's code or commits is off limits";; esac;; esac
  fi
  if [[ "$h" == "$GH_HOST" ]] && [ -n "$T" ]; then
    case "$p" in (/"$T"|/"$T"/*|/"$T".git*|/"$T"\?*|/"$T"#*) deny repo-web "$h/$T" "the target's web pages and git remote are off limits";; esac
  fi
  case "${p%%[?#]*}" in (*.map) deny source-map "$h${p%%[?#]*}" "source maps are off limits";; esac
  load_profile
  for u in $P_URLS; do
    case "$3" in ("${u#*://}"*) deny profile-url "$h${p%%[?#]*}" "the profile lists this URL as off limits";; esac
  done
  return 0
}
# All URLs in a text: scheme URLs, plus bare and ssh mentions of the GitHub hosts.
RE_URL='(https?|git|ssh)://([^/[:space:]"'"'"'<>`)]+)(/[^[:space:]"'"'"'<>`)]*)?'
GH_HOSTS='raw\.githubusercontent\.com|codeload\.github\.com|api\.github\.com|github\.com'
[ "$GH_HOST" = github.com ] || GH_HOSTS="$GH_HOSTS|${GH_HOST//./\\.}"
RE_BARE='(^|[^a-z0-9.-])('"$GH_HOSTS"')([:/][^[:space:]"'"'"'<>`)]*)'
check_urls() { # <text>
  local s="$1" m path
  while [[ "$s" =~ $RE_URL ]]; do
    m="${BASH_REMATCH[0]}"; s="${s#*"$m"}"
    check_url "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${m#*://}"
  done
  s="$1"
  while [[ "$s" =~ $RE_BARE ]]; do
    m="${BASH_REMATCH[0]}"; s="${s#*"$m"}"
    path="${BASH_REMATCH[3]}"; path="/${path#[:/]}"
    check_url "${BASH_REMATCH[2]}" "$path" "${BASH_REMATCH[2]}$path"
  done
  return 0
}

# -------------------------------------------------------------- Bash rules ----
# The command is cut into simple commands at ; & | ( ) and newlines; each one's leading
# wrappers (sudo, env, xargs, VAR=value, bash -c "…", a /path/ prefix) are dropped and its
# words inspected. Word loops and short regexes only — no backtracking on the hot path.
RE_ENV_TPL='(^|[^a-z0-9_-])env/([^[:space:]"'"'"']*/)?templates([/[:space:]"'"'"']|$)'
RE_MAP='[a-z0-9_*-]\.map([[:space:]"'"'"'?#;|&)]|$)'
FETCHES=0
unq() { U="${1#[\"\']}"; U="${U%[\"\']}"; }

# Advance j past the word that closes a quote w[j] opens (j, w and n are the caller's):
# the words are split at blanks, so a quoted value can span several.
skip_quoted() {
  local d="${w[$j]//[^\"]/}" q='"'
  [ $(( ${#d} % 2 )) = 1 ] || { d="${w[$j]//[^\']/}"; q="'"; }
  [ $(( ${#d} % 2 )) = 1 ] || return 0
  while [ $((j+1)) -lt "$n" ]; do
    j=$((j+1)); d="${w[$j]//[^$q]/}"; [ $(( ${#d} % 2 )) = 1 ] && return 0
  done
}
# `gh api` from word <k> on (check_simple's w and n): GH_EP = the endpoint, the first word
# that is neither a flag nor a flag's value. True when the call writes: a method other than
# GET or HEAD, or a field or --input without a method.
gh_api_write() { # <k>
  local j="$1" m="" f=0
  GH_EP=""
  while [ "$j" -lt "$n" ]; do
    unq "${w[$j]}"
    case "$U" in
      (-X|--method) j=$((j+1)); unq "${w[$j]:-}"; m="$U";;
      (-X?*) m="${U#-X}";;
      (--method=*) m="${U#--method=}";;
      (-f|-F|--field|--raw-field|--input) f=1; j=$((j+1)); skip_quoted;;
      (-[fF]?*|--field=*|--raw-field=*|--input=*) f=1; skip_quoted;;
      (-H|--header|--hostname|-q|--jq|-t|--template|-p|--preview|--cache) j=$((j+1)); skip_quoted;;
      (-*) skip_quoted;;
      (*) [ -n "$GH_EP" ] || GH_EP="$U"; skip_quoted;;
    esac
    j=$((j+1))
  done
  case "$m" in (GET|HEAD) return 1;; ('') [ "$f" = 1 ];; (*) return 0;; esac
}
# An endpoint under the target's issues: repos/<T>/issues…, with or without a leading /,
# /api/v3 or scheme and host; an owner/repo given as a variable counts as <T>.
RE_ISSUES_EP='^/?(api/v3/)?repos/([^/]+)/([^/?#]+)/issues([/?#]|$)'
RE_ISSUES_EP_VAR='^/?(api/v3/)?repos/(\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}/]+\})/issues([/?#]|$)'
issues_endpoint() { # <endpoint>
  local e="$1"
  case "$e" in (http://*|https://*) e="${e#*://}"; e="/${e#*/}";; esac
  [[ "$e" =~ $RE_ISSUES_EP_VAR ]] && return 0
  [[ "$e" =~ $RE_ISSUES_EP ]] && repo_is_target "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

check_simple() { # <one simple command>
  local -a w; local i=0 n cmd sub x rest=" "
  read -r -a w <<<"$1" || true
  n=${#w[@]}
  while [ "$i" -lt "$n" ]; do
    unq "${w[$i]}"
    case "$U" in
      (sudo|env|xargs|exec|nohup|time|command|builtin|then|do|else|if|while|until|'!'|'$'|'{'|'}'|-*|[A-Za-z_]*=*) i=$((i+1));;
      (bash|sh|zsh|dash) unq "${w[$((i+1))]:-}"; case "$U" in (-c|-lc|-ec|-xc) i=$((i+2));; (*) break;; esac;;
      (*) break;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  unq "${w[$i]}"; cmd="${U##*/}"; i=$((i+1))
  if [ "$cmd" = k3s ]; then unq "${w[$i]:-}"; cmd="$U"; i=$((i+1)); fi
  for x in ${w[@]+"${w[@]:$i}"}; do unq "$x"; rest="$rest$U "; done
  case "$cmd" in
    (git)
      FETCHES=1
      while [ "$i" -lt "$n" ]; do unq "${w[$i]}"
        case "$U" in (-C|-c|--git-dir|--work-tree|--namespace) i=$((i+2));; (-*) i=$((i+1));; (*) break;; esac
      done
      unq "${w[$i]:-}"; sub="$U"
      [ "$sub" = clean ] && deny git-clean "" "git clean is never run (it would wipe \$HOME)"
      case "$sub" in (commit|push) scheduled && deny scheduled-git "" "a scheduled run never commits or pushes";; esac;;
    (kubectl)
      case "$rest" in (*" exec "*|*" cp "*|*" debug "*|*" attach "*) deny container-fs "" "container filesystems are off limits; use the profile's read-only diagnosis";; esac;;
    (ctr|crictl) deny container-fs "" "image filesystems are off limits";;
    (docker|podman|nerdctl)
      case "$rest" in (*" exec "*|*" cp "*|*" export "*|*" save "*|*" run "*|*" create "*) deny container-fs "" "container and image filesystems are off limits";; esac;;
    (helm)
      case "$rest" in (*" pull "*|*" fetch "*|*" template "*|*" get manifest "*|*" get all "*|*" show values "*|*" show all "*) deny chart-template "" "chart templates and default values are off limits";; esac;;
    (gh)
      unq "${w[$i]:-}"; sub="$U"
      case "$sub" in
        (api)
          case "$rest" in (*" graphql "*|*" /graphql "*) deny gh-graphql "$API_HOST/graphql" "GraphQL is off limits; use the issues REST endpoints";; esac
          check_repo_paths "$rest"
          if [ -n "$T" ]; then case "$rest" in (*search/code*"$T"*|*search/commits*"$T"*) deny gh-search "$API_HOST/search" "searching the target's code or commits is off limits";; esac; fi
          gh_api_write "$((i+1))" && ! issues_endpoint "$GH_EP" && scheduled \
            && deny scheduled-git "" "a scheduled run writes only the target's issue comments and labels";;
        (pr) case "$rest" in (" pr create "*|" pr merge "*) scheduled && deny scheduled-git "" "a scheduled run never opens or merges a PR";; esac;;
      esac
      case "$sub" in (pr|repo|release|run|workflow|browse|gist|search|cache|attestation|codespace|ruleset|project)
        if [ -n "$T" ]; then case "$rest" in (*"$T"*) deny gh-cli "$GH_HOST/$T" "only the target's issues may be read";; esac; fi;; esac;;
    (curl|wget|http|https|xh|aria2c|lynx|w3m) FETCHES=1;;
  esac
  return 0
}

# The command without the bodies of literal heredocs (<<'EOF', <<"EOF", <<\EOF) — text being
# written, not run — unless the heredoc feeds a shell.
RE_HEREDOC="<<-?[[:space:]]*('([A-Za-z_][A-Za-z0-9_]*)'|\"([A-Za-z_][A-Za-z0-9_]*)\"|\\\\([A-Za-z_][A-Za-z0-9_]*))"
RE_SHELL_IN='(^|[^a-z0-9_-])(bash|sh|zsh|dash|ksh)([[:space:]]+-[a-z]+)*[[:space:]]*<<'
strip_heredocs() {
  local line t d="" out="" tab=$'\t'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$d" ]; then t="${line#"${line%%[!$tab]*}"}"; [ "$t" = "$d" ] && d=""; continue; fi
    out="$out$line"$'\n'
    if [[ "$line" =~ $RE_HEREDOC ]]; then
      t="${BASH_REMATCH[2]:-}${BASH_REMATCH[3]:-}${BASH_REMATCH[4]:-}"
      [[ "$line" =~ $RE_SHELL_IN ]] || d="$t"
    fi
  done <<<"$1"
  X="$out"
}

check_bash() {
  local seg e
  case "$CMD" in (*RUN_MODE*|*scripts/hooks/*|*.claude/settings*)
    scheduled && deny policy-tamper "" "a scheduled run never touches the policy or its run marker";; esac
  case "$CMD" in (*'<<'*) strip_heredocs "$CMD"; CMD="$X";; esac
  while IFS= read -r seg; do check_simple "$seg"; done <<<"$(printf '%s\n' "$CMD" | tr ';&|()' '\n\n\n\n\n')"
  case "$CMD" in (*node_modules/*)
    load_profile
    for e in $P_PKGS; do
      case "$CMD" in (*node_modules/"$e"/*|*node_modules/"$e"|*node_modules/"$e"[\ \"\']*)
        deny product-package "node_modules/$e" "files of the product's installed packages are off limits";; esac
    done;; esac
  case "$CMD" in (*quality-inspector-chart-*) deny chart-template "/tmp/quality-inspector-chart-*" "the pulled chart is off limits";; esac
  case "$CMD" in (*env/*templates*) [[ "$CMD" =~ $RE_ENV_TPL ]] && deny chart-template "work/env/…/templates" "deployment templates are off limits";; esac
  case "$CMD" in (*.map*) [[ "$CMD" =~ $RE_MAP ]] && deny source-map "*.map" "source maps are off limits";; esac
  [ "$FETCHES" = 1 ] && check_urls "$CMD"
  return 0
}

# ------------------------------------------------------------- write rules ----
def_allowlisted() { # <normalized path> — a path the definition's .gitignore re-includes
  local e
  while IFS= read -r e; do
    case "$e" in ('!/'*) ;; (*) continue;; esac
    e="${e#!/}"
    case "$e" in (*/) under "$1" "$DEF_ROOT/${e%/}" && return 0;; (*) [ "$1" = "$DEF_ROOT/$e" ] && return 0;; esac
  done < "$DEF_ROOT/.gitignore"
  return 1
}
check_write() {
  norm "$FPATH"; local p="$N"
  [ "$p" = "$WORK/env/RUN_MODE" ] && deny run-mode "$p" "only the schedule's Precheck writes the run marker"
  if under "$p" "$WORK"; then
    [ "$p" = "$WORK/CONFIG.md" ] && scheduled && deny scheduled-def "$p" "a scheduled run never changes the configuration"
    return 0
  fi
  in_tmp_qi "$p" && return 0
  if [ -f "$DEF_ROOT/.gitignore" ] && def_allowlisted "$p"; then
    scheduled && deny scheduled-def "$p" "a scheduled run never edits the definition"
    return 0
  fi
  deny write-outside "$p" "writes go to work/ or /tmp/quality-inspector-* only"
}

# ------------------------------------------------------------------ dispatch ----
case "$TOOL" in (Write|Edit|MultiEdit|NotebookEdit) ;; (*) shopt -s nocasematch;; esac
case "$TOOL" in
  Bash) check_bash ;;
  Read) [ -n "$FPATH" ] && { norm "$FPATH"; check_read_path "$N"; } ;;
  Glob) norm "${GPATH:-.}"; b="$N"; check_read_path "$b"; [ -n "$GPAT" ] && { norm "$b/$GPAT"; check_read_path "$N"; } ;;
  Grep) norm "${GPATH:-.}"; b="$N"; check_read_path "$b"; [ -n "$GGLOB" ] && { norm "$b/$GGLOB"; check_read_path "$N"; } ;;
  Write|Edit|MultiEdit|NotebookEdit) check_write ;;
  WebFetch) check_urls "$URL" ;;
  WebSearch) check_urls "$QUERY" ;;
esac
exit 0
