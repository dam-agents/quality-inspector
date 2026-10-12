#!/usr/bin/env bash
# preflight.sh — deterministic pre-flight for quality-inspector.
#
# The script DETECTS, it NEVER ACTS:
#
#   - NO external writes at all (list/GET calls only),
#   - NO git commit/push,
#   - local writes only: one line per call in work/<RUNTYPE>.log, the audit-mode
#     log retention sweep.
#
#   preflight.sh <mode>   -> one JSON object on stdout; everything else to stderr.
#   .nothing_to_do == true  -> the agent ends the run immediately.
#   otherwise               -> the agent processes the arrays per CLAUDE.md + docs/.
#
# Modes: issues (default) | regression | audit.
# Requires: bash, jq, gh, curl, sed/grep/awk, GNU date (Linux pod).

set -u
export LC_ALL=C

MODE="${1:-issues}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

LOGS=()
log() { LOGS+=("$1"); }
logs_json() { printf '%s\n' "${LOGS[@]:-}" | jq -R . | jq -sc '[.[] | select(length>0)]'; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/state.sh" || { echo "cannot source lib/state.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/charts.sh" || { echo "cannot source lib/charts.sh" >&2; exit 1; }

iso2epoch() { date -d "$1" +%s 2>/dev/null \
              || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- config ----
TARGET="${QI_TARGET_REPO:-$(cfg target_repo)}"
QA_LABEL="$(cfg qa_label)"; QA_LABEL="${QA_LABEL:-qa:ready}"
RETEST_LABEL="$(cfg retest_label)"; RETEST_LABEL="${RETEST_LABEL:-qa:retest}"
CHART_REF="$(cfg chart_ref)"; CHART_REF="${CHART_REF:-oci://quay.io/dam-agents/charts/platform}"
CAND_CH="$(cfg candidate_channel)"; CAND_CH="${CAND_CH:-main}"
BASE_CH="$(cfg baseline_channel)"; BASE_CH="${BASE_CH:-release}"
MAX_ISSUES="$(cfg max_issues_per_run)"; MAX_ISSUES="${MAX_ISSUES:-1}"
LOCK_TTL_MIN="$(cfg lock_ttl_min)"; LOCK_TTL_MIN="${LOCK_TTL_MIN:-180}"
case "$MAX_ISSUES" in (''|*[!0-9]*) MAX_ISSUES=1;; esac
case "$LOCK_TTL_MIN" in (''|*[!0-9]*) LOCK_TTL_MIN=180;; esac

# A [host/]owner/repo ref: the host part only when it has three segments.
GH_HOST_ARGS=(); REPO_PATH="$TARGET"
if [ "$(printf '%s' "$TARGET" | tr -cd '/' | wc -c | tr -d ' ')" = 2 ]; then
  GH_HOST_ARGS=(--hostname "${TARGET%%/*}"); REPO_PATH="${TARGET#*/}"
fi

runlog() { mkdir -p "$WORK" 2>/dev/null && printf '%s %s\n' "$NOW_ISO" "$2" >> "$WORK/$1.log" 2>/dev/null || true; }

fail_out() {  # nothing-to-do JSON with an error; the agent just logs it
  runlog "$(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')" "ERROR: $1"
  jq -nc --arg mode "$MODE" --arg err "$1" --argjson logs "$(logs_json)" \
    '{mode:$mode, nothing_to_do:true, error:$err, logs:$logs}'
  exit 0
}

# The nested environment serves one run at a time (scripts/env.sh lock). A live
# holder makes this occurrence idle; a lock past the TTL is the holder's to take over.
env_busy_out() {
  local held ts
  [ -f "$WORK/env/LOCK" ] || return 0
  read -r held ts < "$WORK/env/LOCK" 2>/dev/null || return 0
  [ $(( (NOW_EPOCH - $(iso2epoch "$ts")) / 60 )) -ge "$LOCK_TTL_MIN" ] && return 0
  log "nested environment busy (held by $held since $ts) — next occurrence"
  runlog "$1" "busy holder=$held"
  jq -nc --arg mode "$MODE" --argjson logs "$(logs_json)" '{mode:$mode, nothing_to_do:true, logs:$logs}'
  exit 0
}

# Newest events-log timestamp mentioning `issue=<n>`, as epoch; 0 when none.
last_event_epoch() {
  local f ts
  ts="$(for f in "$WORK"/logs/events-*.jsonl; do [ -f "$f" ] && echo "$f"; done | sort | tail -2 \
        | xargs -r cat 2>/dev/null \
        | jq -r --arg re "issue=$1( |$)" 'select(.msg | test($re)) | .ts' 2>/dev/null | sort | tail -1)"
  [ -n "$ts" ] && iso2epoch "$ts" || echo 0
}

# ============================================================ ISSUES MODE ====
mode_issues() {
  [ -n "$TARGET" ] || fail_out "target_repo is not configured (work/CONFIG.md or QI_TARGET_REPO)"
  env_busy_out ISSUES

  local versions candidate baseline
  versions="$(chart_versions "$CHART_REF" "$CAND_CH" "$BASE_CH" 2>/tmp/quality-inspector-pf-err.$$)" \
    || { local e; e="$(cat /tmp/quality-inspector-pf-err.$$ 2>/dev/null)"; rm -f /tmp/quality-inspector-pf-err.$$; fail_out "cannot resolve chart versions: $e"; }
  rm -f /tmp/quality-inspector-pf-err.$$
  candidate="$(printf '%s' "$versions" | jq -r .candidate)"
  baseline="$(printf '%s' "$versions" | jq -r '.baseline // empty')"

  local listing
  listing="$(gh api ${GH_HOST_ARGS[@]+"${GH_HOST_ARGS[@]}"} -X GET "repos/$REPO_PATH/issues" \
      -f labels="$QA_LABEL" -f state=all -f per_page=100 2>/dev/null)" \
    || fail_out "issue listing failed for the target repository"
  printf '%s' "$listing" | jq -e 'type == "array"' >/dev/null 2>&1 \
    || fail_out "issue listing returned no array"

  local due='[]' reports='[]' deferred=0 n=0 row
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    local num title body hash retest kind="" takeover=false dw=false
    num="$(printf '%s' "$item" | jq -r .number)"
    title="$(printf '%s' "$item" | jq -r '.title // ""')"
    body="$(printf '%s' "$item" | jq -r '.body // ""')"
    retest="$(printf '%s' "$item" | jq -r --arg l "$RETEST_LABEL" '[.labels[]?.name] | index($l) != null')"
    hash="$(text_hash "$(issue_spec_text "$title" "$body")")"
    has_done_when "$body" && dw=true
    row="$(qa_row "$num")"
    if [ -z "$row" ]; then
      kind=first
    else
      local r_hash r_status r_upd age silent
      r_hash="$(cell "$row" 2)"; r_status="$(cell "$row" 6)"; r_upd="$(cell "$row" 7)"
      if [ "$r_status" = in_progress ]; then
        age=$(( (NOW_EPOCH - $(iso2epoch "$r_upd")) / 60 ))
        silent=$(( (NOW_EPOCH - $(last_event_epoch "$num")) / 60 ))
        if [ "$age" -ge "$LOCK_TTL_MIN" ] && [ "$silent" -ge 30 ]; then
          kind=takeover; takeover=true
          log "issue #$num: stale lock (${age}m old, ${silent}m silent) — takeover"
        else
          log "issue #$num: in progress (${age}m) — skip"; continue
        fi
      elif [ "$retest" = true ]; then kind=retest
      elif [ "$r_hash" != "$hash" ]; then kind=ac_changed
      elif [ "$r_status" = report_pending ]; then
        reports="$(printf '%s' "$reports" | jq -c --argjson i "$num" '. + [{issue:$i}]')"
        log "issue #$num: report pending delivery — due"; continue
      else
        log "issue #$num: done at ac=$hash — skip"; continue
      fi
    fi
    if [ "$n" -ge "$MAX_ISSUES" ]; then deferred=$((deferred+1)); log "issue #$num: $kind — deferred (max_issues_per_run)"; continue; fi
    n=$((n+1))
    due="$(printf '%s' "$due" | jq -c --argjson i "$num" --arg h "$hash" --arg k "$kind" \
          --argjson t "$takeover" --argjson d "$dw" --argjson r "$retest" \
          '. + [{issue:$i, ac_hash:$h, kind:$k, takeover:$t, has_done_when:$d, retest_label_present:$r}]')"
    log "issue #$num: $kind (ac=$hash) — due"
  done < <(printf '%s' "$listing" | jq -c 'map(select(.pull_request == null)) | sort_by(.number) | .[]')

  local count rc; count="$(printf '%s' "$due" | jq length)"; rc="$(printf '%s' "$reports" | jq length)"
  runlog ISSUES "candidate=$candidate baseline=${baseline:-none} due=$count reports=$rc deferred=$deferred"
  jq -nc --arg mode issues --arg c "$candidate" --arg b "$baseline" \
    --argjson due "$due" --argjson rep "$reports" --argjson logs "$(logs_json)" \
    '{mode:$mode, nothing_to_do:(($due|length)==0 and ($rep|length)==0),
      candidate:$c, baseline:(if $b=="" then null else $b end),
      issues_due:$due, reports_due:$rep, logs:$logs}'
}

# ======================================================== REGRESSION MODE ====
mode_regression() {
  local tests last versions candidate drift
  tests="$(table_rows "$WORK/SUITE.md" | awk -F'|' '{t=$2; tier=$4; gsub(/[ \t]/,"",t); gsub(/[ \t]/,"",tier)} tier=="regression" {print t}' \
           | jq -R . | jq -sc .)"
  if [ "$(printf '%s' "$tests" | jq length)" = 0 ]; then
    log "no regression-tier tests yet"; runlog REGRESSION "skip=no-tests"
    jq -nc --argjson logs "$(logs_json)" '{mode:"regression", nothing_to_do:true, logs:$logs}'; return
  fi
  env_busy_out REGRESSION
  versions="$(chart_versions "$CHART_REF" "$CAND_CH" none 2>/dev/null)" || fail_out "cannot resolve the candidate chart version"
  candidate="$(printf '%s' "$versions" | jq -r .candidate)"
  last="$(grep -o 'ran candidate=[^ ]*' "$WORK/REGRESSION.log" 2>/dev/null | tail -1 | cut -d= -f2)"
  if [ "$last" = "$candidate" ]; then
    log "candidate $candidate already regression-tested"; runlog REGRESSION "skip=same-candidate candidate=$candidate"
    jq -nc --arg c "$candidate" --argjson logs "$(logs_json)" '{mode:"regression", nothing_to_do:true, candidate:$c, logs:$logs}'; return
  fi
  drift="$(bash "$SCRIPT_DIR/check-asserts.sh" --json 2>/dev/null | jq -c '.drift // []' 2>/dev/null)" || drift='null'
  [ -n "$drift" ] || drift='null'
  [ "$drift" = null ] && log "WARN: assertion drift check could not run"
  log "candidate $candidate is new (last regression: ${last:-never}) — due"
  runlog REGRESSION "due candidate=$candidate tests=$(printf '%s' "$tests" | jq length)"
  jq -nc --arg c "$candidate" --arg p "$last" --argjson t "$tests" --argjson d "$drift" --argjson logs "$(logs_json)" \
    '{mode:"regression", nothing_to_do:false, candidate:$c, previous_candidate:(if $p=="" then null else $p end),
      tests:$t, assert_drift:$d, logs:$logs}'
}

# ============================================================= AUDIT MODE ====
# grep -c prints 0 AND exits 1 on no match; never let `|| echo 0` double it.
count_lines() { local n; n="$(grep -c -- "$1" "$2" 2>/dev/null)"; echo "${n:-0}"; }
CHECKS='[]'
check() { CHECKS="$(printf '%s' "$CHECKS" | jq -c --arg id "$1" --arg s "$2" --arg d "$3" '. + [{id:$id, status:$s, detail:$d}]')"; }

# 0 = the request succeeded (reachable), 1 = refused/failed, 2 = held (timed out).
probe_gh() { timeout 20 gh api ${GH_HOST_ARGS[@]+"${GH_HOST_ARGS[@]}"} "$1" >/dev/null 2>&1; case $? in (0) return 0;; (124) return 2;; (*) return 1;; esac; }
probe_url() { local c; c="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$1" 2>/dev/null)"
  case "$c" in (2??) return 0;; (000) return 2;; (*) return 1;; esac; }

mode_audit() {
  # connectivity & identity
  if gh api ${GH_HOST_ARGS[@]+"${GH_HOST_ARGS[@]}"} user --jq .login >/dev/null 2>&1; then check github_auth ok "token resolves an identity"
  else check github_auth fail "gh api user failed — the GitHub connection is not injected"; fi
  if [ -n "$TARGET" ]; then
    if probe_gh "repos/$REPO_PATH/issues?per_page=1"; then check issues_read ok "issues endpoint reachable"
    else check issues_read fail "cannot list issues of the target repository"; fi
    # black-box boundary: each of these must be refused (docs/black-box.md)
    local p r
    for p in "repos/$REPO_PATH/contents/" "repos/$REPO_PATH/pulls?per_page=1" "repos/$REPO_PATH/commits?per_page=1" "repos/$REPO_PATH/git/refs/heads"; do
      probe_gh "$p"; r=$?
      case $r in
        (0) check "boundary:${p%%\?*}" fail "source surface is reachable — add the deny rule (README → Black-box boundary)";;
        (2) check "boundary:${p%%\?*}" warn "request was held, not denied — make the rule an explicit deny";;
        (*) check "boundary:${p%%\?*}" ok "refused";;
      esac
    done
    probe_url "https://raw.githubusercontent.com/$REPO_PATH/HEAD/README.md"; r=$?
    case $r in (0) check boundary:raw fail "raw.githubusercontent.com serves the repository";; (2) check boundary:raw warn "raw host held, not denied";; (*) check boundary:raw ok "refused";; esac
  else
    check config_target fail "target_repo not configured"
  fi
  chart_versions "$CHART_REF" "$CAND_CH" "$BASE_CH" >/dev/null 2>&1 \
    && check registry ok "chart tags listable" || check registry fail "cannot list chart tags at $CHART_REF"

  # environment
  [ "$(id -u)" = 0 ] && check vm_root ok "running as root (vm backend)" || check vm_root fail "not root — the nested cluster needs the vm backend"
  command -v k3s >/dev/null 2>&1 && check k3s_binary ok "k3s present" || check k3s_binary fail "k3s missing from the image"
  local used; used="$(df -P "$HOME_DIR" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
  if [ -z "$used" ]; then check disk warn "not measured"
  elif [ "$used" -ge 85 ]; then check disk warn "home volume ${used}% used"
  else check disk ok "home volume ${used}% used"; fi
  [ -d "$WORK/.git" ] && check work_not_git fail "work/.git exists" || check work_not_git ok "work/ is a plain directory"
  local tmpd; tmpd="$(ls -d /tmp/quality-inspector-* 2>/dev/null | wc -l | tr -d ' ')"
  [ "$tmpd" = 0 ] && check tmp_leftovers ok "none" || check tmp_leftovers warn "$tmpd leftover /tmp/quality-inspector-* entries"

  # state consistency
  local stale=0 r_upd
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "$(cell "$row" 6)" = in_progress ] || continue
    r_upd="$(cell "$row" 7)"
    [ $(( (NOW_EPOCH - $(iso2epoch "$r_upd")) / 60 )) -ge "$LOCK_TTL_MIN" ] && stale=$((stale+1))
  done < <(table_rows "$WORK/QA.md")
  [ "$stale" = 0 ] && check stale_locks ok "none" || check stale_locks warn "$stale in_progress rows past the TTL"
  local drift; drift="$(bash "$SCRIPT_DIR/check-asserts.sh" --json 2>/dev/null | jq -c '.drift // []' 2>/dev/null)"
  if [ -z "$drift" ]; then check assert_drift warn "not measured"
  elif [ "$drift" = '[]' ]; then check assert_drift ok "regression assertions match their promoted hashes"
  else check assert_drift fail "assertion blocks changed without promotion: $drift"; fi

  # cadence: the issues pre-flight logs every call, declined ones included
  local last_iso; last_iso="$(tail -1 "$WORK/ISSUES.log" 2>/dev/null | cut -d' ' -f1)"
  if [ -z "$last_iso" ]; then check issues_cadence warn "ISSUES.log empty"
  elif [ $(( (NOW_EPOCH - $(iso2epoch "$last_iso")) / 3600 )) -ge 3 ]; then check issues_cadence warn "last issues pre-flight $last_iso"
  else check issues_cadence ok "last issues pre-flight $last_iso"; fi

  # definition
  [ -z "$(git -C "$HOME_DIR" status --porcelain 2>/dev/null)" ] && check definition_clean ok "clean" || check definition_clean warn "uncommitted definition changes"
  local v_co v_ad; v_co="$(head -1 "$HOME_DIR/VERSION" 2>/dev/null)"; v_ad="$(head -1 "$WORK/VERSION" 2>/dev/null)"
  [ "$v_co" = "${v_ad:-1.0.0}" ] && check version ok "$v_co adopted" || check version warn "checked out $v_co, adopted ${v_ad:-1.0.0}"

  # error signatures + retention
  local week_ago failures
  week_ago="$(date -u -d "@$((NOW_EPOCH - 7*86400))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r $((NOW_EPOCH - 7*86400)) +%Y-%m-%dT%H:%M:%SZ)"
  failures="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -sc --arg since "$week_ago" '
    [.[] | select(.level=="error" and .ts >= $since)
         | .sig = (.event + ": " + (.msg | gsub("[0-9]+"; "N") | .[0:120]))]
    | group_by(.sig) | map({signature: .[0].sig, count: length, first: (map(.ts)|min), last: (map(.ts)|max)})' 2>/dev/null)"
  [ -n "$failures" ] || failures='null'
  find "$WORK/logs" -name 'events-*.jsonl' -mtime +14 -delete 2>/dev/null || true
  # UI maps: the newest three builds; the newest is the next diff's starting point.
  ls -1dt "$WORK"/inventory/*/ 2>/dev/null | tail -n +4 | while read -r d; do rm -rf "$d"; done

  # stats
  local stats
  stats="$(table_rows "$WORK/QA.md" | awk -F'|' -v since="$week_ago" '{u=$8; v=$6; gsub(/[ \t]/,"",u); gsub(/[ \t]/,"",v)} u>=since {print v}' \
           | jq -R . | jq -sc 'group_by(.) | map({key:.[0], value:length}) | from_entries')"
  [ -n "$stats" ] || stats='{}'
  stats="$(jq -nc --argjson v "$stats" --arg runs "$(count_lines '' "$WORK/ISSUES.log")" \
    --arg reg "$(count_lines 'ran candidate=' "$WORK/REGRESSION.log")" \
    --arg heals "$(count_lines '^| 20' "$WORK/HEALS.md")" \
    '{verdicts_7d:$v, issues_preflights_total:($runs|tonumber), regression_runs_total:($reg|tonumber), heals_total:($heals|tonumber)}')"

  runlog AUDIT_PREFLIGHT "checks=$(printf '%s' "$CHECKS" | jq length)"
  jq -nc --argjson c "$CHECKS" --argjson f "$failures" --argjson s "$stats" --argjson logs "$(logs_json)" \
    '{mode:"audit", nothing_to_do:false, checks:$c, failures:$f, stats:$s, logs:$logs}'
}

case "$MODE" in
  issues)     mode_issues ;;
  regression) mode_regression ;;
  audit)      mode_audit ;;
  *)          fail_out "unknown mode: $MODE" ;;
esac
