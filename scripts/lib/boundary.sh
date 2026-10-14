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
# the platform's path match (SQL LIKE) does not.
_bb_swapcase() { printf '%s' "$1" | tr 'a-zA-Z' 'A-Za-z'; }
# profile_source_path, without leading or trailing slashes; empty = the profile lives
# outside the target repository.
_bb_profile_path() { cfg profile_source_path | sed -e 's|^/*||' -e 's|/*$||'; }
# A plain directory path: a pattern character (* % ? …) or a . or .. segment in an allow
# rule opens more than the profile's directory.
_bb_profile_path_ok() { printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$' && ! printf '/%s/' "$1" | grep -qE '/\.\.?/'; }
# This definition's repository as "<host> <owner>/<repo>", from the checkout's origin
# (https or scp-style); QI_DEFINITION_REPO (<host>/<owner>/<repo>) overrides.
_bb_definition() {
  local u="${QI_DEFINITION_REPO:-}"
  [ -n "$u" ] || u="$(git -C "$(dirname "${BASH_SOURCE[0]}")/../.." remote get-url origin 2>/dev/null)"
  u="${u#*://}"; u="${u##*@}"; u="${u%/}"; u="${u%.git}"; u="$(printf '%s' "$u" | sed 's|^\([^/:]*\):|\1/|')"
  [ "$(printf '%s' "$u" | tr -cd '/' | wc -c | tr -d ' ')" = 2 ] || return 1
  printf '%s %s\n' "${u%%/*}" "${u#*/}"
}

# The target's egress rules, one "<verdict> <method> <host> <path pattern>" per line; the
# label rule names the retest label only, URL-encoded. Rules are matched most specific
# first: the exact host, then a named method over '*', then a path over '*', then the
# longer path — so every deny that must beat a GET allow is a GET rule itself.
# The target's GitHub hosts are deny-by-default: the connection allows every repository
# the token — or anyone, for a public target — can read, forks and other-case spellings
# of the target included, so only an allowlist holds. Allowed: the target's issues, the
# profile's directory (profile_source_path), this definition's repository and the other
# skill sources named.
boundary_rules() { # <target> [<owner>/<repo> of another skill source…]
  local h r api p l pp dh dr s
  h="$(_bb_host "$1")"; r="$(_bb_repo "$1")"; shift
  api="$(_bb_api_host "$h")"; p="$(_bb_api_prefix "$h")"; pp="$(_bb_profile_path)"
  l="$(cfg retest_label)"; l="$(jq -rn --arg l "${l:-qa:retest}" '$l | @uri')"
  cat <<EOF
allow GET $api $p/user
allow GET $api $p/repos/$r/issues*
allow POST $api $p/repos/$r/issues/*/comments*
allow DELETE $api $p/repos/$r/issues/*/labels/$l
deny GET $api $p/repos/$r/issues/*/timeline*
deny GET $api $p/repos/$r/issues/*/events*
deny GET $api $p/repos/$r/issues/events*
EOF
  # The platform fetches a skill by directory when the archive is denied and this path
  # is not: `contents/<path>?ref=…`, then everything below `<path>/`.
  [ -n "$pp" ] && _bb_profile_path_ok "$pp" && printf 'allow GET %s %s\nallow GET %s %s\n' \
    "$api" "$p/repos/$r/contents/$pp/*" "$api" "$p/repos/$r/contents/$pp?*"
  if read -r dh dr < <(_bb_definition) && [ "$dh" = "$h" ] && [ "$(_bb_lower "$dr")" != "$(_bb_lower "$r")" ]; then
    printf 'allow * %s %s\nallow * %s %s\nallow * %s %s\n' "$api" "$p/repos/$dr/*" "$h" "/$dr/*" "$h" "/$dr.git/*"
  fi
  for s in "$@"; do
    [ "$(_bb_lower "$s")" = "$(_bb_lower "$r")" ] && continue
    echo "allow GET $api $p/repos/$s/*"
    if [ "$h" = github.com ]; then echo "allow GET codeload.github.com /$s/*"
    else printf 'allow GET %s %s\nallow GET %s %s\n' "$h" "/_codeload/$s/*" "codeload.$h" "/$s/*"; fi
  done
  echo "deny * $api /*"
  [ "$api" = "$h" ] || echo "deny * $h /*"
  if [ "$h" = github.com ]; then echo "deny * codeload.github.com /*"
  else printf 'deny * raw.%s /*\ndeny * codeload.%s /*\n' "$h" "$h"; fi
}

# The rules of the work backup repository (work_repo; docs/persistence.md → Backup & restore),
# same line format; nothing when it is unset. Only what work-backup.sh requests: the
# repository's metadata and the git fetch and push. Their paths are longer than the
# deny-by-default `/*` of the target's GitHub hosts, so they win; the git rule's method `*`
# loses to no GET deny there.
work_repo_rules() {
  local w h r api p
  w="$(cfg work_repo)"; [ -n "$w" ] || return 0
  h="$(_bb_host "$w")"; r="$(_bb_repo "$w")"; api="$(_bb_api_host "$h")"; p="$(_bb_api_prefix "$h")"
  printf 'allow GET %s %s\nallow * %s %s\n' "$api" "$p/repos/$r" "$h" "/$r.git/*"
}

# The probes, one "<kind> <target>" per line: gh <api path> (GET), gql (a GraphQL call),
# url <url>. {issue} stands for a real issue number, {id} for repository number 1.
boundary_targets() { # <target>
  local h r R pp dir p
  h="$(_bb_host "$1")"; r="$(_bb_repo "$1")"; R="$(_bb_swapcase "$r")"; pp="$(_bb_profile_path)"
  printf '%s\n' "gh repos/$r/contents/" "gh repos/$R/contents/" "gh repos/$r/pulls?per_page=1" \
    "gh repos/$r/commits?per_page=1" "gh repos/$r/git/refs/heads" "gh repos/$r/issues/{issue}/timeline" \
    "gh repos/$r/issues/{issue}/events" "gh repos/$r/issues/events?per_page=1" \
    "gh search/code?q=repo:$r+a&per_page=1" "gh repositories/{id}/contents/" "gql graphql" \
    "url https://$h/$r/archive/HEAD.tar.gz" "url https://$h/$R/archive/HEAD.tar.gz" \
    "url https://gitlab.com/" "url https://codeberg.org/"
  [ "$h" = github.com ] && printf '%s\n' "url https://raw.githubusercontent.com/$r/HEAD/README.md" \
    "url https://codeload.github.com/$r/tar.gz/HEAD" "url https://codeload.github.com/$R/tar.gz/HEAD"
  # Out of the profile's directory by a dot segment, which the contents API resolves.
  [ -n "$pp" ] && _bb_profile_path_ok "$pp" && printf '%s\n' "gh repos/$r/contents/$pp/.." "gh repos/$r/contents/$pp/%2e%2e"
  dir="$(profile_dir)" && [ -f "$dir/profile.json" ] || return 0
  jq -r '.boundary.github_paths[]? // empty' "$dir/profile.json" | while read -r p; do printf 'gh repos/%s/%s\n' "$r" "${p#/}"; done
  jq -r '.boundary.urls[]? // empty' "$dir/profile.json" | sed "s|{repo}|$r|g; s|^|url |"
}

# Run every probe: one "<ok|warn|fail> boundary:<target> <detail>" line each. Only the
# gateway's refusal (403, or no connection) proves a deny; any other answer is no proof.
boundary_probe() { # <target>
  local h r ha=() issue kind target out code rc label
  h="$(_bb_host "$1")"; r="$(_bb_repo "$1")"
  [ "$h" = github.com ] || ha=(--hostname "$h")
  issue="$(_bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} "repos/$r/issues?state=all&per_page=1" --jq '.[0].number // empty' 2>/dev/null)"
  # {id} is repository 1, public on github.com: the /repositories/* deny is host-wide, and
  # the target's own id needs GET /repos/<T>, which is not an issues endpoint.
  while read -r kind target; do
    target="$(printf '%s' "$target" | sed "s/{issue}/${issue:-1}/g; s/{id}/1/g")"
    case "$kind" in
      (gh)  out="$({ _bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} -i "$target" </dev/null 2>/dev/null; echo "rc=$?"; } | sed -n '1p;$p')" ;;
      (gql) out="$({ _bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} -i graphql -f query='{viewer{login}}' </dev/null 2>/dev/null; echo "rc=$?"; } | sed -n '1p;$p')"
            target=graphql ;;
      (url) out="$(curl -s -o /dev/null -w 'HTTP/1.1 %{http_code}' --max-time 20 --max-filesize 1 "$target" </dev/null 2>/dev/null; c=$?; echo; echo "rc=$c")" ;;
      (*)   continue ;;
    esac
    code="$(printf '%s\n' "$out" | awk '/^HTTP\//{print $2; exit}')"; rc="${out##*rc=}"
    case "$code" in (''|000) case "$rc" in (124|28) code=held;; (*) code=000;; esac;; esac
    label="boundary:${target%%\?*}"
    case "$code:$target" in
      (2??:*/..|2??:*%2e%2e) echo "fail $label source surface reachable (HTTP $code): the gateway matches the path before it resolves dot segments, so the profile allows open the whole repository — empty profile_source_path, delete the profile allows, and report the gateway to the platform";;
      (2??:*|3??:*) echo "fail $label source surface reachable (HTTP $code)";;
      (403:*|000:*) echo "ok $label refused";;
      (held:*)  echo "warn $label request held for approval — make it an explicit deny so nobody approves it by accident";;
      (*)       echo "warn $label answered HTTP $code, not the gateway's refusal — the deny is unproven";;
    esac
  done < <(boundary_targets "$1")
  # The one read the platform needs in the target: the profile's directory, requested as the
  # platform requests it — `<path>?ref=…`; the rules allow `<path>?*`, not `<path>` alone.
  local pp; pp="$(_bb_profile_path)"; [ -n "$pp" ] || return 0
  _bb_profile_path_ok "$pp" || { echo "fail profile_source profile_source_path '$pp' is not a plain directory path — set the skill source's path in target_repo (no * % ?, no . or .. segment), or leave it empty"; return 0; }
  code="$(_bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} -i "repos/$r/contents/$pp?ref=HEAD" </dev/null 2>/dev/null | awk '/^HTTP\//{print $2; exit}')"
  case "$code" in
    (2??) ;;
    (*) echo "fail profile_source repos/$r/contents/$pp?ref=HEAD not readable (HTTP ${code:-none}), so the platform cannot (re)install the profile — apply the profile allows bash scripts/egress-rules.sh prints, and check profile_source_path against the skill source's path"; return 0;;
  esac
  local scan foreign unread
  scan="$(_bb_foreign_files "$r" "$pp")"
  foreign="$(printf '%s\n' "$scan" | sed -n 's/^foreign //p' | tr '\n' ' ')"
  unread="$(printf '%s\n' "$scan" | sed -n 's/^unreadable //p' | tr '\n' ' ')"
  if [ -n "$foreign" ]; then
    echo "fail profile_source $pp serves content from elsewhere in the repository (the contents API answers a symlink with its target): ${foreign% } — remove those symlinks and submodules in the profile's repository"
  elif [ -n "$unread" ]; then
    echo "warn profile_source could not list or read ${unread% } — symlinks there are unchecked"
  elif printf '%s\n' "$scan" | grep -qx truncated; then
    echo "warn profile_source $pp is too large to check for symlinks"
  else
    echo "ok profile_source repos/$r/contents/$pp?ref=HEAD readable, every file its own — the platform fetches only this directory"
  fi
}

# The fix for a probe's fail line: the remedy it carries after " — ", else the generic one.
boundary_fix() { # <detail>
  case "$1" in
    (*' — '*) printf '%s\n' "${1#* — }";;
    (*) echo "the operator applies the rules bash scripts/egress-rules.sh prints (docs/black-box.md → Egress rules)";;
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
