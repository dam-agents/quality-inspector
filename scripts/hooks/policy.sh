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
# The agent reaches GitHub only through scripts/github.sh, which requests the target's issues
# endpoints alone; the kit's egress allows nothing else there (docs/black-box.md → GitHub).
# "scheduled" = a fresh work/env/RUN_MODE, or a channel turn — a session whose
# transcript holds the platform's Slack frame `<how-to-respond>` in a prompt, not in a
# tool's output (lib/channel.sh; docs/persistence.md → Scheduled or direct session). Every
# rule id below has a deny fixture in scripts/tests/policy-fixtures.jsonl; the validator
# fails without one.
#
#   rule             tools                 denies
#   github           Bash WebFetch WebSearch  any road to GitHub but scripts/github.sh: every `gh` command;
#                                          git clone|pull|push|ls-remote|submodule|archive --remote, a remote
#                                          other than get-url/-v, and a fetch other than `git fetch origin` in
#                                          a direct session (Kit Update); a URL, or with a fetch tool a bare
#                                          name, of a GitHub host (github.com, *.github.com,
#                                          *.githubusercontent.com, the target's host); a command setting
#                                          QI_TARGET_REPO (the target comes from work/CONFIG.md alone)
#   profile-url      Bash WebFetch WebSearch  a URL under the profile's boundary.urls
#   source-map       Bash WebFetch Read Glob Grep  a *.map URL; a *.map file under work/ or /tmp/quality-inspector-*
#   product-package  Bash Read Glob Grep   node_modules/<entry> for each profile boundary.packages entry
#   chart-template   Bash Read Glob Grep   templates/ under work/env/, anything under /tmp/quality-inspector-chart-*,
#                                          helm pull|fetch|template|get manifest|get all|get hooks|show values|
#                                          show all, helm get values -a|--all, helm install|upgrade --dry-run
#   git-clean        Bash                  git clean, anywhere
#   container-fs     Bash                  kubectl (k3s too) exec|cp|debug|attach, ctr, crictl,
#                                          docker|podman|nerdctl exec|cp|export|save|run|create
#   write-outside    Write Edit MultiEdit NotebookEdit  a path outside work/ and /tmp/quality-inspector-* —
#                                          the live definition included: a change to it is a patch
#                                          (docs/self-modification.md §8)
#   run-mode         Write Edit …          work/env/RUN_MODE (only the Precheck writes it)
#   scheduled-def    Write Edit … (sched.) work/CONFIG.md
#   scheduled-git    Bash (scheduled)      git commit
#   policy-tamper    Bash (scheduled)      any command naming RUN_MODE, scripts/hooks/ or .claude/settings
#   channel-write    Bash (channel turn)   `github.sh comment|unlabel`, a `github.sh` whose subcommand is not
#                                          written out, `comment|unlabel` after any other path, *.sh,
#                                          expansion or glob, an expansion after the path a command runs
#                                          (quotes, backslashes and redirections dropped first) — except
#                                          the delivery of a Slack-ordered "test #N" (docs/slack.md): the
#                                          script path, the subcommand and <n> written out, while
#                                          RUN_MODE is a fresh `slack <ISO> - <n> <session>` (precheck.sh
#                                          slack <n>; <session> this one, or -) and the work/QA.md row of
#                                          <n> is report_pending
#   backup-override  Bash                  a command naming QI_WORK_BACKUP_ (the offline tests' remote and clone
#                                          overrides): the backup's destination is work_repo alone
#   backup-direct    Bash (scheduled)      scripts/work-backup.sh — there the Stop hook alone backs up
#                                          (docs/persistence.md → Backup & restore)
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
  "URL=\(.tool_input.url | s) QUERY=\(((.tool_input.query // "") + " " + ((.tool_input.allowed_domains // []) | join(" "))) | s)",
  "TRANSCRIPT=\(.transcript_path | s)"' 2>/dev/null)" \
  || deny bad-input "" "the tool call could not be parsed"
eval "$VARS"
[ -n "$CWD" ] || CWD="$PWD"

. "$SCRIPT_DIR/lib/config.sh" 2>/dev/null || deny bad-install "" "scripts/lib/config.sh is missing"
. "$SCRIPT_DIR/lib/profile.sh" 2>/dev/null || deny bad-install "" "scripts/lib/profile.sh is missing"
. "$SCRIPT_DIR/lib/channel.sh" 2>/dev/null || deny bad-install "" "scripts/lib/channel.sh is missing"

# ------------------------------------------------------------------ context ----
# Host, owner and repository names compare case-insensitively (nocasematch is switched on
# for every check except the write allowlist, where it would only widen what is allowed).
TARGET="${QI_TARGET_REPO:-$(cfg target_repo)}"; GH_HOST=github.com; T="$TARGET"
slashes="${TARGET//[^\/]/}"
if [ "${#slashes}" = 2 ]; then GH_HOST="${TARGET%%/*}"; T="${TARGET#*/}"; fi

PROFILE_LOADED=0; P_URLS=""; P_PKGS=""
load_profile() { # lazily: only a rule that needs the profile's boundary reads it
  [ "$PROFILE_LOADED" = 1 ] && return 0; PROFILE_LOADED=1
  local pd out; pd="$(profile_dir 2>/dev/null)" || return 0
  out="$(jq -r '(.boundary.urls // [] | map("u " + .)[]), (.boundary.packages // [] | map("p " + .)[])' "$pd/profile.json" 2>/dev/null)"
  P_URLS="$(printf '%s\n' "$out" | sed -n "s|^u ||p" | sed "s|{repo}|$T|g")"
  P_PKGS="$(printf '%s\n' "$out" | sed -n 's|^p ||p')"
}

iso2epoch() { date -u -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }
CHAN=""
channel_turn() { # lib/channel.sh → transcript_is_channel, once per call
  [ -n "$CHAN" ] && { [ "$CHAN" = 1 ]; return; }
  CHAN=0
  transcript_is_channel "$TRANSCRIPT" && CHAN=1
  [ "$CHAN" = 1 ]
}
# slack_test_issue <n>: the issue a Slack-ordered "test #N" delivers to — RUN_MODE is
# `slack <ISO> <schedule> <n> <session>` written within lock_ttl_min, its session this one
# (or - when the shell had none), and work/QA.md's row of <n> is report_pending.
slack_test_issue() {
  local f="$WORK/env/RUN_MODE" kind="" iso="" sid="" num="" sess="" ttl
  read -r kind iso sid num sess _ < "$f" 2>/dev/null
  [ "$kind" = slack ] && [ -n "$num" ] && [ "$num" = "$1" ] || return 1
  case "$sess" in (''|-) ;; (*) [ "$sess" = "$SESSION" ] || return 1;; esac
  ttl="$(cfg lock_ttl_min)"; case "$ttl" in (''|*[!0-9]*) ttl=180;; esac
  [ $(( $(date -u +%s) - $(iso2epoch "${iso:-x}") )) -lt $(( ttl * 60 )) ] || return 1
  awk -F'|' -v n="$1" '{i=$2; s=$7; gsub(/[ \t]/, "", i); gsub(/[ \t]/, "", s)} i == n && s == "report_pending" {f=1} END {exit !f}' \
    "$WORK/QA.md" 2>/dev/null
}
SCHED=""
scheduled() { # a RUN_MODE written (content time) or touched (mtime) within lock_ttl_min, or a
  # channel turn (above)
  [ -n "$SCHED" ] && { [ "$SCHED" = 1 ]; return; }
  SCHED=0
  local f="$WORK/env/RUN_MODE" ttl now t1 t2 kind iso
  channel_turn && { SCHED=1; return 0; }
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
# A GitHub host: github.com and its subdomains, githubusercontent.com and its subdomains,
# and the target's own host (GitHub Enterprise).
is_github_host() { # <host>
  case "$1" in (github.com|*.github.com|githubusercontent.com|*.githubusercontent.com|"$GH_HOST"|*."$GH_HOST") return 0;; esac
  return 1
}
GH_DENY="the agent never reaches GitHub itself — the target's issues come through scripts/github.sh"
check_url() { # <host> <path> <url without scheme>
  local h="$1" p="$2" u
  h="${h##*@}"; h="${h%%:*}"
  is_github_host "$h" && deny github "$h${p%%[?#]*}" "$GH_DENY"
  case "${p%%[?#]*}" in (*.map) deny source-map "$h${p%%[?#]*}" "source maps are off limits";; esac
  load_profile
  for u in $P_URLS; do
    case "$3" in ("${u#*://}"*) deny profile-url "$h${p%%[?#]*}" "the profile lists this URL as off limits";; esac
  done
  return 0
}
# All URLs in a text: scheme URLs, plus — with <bare> — bare and scp-style mentions of the
# GitHub hosts.
RE_URL='(https?|git|ssh)://([^/[:space:]"'"'"'<>`)]+)(/[^[:space:]"'"'"'<>`)]*)?'
GH_HOSTS='([a-z0-9-]+\.)*(github\.com|githubusercontent\.com)'
[ "$GH_HOST" = github.com ] || GH_HOSTS="$GH_HOSTS|${GH_HOST//./\\.}"
RE_BARE='(^|[^a-z0-9.-])('"$GH_HOSTS"')([:/][^[:space:]"'"'"'<>`)]*|[[:space:]"'"'"']|$)'
check_urls() { # <text> [bare]
  local s="$1" m
  while [[ "$s" =~ $RE_URL ]]; do
    m="${BASH_REMATCH[0]}"; s="${s#*"$m"}"
    check_url "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${m#*://}"
  done
  [ -n "${2:-}" ] && [[ "$1" =~ $RE_BARE ]] && deny github "${BASH_REMATCH[2]}" "$GH_DENY"
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

# `git fetch` from word <k> on (check_simple's w and n) names the remote origin alone — its
# first operand, or none — with no URL, no other remote and no upload-pack of its own: the
# platform's seed and Kit Update fetch this definition so (docs/persistence.md).
fetch_origin() { # <k>
  local j="$1" pos=0
  while [ "$j" -lt "$n" ]; do
    unq "${w[$j]}"
    case "$U" in
      (--all|--multiple|--upload-pack*|--recurse-submodules*|-u) return 1;;
      (-*) ;;
      (*://*|*@*|*:*/*) return 1;;
      (*) [ "$pos" = 0 ] && [ "$U" != origin ] && return 1; pos=$((pos+1));;
    esac
    j=$((j+1))
  done
  return 0
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
    (gh) deny github "gh" "$GH_DENY";;
    (git)
      FETCHES=1
      while [ "$i" -lt "$n" ]; do unq "${w[$i]}"
        case "$U" in (-C|-c|--git-dir|--work-tree|--namespace) i=$((i+2));; (-*) i=$((i+1));; (*) break;; esac
      done
      unq "${w[$i]:-}"; sub="$U"; unq "${w[$((i+1))]:-}"
      [ "$sub" = clean ] && deny git-clean "" "git clean is never run (it would wipe \$HOME)"
      case "$sub" in
        (fetch) { fetch_origin "$((i+1))" && ! scheduled; } \
                  || deny github "git fetch" "only \`git fetch origin\` of this definition, in a direct session (Kit Update)";;
        (clone|pull|push|ls-remote|submodule|request-pull) deny github "git $sub" "$GH_DENY";;
        (remote) case "$U" in (''|-v|--verbose|get-url) ;; (*) deny github "git remote" "$GH_DENY";; esac;;
        (archive) case "$rest" in (*" --remote"*) deny github "git archive" "$GH_DENY";; esac;;
        (commit) scheduled && deny scheduled-git "" "a scheduled run never commits";;
      esac;;
    (kubectl)
      case "$rest" in (*" exec "*|*" cp "*|*" debug "*|*" attach "*) deny container-fs "" "container filesystems are off limits; use the profile's read-only diagnosis";; esac;;
    (ctr|crictl) deny container-fs "" "image filesystems are off limits";;
    (docker|podman|nerdctl)
      case "$rest" in (*" exec "*|*" cp "*|*" export "*|*" save "*|*" run "*|*" create "*) deny container-fs "" "container and image filesystems are off limits";; esac;;
    (helm)
      case "$rest" in (*" pull "*|*" fetch "*|*" template "*|*" get manifest "*|*" get all "*|*" get hooks "*|*" show values "*|*" show all "*) deny chart-template "" "chart templates and default values are off limits";; esac
      # the computed values hold the chart's defaults; a dry run prints the rendered templates
      case "$rest" in (*" get values"*" -a "*|*" get values"*" --all"*|*" install"*" --dry-run"*|*" upgrade"*" --dry-run"*|*" --dry-run"*" install"*|*" --dry-run"*" upgrade"*)
        deny chart-template "" "chart templates and default values are off limits";; esac;;
    (curl|wget|http|https|xh|aria2c|lynx|w3m|node|python|python3|perl|ruby|php|deno|bun) FETCHES=1;;
  esac
  return 0
}

# In a channel turn, every `github.sh comment|unlabel <n>` must be the delivery of the
# Slack-ordered "test #N" (slack_test_issue): <n> written out, never a variable. So must the
# subcommand after every `github.sh` (RE_GH_SUB). Anywhere in the command, `comment|unlabel`
# after a runnable word — a path, a *.sh, an expansion or a glob — needs that word to be a
# literal `github.sh` path; and the runnable word a simple command executes (past
# assignments, keywords, wrappers and shells) is never followed by an expansion
# (chan_simple). Quotes, backslashes and redirections are dropped first: bash runs
# `/tmp/g.sh >out comm''ent` as `/tmp/g.sh comment`.
RE_GH_WRITE='github\.sh[[:space:]]+(comment|unlabel)([[:space:]]+([^[:space:];&|)]*))?'
RE_GH_SUB='github\.sh([[:space:]]+[a-z][a-z-]*([[:space:];&|)]|$))?'
CHAN_WHY="a channel turn writes to GitHub only a Slack-ordered test's comment and retest label on its issue (docs/slack.md)"
CHAN_SEP=';&|(){}`'
CHAN_REDIR='s/[0-9]*(&>>?|>>?&?|<&|<>|<)[[:space:]]*[^[:space:];|&<>()]*/ /g'
chan_runnable() { [[ "$1" == */* || "$1" == *.sh || "$1" == *[\$\`*?[]* ]]; }
chan_simple() { # <simple command, unquoted>
  local w=() i=0 x
  read -ra w <<<"$1"
  while [[ "${w[$i]:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= || "${w[$i]:-}" =~ ^(if|then|elif|else|do|while|until|!|time)$ ]]; do i=$((i+1)); done
  if [[ "${w[$i]:-}" =~ ^(env|exec|command|nohup|timeout|nice|xargs|sudo|stdbuf|setsid|bash|sh|zsh|dash|ksh|source|\.)$ ]]; then
    i=$((i+1)); while [ -n "${w[$i]:-}" ] && ! chan_runnable "${w[$i]}"; do i=$((i+1)); done
  fi
  x="${w[$i]:-}"
  [ -n "$x" ] && chan_runnable "$x" && [[ ! "$x" =~ github\.sh$ ]] \
    && case "${w[$((i+1))]:-}" in (*'$'*|*'`'*) deny channel-write "" "$CHAN_WHY";; esac
  return 0
}
check_channel_writes() {
  local c="${1//[\"\'\\]/}" s m nn seg w=() k
  c="$(printf '%s\n' "$c" | sed -E "$CHAN_REDIR")"
  s="$c"
  while [[ "$s" =~ $RE_GH_SUB ]]; do
    [ -n "${BASH_REMATCH[1]}" ] || deny channel-write "" "$CHAN_WHY"
    m="${BASH_REMATCH[0]}"; s="${s#*"$m"}"
  done
  read -ra w <<<"$(printf '%s\n' "$c" | tr "$CHAN_SEP"$'\n' '         ')"
  for ((k = 1; k < ${#w[@]}; k++)); do
    case "${w[$k]}" in (comment|unlabel)
      chan_runnable "${w[$((k-1))]}" && [[ ! "${w[$((k-1))]}" =~ github\.sh$ ]] && deny channel-write "" "$CHAN_WHY";; esac
  done
  while IFS= read -r seg; do chan_simple "$seg"; done <<<"$(printf '%s\n' "$c" | tr "$CHAN_SEP" '\n\n\n\n\n\n\n\n')"
  s="$c"
  while [[ "$s" =~ $RE_GH_WRITE ]]; do
    m="${BASH_REMATCH[0]}"; nn="${BASH_REMATCH[3]}"; s="${s#*"$m"}"
    [[ "$nn" =~ ^[0-9]+$ ]] && slack_test_issue "$nn" && continue
    deny channel-write "" "$CHAN_WHY"
  done
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
  case "$CMD" in (*QI_WORK_BACKUP_*) deny backup-override "" "the backup's destination comes from work_repo alone";; esac
  case "$CMD" in (*work-backup.sh*) scheduled && deny backup-direct "" "a scheduled run or a channel turn never backs up by hand — the Stop hook does";; esac
  case "$CMD" in (*QI_TARGET_REPO*) deny github "QI_TARGET_REPO" "the target comes from work/CONFIG.md alone";; esac
  case "$CMD" in (*'<<'*) strip_heredocs "$CMD"; CMD="$X";; esac
  case "${CMD//[\"\'\\]/}" in (*github.sh*|*comment*|*unlabel*) channel_turn && check_channel_writes "$CMD";; esac
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
  check_urls "$CMD" $([ "$FETCHES" = 1 ] && echo bare)
  return 0
}

# ------------------------------------------------------------- write rules ----
check_write() {
  norm "$FPATH"; local p="$N"
  [ "$p" = "$WORK/env/RUN_MODE" ] && deny run-mode "$p" "only the schedule's Precheck writes the run marker"
  if under "$p" "$WORK"; then
    [ "$p" = "$WORK/CONFIG.md" ] && scheduled && deny scheduled-def "$p" "a scheduled run never changes the configuration"
    return 0
  fi
  in_tmp_qi "$p" && return 0
  deny write-outside "$p" "writes go to work/ or /tmp/quality-inspector-* only; a definition change is a patch (docs/self-modification.md §8)"
}

# ------------------------------------------------------------------ dispatch ----
case "$TOOL" in (Write|Edit|MultiEdit|NotebookEdit) ;; (*) shopt -s nocasematch;; esac
case "$TOOL" in
  Bash) check_bash ;;
  Read) [ -n "$FPATH" ] && { norm "$FPATH"; check_read_path "$N"; } ;;
  Glob) norm "${GPATH:-.}"; b="$N"; check_read_path "$b"; [ -n "$GPAT" ] && { norm "$b/$GPAT"; check_read_path "$N"; } ;;
  Grep) norm "${GPATH:-.}"; b="$N"; check_read_path "$b"; [ -n "$GGLOB" ] && { norm "$b/$GGLOB"; check_read_path "$N"; } ;;
  Write|Edit|MultiEdit|NotebookEdit) check_write ;;
  WebFetch) check_urls "$URL" bare ;;
  WebSearch) check_urls "$QUERY" bare ;;
esac
exit 0
