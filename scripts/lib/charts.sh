#!/usr/bin/env bash
# charts.sh — resolve the candidate and baseline chart versions from the registry.
# Read-only tag listings. Sourced by preflight.sh, verify-onboarding.sh and env.sh.
#
# Only quay.io OCI refs are listable without credentials today; any other host
# yields an error so the caller reports "could not look", never a stale answer.
# Dev builds (0.0.0-main.*) outnumber releases by far, so the newest page of tags
# may hold no release at all: the listing pages until it has seen both, and the
# release before the newest is looked up by name prefix.

_quay_tags() { # <repo> <page> [name-like]
  local url="https://quay.io/api/v1/repository/$1/tag/?limit=100&onlyActiveTags=true&page=$2"
  [ -n "${3:-}" ] && url="$url&filter_tag_name=like:$3"
  curl -fsS --max-time 20 "$url" 2>/dev/null
}

_releases() { jq -c '[.tags[]? | .name | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))]
                     | sort_by(split(".") | map(tonumber)) | reverse'; }

# chart_versions <oci-ref> <candidate_channel> <baseline_channel>
# -> prints {"candidate": "...", "baseline": "..."|null} or returns 1 with a reason on stderr.
chart_versions() {
  local ref="$1" cand_ch="${2:-main}" base_ch="${3:-release}" repo page body main="" r1="" r0="" maj min rels
  case "$ref" in
    oci://quay.io/*) repo="${ref#oci://quay.io/}" ;;
    *) echo "chart_ref $ref is not on quay.io — cannot list tags" >&2; return 1 ;;
  esac
  for page in 1 2 3 4 5; do
    body="$(_quay_tags "$repo" "$page")" || { echo "quay tag listing failed for $repo" >&2; return 1; }
    [ -n "$main" ] || main="$(printf '%s' "$body" | jq -r '[.tags[]? | select(.name | test("^0\\.0\\.0-main\\.")) | {name, ts: (.start_ts // 0)}]
                                                          | sort_by(.ts) | last | .name // empty')"
    [ -n "$r1" ] || r1="$(printf '%s' "$body" | _releases | jq -r '.[0] // empty')"
    { [ -n "$main" ] && [ -n "$r1" ]; } && break
    [ "$(printf '%s' "$body" | jq -r '.has_additional // false')" = true ] || break
  done
  if [ "$cand_ch" = release ] && [ "$base_ch" != none ] && [ -n "$r1" ]; then
    maj="${r1%%.*}"; min="${r1#*.}"; min="${min%%.*}"
    rels="$(_quay_tags "$repo" 1 "$maj.$min." | _releases)" || rels='[]'
    r0="$(printf '%s' "$rels" | jq -r --arg r "$r1" 'map(select(. != $r)) | .[0] // empty')"
    if [ -z "$r0" ] && [ "$min" -gt 0 ]; then
      r0="$(_quay_tags "$repo" 1 "$maj.$((min - 1))." | _releases | jq -r '.[0] // empty')"
    fi
  fi
  local cand base
  if [ "$cand_ch" = release ]; then cand="$r1"; base="$r0"; else cand="$main"; base="$r1"; fi
  [ "$base_ch" = none ] && base=""
  [ -n "$cand" ] || { echo "no $cand_ch chart version found in $repo" >&2; return 1; }
  jq -nc --arg c "$cand" --arg b "$base" '{candidate:$c, baseline:(if $b=="" then null else $b end)}'
}
