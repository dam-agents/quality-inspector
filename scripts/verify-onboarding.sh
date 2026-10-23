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
#   --egress            the CONFIG block plus one request per profile egress rule: allowed,
#                       refused at once (a kit deny or a denied prompt — add it by hand),
#                       HTTP 403 (a warn: the gateway or the host itself) or held for the
#                       operator's approval prompt (direct session only)
#   (none)              every offline block: definition, schedules, work/, CONFIG
#   --live              offline blocks plus integrations, the black-box boundary, the
#                       VM, and one read-only pre-flight + Precheck per scheduled mode
#   --models            the models the connection lists, each probed with one agent step
#                       call: which answer, for choosing e2e_model (prints nothing else)
#   --schedules <file>  JSON from mcp__platform-outbound__list_schedules, for the
#                       schedule-name check (the script cannot call MCP itself)
#
# Exit 0 iff nothing FAILed.

set -u
export LC_ALL=C

LIVE=0; STRUCTURE=1; SCHED_FILE=""; EGRESS=0; MODELS=0
while [ $# -gt 0 ]; do
  case "$1" in
    (--live)      LIVE=1; EGRESS=1;;
    (--config)    STRUCTURE=0;;
    (--egress)    STRUCTURE=0; EGRESS=1;;
    (--models)    MODELS=1;;
    (--schedules) SCHED_FILE="${2:-}"; shift;;
    (*) printf 'usage: %s [--config|--egress|--live|--models] [--schedules <file>]\n' "$0" >&2; exit 2;;
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
. "$SCRIPT_DIR/lib/lock.sh" || { echo "cannot source lib/lock.sh" >&2; exit 1; }

# --models: `<answer> <model> — <detail>` per listed model, e2e_model's first; exit 0 iff one answers.
if [ "$MODELS" = 1 ]; then
  cur="$(cfg e2e_model)"; cur="${cur:-claude-sonnet-5}"; any=1
  for m in $( { echo "$cur"; model_list; } | awk '!seen[$0]++'); do
    IFS='|' read -r code mbase _ _ merr <<<"$(model_probe "$m")"
    case "$code" in
      (none) echo "no model connection — give this agent one in its settings"; exit 1;;
      (200) echo "answers $m"; any=0;;
      (*) echo "fails   $m — HTTP $code${merr:+: $merr}";;
    esac
  done
  exit $any
fi

SCHEDULES="quality-inspector-issues-1h quality-inspector-regression-nightly quality-inspector-benchmark-monthly quality-inspector-security-weekly quality-inspector-audit-weekly quality-inspector-scenarios-weekly quality-inspector-modules-nightly"
KNOWN_KEYS="profile target_repo display_name qa_label retest_label marker_prefix candidate_channel
baseline_channel issue_comments artifact_reports include_comments max_issues_per_run lock_ttl_min
e2e_version e2e_web_version e2e_model audit_report log_level media_retention_days spec_feedback profile_source_path
explorations max_explorations_per_ac auto_promote security_checks security_failed_logins
confirm_regressions bisect_max_steps max_wallclock_min_per_issue max_model_steps_per_issue min_free_disk_gi
scenario_discovery scenario_channel profile_scenarios regression_channel max_scenarios_per_run max_scenarios_per_day work_repo test_catalog
lend_model live_browser slack_channel slack_tests_per_day slack_report_visibility github_login found_label fix_label
$(jq -r '[.global, (.modules[] | select(.kind == "modules" or .kind == "queue") | .settings)] | add | keys[]' "$SCRIPT_DIR/lib/modules.json" 2>/dev/null)"

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
  th="$(bash "$SCRIPT_DIR/hooks/install.sh" --check-trace 2>&1)" && ok trace_hook "$th" || warn trace_hook "$th"
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
  bad="$(table_rows "$WORK/SCENARIOS.md" | awk -F'|' -v src="$SCEN_SOURCES" -v ver="$SCEN_VERDICTS" -v sta="$SCEN_STATUSES" \
    'NF!=11 || $2 !~ /^ *(S-[0-9]+|P-[a-z0-9][a-z0-9-]*) *$/ || $3 !~ ("^ *(" src ") *$") || $8 !~ ("^ *(" ver ") *$") || $9 !~ ("^ *(" sta ") *$")' | head -3)"
  [ -z "$bad" ] && ok scenarios_rows "row format" || fail scenarios_rows "malformed rows (a scenario is never verified): $bad" "fix the rows to the format in docs/scenarios.md → State"
  [ -f "$WORK/LESSONS.md" ] && ok lessons "present" || fail lessons "work/LESSONS.md missing" "ONBOARDING.md Step 2b"
  [ "$(grep '^|' "$WORK/CATALOG.md" 2>/dev/null | head -1)" = "$CATALOG_HEADER" ] \
    && ok catalog_collections "header intact" || fail catalog_collections "work/CATALOG.md missing or header changed" "re-seed per ONBOARDING.md Step 2b (keep existing rows)"
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
  # Keys a version dropped (lib/config.sh); a restore deletes them itself.
  for k in $CONFIG_OBSOLETE_KEYS; do
    grep -q "^- $k:" "$CONFIG" && warn "cfg:$k" "obsolete — delete the line (CHANGELOG.md names the version that dropped it)"
  done
  w="$(cfg work_repo)"
  if [ -z "$w" ]; then ok cfg:work_repo "unset — work/ is local-only"
  elif ! printf '%s' "$w" | grep -qE '^([A-Za-z0-9.-]+/)?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    fail cfg:work_repo "'$w' is not [host/]owner/repo" "name the private backup repository, or remove the key"
  elif [ "$(_bb_lower "$(_bb_host "$w")/$(_bb_repo "$w")")" = "$(_bb_lower "$(_bb_host "$t")/$(_bb_repo "$t")")" ]; then
    fail cfg:work_repo "is the target repository" "name a separate private repository (docs/persistence.md → Backup & restore)"
  else ok cfg:work_repo "$w"; fi
  enum() { local v; v="$(cfg "$1")"; [ -z "$v" ] && { ok "cfg:$1" "default"; return; }
    case " $2 " in (*" $v "*) ok "cfg:$1" "$v";; (*) fail "cfg:$1" "'$v' is not one of: $2" "set a documented value (CLAUDE.md → Runtime configuration)";; esac; }
  enum issue_comments "enabled disabled"; enum artifact_reports "enabled disabled"
  enum include_comments "enabled disabled"; enum audit_report "enabled disabled"; enum log_level "info debug"
  enum spec_feedback "enabled disabled"; enum auto_promote "disabled verified"; enum lend_model "enabled disabled"
  enum test_catalog "enabled disabled"; enum slack_report_visibility "private public"
  v="$(cfg scenario_channel)"
  if [ -z "$v" ]; then ok cfg:scenario_channel "empty — proposals stay in the chat UI"
  elif printf '%s' "$v" | grep -qE '^[CDG][A-Z0-9]{6,}$'; then ok cfg:scenario_channel "$v"
  else fail cfg:scenario_channel "'$v' is not a Slack conversation id" "set the C…/G…/D… id of a conversation this agent is bound to, or leave it empty"; fi
  enum profile_scenarios "enabled disabled"
  v="$(cfg regression_channel)"
  if [ -z "$v" ]; then ok cfg:regression_channel "empty — the nightly summary stays in the chat UI; a black-box breach alert goes to slack_channel"
  elif printf '%s' "$v" | grep -qE '^[CDG][A-Z0-9]{6,}$'; then ok cfg:regression_channel "$v"
  else fail cfg:regression_channel "'$v' is not a Slack conversation id" "set the C…/G…/D… id of a conversation this agent is bound to, or leave it empty"; fi
  case "$(cfg slack_channel)" in ('') ok cfg:slack_channel "none — Slack orders no issue test";;
    (*) printf '%s' "$(cfg slack_channel)" | grep -qE '^[CGD][A-Z0-9]{6,}$' && ok cfg:slack_channel "$(cfg slack_channel)" \
          || fail cfg:slack_channel "'$(cfg slack_channel)' is not a Slack chat id" "use the id describe_channel lists, e.g. C0123ABCD (docs/slack.md)";; esac
  case "$(cfg live_browser)" in (''|disabled) ok cfg:live_browser "disabled";;
    (http://127.0.0.1:[0-9]*|http://localhost:[0-9]*) ok cfg:live_browser "$(cfg live_browser)";;
    (*) fail cfg:live_browser "'$(cfg live_browser)' is not a CDP endpoint on this VM" "http://127.0.0.1:<port> from /etc/AGENTS.md, or disabled (docs/test-authoring.md → Watching live)";; esac
  for k in lock_ttl_min media_retention_days min_free_disk_gi max_scenarios_per_day slack_tests_per_day; do
    v="$(cfg "$k")"; case "$v" in (''|*[!0-9]*) [ -z "$v" ] && ok "cfg:$k" "default" || fail "cfg:$k" "'$v' is not a number" "set a positive integer";; (*) ok "cfg:$k" "$v";; esac
  done
  # The keys of the testing modules' registry, judged by it (one home: scripts/lib/modules.json, docs/modules.md).
  mc="$(bash "$SCRIPT_DIR/modules.sh" check 2>/dev/null)" || mc=""
  if [ -z "$mc" ]; then fail cfg:modules "scripts/modules.sh check failed" "restore scripts/modules.sh and scripts/lib/modules.json from origin/main"
  else while IFS=$'\x1f' read -r k v okv allowed; do
      [ "$okv" = true ] && ok "cfg:$k" "$v" || fail "cfg:$k" "'$v' is not one of: $allowed" "set a documented value (docs/modules.md)"
    done < <(jq -r '.[] | [.key, .value, (.ok | tostring), .allowed] | join("\u001f")' <<<"$mc"); fi
  case "$(reg bisect_max_steps)" in (0) ;; (*) [ "$(reg confirm_regressions)" = enabled ] \
    || warn cfg:bisect_max_steps "set, but bisection runs only with confirm_regressions: enabled (docs/triage.md)";; esac
  # A live run must never look stale: the lock outlives the wall-clock budget (docs/nested-env.md → Budgets).
  ttl="$(cfg lock_ttl_min)"; case "$ttl" in (''|*[!0-9]*) ttl=180;; esac
  wall="$(reg max_wallclock_min_per_issue)"; case "$wall" in (''|*[!0-9]*) wall=150;; esac
  [ "$ttl" -gt "$wall" ] && ok cfg:lock_vs_budget "lock_ttl_min $ttl > max_wallclock_min_per_issue $wall" \
    || fail cfg:lock_vs_budget "lock_ttl_min $ttl is not above max_wallclock_min_per_issue $wall" "raise lock_ttl_min or lower the budget"
  wall="$(reg modules_max_wallclock_min)"; case "$wall" in (''|*[!0-9]*) wall=90;; esac
  [ "$ttl" -gt "$wall" ] && ok cfg:lock_vs_modules "lock_ttl_min $ttl > modules_max_wallclock_min $wall" \
    || fail cfg:lock_vs_modules "lock_ttl_min $ttl is not above modules_max_wallclock_min $wall" "raise lock_ttl_min or lower the modules budget"
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
    # A profile egress rule egress-rules.sh refuses: a GitHub allow outside the closed set, or
    # a {profile.<key>} with no plain value (docs/black-box.md → Sandbox accounts).
    while IFS="$(printf '\t')" read -r h p why; do
      fail "profile_egress:$h" "$p refused: $why" "never add this rule; set the key it names, or report the rule to the profile's repository"
    done < <(bash "$SCRIPT_DIR/egress-rules.sh" --json 2>/dev/null | jq -r '.rules[]? | select(.source == "profile" and .how == "refused") | [.host, .path, .why] | @tsv')
    # The sandbox accounts (docs/profile-contract.md → `sandbox`): each credential set.
    if sb="$(bash "$SCRIPT_DIR/sandbox.sh" status 2>&1)"; then
      if [ "$(jq -r .declared <<<"$sb")" = true ]; then
        miss="$(jq -r '[.accounts[].credentials[] | select(.set | not) | .name] | join(" ")' <<<"$sb")"
        [ -z "$miss" ] && ok sandbox_credentials "$(jq -r '[.accounts[].id] | join(", ")' <<<"$sb") set" \
          || fail sandbox_credentials "not set: $miss" "the operator creates the accounts and fills these lines in work/env/credentials.env (ONBOARDING.md Step 3a) — never in chat"
        while read -r pr; do [ -n "$pr" ] && fail sandbox "$pr" "fix the profile (docs/profile-contract.md → sandbox)"; done < <(jq -r '.problems[]' <<<"$sb")
      fi
    else
      fail sandbox "$sb" "fix the profile's sandbox section (docs/profile-contract.md → sandbox)"
    fi
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

# ------------------------------------------------------------------- egress
# One request per profile egress rule, so a missing rule shows before env.sh up does. The
# gateway refuses a request under a deny at once (no connection, or a 403) — no prompt ever
# appears for it; a request no rule matches is held while the operator's approval prompt is
# open, in a direct session only (a scheduled run is refused). Any other HTTP answer is
# passage. A 403 is no proof: a storage or CDN host answers the probe's made-up path so too.
if [ "$EGRESS" = 1 ]; then
  er="$(bash "$SCRIPT_DIR/egress-rules.sh" --json 2>/dev/null)" || er='{"rules":[]}'
  while IFS="$(printf '\t')" read -r how m h p why; do
    case "${h#\*.}" in (''|*[!A-Za-z0-9.-]*) warn "egress:${h//[!A-Za-z0-9.*-]/?}" "not a plain host name — not probed; check the profile's egress"; continue;; esac
    case "$m" in (GET|HEAD|'*') ;; (*) warn "egress:$h" "$m $p is not probed (only GET) — $why"; continue;; esac
    case "$h" in ('*'*) warn "egress:$h" "a wildcard host is not probed: each host it reaches prompts once on first use (env.sh up) — approve each, or add the wildcard by hand"; continue;; esac
    case "$p" in ('*') path=/;; (*) path="${p//\*/qi-egress-check}";; esac
    code="$(curl -s -o /dev/null -r 0-0 --max-filesize 1048576 -w '%{http_code}' --max-time 25 "https://$h$path" </dev/null 2>/dev/null)"; rc=$?
    case "$code:$rc" in
      (000:28) warn "egress:$h" "held for approval — approve its prompt (Allow permanently), then re-run: GET $p ($why)";;
      (000:6) fail "egress:$h" "the host does not resolve (DNS)" "check the host name in the profile's egress (a typo is a profile defect: report it to the profile's repository)";;
      (000:35|000:51|000:60) fail "egress:$h" "TLS to the host failed (curl exit $rc)" \
        "check the host name and its certificate — not an egress rule; a gateway that intercepts TLS needs its CA in this VM's trust store";;
      (403:*) warn "egress:$h" "GET $p answered HTTP 403 — the gateway's refusal, or the host's own answer to the probe's path${how:+ ($how)}: when this rule is not in the agent's network settings yet, add an allow rule there: host $h, method GET, path $p ($why)";;
      (000:*) fail "egress:$h" "GET $p refused at once${how:+ ($how)}" \
        "add an allow rule in the agent's network settings: host $h, method GET, path $p — no prompt appears for a request under a deny (a prompt answered Deny forever left a deny rule: delete it)";;
      (*) ok "egress:$h" "GET $p passes (HTTP $code)";;
    esac
  done < <(jq -r '.rules[] | select(.source == "profile" and .verdict == "allow" and .how != "refused") | [.how, .method, .host, .path, .why] | @tsv' <<<"$er")
fi

# --------------------------------------------------------------------- live
if [ "$LIVE" = 1 ]; then
  T="${QI_TARGET_REPO:-$(cfg target_repo)}"
  GL="$(cfg github_login)"; login="$(bash "$SCRIPT_DIR/github.sh" whoami 2>/dev/null)"
  [ -n "$login" ] && ok github_identity "acting as $login${GL:+ (github_login)}" \
    || fail github_identity "github.sh whoami failed" "grant the GitHub connection to this agent (README → Setup); a GitHub App token: set github_login to its <slug>[bot]"
  bash "$SCRIPT_DIR/github.sh" check >/dev/null 2>&1 \
    && ok issues_read "target issues readable" || fail issues_read "cannot list target issues" "check target_repo, the connection's repository access and the kit's egress (bash scripts/egress-rules.sh --kit lists it)"
  while read -r status id detail; do
    case "$status" in
      (fail) fail "$id" "${detail%% — *}" "$(boundary_fix "$detail")";;
      (ok)   ok "$id" "$detail";;
      (*)    warn "$id" "$detail";;
    esac
  done < <(boundary_probe "$T")
  wb="$(bash "$SCRIPT_DIR/work-backup.sh" check 2>/dev/null)"
  if [ "$(jq -r '.configured // empty' <<<"$wb" 2>/dev/null)" = true ]; then
    jq -e '.problem' >/dev/null 2>&1 <<<"$wb" \
      && fail work_backup "$(jq -r .problem <<<"$wb")" "make work_repo a private repository the connection can push to, never the target or its fork, and have the operator add the work backup rule egress-rules.sh lists" \
      || ok work_backup "$(jq -r .repo <<<"$wb") private and reachable"
  fi
  cv="$(profile_run versions 2>&1)" && printf '%s' "$cv" | jq -e '.candidate' >/dev/null 2>&1 \
    && ok builds "$cv" || fail builds "$cv" "fix the profile's bin/versions or its egress (profile README)"
  IFS='|' read -r code mbase mvn mmodel merr <<<"$(model_probe)"
  case "$code" in
    (none) fail model_provider "no model connection: none of $MODEL_AUTH_VARS is set" \
      "give this agent an Anthropic-compatible model connection in its settings (README → Setup)";;
    (200) ok model_provider "$mmodel answers at $mbase with $mvn";;
    (401|403) fail model_provider "$mbase answered $code to $mvn${merr:+: $merr}" \
      "the gateway swaps only the connection's placeholder, in the header that connection uses: check that this agent's model connection is granted and that $mvn holds its placeholder (platform:conn:<id>)";;
    (400|404) fail model_provider "$mbase refused model $mmodel (HTTP $code)${merr:+: $merr}" \
      "set e2e_model in work/CONFIG.md to a model this provider serves — bash scripts/verify-onboarding.sh --models lists the ones that answer";;
    (429) fail model_provider "$mbase rate-limits or is out of quota for $mmodel (HTTP 429)${merr:+: $merr}" \
      "not an egress problem: set e2e_model to another model or give the agent another provider — bash scripts/verify-onboarding.sh --models lists the ones that answer";;
    (5??) fail model_provider "$mbase failed for $mmodel (HTTP $code)${merr:+: $merr}" \
      "the provider's own error: retry later, or pick another model (bash scripts/verify-onboarding.sh --models)";;
    (*) fail model_provider "$mbase unreachable (HTTP $code)" "the gateway refused or held it: add an allow rule for the provider's host in the agent's network settings";;
  esac
  # The environment lock frees a dead holder at once only when the runtime answers (lib/lock.sh).
  session_running "${CLAUDE_CODE_SESSION_ID:-}"
  case $? in
    (0) ok lock_liveness "the runtime answers — a dead run's lock is freed at once";;
    (*) warn lock_liveness "the runtime gives no session state here — the environment lock falls back to lock_ttl_min";;
  esac
  sc="$(bash "$SCRIPT_DIR/sandbox.sh" check 2>&1)"; rc=$?
  profile_dir >/dev/null || rc=skip   # the profile check above already failed
  case "$rc" in
    (skip) ;;
    (0) [ "$sc" = "the profile declares no sandbox accounts" ] || ok sandbox_accounts "$(printf '%s' "$sc" | tail -1)";;
    (3) warn sandbox_accounts "$sc";;
    (*) fail sandbox_accounts "$(printf '%s' "$sc" | grep -m1 -E '^FAIL' || printf '%s' "$sc" | tail -1)" \
      "the operator fixes the account or its credentials (ONBOARDING.md Step 3a); a refused request is a missing egress rule (egress-rules.sh)";;
  esac
  if [ "$(cfg lend_model)" = enabled ]; then
    IFS='|' read -r mk mkind _ <<<"$(model_env)"
    [ -n "$mk" ] && ok lend_model "lends this agent's $mkind connection by its placeholder" \
      || fail lend_model "this agent has no model connection to lend" "give it one in its settings, or set lend_model: disabled"
  fi
  case "$(cfg live_browser)" in (''|disabled) ;;
    (*) live_cdp >/dev/null 2>&1 && ok live_browser "answers" || warn live_browser "does not answer, or this session is not shown direct (a scheduled run, a channel turn, no transcript) — runs stay headless";; esac
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
  for m in issues regression discovery modules; do
    out="$(bash "$SCRIPT_DIR/preflight.sh" "$m" 2>/dev/null)"
    if printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1; then
      err="$(printf '%s' "$out" | jq -r '.error // empty')"
      [ -z "$err" ] && ok "preflight:$m" "valid worklist" || fail "preflight:$m" "$err" "fix the cause named, then re-run"
    else
      fail "preflight:$m" "no JSON" "bash -x scripts/preflight.sh $m and fix"
    fi
    s=$(date +%s); bash "$SCRIPT_DIR/precheck.sh" "$m" >/dev/null 2>&1; rc=$?; d=$(( $(date +%s) - s ))
    case "$rc" in (0|1) [ "$d" -lt 90 ] && ok "precheck:$m" "exit $rc in ${d}s" || fail "precheck:$m" "took ${d}s" "make the $m pre-flight faster than 2 minutes";;
      (*) fail "precheck:$m" "exit $rc" "fix scripts/precheck.sh / preflight.sh $m";; esac
  done
fi

# ------------------------------------------------------------------- summary
if [ "$LIVE" = 1 ]; then SCOPE="structure+live"
elif [ "$STRUCTURE" = 1 ]; then SCOPE="structure"
elif [ "$EGRESS" = 1 ]; then SCOPE="config+egress"
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
