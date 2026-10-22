#!/usr/bin/env bash
# modules.sh — the testing modules (docs/modules.md): their state, which are due, and the one
# writer of their settings. Local only: no external calls; its writes are work/CONFIG.md
# bullets of the registry's keys, work/FOCUS.md, work/MODULES.log, work/schedules.json and
# event lines.
#
#   modules.sh status                      {"modules":[{id,title,kind,what,doc,state,schedule,
#                                           last_run,settings:{<key>:{value,default,type,…}}}],
#                                           "global":{…}, "focus":[…], "schedules_as_of"} —
#                                           what the dashboard shows
#   modules.sh due [<candidate>]           {"on":[<id>…], "due":[<id>…], "previous":{<id>:
#                                           <candidate>|null}, "focus":[<area>…]} — the `modules`
#                                           run's worklist; without a candidate nothing is due
#   modules.sh set <id|global> <key>=<value>…
#                                          write each key of that module (or `global`) to
#                                          work/CONFIG.md; refuses a key outside the module, a
#                                          value outside its type, every write when one is bad
#   modules.sh focus <area>                queue an area for the next modules run
#   modules.sh focus-done <area> <build>   mark the queued area done (exit 2 when none is queued)
#   modules.sh dismiss D-<k>               the operator's "not a defect": a row in
#                                          work/design/DISMISSED.md (docs/ui-sweep.md)
#   modules.sh value <key>                 a registry key's effective value: the CONFIG.md bullet
#                                          when it fits its type, else the default — what a script
#                                          that runs a module reads
#   modules.sh ran <id> <candidate> [k=v…] append `<ISO> ran module=<id> candidate=<c> k=v…`
#                                          to work/MODULES.log (what `due` keys on)
#   modules.sh check                       [{key, value, ok, allowed}] for every registry key set
#                                          in CONFIG.md — what verify-onboarding.sh judges
#   modules.sh schedules <file|->          keep name, enabled and cron of each listed schedule
#                                          (the platform's list_schedules answer) in
#                                          work/schedules.json, with the time it was taken
#
# The registry (lib/modules.json) is the closed set: a key it does not name, or a value
# outside its type, is never written. `set`, `focus` and `dismiss` are the operator's word: they run in
# the direct session only (lib/config.sh → direct_session) — never in a scheduled turn, a
# Slack turn or a dashboard viewer's turn. Exit 2 = refused input, 1 = failed write.

set -u
export LC_ALL=C
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REG="$SCRIPT_DIR/lib/modules.json"
. "$SCRIPT_DIR/lib/config.sh" || exit 1
. "$SCRIPT_DIR/lib/state.sh" || exit 1
. "$SCRIPT_DIR/log.sh" 2>/dev/null || logev() { :; }
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_EPOCH="$(date -u +%s)"
WEEK_S=$((7 * 86400))

die() { printf '%s\n' "$2" >&2; exit "$1"; }
iso2epoch() { date -d "$1" +%s 2>/dev/null || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }
[ -r "$REG" ] || die 1 "modules.sh: $REG missing"

# The settings of one module (or `global`) as {key: spec}.
specs() { if [ "$1" = global ]; then jq -c '.global' "$REG"; else jq -c --arg id "$1" '.modules[] | select(.id == $id) | .settings' "$REG"; fi; }

# valid <spec-json> <value> -> exit 0 when the value fits the type.
valid() {
  local t v="$2"; t="$(jq -r .type <<<"$1")"
  case "$t" in
    enum) jq -e --arg v "$v" '.values | index($v) != null' <<<"$1" >/dev/null ;;
    cadence) jq -e --arg v "$v" '.cadences | index($v) != null' "$REG" >/dev/null ;;
    int) case "$v" in (''|*[!0-9]*) return 1;; esac
         [ "${#v}" -le 6 ] && jq -e --argjson v "$v" '$v >= .min and $v <= .max' <<<"$1" >/dev/null ;;
    viewports) [[ "$v" =~ ^[0-9]{3,4}x[0-9]{3,4}(,[0-9]{3,4}x[0-9]{3,4}){0,3}$ ]] || return 1
         local p w h
         for p in ${v//,/ }; do w="${p%x*}"; h="${p#*x}"
           [ "$w" -ge 320 ] && [ "$w" -le 3840 ] && [ "$h" -ge 480 ] && [ "$h" -le 2400 ] || return 1; done ;;
    *) return 1 ;;
  esac
}

# The effective value: the CONFIG.md bullet when it fits the type, else the default.
value_of() { # <key> <spec-json>
  local v; v="$(cfg "$1")"
  if [ -n "$v" ] && valid "$2" "$v"; then printf '%s' "$v"; else jq -r '.default' <<<"$2"; fi
}

# The last finished run in a module's log: {utc, candidate|null}, or null.
last_run() { # <id> <log|null> <ran-marker>
  local line f="$WORK/$2.log"
  [ "$2" = null ] && { echo null; return; }
  if [ "$2" = MODULES ]; then line="$(grep -- " ran module=$1 " "$f" 2>/dev/null | tail -1)"
  else line="$(grep -- "$3" "$f" 2>/dev/null | grep -v ' ERROR: ' | tail -1)"; fi
  [ -n "$line" ] || { echo null; return; }
  jq -nc --arg u "${line%% *}" --arg c "$(printf '%s' "$line" | grep -o 'candidate=[^ ]*' | head -1 | cut -d= -f2)" \
    '{utc:$u, candidate:(if $c == "" then null else $c end)}'
}

focus_rows() { table_rows "$WORK/FOCUS.md"; }

cmd_status() {
  local out='[]' id kind log ran sw specs_j settings key spec val raw state sched last
  local schedules='{}' as_of=null
  [ -r "$WORK/schedules.json" ] && schedules="$(jq -c '.schedules // {}' "$WORK/schedules.json" 2>/dev/null || echo '{}')" \
    && as_of="$(jq -c '.taken_utc // null' "$WORK/schedules.json" 2>/dev/null || echo null)"
  while IFS=$'\x1f' read -r id kind log ran sw; do   # not a tab: empty fields would collapse
    specs_j="$(specs "$id")"; settings='{}'
    for key in $(jq -r 'keys_unsorted[]' <<<"$specs_j"); do
      spec="$(jq -c --arg k "$key" '.[$k]' <<<"$specs_j")"; val="$(value_of "$key" "$spec")"; raw="$(cfg "$key")"
      # A bullet outside its type reads as the default here; `raw` shows what CONFIG.md says (verify-onboarding fails it).
      settings="$(jq -c --arg k "$key" --arg v "$val" --arg r "$raw" --argjson s "$spec" \
        '. + {($k): ($s + {value: $v} + (if $r != "" and $r != $v then {raw: $r, invalid: true} else {} end))}' <<<"$settings")"
    done
    sched="$(jq -c --arg id "$id" --argjson s "$schedules" '.modules[] | select(.id == $id) | .schedule as $n
      | if $n == null then null else {name:$n} + ($s[$n] // {enabled:null, cron:null}) end' "$REG")"
    # on/off: the switch key's value; a scheduled module is off while its schedule is.
    state="on"
    [ -n "$sw" ] && state="$(jq -r --arg k "$sw" '.[$k].value' <<<"$settings")"
    if [ "$kind" = schedule ]; then case "$(jq -r '.enabled' <<<"$sched")" in (false) state="off";; (null) state="unknown";; esac; fi
    last="$(last_run "$id" "$log" "${ran:- ran }")"
    out="$(jq -c --arg id "$id" --arg st "$state" --argjson set "$settings" --argjson sc "$sched" --argjson lr "$last" \
      --argjson m "$(jq -c --arg id "$id" '.modules[] | select(.id == $id) | {id,title,kind,what,doc}' "$REG")" \
      '. + [$m + {state:$st, schedule:$sc, last_run:$lr, settings:$set}]' <<<"$out")"
  done < <(jq -r '.modules[] | [.id, .kind, (.log // "null"), (.ran // ""), (.switch // "")] | join("\u001f")' "$REG")
  local g='{}' gs; gs="$(specs global)"
  for key in $(jq -r 'keys_unsorted[]' <<<"$gs"); do
    spec="$(jq -c --arg k "$key" '.[$k]' <<<"$gs")"
    g="$(jq -c --arg k "$key" --arg v "$(value_of "$key" "$spec")" --argjson s "$spec" '. + {($k): ($s + {value:$v})}' <<<"$g")"
  done
  local focus; focus="$(focus_rows | while IFS= read -r r; do
      jq -nc --arg a "$(cell "$r" 1)" --arg q "$(cell "$r" 2)" --arg s "$(cell "$r" 3)" --arg b "$(cell "$r" 4)" \
        '{area:$a, queued_utc:$q, status:$s, build:(if $b == "-" or $b == "" then null else $b end)}'; done | jq -sc .)"
  jq -nc --argjson m "$out" --argjson g "$g" --argjson f "${focus:-[]}" --argjson a "$as_of" --arg now "$NOW_ISO" \
    --argjson c "$(jq -c .cadences "$REG")" \
    '{schema:"qi-modules-status/v1", generated_utc:$now, cadences:$c, modules:$m, global:$g, focus:$f, schedules_as_of:$a}'
}

cmd_due() {
  local cand="${1:-}" due='[]' on='[]' prev='{}' id key cadence line last lc le
  while IFS=$'\t' read -r id key; do
    cadence="$(value_of "$key" "$(specs "$id" | jq -c --arg k "$key" '.[$k]')")"
    [ "$cadence" = disabled ] || on="$(jq -c --arg id "$id" '. + [$id]' <<<"$on")"
    [ -n "$cand" ] || continue
    line="$(grep -- " ran module=$id " "$WORK/MODULES.log" 2>/dev/null | tail -1)"
    lc="$(printf '%s' "$line" | grep -o 'candidate=[^ ]*' | head -1 | cut -d= -f2)"
    prev="$(jq -c --arg id "$id" --arg c "$lc" '. + {($id): (if $c == "" then null else $c end)}' <<<"$prev")"
    case "$cadence" in
      per-build) [ "$lc" != "$cand" ] && due="$(jq -c --arg id "$id" '. + [$id]' <<<"$due")" ;;
      weekly) le="$(iso2epoch "${line%% *}")"
              if [ "$lc" != "$cand" ] && { [ -z "$line" ] || [ $((NOW_EPOCH - le)) -ge "$WEEK_S" ]; }; then
                due="$(jq -c --arg id "$id" '. + [$id]' <<<"$due")"; fi ;;
    esac
  done < <(jq -r '.modules[] | select(.kind == "modules") | [.id, .switch] | @tsv' "$REG")
  local focus; focus="$(focus_rows | while IFS= read -r r; do [ "$(cell "$r" 3)" = queued ] && cell "$r" 1; done | jq -R . | jq -sc .)"
  jq -nc --argjson d "$due" --argjson o "$on" --argjson p "$prev" --argjson f "${focus:-[]}" '{on:$o, due:$d, previous:$p, focus:$f}'
}

# set_bullet <key> <value>: replace the first `- <key>:` bullet, else append one.
set_bullet() {
  local tmp="$CONFIG.tmp.$$"
  if grep -q "^- $1:" "$CONFIG"; then
    awk -v k="- $1:" -v line="- $1: $2" 'index($0, k) == 1 && !done { print line; done = 1; next } { print }' "$CONFIG" > "$tmp"
  else { cat "$CONFIG"; printf -- '- %s: %s\n' "$1" "$2"; } > "$tmp"; fi
  mv "$tmp" "$CONFIG"
}

operator_only() { direct_session || die 2 "modules.sh: $1 is the operator's, in the direct session only ($WHY_NOT_DIRECT)"; }

cmd_set() {
  local id="${1:-}" s pair key val spec old changes='[]'
  operator_only set
  [ -n "$id" ] && [ $# -ge 2 ] || die 2 "usage: modules.sh set <id|global> <key>=<value>…"
  [ -f "$CONFIG" ] || die 2 "modules.sh: $CONFIG missing — onboard first"
  s="$(specs "$id")"; [ -n "$s" ] && [ "$s" != null ] || die 2 "modules.sh: unknown module '$id'"
  shift
  for pair in "$@"; do   # validate every pair before writing any
    key="${pair%%=*}"; val="${pair#*=}"
    [ "$key" != "$pair" ] || die 2 "modules.sh: '$pair' is not <key>=<value>"
    case "$val" in (*$'\n'*|*$'\r'*|*'|'*|*'#'*) die 2 "modules.sh: a value is one plain word";; esac
    spec="$(jq -c --arg k "$key" '.[$k] // empty' <<<"$s")"
    [ -n "$spec" ] || die 2 "modules.sh: '$key' is not a setting of '$id'"
    valid "$spec" "$val" || die 2 "modules.sh: '$val' is not a valid $key ($(jq -c 'del(.default)' <<<"$spec"))"
  done
  for pair in "$@"; do
    key="${pair%%=*}"; val="${pair#*=}"; old="$(cfg "$key")"
    set_bullet "$key" "$val" || die 1 "modules.sh: cannot write $CONFIG"
    logev info module_set "module=$id key=$key old=${old:--} new=$val"
    changes="$(jq -c --arg k "$key" --arg o "$old" --arg v "$val" '. + [{key:$k, old:(if $o == "" then null else $o end), new:$v}]' <<<"$changes")"
  done
  jq -nc --arg id "$id" --argjson c "$changes" '{module:$id, set:$c}'
}

FOCUS_RE='^[A-Za-z0-9][A-Za-z0-9 _./-]{0,39}$'
cmd_focus() {
  local area="${1:-}"
  operator_only focus
  [[ "$area" =~ $FOCUS_RE ]] || die 2 "modules.sh: '$area' is not an area name"
  [ -f "$WORK/FOCUS.md" ] || printf '%s\n|%s\n' "$FOCUS_HEADER" " --- | --- | --- | --- |" > "$WORK/FOCUS.md"
  if focus_rows | while IFS= read -r r; do [ "$(cell "$r" 1)" = "$area" ] && [ "$(cell "$r" 3)" = queued ] && exit 3; done; [ $? = 3 ]; then
    jq -nc --arg a "$area" '{area:$a, queued:false, reason:"already queued"}'; return
  fi
  printf '| %s | %s | queued | - |\n' "$area" "$NOW_ISO" >> "$WORK/FOCUS.md" || die 1 "modules.sh: cannot write FOCUS.md"
  logev info module_set "module=feature-focus key=focus old=- new=$area"
  jq -nc --arg a "$area" '{area:$a, queued:true}'
}

cmd_focus_done() {
  local area="${1:-}" build="${2:-}" tmp="$WORK/FOCUS.md.tmp.$$"
  [ -n "$area" ] && [ -n "$build" ] || die 2 "usage: modules.sh focus-done <area> <build>"
  [ -f "$WORK/FOCUS.md" ] || die 2 "modules.sh: no FOCUS.md"
  awk -F'|' -v a="$area" -v b="$build" 'BEGIN{OFS="|"} { x=$2; gsub(/^[ \t]+|[ \t]+$/,"",x); s=$4; gsub(/^[ \t]+|[ \t]+$/,"",s) }
    !done && NR > 2 && x == a && s == "queued" { $4=" done "; $5=" " b " "; done=1 } { print } END { exit !done }' "$WORK/FOCUS.md" > "$tmp" \
    || { rm -f "$tmp"; die 2 "modules.sh: no queued focus on '$area'"; }
  mv "$tmp" "$WORK/FOCUS.md" || die 1 "modules.sh: cannot write FOCUS.md"
  jq -nc --arg a "$area" --arg b "$build" '{area:$a, done:$b}'
}

cmd_ran() {
  local id="${1:-}" cand="${2:-}" kv
  jq -e --arg id "$id" '.modules[] | select(.id == $id and (.kind == "modules" or .kind == "queue"))' "$REG" >/dev/null \
    || die 2 "modules.sh: '$id' is not a module of the modules run"
  [ -n "$cand" ] || die 2 "usage: modules.sh ran <id> <candidate> [k=v…]"
  shift 2
  for kv in "$@"; do [[ "$kv" =~ ^[a-z_]+=[A-Za-z0-9._-]+$ ]] || die 2 "modules.sh: '$kv' is not k=v"; done
  printf '%s ran module=%s candidate=%s%s\n' "$NOW_ISO" "$id" "$cand" "${*:+ $*}" >> "$WORK/MODULES.log" || die 1 "cannot write MODULES.log"
}

spec_of() { jq -c --arg k "$1" '[.global, (.modules[].settings)] | add | .[$k] // empty' "$REG"; }

cmd_value() {
  local spec; spec="$(spec_of "${1:-}")"
  [ -n "$spec" ] || die 2 "modules.sh: '${1:-}' is not a registry key"
  value_of "$1" "$spec"; echo
}

cmd_dismiss() {
  local id="${1:-}" f="$WORK/design/DISMISSED.md"
  operator_only dismiss
  [[ "$id" =~ ^D-[0-9]{1,6}$ ]] || die 2 "modules.sh: '$id' is not a design finding id (D-<k>)"
  mkdir -p "$WORK/design" || die 1 "modules.sh: cannot create work/design"
  [ -f "$f" ] || printf '%s\n| --- | --- |\n' "$DISMISSED_HEADER" > "$f" || die 1 "modules.sh: cannot write $f"
  if table_rows "$f" | while IFS= read -r r; do [ "$(cell "$r" 1)" = "$id" ] && exit 3; done; [ $? = 3 ]; then
    jq -nc --arg id "$id" '{id:$id, dismissed:false, reason:"already dismissed"}'; return
  fi
  printf '| %s | %s |\n' "$id" "$NOW_ISO" >> "$f" || die 1 "modules.sh: cannot write $f"
  logev info module_set "module=ui-sweep key=dismiss old=- new=$id"
  jq -nc --arg id "$id" '{id:$id, dismissed:true}'
}

cmd_check() {
  local out='[]' key spec v
  while IFS= read -r key; do
    spec="$(spec_of "$key")"
    v="$(cfg "$key")"; [ -n "$v" ] || continue
    out="$(jq -c --arg k "$key" --arg v "$v" --argjson ok "$(valid "$spec" "$v" && echo true || echo false)" --argjson s "$spec" \
      --argjson c "$(jq -c .cadences "$REG")" \
      '. + [{key:$k, value:$v, ok:$ok, allowed:(if $s.type == "cadence" then ($c | join(" ")) elif $s.type == "enum" then ($s.values | join(" "))
        elif $s.type == "int" then "\($s.min)..\($s.max)" else "up to 4 WxH, comma-separated" end)}]' <<<"$out")"
  done < <(jq -r '[.global, (.modules[].settings)] | add | keys_unsorted[]' "$REG")
  printf '%s\n' "$out"
}

cmd_schedules() {
  local src="${1:--}" in
  in="$(cat -- "$src" 2>/dev/null)" || die 2 "modules.sh: cannot read $src"
  jq -ce --arg now "$NOW_ISO" '(if type == "array" then . else (.schedules // .items // []) end)
      | map(select(type == "object" and (.name | type) == "string")
            | {key: .name, value: {enabled: (if .enabled == null then null else (.enabled == true) end),
                                   cron: ((.cron // .schedule // null) | if type == "string" then . else null end)}})
      | {taken_utc: $now, schedules: from_entries}' <<<"$in" > "$WORK/schedules.json.tmp" \
    || { rm -f "$WORK/schedules.json.tmp"; die 2 "modules.sh: not a schedule listing"; }
  mv "$WORK/schedules.json.tmp" "$WORK/schedules.json" && jq -c '{taken_utc, schedules: (.schedules | length)}' "$WORK/schedules.json"
}

case "${1:-}" in
  status) cmd_status ;;
  due) shift; cmd_due "$@" ;;
  set) shift; cmd_set "$@" ;;
  focus) shift; cmd_focus "$@" ;;
  focus-done) shift; cmd_focus_done "$@" ;;
  ran) shift; cmd_ran "$@" ;;
  check) cmd_check ;;
  value) shift; cmd_value "$@" ;;
  dismiss) shift; cmd_dismiss "$@" ;;
  schedules) shift; cmd_schedules "$@" ;;
  *) die 2 "usage: modules.sh status | due [<candidate>] | set <id|global> <key>=<value>… | focus <area> | focus-done <area> <build> | dismiss D-<k> | value <key> | ran <id> <candidate> [k=v…] | check | schedules <file|->" ;;
esac
