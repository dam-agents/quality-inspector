#!/usr/bin/env bash
# scenarios.sh — bookkeeping for scenarios (docs/scenarios.md). Local only: no external
# calls; its writes are a scenario's empty directory, its work/SCENARIOS.md row and event lines.
#
#   scenarios.sh new <slack|operator|discovery|dashboard>  reserve the next id: creates
#                                                 work/scenarios/S-<k>/ under the row lock (two
#                                                 turns at once never share an id), logs
#                                                 `scenario_new`, prints S-<k>
#   scenarios.sh adopt <slug>                     the profile's scenarios/<slug>.md as P-<slug>:
#                                                 creates work/scenarios/P-<slug>/, copies the
#                                                 file byte for byte to source-<spec_hash>.md
#                                                 (kept when it exists), logs `scenario_adopt`,
#                                                 prints {"id","slug","spec_hash","source",
#                                                 "previous_spec_hash"} — the previous from the row
#   scenarios.sh admit                            {"runs_today":n,"cap":m,"admit":bool,
#                                                  "env":{"busy":bool,"holder":…,"since":…}}
#   scenarios.sh lint <request.md>                {"injection":{…},"injection_suspect":bool} —
#                                                 the issues' injection lint (lib/scan-issues.mjs)
#   scenarios.sh set <id> [<column>=<value>…]     (S-<k> or P-<slug>) the one writer of a work/SCENARIOS.md row: a
#                                                 locked read-modify-write (Slack turns and runs
#                                                 write at once), updated_utc = now, prints the
#                                                 row. A new row needs source= and status=. A
#                                                 scenario is never verified: verdict= takes
#                                                 only the scenario verdicts. status=in_progress
#                                                 from another status, or over a claim older than
#                                                 lock_ttl_min, logs `scenario_run`.
#
# `admit` counts today's `scenario_run` events against `max_scenarios_per_day`: runs that
# took the environment, from Slack and discovery alike. `env.busy` is a lock held by anyone
# (lib/lock.sh: live, or held) — the caller's own scenario never holds it yet.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/state.sh" || { echo "cannot source lib/state.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/lock.sh" || { echo "cannot source lib/lock.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/profile.sh" || { echo "cannot source lib/profile.sh" >&2; exit 1; }
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi
export LOG_JOB="${LOG_JOB:-scenario}"

iso2epoch() { date -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }

cmd_new() {
  case "${1:-}" in (slack|operator|discovery|dashboard) ;; (*) echo "usage: $0 new <slack|operator|discovery|dashboard>" >&2; exit 2;; esac
  mkdir -p "$WORK/scenarios" || exit 1
  local k
  row_lock
  k="$(ls -1 "$WORK/scenarios" 2>/dev/null | sed -n 's/^S-\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1)"
  k=$(( ${k:-0} + 1 ))
  mkdir "$WORK/scenarios/S-$k" || exit 1
  logev info scenario_new "id=S-$k source=$1"
  echo "S-$k"
}

# row_lock: one writer of work/scenarios/ and work/SCENARIOS.md at a time (lib/lock.sh
# lock_mutex, up to 10 s; a lock older than a minute belongs to a writer that died), held
# until the script exits.
row_lock() {
  local lk="$WORK/scenarios/.lock"
  lock_mutex "$lk" 100 || { echo "scenarios: work/SCENARIOS.md stays locked ($lk)" >&2; exit 1; }
  ROW_LOCK="$lk"; trap 'rm -f "$ROW_LOCK" 2>/dev/null' EXIT
}

# Columns of a row, in SCENARIOS_HEADER order, and the values each one takes.
SOURCES="$SCEN_SOURCES"; STATUSES="$SCEN_STATUSES"; VERDICTS="$SCEN_VERDICTS"   # lib/state.sh
one_of() { case "|$2|" in (*"|$1|"*) return 0;; esac; return 1; }

# A scenario id: S-<k> (a request or a proposal), or P-<slug> (the profile's scenarios/<slug>.md).
valid_id() {
  case "$1" in
    (S-[0-9]*) case "${1#S-}" in (*[!0-9]*) return 1;; esac; return 0 ;;
    (P-*) printf '%s' "${1#P-}" | grep -qE '^[a-z0-9][a-z0-9-]{0,47}$' ;;
    (*) return 1 ;;
  esac
}

cmd_set() {
  local id="${1:-}" kv k v f="$WORK/SCENARIOS.md" tmp old row now ttl
  local c_source="" c_requester="" c_thread="" c_hash="" c_build="" c_verdict="" c_status=""
  valid_id "$id" || { echo "usage: $0 set <S-<k>|P-<slug>> [<column>=<value>…]" >&2; exit 2; }
  shift
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    [ "$k" != "$kv" ] && [ -n "$v" ] || { echo "scenarios: '$kv' is not <column>=<value>" >&2; exit 2; }
    case "$v" in (*[[:space:]]*|*'|'*|*'\'*) echo "scenarios: a $k value holds no space, '|' or '\\'" >&2; exit 2;; esac
    case "$k" in
      (source)  one_of "$v" "$SOURCES" || { echo "scenarios: source is $SOURCES" >&2; exit 2; }; c_source="$v" ;;
      (status)  one_of "$v" "$STATUSES" || { echo "scenarios: status is $STATUSES" >&2; exit 2; }; c_status="$v" ;;
      (verdict) one_of "$v" "$VERDICTS" || { echo "scenarios: verdict is $VERDICTS — a scenario is never verified" >&2; exit 2; }; c_verdict="$v" ;;
      (requester) c_requester="$v" ;;
      (thread)    c_thread="$v" ;;
      (spec_hash) c_hash="$v" ;;
      (build)     c_build="$v" ;;
      (*) echo "scenarios: unknown column '$k'" >&2; exit 2 ;;
    esac
  done
  mkdir -p "$WORK/scenarios" || exit 1
  row_lock
  [ -f "$f" ] || printf '# Scenarios — one row per scenario (docs/scenarios.md → State)\n\n%s\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n' "$SCENARIOS_HEADER" > "$f"
  old="$(table_rows "$f" | awk -F'|' -v id="$id" '{x=$2; gsub(/[ \t]/,"",x)} x==id {print; exit}')"
  if [ -z "$old" ] && { [ -z "$c_source" ] || [ -z "$c_status" ]; }; then
    echo "scenarios: $id has no row yet — its first write names source= and status=" >&2; exit 2
  fi
  pick() { if [ -n "$1" ]; then printf '%s' "$1"; elif [ -n "$old" ]; then cell "$old" "$2"; else printf -- '-'; fi; }
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  c_source="$(pick "$c_source" 2)"; c_requester="$(pick "$c_requester" 3)"; c_thread="$(pick "$c_thread" 4)"
  c_hash="$(pick "$c_hash" 5)"; c_build="$(pick "$c_build" 6)"; c_verdict="$(pick "$c_verdict" 7)"
  local want="$c_status" was="" since=""
  [ -n "$old" ] && { was="$(cell "$old" 8)"; since="$(cell "$old" 9)"; }
  c_status="$(pick "$c_status" 8)"
  row="| $id | $c_source | $c_requester | $c_thread | $c_hash | $c_build | $c_verdict | $c_status | $now |"
  tmp="$(mktemp "$WORK/.SCENARIOS.md.XXXXXX")" || exit 1
  awk -v id="$id" -v row="$row" '
    { L[NR] = $0
      if ($0 ~ /^\|/) { last = NR; t++
        if (t > 2) { split($0, c, "|"); k = c[2]; gsub(/[ \t]/, "", k); if (k == id) hit[NR] = 1 } } }
    END { done = 0
      for (i = 1; i <= NR; i++) {
        if (i in hit) { if (!done) { print row; done = 1 }; continue }
        print L[i]
        if (i == last && !done) { print row; done = 1 } } }' "$f" > "$tmp" && mv -f "$tmp" "$f" \
    || { rm -f "$tmp"; echo "scenarios: cannot rewrite work/SCENARIOS.md" >&2; exit 1; }
  # A claim takes the environment: what max_scenarios_per_day counts (scripts/lib/state.sh).
  # A bare `set S-<k>` only refreshes updated_utc and claims nothing.
  if [ "$want" = in_progress ]; then
    ttl="$(cfg lock_ttl_min)"; case "$ttl" in (''|*[!0-9]*) ttl=180;; esac
    if [ "$was" != in_progress ] || [ $(( ($(date -u +%s) - $(iso2epoch "$since")) / 60 )) -ge "$ttl" ]; then
      logev info scenario_run "id=$id build=$c_build"
    fi
  fi
  printf '%s\n' "$row"
}

cmd_admit() {
  local cap runs ttl state held ts sess busy=false
  cap="$(cfg max_scenarios_per_day)"; case "$cap" in (''|*[!0-9]*) cap=10;; esac
  ttl="$(cfg lock_ttl_min)"; case "$ttl" in (''|*[!0-9]*) ttl=180;; esac
  runs="$(scenario_runs_today)"
  read -r state held ts sess <<<"$(lock_state "$WORK/env/LOCK" "$ttl")"
  case "$state" in (live|held) busy=true;; esac
  jq -nc --argjson r "${runs:-0}" --argjson c "$cap" --argjson b "$busy" --arg h "$held" --arg s "$ts" \
    '{runs_today:$r, cap:$c, admit:($r < $c),
      env:{busy:$b, holder:(if $b then $h else null end), since:(if $b then $s else null end)}}'
}

# The same sentences that make an issue an injection suspect make a request one; one list,
# in lib/scan-issues.mjs (docs/acceptance-criteria.md → Injection suspects).
cmd_lint() {
  [ -f "${1:-}" ] || { echo "usage: $0 lint <request.md>" >&2; exit 2; }
  # The module path is an argument, never source text. The request stays argv[1]:
  # scan-issues.mjs runs its own CLI when argv[1] is its own path.
  node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import { pathToFileURL } from 'node:url';
    const { injectionLint } = await import(pathToFileURL(process.argv[2]).href);
    console.log(JSON.stringify(injectionLint(readFileSync(process.argv[1], 'utf8'))));" "$1" "$SCRIPT_DIR/lib/scan-issues.mjs"
}

# The verbatim text of a profile scenario, kept per spec_hash next to the criteria the agent
# freezes from it (docs/scenarios.md → Profile scenarios). Local only: the profile is the
# skill already on disk.
cmd_adopt() {
  local slug="${1:-}" line h src dir prev row
  printf '%s' "$slug" | grep -qE '^[a-z0-9][a-z0-9-]{0,47}$' || { echo "usage: $0 adopt <slug>" >&2; exit 2; }
  line="$(profile_scenarios 2>/dev/null | awk -F'\t' -v s="$slug" '$1 == s {print; exit}')"
  [ -n "$line" ] || { echo "scenarios: the profile has no scenarios/$slug.md" >&2; exit 1; }
  h="$(printf '%s' "$line" | cut -f2)"; src="$(printf '%s' "$line" | cut -f3)"
  dir="$WORK/scenarios/P-$slug"
  mkdir -p "$dir" || exit 1
  [ -f "$dir/source-$h.md" ] || cp "$src" "$dir/source-$h.md" || { echo "scenarios: cannot copy $src" >&2; exit 1; }
  row="$(table_rows "$WORK/SCENARIOS.md" | awk -F'|' -v id="P-$slug" '{x=$2; gsub(/[ \t]/,"",x)} x==id {print; exit}')"
  prev="-"; [ -n "$row" ] && prev="$(cell "$row" 5)"
  logev info scenario_adopt "id=P-$slug spec=$h"
  jq -nc --arg id "P-$slug" --arg s "$slug" --arg h "$h" --arg src "scenarios/P-$slug/source-$h.md" --arg p "$prev" \
    '{id:$id, slug:$s, spec_hash:$h, source:$src, previous_spec_hash:(if $p == "-" then null else $p end)}'
}

case "${1:-}" in
  new)   cmd_new "${2:-}" ;;
  adopt) cmd_adopt "${2:-}" ;;
  admit) cmd_admit ;;
  lint)  cmd_lint "${2:-}" ;;
  set)   shift; cmd_set "$@" ;;
  *) echo "usage: $0 new <slack|operator|discovery|dashboard> | adopt <slug> | admit | lint <file> | set <S-<k>|P-<slug>> [<column>=<value>…]" >&2; exit 2 ;;
esac
