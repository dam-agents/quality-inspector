#!/usr/bin/env bash
# boundary.sh — the black-box boundary of one target (docs/black-box.md): the egress
# rules it needs and the probes that prove them. Sourced after lib/config.sh and
# lib/profile.sh. A target is a [<host>/]<owner>/<repo> ref; the host defaults to github.com.

_bb_host() { case "$(printf '%s' "$1" | tr -cd '/' | wc -c | tr -d ' ')" in (2) printf '%s\n' "${1%%/*}";; (*) echo github.com;; esac; }
_bb_repo() { case "$(printf '%s' "$1" | tr -cd '/' | wc -c | tr -d ' ')" in (2) printf '%s\n' "${1#*/}";; (*) printf '%s\n' "$1";; esac; }
# The API of a GitHub host: its hostname and REST prefix.
_bb_api_host() { case "$1" in (github.com) echo api.github.com;; (*.ghe.com) echo "api.$1";; (*) echo "$1";; esac; }
_bb_api_prefix() { case "$1" in (github.com|*.ghe.com) echo "";; (*) echo /api/v3;; esac; }
_bb_timeout() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }
_bb_lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
# The target's owner and name in the other case: GitHub resolves them case-insensitively,
# and only a gateway with case-blind GitHub denies (dam-agents/dam#4909) refuses each form.
_bb_swapcase() { printf '%s' "$1" | tr 'a-zA-Z' 'A-Za-z'; }
# The directory a profile lives in, in whichever repository (docs/profile-contract.md →
# Where it lives): the one path of a repository the egress opens, for the platform's install.
PROFILE_SOURCE_DIR=.quality-inspector
# This definition's repository as "<host> <owner>/<repo>", from the checkout's origin
# (https or scp-style); QI_DEFINITION_REPO (<host>/<owner>/<repo>) overrides.
_bb_definition() {
  local u="${QI_DEFINITION_REPO:-}"
  [ -n "$u" ] || u="$(git -C "$(dirname "${BASH_SOURCE[0]}")/../.." remote get-url origin 2>/dev/null)"
  u="${u#*://}"; u="${u##*@}"; u="${u%/}"; u="${u%.git}"; u="$(printf '%s' "$u" | sed 's|^\([^/:]*\):|\1/|')"
  [ "$(printf '%s' "$u" | tr -cd '/' | wc -c | tr -d ' ')" = 2 ] || return 1
  printf '%s %s\n' "${u%%/*}" "${u#*/}"
}

# The GitHub egress every deployment shares, one "<verdict> <method> <host> <path pattern>"
# per line, on one GitHub host: the kit carries it for github.com (validate-definition.sh
# compares), egress-rules.sh lists it for a GitHub Enterprise target. No rule names the
# target — the host is deny-by-default, and what opens opens for every repository alike: the
# issues endpoints, the profile directory and a repository's metadata and head ref (the
# platform's install and scan). The platform matches by the exact host, then a named method
# over '*', then the longer path, with '*' as SQL LIKE '%', which spans '/' and the query
# string. So every allow `/repos/*/*<rest>` gets two denies two characters longer, which
# leave it only the request it is for: `/repos/*/*/*<rest>` (<rest> after a third segment —
# a code path carrying <rest> in its query) and `/repos/*_2F*<rest>` (an encoded slash in
# owner or repo). Two rules of equal length have no order, hence never +1. A <definition>
# adds the read-only git fetch of this definition's repository: the platform's seed and Kit
# Update run `git fetch origin` in the agent (docs/persistence.md → Definition version).
github_rules() { # <host> [<owner>/<repo> of this definition]
  local h="$1" d="${2:-}" api p m rest
  api="$(_bb_api_host "$h")"; p="$(_bb_api_prefix "$h")"
  echo "deny * $api /*"
  echo "allow GET $api $p/user"
  while read -r m rest; do
    printf '%s %s %s %s\n' allow "$m" "$api" "$p/repos/*/*$rest" \
      deny "$m" "$api" "$p/repos/*/*/*$rest" deny "$m" "$api" "$p/repos/*_2F*$rest"
  done <<EOF
GET
GET /issues*
POST /issues/*/comments
DELETE /issues/*/labels/*
GET /contents/$PROFILE_SOURCE_DIR/*
GET /contents/$PROFILE_SOURCE_DIR?*
GET /git/refs/heads/*
EOF
  # Issue timelines and events name the commits that closed them.
  printf 'deny GET %s %s\n' "$api" "$p/repos/*/*/issues/*/timeline*" "$api" "$p/repos/*/*/issues/*/events*" \
    "$api" "$p/repos/*/*/issues/events*"
  [ "$api" = "$h" ] || echo "deny * $h /*"
  [ -n "$d" ] && printf 'allow GET %s %s\nallow POST %s %s\n' \
    "$h" "/$d*/info/refs?service=git-upload-pack" "$h" "/$d*/git-upload-pack"
  if [ "$h" = github.com ]; then echo "deny * codeload.github.com /*"
  else printf 'deny * raw.%s /*\ndeny * codeload.%s /*\n' "$h" "$h"; fi
}

# The rules of the work backup repository (work_repo; docs/persistence.md → Backup & restore),
# same line format; nothing when it is unset. Only what work-backup.sh requests: the
# repository's metadata and the git fetch and push. The metadata allow is the shared one;
# the git rule is longer than the host's deny-by-default `/*`.
work_repo_rules() {
  local w h r
  w="$(cfg work_repo)"; [ -n "$w" ] || return 0
  h="$(_bb_host "$w")"; r="$(_bb_repo "$w")"
  printf 'allow * %s %s\n' "$h" "/$r.git/*"
}

# The probes, one "<kind> <target>" per line, each through the client an agent would use:
# gh <api path> (GET), gql <owner/repo> (a GraphQL query for its tree), git <url> and ssh
# <url> (`git ls-remote`), url <url> (curl). {issue} stands for a real issue number, {id}
# for repository number 1. Besides each surface, the shapes that would slip a code path past
# the shared allows: <rest> of an allow in a query string, an encoded slash, a dot segment
# out of the profile directory.
boundary_targets() { # <target>
  local h r R pd="$PROFILE_SOURCE_DIR" dir p
  h="$(_bb_host "$1")"; r="$(_bb_repo "$1")"; R="$(_bb_swapcase "$r")"
  printf '%s\n' "gh repos/$r/contents/" "gh repos/$R/contents/" "gh repos/$r/readme" \
    "gh repos/$r/git/trees/HEAD" "gh repos/$r/git/blobs/0000000000000000000000000000000000000000" \
    "gh repos/$r/pulls?per_page=1" "gh repos/$r/commits?per_page=1" "gh repos/$r/compare/HEAD...HEAD" \
    "gh repos/$r/branches?per_page=1" "gh repos/$r/git/refs/heads" "gh repos/$r/tarball/HEAD" "gh repos/$r/zipball/HEAD" \
    "gh repos/$r/releases?per_page=1" "gh repos/$r/actions/artifacts?per_page=1" \
    "gh repos/$r/issues/{issue}/timeline" "gh repos/$r/issues/{issue}/TIMELINE" \
    "gh repos/$r/issues/{issue}/events" "gh repos/$r/issues/events?per_page=1" \
    "gh repos/$r/contents/README.md?x=/issues" "gh repos/$r/contents/README.md?x=/contents/$pd/x" \
    "gh repos/${r%%/*}%2F${r#*/}%2Fcontents%2FREADME.md" "gh repos/$r/contents/$pd/.." "gh repos/$r/contents/$pd/%2e%2e" \
    "gh search/code?q=repo:$r+a&per_page=1" "gh search/commits?q=repo:$r+a&per_page=1" \
    "gh repositories/{id}/contents/" "gql $r" \
    "git https://$h/$r.git" "git https://$h/$r.wiki.git" "ssh ssh://git@$h/$r.git" \
    "url https://$h/$r/archive/HEAD.tar.gz" "url https://$h/$R/archive/HEAD.tar.gz" \
    "url https://$h/$r.git/info/refs?service=git-upload-pack" \
    "url https://gitlab.com/" "url https://codeberg.org/"
  [ "$h" = github.com ] && printf '%s\n' "ssh ssh://git@ssh.github.com:443/$r.git" \
    "url https://raw.githubusercontent.com/$r/HEAD/README.md" \
    "url https://codeload.github.com/$r/tar.gz/HEAD" "url https://codeload.github.com/$R/tar.gz/HEAD"
  dir="$(profile_dir)" && [ -f "$dir/profile.json" ] || return 0
  jq -r '.boundary.github_paths[]? // empty' "$dir/profile.json" | while read -r p; do printf 'gh repos/%s/%s\n' "$r" "${p#/}"; done
  jq -r '.boundary.urls[]? // empty' "$dir/profile.json" | sed "s|{repo}|$r|g; s|^|url |"
}

# git's SSH client for the ssh probes: never a prompt, a short connect, any host key.
_BB_SSH='ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR'

# One probe's answer, from what its client printed — gh -i, curl -D -, git's curl trace, ssh's
# errors — and a last "rc=<exit code>" line: "<code> <github>". <code> is the last HTTP status
# (a proxy's CONNECT answer comes first) or held, none (no connection), nocli (no client in the
# VM), noauth (gh sent nothing: no token), sshd (an SSH server answered); <github> is yes when
# GitHub itself sent the answer (its X-GitHub-Request-Id header), whatever the status.
_bb_answer() { # <kind> <output>
  local out="$2" rc code github=no
  rc="${out##*rc=}"; rc="${rc%%[!0-9]*}"
  code="$(printf '%s\n' "$out" | sed -n 's/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' | tail -1)"
  printf '%s\n' "$out" | grep -qi '^x-github-request-id:' && github=yes
  case "$1:$rc" in (git:0|ssh:0) code=200;; esac   # git listed the refs
  if [ -z "$code" ]; then
    case "$1:$rc" in
      (*:124|url:28) code=held;;
      (*:127) code=nocli;;
      (gh:4|gql:4) code=noauth;;
      (*) code=none;;
    esac
    case "$1:$out" in
      (ssh:*'cannot run ssh'*) code=nocli;;
      (ssh:*'Permission denied'*) code=sshd;;
    esac
  fi
  printf '%s %s\n' "$code" "$github"
}

# A GraphQL query for the root tree of <owner/repo> — the source, not just the endpoint.
_bb_gql() { printf 'query{repository(owner:"%s",name:"%s"){object(expression:"HEAD:"){__typename}}}' "${1%%/*}" "${1#*/}"; }

# Run every probe: one "<ok|warn|fail> boundary:<target> <detail>" line each. Only the
# gateway's refusal (403, or no connection) proves a deny. An answer from GitHub itself is a
# fail whatever its status — the egress let the request through, and only the token's
# permissions stood between it and the code. A probe that sent nothing proves nothing.
boundary_probe() { # <target>
  local h r ha=() issue kind target out code github label
  h="$(_bb_host "$1")"; r="$(_bb_repo "$1")"
  [ "$h" = github.com ] || ha=(--hostname "$h")
  issue="$(_bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} "repos/$r/issues?state=all&per_page=1" --jq '.[0].number // empty' 2>/dev/null)"
  case "$issue" in (''|*[!0-9]*) issue=1;; esac
  # {id} is repository 1, public on github.com: the /repositories/* deny is host-wide, and
  # the target's own id needs GET /repos/<T>, which is not an issues endpoint.
  while read -r kind target; do
    target="$(printf '%s' "$target" | sed "s/{issue}/$issue/g; s/{id}/1/g")"
    label="boundary:${target%%\?*}"
    case "$kind" in
      (gh)  out="$({ _bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} -i "$target" </dev/null 2>/dev/null; echo "rc=$?"; } | LC_ALL=C sed -n '1,/^[[:space:]]*$/p;$p')" ;;
      (gql) out="$({ _bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} -i graphql -f query="$(_bb_gql "$target")" </dev/null 2>/dev/null; echo "rc=$?"; } | LC_ALL=C sed -n '1,/^[[:space:]]*$/p;$p')"
            label=boundary:graphql ;;
      (git|ssh) out="$( { GIT_TERMINAL_PROMPT=0 GIT_TRACE_CURL=1 GIT_TRACE_CURL_NO_DATA=1 GIT_SSH_COMMAND="$_BB_SSH" \
              _bb_timeout 25 git ls-remote "$target" HEAD </dev/null 2>&1 >/dev/null; echo "rc=$?"; } | sed -n 's/.*<= Recv header: //p; /Permission denied/p; /cannot run ssh/p; /^rc=/p')"
            label="boundary:$kind:${target%%\?*}" ;;
      (url) out="$({ curl -s -o /dev/null -D - --max-time 20 --max-filesize 1 "$target" </dev/null 2>/dev/null; c=$?; echo; echo "rc=$c"; })" ;;
      (*)   continue ;;
    esac
    read -r code github <<<"$(_bb_answer "$kind" "$out")"
    case "$code:$github:$target" in
      ([23]??:*:*/..|[23]??:*:*%2e%2e|*:yes:*/..|*:yes:*%2e%2e) echo "fail $label source surface reachable (HTTP $code): the gateway does not deny dot segments (dam-agents/dam#4909), so the profile directory allow opens the whole repository — report the gateway to the platform";;
      ([23]??:*:*/TIMELINE|*:yes:*/TIMELINE) echo "fail $label source surface reachable (HTTP $code): the gateway matches a GitHub deny only in exact case — report the gateway to the platform (dam-agents/dam#4909)";;
      ([23]??:*) echo "fail $label source surface reachable (HTTP $code)";;
      (*:yes:*) echo "fail $label source surface reachable (HTTP $code from GitHub itself: the egress let the request through, only the token's permissions stopped it)";;
      (403:*|none:*) echo "ok $label refused";;
      (held:*)  echo "warn $label request held for approval — make it an explicit deny so nobody approves it by accident";;
      (nocli:*) echo "warn $label not probed: the VM has no ${kind/gql/gh} client — the deny is unproven";;
      (noauth:*) echo "warn $label not probed: gh has no token, so no request left the VM — the deny is unproven";;
      (sshd:*)  echo "warn $label an SSH server answered (it refused the VM's key) — only a missing key keeps the code out; ask the platform to block SSH to code hosts";;
      (*)       echo "warn $label answered HTTP $code, not the gateway's refusal — the deny is unproven";;
    esac
  done < <(boundary_targets "$1")
  # The target's profile directory, when it has one, must serve only its own files: the
  # contents API answers a symlink with its target.
  code="$(_bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} -i "repos/$r/contents/$PROFILE_SOURCE_DIR?ref=HEAD" </dev/null 2>/dev/null | awk '/^HTTP\//{print $2; exit}')"
  case "$code" in
    (2??) ;;
    (404) echo "ok profile_source the target holds no $PROFILE_SOURCE_DIR directory"; return 0;;
    (*) echo "warn profile_source repos/$r/contents/$PROFILE_SOURCE_DIR?ref=HEAD answered HTTP ${code:-none} — the platform cannot install a profile from the target"; return 0;;
  esac
  local scan foreign unread
  scan="$(_bb_foreign_files "$r" "$PROFILE_SOURCE_DIR")"
  foreign="$(printf '%s\n' "$scan" | sed -n 's/^foreign //p' | tr '\n' ' ')"
  unread="$(printf '%s\n' "$scan" | sed -n 's/^unreadable //p' | tr '\n' ' ')"
  if [ -n "$foreign" ]; then
    echo "fail profile_source $PROFILE_SOURCE_DIR serves content from elsewhere in the repository (the contents API answers a symlink with its target): ${foreign% } — remove those symlinks and submodules in the target repository"
  elif [ -n "$unread" ]; then
    echo "warn profile_source could not list or read ${unread% } — symlinks there are unchecked"
  elif printf '%s\n' "$scan" | grep -qx truncated; then
    echo "warn profile_source $PROFILE_SOURCE_DIR is too large to check for symlinks"
  else
    echo "ok profile_source repos/$r/contents/$PROFILE_SOURCE_DIR?ref=HEAD every file its own"
  fi
}

# The fix for a probe's fail line: the remedy it carries after " — ", else the generic one.
boundary_fix() { # <detail>
  case "$1" in
    (*' — '*) printf '%s\n' "${1#* — }";;
    (*) echo "the agent's egress lacks the kit's GitHub rules: recreate it from the kit, or have the operator add what bash scripts/egress-rules.sh --kit lists in the agent's network settings (docs/black-box.md → Egress rules)";;
  esac
}

# Under <path> at HEAD, one line per finding: "foreign <path>" for a file whose contents-API
# answer is not the file listed there (a symlink lists the size of its link text and
# serves its target; a submodule serves no file), "unreadable <path>" for a failed
# request, "truncated" past 100 requests. Only the type and size are kept, never the
# content. Called from boundary_probe, whose $ha it uses.
_bb_foreign_files() { # <owner/repo> <path>
  local r="$1" queue=("$2") d n=0 listing type path size got
  while [ ${#queue[@]} -gt 0 ]; do
    d="${queue[0]}"; queue=("${queue[@]:1}")
    n=$((n + 1)); [ "$n" -le 100 ] || { echo truncated; return 0; }
    listing="$(_bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} "repos/$r/contents/$d?ref=HEAD" --jq '.[] | [.type, .path, .size] | @tsv' </dev/null 2>/dev/null)" \
      || { echo "unreadable $d"; continue; }
    while IFS="$(printf '\t')" read -r type path size; do
      case "$type" in
        (dir) queue+=("$path");;
        (file|symlink|submodule)
          n=$((n + 1)); [ "$n" -le 100 ] || { echo truncated; return 0; }
          got="$(_bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} "repos/$r/contents/$path?ref=HEAD" --jq '"\(.type) \(.size)"' </dev/null 2>/dev/null)" \
            || { echo "unreadable $path"; continue; }
          [ "$got" = "file $size" ] || echo "foreign $path";;
      esac
    done <<<"$listing"
  done
}
