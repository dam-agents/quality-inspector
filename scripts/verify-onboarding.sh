#!/usr/bin/env bash
# verify-onboarding.sh — one-shot structure verification of an onboarded quality-inspector agent.
#
# Runs during ONBOARDING (`--config` after work/CONFIG.md is written, then `--live`
# at the end), from upgrade steps that change what onboarding produces, and from the
# weekly audit. Shape only — required files, keys, enums, table headers, row formats;
# the data inside is never judged.
#
# Detects, never repairs: no external writes, no local writes beyond one structured
# log event. Every FAIL line carries a `fix:`; re-run after fixing until PASS.
#
#   ok   <check> — <detail>
#   warn <check> — <detail>                      informational, never blocks
#   FAIL <check> — <problem> — fix: <instruction>
#
#   --config            the CONFIG block only (mid-onboarding)
#   (none)              every offline block: definition, schedules, work/, CONFIG
#   --live              offline blocks plus integrations, the black-box boundary, the
#                       VM, and one read-only pre-flight + Precheck per scheduled mode
#   --schedules <file>  JSON from mcp__platform-outbound__list_schedules, for the
#                       schedule-name check (the script cannot call MCP itself)
#
# Exit 0 iff nothing FAILed.

set -u
export LC_ALL=C

LIVE=0; STRUCTURE=1; SCHED_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    (--live)      LIVE=1;;
    (--config)    STRUCTURE=0;;
    (--schedules) SCHED_FILE="${2:-}"; shift;;
    (*) printf 'usage: %s [--config|--live] [--schedules <file>]\n' "$0" >&2; exit 2;;
  esac
  shift
done

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi

CHECKS=0; FAILS=0; WARNS=0
ok()   { CHECKS=$((CHECKS+1)); printf 'ok   %s — %s\n' "$1" "$2"; }
fail() { CHECKS=$((CHECKS+1)); FAILS=$((FAILS+1)); printf 'FAIL %s — %s — fix: %s\n' "$1" "$2" "$3"; }
warn() { WARNS=$((WARNS+1)); printf 'warn %s — %s\n' "$1" "$2"; }

. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/state.sh" || { echo "cannot source lib/state.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/profile.sh" || { echo "cannot source lib/profile.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/boundary.sh" || { echo "cannot source lib/boundary.sh" >&2; exit 1; }

SCHEDULES="quality-inspector-issues-1h quality-inspector-regression-nightly quality-inspector-benchmark-monthly quality-inspector-security-weekly quality-inspector-audit-weekly quality-inspector-scenarios-weekly"
KNOWN_KEYS="profile target_repo display_name qa_label retest_label marker_prefix candidate_channel
baseline_channel issue_comments artifact_reports include_comments max_issues_per_run lock_ttl_min
e2e_version e2e_web_version e2e_model audit_report log_level media_retention_days spec_feedback
explorations max_explorations_per_ac auto_promote security_checks security_failed_logins
confirm_regressions bisect_max_steps max_wallclock_min_per_issue max_model_steps_per_issue min_free_disk_gi
scenario_discovery scenario_channel max_scenarios_per_run max_scenarios_per_day"

if [ "$STRUCTURE" = 1 ]; then
  # ------------------------------------------------------------- definition
  if git -C "$HOME_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    ok definition_repo "checkout at $HOME_DIR"
    [ -z "$(git -C "$HOME_DIR" status --porcelain 2>/dev/null)" ] \
      && ok definition_clean "no untracked or modified definition files" \
      || fail definition_clean "git status in \$HOME is not clean" "fix .gitignore re-includes or revert the change (ONBOARDING.md Step 1); never git clean"
  else
    fail definition_repo "\$HOME is not a git checkout" "re-run ONBOARDING.md Step 1"
  fi
  ph="$(bash "$SCRIPT_DIR/hooks/install.sh" --check 2>&1)" && ok policy_hook "$ph" \
    || fail policy_hook "$ph" "bash \"\$HOME/scripts/hooks/install.sh\" (ONBOARDING.md Step 2e), then start a new session"
  [ "$(grep -v '^[[:space:]]*#' "$HOME_DIR/.gitignore" 2>/dev/null | grep -v '^[[:space:]]*$' | head -1)" = '/*' ] \
    && ok gitignore_allowlist "first rule is /*" \
    || fail gitignore_allowlist ".gitignore is not an allowlist" "restore .gitignore from origin/main"
  if [ -f "$HOME_DIR/.quality-inspector-onboarded" ] && grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$HOME_DIR/.quality-inspector-onboarded"; then
    ok sentinel "$(cat "$HOME_DIR/.quality-inspector-onboarded")"
  else
    fail sentinel "missing or malformed \$HOME/.quality-inspector-onboarded" "write it per ONBOARDING.md Step 6"
  fi

  # -------------------------------------------------------------- schedules
  if [ -n "$SCHED_FILE" ] && [ -f "$SCHED_FILE" ]; then
    for s in $SCHEDULES; do
      jq -e --arg n "$s" '[.. | objects | select(has("name")) | .name] | index($n) != null' "$SCHED_FILE" >/dev/null 2>&1 \
        && ok "schedule:$s" "exists" \
        || fail "schedule:$s" "not on this agent" "create it per ONBOARDING.md Step 5 (task text from kit.yaml)"
    done
  else
    warn schedules "not checked — pass --schedules <list_schedules JSON>"
  fi

  # ------------------------------------------------------------------ work/
  if [ -d "$WORK" ] && [ ! -e "$WORK/.git" ]; then ok work_dir "plain directory"
  else fail work_dir "work/ missing or a git repo" "ONBOARDING.md Step 2; never make work/ a repo"; fi
  [ -f "$WORK/AGENTS.md" ] && ok work_agents_md "pointer present" || fail work_agents_md "work/AGENTS.md missing" "ONBOARDING.md Step 2c"
  [ "$(head -1 "$WORK/VERSION" 2>/dev/null)" = "$(head -1 "$HOME_DIR/VERSION" 2>/dev/null)" ] \
    && ok work_version "$(head -1 "$WORK/VERSION")" \
    || fail work_version "work/VERSION differs from the checkout" "migrate per docs/persistence.md → Definition version & upgrade"
  [ "$(grep '^|' "$WORK/QA.md" 2>/dev/null | head -1)" = "$QA_HEADER" ] \
    && ok qa_table "header intact" || fail qa_table "work/QA.md missing or header changed" "re-seed per ONBOARDING.md Step 2b (keep existing rows)"
  bad="$(table_rows "$WORK/QA.md" | awk -F'|' 'NF!=9 || $2 !~ /^ *[0-9]+ *$/ || $7 !~ /^ *(in_progress|report_pending|reported) *$/' | head -3)"
  [ -z "$bad" ] && ok qa_rows "row format" || fail qa_rows "malformed rows: $bad" "fix the rows to the format in docs/issue-qa.md → State"
  [ "$(grep '^|' "$WORK/SUITE.md" 2>/dev/null | head -1)" = "$SUITE_HEADER" ] \
    && ok suite_table "header intact" || fail suite_table "work/SUITE.md missing or header changed" "re-seed per ONBOARDING.md Step 2b (keep existing rows)"
  bad="$(table_rows "$WORK/SUITE.md" | awk -F'|' 'NF!=7 || $4 !~ /^ *(exploratory|promotable|regression|retired|quarantined) *$/' | head -3)"
  [ -z "$bad" ] && ok suite_rows "row format" || fail suite_rows "malformed rows: $bad" "fix the rows to the format in docs/regression.md → Tiers"
  [ "$(grep '^|' "$WORK/HEALS.md" 2>/dev/null | head -1)" = "$HEALS_HEADER" ] \
    && ok heals_log "header intact" || fail heals_log "work/HEALS.md missing or header changed" "re-seed per ONBOARDING.md Step 2b (keep existing rows)"
  [ "$(grep '^|' "$WORK/FLAKY.md" 2>/dev/null | head -1)" = "$FLAKY_HEADER" ] \
    && ok flaky_log "header intact" || fail flaky_log "work/FLAKY.md missing or header changed" "re-seed per ONBOARDING.md Step 2b (keep existing rows)"
  [ "$(grep '^|' "$WORK/COVERAGE.md" 2>/dev/null | head -1)" = "$COVERAGE_HEADER" ] \
    && ok coverage_table "header intact" || fail coverage_table "work/COVERAGE.md missing or header changed" "re-seed per ONBOARDING.md Step 2b"
  [ "$(grep '^|' "$WORK/SCENARIOS.md" 2>/dev/null | head -1)" = "$SCENARIOS_HEADER" ] && [ -d "$WORK/scenarios" ] \
    && ok scenarios_table "header intact" || fail scenarios_table "work/SCENARIOS.md or work/scenarios/ missing, or the header changed" "re-seed per ONBOARDING.md Step 2b (keep existing rows)"
  bad="$(table_rows "$WORK/SCENARIOS.md" | awk -F'|' 'NF!=11 || $2 !~ /^ *S-[0-9]+ *$/ || $3 !~ /^ *(slack|operator|discovery) *$/ || $8 !~ /^ *(passed|failed|regression|needs-review|blocked|flaky|not-testable|-) *$/ || $9 !~ /^ *(proposed|queued|in_progress|report_pending|reported|rejected) *$/' | head -3)"
  [ -z "$bad" ] && ok scenarios_rows "row format" || fail scenarios_rows "malformed rows (a scenario is never verified): $bad" "fix the rows to the format in docs/scenarios.md → State"
  [ -f "$WORK/LESSONS.md" ] && ok lessons "present" || fail lessons "work/LESSONS.md missing" "ONBOARDING.md Step 2b"
  # perf-trend.mjs creates it on first use; missing is only worth a note.
  [ -d "$WORK/perf" ] && ok perf_dir "present" || warn perf_dir "work/perf missing — mkdir -p work/perf (ONBOARDING.md Step 2b)"
  if [ -f "$WORK/env/credentials.env" ]; then
    perm="$(stat -c %a "$WORK/env/credentials.env" 2>/dev/null || stat -f %Lp "$WORK/env/credentials.env" 2>/dev/null)"
    [ "$perm" = 600 ] && ok env_credentials "mode 600" || fail env_credentials "mode $perm" "chmod 600 work/env/credentials.env"
    for k in E2E_USER_OWNER_USERNAME E2E_USER_OWNER_PASSWORD; do
      grep -q "^$k=." "$WORK/env/credentials.env" || fail env_credentials "$k missing" "run scripts/env.sh init (the profile writes it)"
    done
  else
    fail env_credentials "work/env/credentials.env missing" "bash \"\$HOME/scripts/env.sh\" init"
  fi
  [ -f "$WORK/suite/e2e.config.ts" ] && ok suite_project "present" || fail suite_project "work/suite not initialized" "bash \"\$HOME/scripts/suite.sh\" init"
  [ -d "$WORK/suite/node_modules/e2e" ] && ok suite_deps "e2e $(jq -r .version "$WORK/suite/node_modules/e2e/package.json" 2>/dev/null)" \
    || fail suite_deps "e2e not installed" "bash \"\$HOME/scripts/suite.sh\" init"
fi

# ------------------------------------------------------------------- CONFIG
if [ -f "$CONFIG" ]; then
  ok config_file "present"
  t="$(cfg target_repo)"
  printf '%s' "$t" | grep -qE '^([A-Za-z0-9.-]+/)?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
    && ok cfg:target_repo "set" || fail cfg:target_repo "missing or not [host/]owner/repo" "ask the operator (ONBOARDING.md Step 3)"
  enum() { local v; v="$(cfg "$1")"; [ -z "$v" ] && { ok "cfg:$1" "default"; return; }
    case " $2 " in (*" $v "*) ok "cfg:$1" "$v";; (*) fail "cfg:$1" "'$v' is not one of: $2" "set a documented value (CLAUDE.md → Runtime configuration)";; esac; }
  enum issue_comments "enabled disabled"; enum artifact_reports "enabled disabled"
  enum include_comments "enabled disabled"; enum audit_report "enabled disabled"; enum log_level "info debug"
  enum spec_feedback "enabled disabled"; enum explorations "enabled disabled"; enum auto_promote "disabled verified"
  enum security_checks "enabled disabled"; enum confirm_regressions "enabled disabled"
  enum scenario_discovery "disabled propose run"
  v="$(cfg scenario_channel)"
  if [ -z "$v" ]; then ok cfg:scenario_channel "empty — proposals stay in the chat UI"
  elif printf '%s' "$v" | grep -qE '^[CDG][A-Z0-9]{6,}$'; then ok cfg:scenario_channel "$v"
  else fail cfg:scenario_channel "'$v' is not a Slack conversation id" "set the C…/G…/D… id of a conversation this agent is bound to, or leave it empty"; fi
  for k in max_issues_per_run lock_ttl_min media_retention_days max_explorations_per_ac security_failed_logins bisect_max_steps \
           max_wallclock_min_per_issue max_model_steps_per_issue min_free_disk_gi max_scenarios_per_run max_scenarios_per_day; do
    v="$(cfg "$k")"; case "$v" in (''|*[!0-9]*) [ -z "$v" ] && ok "cfg:$k" "default" || fail "cfg:$k" "'$v' is not a number" "set a positive integer";; (*) ok "cfg:$k" "$v";; esac
  done
  case "$(cfg bisect_max_steps)" in (''|0|*[!0-9]*) ;; (*) [ "$(cfg confirm_regressions)" = enabled ] \
    || warn cfg:bisect_max_steps "set, but bisection runs only with confirm_regressions: enabled (docs/triage.md)";; esac
  # A live run must never look stale: the lock outlives the wall-clock budget (docs/nested-env.md → Budgets).
  ttl="$(cfg lock_ttl_min)"; case "$ttl" in (''|*[!0-9]*) ttl=180;; esac
  wall="$(cfg max_wallclock_min_per_issue)"; case "$wall" in (''|*[!0-9]*) wall=150;; esac
  [ "$ttl" -gt "$wall" ] && ok cfg:lock_vs_budget "lock_ttl_min $ttl > max_wallclock_min_per_issue $wall" \
    || fail cfg:lock_vs_budget "lock_ttl_min $ttl is not above max_wallclock_min_per_issue $wall" "raise lock_ttl_min or lower the budget"
  # ---------------------------------------------------------------- profile
  if pd="$(profile_dir)"; then
    ok profile "$(profile_field '.product') at $pd"
    [ "$(profile_field '.schema')" = qi-profile/v1 ] && ok profile_schema "qi-profile/v1" \
      || fail profile_schema "profile.json schema is not qi-profile/v1" "install a profile built for this contract (docs/profile-contract.md)"
    for b in env versions build-time; do
      exe="$(profile_bin "$b")" && ok "profile_bin:$b" "${exe#$HOME_DIR/}" \
        || fail "profile_bin:$b" "neither the profile nor its engine provides it" "fix the profile (docs/profile-contract.md → Engines)"
    done
    case "$(profile_field '.app.url')" in
      (http://localhost*|http://127.0.0.1*) ok profile_app_url "$(profile_field '.app.url')";;
      (*) fail profile_app_url "app.url '$(profile_field '.app.url')' is not local" "the product must run inside this VM (docs/profile-contract.md)";;
    esac
    PKEYS="$(jq -r '.config // {} | keys[]' "$pd/profile.json" 2>/dev/null | sed 's/^/profile./')"
  else
    fail profile "profile '$(cfg profile)' is not installed" "install it with the skill tools (ONBOARDING.md Step 3)"
    PKEYS=""
  fi
  unknown="$(sed -n 's/^- \([A-Za-z0-9_.]*\):.*/\1/p' "$CONFIG" | while read -r k; do
    printf '%s\n' $KNOWN_KEYS $PKEYS | grep -qx "$k" || printf '%s ' "$k"; done)"
  [ -z "$unknown" ] && ok config_keys "all keys known" \
    || fail config_keys "unknown keys (invisible to the runtime): $unknown" "rename to a documented key or remove (CLAUDE.md → Runtime configuration)"
else
  fail config_file "work/CONFIG.md missing" "write it per ONBOARDING.md Step 3"
fi

# --------------------------------------------------------------------- live
if [ "$LIVE" = 1 ]; then
  T="${QI_TARGET_REPO:-$(cfg target_repo)}"; HA=(); RP="$T"
  if [ "$(printf '%s' "$T" | tr -cd '/' | wc -c | tr -d ' ')" = 2 ]; then HA=(--hostname "${T%%/*}"); RP="${T#*/}"; fi
  login="$(gh api ${HA[@]+"${HA[@]}"} user --jq .login 2>/dev/null)"
  [ -n "$login" ] && ok github_identity "acting as $login" || fail github_identity "gh api user failed" "grant the GitHub connection to this agent (README → Setup)"
  timeout 20 gh api ${HA[@]+"${HA[@]}"} "repos/$RP/issues?per_page=1" >/dev/null 2>&1 \
    && ok issues_read "target issues readable" || fail issues_read "cannot list target issues" "check target_repo and the connection's repository access"
  while read -r status id detail; do
    case "$status" in
      (fail) fail "$id" "$detail" "the operator adds the deny rule (bash scripts/egress-rules.sh)";;
      (ok)   ok "$id" "$detail";;
      (*)    warn "$id" "$detail";;
    esac
  done < <(boundary_probe "$T")
  cv="$(profile_run versions 2>&1)" && printf '%s' "$cv" | jq -e '.candidate' >/dev/null 2>&1 \
    && ok builds "$cv" || fail builds "$cv" "fix the profile's bin/versions or its egress (profile README)"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 https://api.anthropic.com/v1/models \
          -H 'x-api-key: injected-by-gateway' -H 'anthropic-version: 2023-06-01' 2>/dev/null)"
  case "$code" in
    (200) ok model_provider "Anthropic reachable with the gateway-injected credential";;
    (401|403) warn model_provider "Anthropic answered $code — the gateway does not inject a key for agent steps; set one per README → Setup";;
    (*) fail model_provider "Anthropic unreachable (HTTP $code)" "allow api.anthropic.com in the egress rules";;
  esac
  if [ "$(profile_field '.requires.root')" = true ]; then
    [ "$(id -u)" = 0 ] && ok vm_root "root" || fail vm_root "not running as root" "recreate the agent on the vm backend (README → Setup)"
  fi
  for c in $(profile_field '.requires.commands[]?'); do
    command -v "$c" >/dev/null 2>&1 && ok "command:$c" "present" || fail "command:$c" "missing" "use an agent image that has $c (profile README)"
  done
  nv="$(node -p 'process.versions.node' 2>/dev/null)"
  case "$nv" in
    (2[4-9].*|[3-9][0-9].*) [ "${nv%%.*}" -gt 24 ] || [ "$(echo "$nv" | cut -d. -f2)" -ge 8 ] \
      && ok node "$nv" || fail node "$nv is older than 24.8" "use an agent image with Node >= 24.8 (e2e requires it)";;
    (*) fail node "${nv:-missing}" "use an agent image with Node >= 24.8 (e2e requires it)";;
  esac
  need="$(profile_field '.requires.memory_gi')"; mem="$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null)"
  if [ -n "$need" ]; then
    [ -n "$mem" ] && [ "$mem" -ge "$need" ] && ok memory "${mem}Gi" || warn memory "${mem:-?}Gi — the profile asks for ${need}Gi"
  fi
  st="$(bash "$SCRIPT_DIR/env.sh" status 2>/dev/null)"
  printf '%s' "$st" | jq -e '.running and (.ui_http | test("^[23]"))' >/dev/null 2>&1 \
    && ok product_env "$(printf '%s' "$st" | jq -r .build)" || warn product_env "not up: $st (docs/nested-env.md)"
  for m in issues regression discovery; do
    out="$(bash "$SCRIPT_DIR/preflight.sh" "$m" 2>/dev/null)"
    if printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1; then
      err="$(printf '%s' "$out" | jq -r '.error // empty')"
      [ -z "$err" ] && ok "preflight:$m" "valid worklist" || fail "preflight:$m" "$err" "fix the cause named, then re-run"
    else
      fail "preflight:$m" "no JSON" "bash -x scripts/preflight.sh $m and fix"
    fi
    s=$(date +%s); QI_PRECHECK_PROBE=1 bash "$SCRIPT_DIR/precheck.sh" "$m" >/dev/null 2>&1; rc=$?; d=$(( $(date +%s) - s ))
    case "$rc" in (0|1) [ "$d" -lt 90 ] && ok "precheck:$m" "exit $rc in ${d}s" || fail "precheck:$m" "took ${d}s" "make the $m pre-flight faster than 2 minutes";;
      (*) fail "precheck:$m" "exit $rc" "fix scripts/precheck.sh / preflight.sh $m";; esac
  done
fi

# ------------------------------------------------------------------- summary
if [ "$LIVE" = 1 ]; then SCOPE="structure+live"
elif [ "$STRUCTURE" = 1 ]; then SCOPE="structure"
else SCOPE="config"; fi
if [ "$FAILS" -eq 0 ]; then
  printf 'PASS (%s) — %d checks passed, %d warning(s)\n' "$SCOPE" "$CHECKS" "$WARNS"
  logev info onboarding_verify "PASS $SCOPE ($CHECKS checks, $WARNS warnings)"
  exit 0
else
  printf 'RESULT (%s): %d of %d checks FAILED — apply each fix above, then re-run this script until it prints PASS.\n' "$SCOPE" "$FAILS" "$CHECKS"
  logev error onboarding_verify "FAILED $SCOPE ($FAILS of $CHECKS checks) — agent must repair and re-run"
  exit 1
fi
