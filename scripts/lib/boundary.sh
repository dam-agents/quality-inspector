#!/usr/bin/env bash
# boundary.sh — the black-box boundary of one target (docs/black-box.md): the egress
# rules it needs and the probes that prove them. Sourced after lib/config.sh and
# lib/profile.sh. A target is a [<host>/]<owner>/<repo> ref; the host defaults to github.com.

_bb_host() { case "$(printf '%s' "$1" | tr -cd '/' | wc -c | tr -d ' ')" in (2) printf '%s\n' "${1%%/*}";; (*) echo github.com;; esac; }
_bb_repo() { case "$(printf '%s' "$1" | tr -cd '/' | wc -c | tr -d ' ')" in (2) printf '%s\n' "${1#*/}";; (*) printf '%s\n' "$1";; esac; }
# The API of a GitHub host: its hostname, REST prefix and GraphQL path.
_bb_api_host() { case "$1" in (github.com) echo api.github.com;; (*.ghe.com) echo "api.$1";; (*) echo "$1";; esac; }
_bb_api_prefix() { case "$1" in (github.com|*.ghe.com) echo "";; (*) echo /api/v3;; esac; }
_bb_gql_path() { case "$1" in (github.com|*.ghe.com) echo /graphql;; (*) echo /api/graphql;; esac; }
_bb_timeout() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }

# The target's egress rules, one "<verdict> <method> <host> <path pattern>" per line; the
# label rule names the retest label only, URL-encoded. Rules are matched most specific
# first: the exact host, then a named method over '*', then a path over '*', then the
# longer path — so every deny that must beat a GET allow is a GET rule itself.
# github.com's target-independent denies come from kit.yaml; any other host gets them here.
boundary_rules() { # <target>
  local h r api p g l
  h="$(_bb_host "$1")"; r="$(_bb_repo "$1")"
  api="$(_bb_api_host "$h")"; p="$(_bb_api_prefix "$h")"; g="$(_bb_gql_path "$h")"
  l="$(cfg retest_label)"; l="$(jq -rn --arg l "${l:-qa:retest}" '$l | @uri')"
  cat <<EOF
allow GET $api $p/repos/$r/issues*
allow POST $api $p/repos/$r/issues/*/comments*
allow DELETE $api $p/repos/$r/issues/*/labels/$l
deny GET $api $p/repos/$r/issues/*/timeline*
deny GET $api $p/repos/$r/issues/*/events*
deny GET $api $p/repos/$r/issues/events*
deny * $api $p/repos/$r/*
deny * $h /$r*
EOF
  if [ "$h" = github.com ]; then
    echo "deny * codeload.github.com /$r/*"
  else
    cat <<EOF
deny * $api $g*
deny * $api $p/search/code*
deny * $api $p/search/commits*
deny * $api $p/repositories/*
deny * $api $p/gists*
deny * $h /raw/$r/*
deny * $h /_codeload/$r/*
deny * raw.$h /$r/*
deny * codeload.$h /$r/*
EOF
  fi
}

# The probes, one "<kind> <target>" per line: gh <api path> (GET), gql (a GraphQL call),
# url <url>. {issue} and {id} stand for a real issue number and the repository id.
boundary_targets() { # <target>
  local h r dir p
  h="$(_bb_host "$1")"; r="$(_bb_repo "$1")"
  printf '%s\n' "gh repos/$r/contents/" "gh repos/$r/pulls?per_page=1" "gh repos/$r/commits?per_page=1" \
    "gh repos/$r/git/refs/heads" "gh repos/$r/issues/{issue}/timeline" "gh repos/$r/issues/{issue}/events" \
    "gh repos/$r/issues/events?per_page=1" "gh search/code?q=repo:$r+a&per_page=1" \
    "gh repositories/{id}/contents/" "gql graphql" "url https://$h/$r/archive/HEAD.tar.gz" \
    "url https://gitlab.com/" "url https://codeberg.org/"
  [ "$h" = github.com ] && printf '%s\n' "url https://raw.githubusercontent.com/$r/HEAD/README.md" \
    "url https://codeload.github.com/$r/tar.gz/HEAD"
  dir="$(profile_dir)" && [ -f "$dir/profile.json" ] || return 0
  jq -r '.boundary.github_paths[]? // empty' "$dir/profile.json" | while read -r p; do printf 'gh repos/%s/%s\n' "$r" "${p#/}"; done
  jq -r '.boundary.urls[]? // empty' "$dir/profile.json" | sed "s|{repo}|$r|g; s|^|url |"
}

# Run every probe: one "<ok|warn|fail> boundary:<target> <detail>" line each. Only the
# gateway's refusal (403, or no connection) proves a deny; any other answer is no proof.
boundary_probe() { # <target>
  local h r ha=() issue id kind target out code rc label
  h="$(_bb_host "$1")"; r="$(_bb_repo "$1")"
  [ "$h" = github.com ] || ha=(--hostname "$h")
  issue="$(_bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} "repos/$r/issues?state=all&per_page=1" --jq '.[0].number // empty' 2>/dev/null)"
  id="$(_bb_timeout 20 gh api ${ha[@]+"${ha[@]}"} "repos/$r" --jq '.id // empty' 2>/dev/null)"
  while read -r kind target; do
    target="$(printf '%s' "$target" | sed "s/{issue}/${issue:-1}/g; s/{id}/${id:-0}/g")"
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
    case "$code" in
      (2??|3??) echo "fail $label source surface reachable (HTTP $code)";;
      (403|000) echo "ok $label refused";;
      (held)    echo "warn $label request held for approval — make it an explicit deny so nobody approves it by accident";;
      (*)       echo "warn $label answered HTTP $code, not the gateway's refusal — the deny is unproven";;
    esac
  done < <(boundary_targets "$1")
}
