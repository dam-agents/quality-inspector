#!/usr/bin/env bash
# changes.sh — what landed between two chart builds, told by the issues alone: every
# issue of the target closed as completed between the two tags' push times, with its
# title, labels and spec text (the "Done when" section). No PR, commit or code is read
# (docs/black-box.md). Read-only. Rationale: docs/change-awareness.md.
#
#   changes.sh <from-tag> <to-tag>   -> one JSON object on stdout
#
# The window is approximate by nature: an issue closed minutes before a build may land
# in the next one. Consumers treat it as context for judgment, never as proof.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/state.sh" || { echo "cannot source lib/state.sh" >&2; exit 1; }

FROM="${1:?from-tag}"; TO="${2:?to-tag}"
TARGET="${QI_TARGET_REPO:-$(cfg target_repo)}"
CHART_REF="$(cfg chart_ref)"; CHART_REF="${CHART_REF:-oci://quay.io/dam-agents/charts/platform}"
[ -n "$TARGET" ] || { jq -nc '{error:"target_repo is not configured"}'; exit 0; }
HA=(); RP="$TARGET"
if [ "$(printf '%s' "$TARGET" | tr -cd '/' | wc -c | tr -d ' ')" = 2 ]; then HA=(--hostname "${TARGET%%/*}"); RP="${TARGET#*/}"; fi

# Push time of one tag, from the registry.
tag_utc() {
  local repo="${CHART_REF#oci://quay.io/}" ts
  ts="$(curl -fsS --max-time 20 "https://quay.io/api/v1/repository/$repo/tag/?limit=10&onlyActiveTags=true&filter_tag_name=eq:$1" 2>/dev/null \
        | jq -r '.tags[0].start_ts // empty')" || return 1
  [ -n "$ts" ] || return 1
  date -u -d "@$ts" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$ts" +%Y-%m-%dT%H:%M:%SZ
}

from_utc="$(tag_utc "$FROM")" || { jq -nc --arg t "$FROM" '{error:("cannot read the push time of " + $t)}'; exit 0; }
to_utc="$(tag_utc "$TO")" || { jq -nc --arg t "$TO" '{error:("cannot read the push time of " + $t)}'; exit 0; }

all='[]'; truncated=false
for page in 1 2 3 4 5; do
  body="$(gh api ${HA[@]+"${HA[@]}"} -X GET "repos/$RP/issues" -f state=closed -f since="$from_utc" \
          -f per_page=100 -f page="$page" -f sort=updated -f direction=desc 2>/dev/null)" \
    || { jq -nc '{error:"closed-issue listing failed"}'; exit 0; }
  all="$(jq -c --argjson b "$body" '. + $b' <<<"$all")"
  [ "$(jq length <<<"$body")" -lt 100 ] && break
  [ "$page" = 5 ] && truncated=true
done

issues='[]'
while IFS= read -r it; do
  [ -n "$it" ] || continue
  title="$(jq -r .title <<<"$it")"; body="$(jq -r '.body // ""' <<<"$it")"
  spec="$(issue_spec_text "$title" "$body" | tail -n +2 | head -c 800)"
  issues="$(jq -c --argjson i "$it" --arg s "$spec" '. + [{number:$i.number, title:$i.title,
     labels:[$i.labels[]?.name], closed_at:$i.closed_at, spec:$s}]' <<<"$issues")"
done < <(jq -c --arg f "$from_utc" --arg t "$to_utc" '
  map(select(.pull_request == null and .state_reason == "completed" and .closed_at > $f and .closed_at <= $t))
  | sort_by(.closed_at) | .[]' <<<"$all")

jq -nc --arg f "$FROM" --arg fu "$from_utc" --arg t "$TO" --arg tu "$to_utc" --argjson i "$issues" --argjson tr "$truncated" \
  '{from:{tag:$f, utc:$fu}, to:{tag:$t, utc:$tu}, issues:$i, truncated:$tr}'
