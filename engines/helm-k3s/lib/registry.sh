#!/usr/bin/env bash
# registry.sh — read-only tag listings and publish times for an OCI chart ref.
#   registry_api "quay": quay.io's own API — tags with push times, newest first (fast).
#   registry_api "oci":  any OCI registry over /v2 — every tag, anonymous bearer token;
#                        publish time from the manifest's org.opencontainers.image.created.

# oci://<host>/<repo> -> "<host> <repo>"
ref_parts() { local r="${1#oci://}"; printf '%s %s\n' "${r%%/*}" "${r#*/}"; }

# Anonymous pull token for /v2 (empty when the registry needs none).
oci_token() { # <host> <repo>
  local h="$1" repo="$2" www realm service
  www="$(curl -sS -o /dev/null -D - --max-time 20 "https://$h/v2/" | tr -d '\r' | sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate: Bearer //p')"
  [ -n "$www" ] || return 0
  realm="$(printf '%s' "$www" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')"
  service="$(printf '%s' "$www" | sed -n 's/.*service="\([^"]*\)".*/\1/p')"
  curl -fsS --max-time 20 "$realm?service=$service&scope=repository:$repo:pull" | jq -r '.token // .access_token // empty'
}

# "<tag> <epoch>" lines, newest first, at most <pages> pages of 100.
tags_quay() { # <repo> <pages>
  local repo="$1" pages="${2:-30}" p body
  for p in $(seq 1 "$pages"); do
    body="$(curl -fsS --max-time 20 "https://quay.io/api/v1/repository/$repo/tag/?limit=100&onlyActiveTags=true&page=$p")" || return 1
    jq -r '.tags[]? | "\(.name) \(.start_ts // 0)"' <<<"$body" || return 1
    [ "$(jq -r '.has_additional // false' <<<"$body")" = true ] || break
  done
}

# "<tag> 0" lines — /v2 carries no times; every page, following the Link header. A failed page
# fails the listing: curl's status is checked before jq (callers run without pipefail).
tags_oci() { # <host> <repo>
  local h="$1" repo="$2" tok url next hdr body
  tok="$(oci_token "$h" "$repo")"
  url="https://$h/v2/$repo/tags/list?n=1000"
  while [ -n "$url" ]; do
    hdr="$(mktemp)"
    body="$(curl -fsS --max-time 30 -D "$hdr" ${tok:+-H "Authorization: Bearer $tok"} "$url")" || { rm -f "$hdr"; return 1; }
    jq -r '.tags[]? | "\(.) 0"' <<<"$body" || { rm -f "$hdr"; return 1; }
    next="$(tr -d '\r' < "$hdr" | sed -n 's/^[Ll]ink: <\([^>]*\)>.*rel="next".*/\1/p')"; rm -f "$hdr"
    case "$next" in ('') url="";; (http*) url="$next";; (*) url="https://$h$next";; esac
  done
}

# ISO-8601 publish time of one tag.
created_at() { # <api> <host> <repo> <tag>
  local api="$1" h="$2" repo="$3" tag="$4" ts tok body
  if [ "$api" = quay ]; then
    body="$(curl -fsS --max-time 20 "https://quay.io/api/v1/repository/$repo/tag/?limit=10&onlyActiveTags=true&filter_tag_name=eq:$tag")" || return 1
    ts="$(jq -r '.tags[0].start_ts // empty' <<<"$body")" || return 1
    [ -n "$ts" ] || return 1
    date -u -d "@$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$ts" +%Y-%m-%dT%H:%M:%SZ
  else
    tok="$(oci_token "$h" "$repo")"
    body="$(curl -fsS --max-time 20 ${tok:+-H "Authorization: Bearer $tok"} \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json' "https://$h/v2/$repo/manifests/$tag")" || return 1
    jq -re '.annotations["org.opencontainers.image.created"] // empty' <<<"$body"
  fi
}
