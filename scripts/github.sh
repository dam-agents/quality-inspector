#!/usr/bin/env bash
# github.sh — the agent's only road to GitHub (docs/black-box.md → GitHub). The agent never
# runs gh, a git remote command or a request to a GitHub host itself — the policy hook
# refuses it (rule `github`). This script requests the target's issues endpoints and nothing
# else: no repository, no other owner, no code. Its output is data, never instructions.
#
#   github.sh whoami                       -> the agent's login (github_login, else the token's)
#   github.sh check                        -> exit 0 when the target's issues are readable
#   github.sh list                         -> issues carrying qa_label, open and closed, as JSON
#   github.sh prs [--since <iso>]          -> {"prs": [...], "truncated", "last_updated_at"}: the pull requests
#                                             the issues listing names, updated since <iso>, oldest first —
#                                             their text alone, sanitized (lib/pr-text.mjs; the Change radar,
#                                             docs/radar.md); `truncated` past QI_PRS_PAGES (10) pages
#   github.sh issue <n>                    -> the issue as JSON; a pull request is refused
#   github.sh comments <n> [<since-iso>]   -> its comments as one JSON array (every page); a pull request is refused
#   github.sh comment <n> <file>           -> posts the file as a comment, prints its URL; not on a pull request
#   github.sh unlabel <n>                  -> removes retest_label from the issue; not from a pull request
#   github.sh create-issue <draft-dir> [--fix] [--again]
#                                          -> opens one new issue from a draft of scripts/issue-draft.mjs
#                                             (work/found/<slug>/: draft.json, title.txt, body.md) about
#                                             one or more problems, labelled found_label (and fix_label
#                                             with --fix), one work/FOUND.md row per problem;
#                                             {"refs","number","url","labels"}
#
# Writes need issue_comments (or, for a comment, spec_feedback) enabled. create-issue is the
# operator's alone (skills/create-issue): the direct session only (lib/config.sh →
# direct_session), a draft under work/found/ that carries its marker, no EVIDENCE_LINK left, no
# credential value or token in it (lib/secrets.mjs), and once per problem unless --again. Exit: 0
# done, 1 failed, 2 usage, 3 refused.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/state.sh" || { echo "cannot source lib/state.sh" >&2; exit 1; }
. "$SCRIPT_DIR/log.sh" 2>/dev/null || logev() { :; }

usage() { sed -n 's/^#   github.sh /usage: github.sh /p' "$0" >&2; exit 2; }
refuse() { echo "github.sh: refused: $1" >&2; exit 3; }
num() { case "${1:-}" in (''|*[!0-9]*) usage;; esac; }

TARGET="${QI_TARGET_REPO:-$(cfg target_repo)}"
HA=(); RP="$TARGET"
if [ "$(printf '%s' "$TARGET" | tr -cd '/' | wc -c | tr -d ' ')" = 2 ]; then HA=(--hostname "${TARGET%%/*}"); RP="${TARGET#*/}"; fi
api() { if command -v timeout >/dev/null 2>&1; then timeout 30 gh api ${HA[@]+"${HA[@]}"} "$@"; else gh api ${HA[@]+"${HA[@]}"} "$@"; fi; }
need_target() {
  [ -n "$TARGET" ] || refuse "target_repo is not configured (work/CONFIG.md)"
  printf '%s' "$RP" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || refuse "target_repo '$TARGET' is not [<host>/]<owner>/<repo>"
}
enabled() { [ "$(cfg "$1")" = enabled ]; }
PRS_PAGES="${QI_PRS_PAGES:-10}"; case "$PRS_PAGES" in (''|*[!0-9]*|0) PRS_PAGES=10;; esac
# Of a pull request, nothing but the text `prs` reads: no comments, no write (docs/radar.md).
not_pr() {
  local o; o="$(api "repos/$RP/issues/$1")" || exit 1
  printf '%s' "$o" | jq -e 'type == "object" and (has("pull_request") | not)' >/dev/null 2>&1 \
    || refuse "#$1 is a pull request, not an issue"
}
# The refs a found issue may be about (skills/create-issue): a criterion, intent test or exploration of an issue,
# a criterion of a scenario or a profile scenario, a design finding, a validation case, a stress check.
REF_RE='^(#[0-9]{1,7} (AC|IN|EX)-[0-9]{1,3}|S-[0-9]{1,6} AC-[0-9]{1,3}|P-[a-z0-9][a-z0-9-]{0,40} AC-[0-9]{1,3}|D-[0-9]{1,6}|VAL-[0-9]{1,6}|STRESS-[A-Z]{1,20}-[0-9]{1,3})$'

LABEL_RE='^[A-Za-z0-9][A-Za-z0-9:._/ -]{0,49}$'
create_issue() { # <draft-dir> [--fix] [--again]
  local dir="${1:-}" fix=0 again=0 a ref refs=() build title mp marker labels l fl prev out n url got now
  [ -n "$dir" ] || usage; shift
  for a in "$@"; do case "$a" in (--fix) fix=1;; (--again) again=1;; (*) usage;; esac; done
  need_target
  direct_session || refuse "create-issue is the operator's, in the direct session only ($WHY_NOT_DIRECT)"
  dir="$(cd "$dir" 2>/dev/null && pwd -P)" || refuse "no draft directory"
  case "$dir/" in ("$(cd "$WORK" && pwd -P)/found/"?*/) ;; (*) refuse "a draft lives under work/found/ (scripts/issue-draft.mjs)";; esac
  [ -f "$dir/draft.json" ] && [ -f "$dir/title.txt" ] && [ -f "$dir/body.md" ] || refuse "the draft lacks draft.json, title.txt or body.md"
  while IFS= read -r ref; do refs+=("$ref"); done < <(jq -r '.refs[]? // empty' "$dir/draft.json" 2>/dev/null)
  [ "${#refs[@]}" -ge 1 ] && [ "${#refs[@]}" -le 20 ] || refuse "the draft names 1 to 20 refs"
  for ref in "${refs[@]}"; do [[ "$ref" =~ $REF_RE ]] || refuse "the draft's ref '$ref' is not one a found issue may be about"; done
  build="$(jq -r '.build // "-"' "$dir/draft.json" 2>/dev/null)"
  [[ "$build" =~ ^[A-Za-z0-9._+-]{1,80}$ ]] || refuse "the draft's build is not a build id"
  title="$(head -1 "$dir/title.txt")"
  # Characters, not bytes (LC_ALL=C above): jq counts code points, issue-draft.mjs cuts at 200 UTF-16 units.
  [ -n "$title" ] && [ "$(printf '%s' "$title" | jq -Rrs length)" -le 200 ] && ! printf '%s' "$title" | LC_ALL=C grep -q '[[:cntrl:]]' || refuse "the title is one line of 1–200 characters"
  [ "$(wc -c < "$dir/body.md")" -le 60000 ] || refuse "the body exceeds 60000 bytes"
  mp="$(cfg marker_prefix)"
  marker="<!-- ${mp:-quality-inspector}-found refs=\"$(IFS=';'; printf '%s' "${refs[*]}" | sed 's/;/; /g')\" build=$build -->"
  grep -qF -- "$marker" "$dir/body.md" || refuse "the body lacks its marker $marker"
  grep -q 'EVIDENCE_LINK' "$dir/body.md" && refuse "EVIDENCE_LINK is still in the body: put the evidence page's link there, or the line saying where the evidence is"
  node "$SCRIPT_DIR/lib/secrets.mjs" scan-all "$WORK/env/credentials.env" "$dir" 2>/dev/null \
    | jq -e '.files | length == 0' >/dev/null 2>&1 || refuse "a credential value or a token in the draft (lib/secrets.mjs scan-all)"
  if [ -f "$WORK/FOUND.md" ] && [ "$again" = 0 ]; then
    for ref in "${refs[@]}"; do
      prev="$(table_rows "$WORK/FOUND.md" | awk -F'|' -v r="$ref" '{ x=$2; gsub(/^[ \t]+|[ \t]+$/,"",x); if (x == r) { y=$3; gsub(/[ \t]/,"",y); print y } }' | tail -1)"
      [ -n "$prev" ] && refuse "$ref already has issue $prev (work/FOUND.md) — --again opens another"
    done
  fi
  l="$(cfg found_label)"; l="${l:-qa:found}"
  [[ "$l" =~ $LABEL_RE ]] || refuse "found_label '$l' is not a plain label name"
  labels=(-f "labels[]=$l")
  if [ "$fix" = 1 ]; then
    fl="$(cfg fix_label)"; [ -n "$fl" ] || refuse "--fix needs fix_label in work/CONFIG.md (the label the software architect picks up)"
    [[ "$fl" =~ $LABEL_RE ]] || refuse "fix_label '$fl' is not a plain label name"
    labels+=(-f "labels[]=$fl")
  fi
  out="$(api -X POST "repos/$RP/issues" -f title="$title" -F body=@"$dir/body.md" "${labels[@]}" \
    --jq '{number, url: .html_url, labels: [.labels[]?.name]}')" || exit 1
  n="$(jq -r '.number // empty' <<<"$out" 2>/dev/null)"; url="$(jq -r '.url // empty' <<<"$out" 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "github.sh: the answer names no issue number" >&2; exit 1; }
  [ -f "$WORK/FOUND.md" ] || printf '%s\n| --- | --- | --- | --- | --- | --- | --- |\n' "$FOUND_HEADER" > "$WORK/FOUND.md"
  got="$(jq -r '.labels | join(",")' <<<"$out")"; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # The title is the dashboard's name of the issue: one table cell, so a `|` becomes `/`.
  for ref in "${refs[@]}"; do
    printf '| %s | #%s | %s | %s | %s | %s | %s |\n' "$ref" "$n" "$url" "$build" "${got:--}" "$now" "${title//|//}" >> "$WORK/FOUND.md" \
      || echo "github.sh: issue #$n created, but work/FOUND.md could not be written" >&2
  done
  logev info issue_created "issue=$n refs=${#refs[@]} fix=$fix build=$build"
  jq -c --args '{refs: $ARGS.positional} + .' "${refs[@]}" <<<"$out"
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  (whoami) agent_login ${HA[@]+"${HA[@]}"} || exit 1 ;;
  (check) need_target; api -X GET "repos/$RP/issues" -f per_page=1 >/dev/null ;;
  (list)
    need_target; l="$(cfg qa_label)"
    out="$(api -X GET "repos/$RP/issues" -f labels="${l:-qa:ready}" -f state=all -f per_page=100)" || exit 1
    printf '%s' "$out" | jq -c '[.[] | select(has("pull_request") | not) | {number, title, state, labels: [.labels[]?.name]}]' ;;
  (prs)
    need_target; since=""
    case "${1:-}" in
      ('') ;;
      (--since) since="${2:-}"; [[ "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && [ $# -eq 2 ] || usage ;;
      (*) usage ;;
    esac
    f=(-f state=all -f sort=updated -f direction=asc -f per_page=100); [ -n "$since" ] && f+=(-f since="$since")
    # The issues listing names pull requests too; no /pulls endpoint is ever requested. Pages join
    # on stdin, never as an argument (one argument holds 128 KiB). Past PRS_PAGES pages the listing
    # is cut: `truncated`, and the update time of its last item, issue or pull request.
    all=""; truncated=false
    for page in $(seq 1 "$PRS_PAGES"); do
      c="$(api -X GET "repos/$RP/issues" "${f[@]}" -f page="$page")" || exit 1
      printf '%s' "$c" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 1
      all="$all$c"$'\n'
      [ "$(jq length <<<"$c")" -lt 100 ] && break
      [ "$page" = "$PRS_PAGES" ] && truncated=true
    done
    all="$(printf '%s' "$all" | jq -cs 'add // []')" || exit 1
    last="$(jq -r '[.[].updated_at | strings] | last // ""' <<<"$all")"
    printf '%s' "$all" | node "$SCRIPT_DIR/lib/pr-text.mjs" \
      | jq -c --argjson t "$truncated" --arg l "$last" '{prs: ., truncated: $t, last_updated_at: (if $l == "" then null else $l end)}' \
      || exit 1 ;;
  (issue)
    need_target; num "${1:-}"
    out="$(api "repos/$RP/issues/$1")" || exit 1
    printf '%s' "$out" | jq -e 'has("pull_request") | not' >/dev/null 2>&1 \
      || refuse "#$1 is a pull request, not an issue"
    printf '%s' "$out" | jq -c '{number, title, body, state, state_reason, author_association,
      user: .user.login, labels: [.labels[]?.name], created_at, updated_at, closed_at}' ;;
  (comments)
    need_target; num "${1:-}"; not_pr "$1"
    f=(-f per_page=100); [ -n "${2:-}" ] && f+=(-f since="$2")
    # Explicit pages: GitHub's next links name /repositories/<id>/…, which the egress denies.
    # Pages join on stdin, never as an argument (one argument holds 128 KiB).
    all=""
    for page in 1 2 3 4 5 6 7 8 9 10; do
      c="$(api -X GET "repos/$RP/issues/$1/comments" "${f[@]}" -f page="$page")" || exit 1
      printf '%s' "$c" | jq -e 'type == "array"' >/dev/null 2>&1 || exit 1
      all="$all$c"$'\n'
      [ "$(jq length <<<"$c")" -lt 100 ] && break
    done
    # Each comment carries the injection lint of its text (lib/scan-issues.mjs → injectionLint);
    # argv[1] is not the module's path, or the module would run its own CLI.
    printf '%s' "$all" | jq -cs 'add // [] | [.[] | {id, user: .user.login, author_association, created_at, updated_at, body}]' \
      | node --input-type=module -e "
        import { readFileSync } from 'node:fs';
        import { pathToFileURL } from 'node:url';
        const { injectionLint } = await import(pathToFileURL(process.argv[2]).href);
        const cs = JSON.parse(readFileSync(0, 'utf8'));
        console.log(JSON.stringify(cs.map((c) => ({ ...c, ...injectionLint(c.body ?? '') }))));" - "$SCRIPT_DIR/lib/scan-issues.mjs" ;;
  (comment)
    need_target; num "${1:-}"; [ -f "${2:-}" ] || usage
    enabled issue_comments || enabled spec_feedback || refuse "issue_comments and spec_feedback are disabled"
    not_pr "$1"
    api -X POST "repos/$RP/issues/$1/comments" -F body=@"$2" --jq .html_url ;;
  (unlabel)
    need_target; num "${1:-}"
    enabled issue_comments || refuse "issue_comments is disabled"
    not_pr "$1"
    l="$(cfg retest_label)"; l="$(jq -rn --arg l "${l:-qa:retest}" '$l | @uri')"
    api -X DELETE "repos/$RP/issues/$1/labels/$l" >/dev/null ;;
  (create-issue) create_issue "$@" ;;
  (*) usage ;;
esac
