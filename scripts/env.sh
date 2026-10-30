#!/usr/bin/env bash
# env.sh — the product environment: in this agent's VM or in a platform Environment of its own
# (lib/environment.sh chooses at `up`). The lock is the core's; every other command is the
# profile's bin/env (docs/profile-contract.md → The bin/ contract), run where the product runs.
# The agent calls it; the pre-flight never does. docs/nested-env.md.
#
#   env.sh lock <owner> | unlock <owner>     one run at a time (exit 1 when a live holder has it;
#                                            lib/lock.sh); unlock refuses while an `up` or a
#                                            background `suite.sh run` still runs
#   env.sh init | up <build> | reset | status | down    → the profile, where the product runs
#                                            (`up` first chooses where — nested_target —, in this
#                                            VM checks min_free_disk_gi, and keeps its result in
#                                            work/env/UP for `wait`; `status` adds `target`; in an
#                                            Environment `down` only closes the forward)
#   env.sh where                 {"target":"vm"} or {"target":"environment", name, url, forward}
#   env.sh keep <label> [<days>] the active Environment stays as the run left it, for a person
#                                (default 3 days); prints its row {name, label, build, url, …}
#   env.sh extend <label> <days> a kept Environment stays <days> more from now
#   env.sh release <label|name>  delete a kept Environment (or the active one)
#   env.sh kept                  the kept Environments, a JSON array (work/ENVIRONMENTS.json)
#   env.sh wait <build> [<seconds>]  block until this session's background `up <build>` ends
#                                (default 540 s, under the harness's 10-minute tool limit): exit 0
#                                it succeeded, 3 it still runs (call again), 1 it failed, died, or
#                                no such install was started — a failure prints the last lines of
#                                its output, credential values masked
#   env.sh watch                 the Browser Panel button for the product's UI when live_browser
#                                attaches (lib/config.sh → live_link); prints nothing, exit 1, otherwise
#   env.sh resume               after this VM booted again (the platform hibernates it when idle),
#                                bring back the build the last `up` left answering — no reset, no
#                                other build, where that `up` put it (an Environment gone: nothing) —
#                                in the background; prints one line for the session
#                                when it starts, nothing otherwise. The SessionStart hook's
#                                (scripts/hooks/resume.sh). `down` and `reset` turn it off until the
#                                next `up`; `up`, `reset` and `down` first wait for a resume to end
#   env.sh between <from> <to>   read-only: the profile's `bin/versions --between` — a JSON
#                                array of builds between the two, oldest first; exit 2 when
#                                the profile does not implement it (no array), 1 when it
#                                cannot look (docs/triage.md → Order of work, step 6)
#
# `up` and `reset` keep their whole output in work/env/last-<cmd>.log (mode 600, never backed
# up): the evidence of an environment failure (docs/nested-env.md → Failures).
#
# Every command is idempotent; a failed `up` is safe to re-run.

set -u
export LC_ALL=C

HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
ENVD="$WORK/env"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/lib/config.sh" || { echo "cannot source lib/config.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/profile.sh" || { echo "cannot source lib/profile.sh" >&2; exit 1; }
. "$SCRIPT_DIR/lib/lock.sh" || { echo "cannot source lib/lock.sh" >&2; exit 1; }
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi
. "$SCRIPT_DIR/lib/environment.sh" || { echo "cannot source lib/environment.sh" >&2; exit 1; }
export LOG_JOB="${LOG_JOB:-env}"

LOCK_TTL_MIN="$(cfg lock_ttl_min)"; case "$LOCK_TTL_MIN" in (''|*[!0-9]*) LOCK_TTL_MIN=180;; esac
ME="${CLAUDE_CODE_SESSION_ID:-}"
UPF="$ENVD/UP"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Ours: this session holds it, or — when either side has no session id — the same owner.
lock_mine() { # <held> <session> <owner>
  [ -n "$ME" ] && [ "$2" = "$ME" ] && return 0
  [ "$1" = "$3" ] && { [ -z "$ME" ] || [ "$2" = - ]; }
}
cmd_lock() {
  local owner="${1:?owner}" state held ts sess
  mkdir -p "$ENVD"
  lock_mutex "$ENVD/LOCK.mutex" || { echo "env: another run is taking the lock right now" >&2; exit 1; }
  trap 'rm -f "$ENVD/LOCK.mutex" 2>/dev/null' EXIT
  [ -f "$ENVD/LOCK" ] && read -r held ts sess _ < "$ENVD/LOCK"
  if [ -n "${held:-}" ] && ! lock_mine "$held" "${sess:--}" "$owner"; then
    read -r state held ts sess <<<"$(lock_state "$ENVD/LOCK" "$LOCK_TTL_MIN")"
    case "$state" in
      (live) echo "env: locked by $held since $ts — its session is running" >&2; exit 1;;
      (held) echo "env: locked by $held since $ts" >&2; exit 1;;
      (dead|stale) logev warn env_lock_takeover "$state environment lock of $held ($ts) taken over by $owner";;
    esac
  fi
  printf '%s %s %s\n' "$owner" "$(now)" "$ME" > "$ENVD/LOCK.tmp" && mv -f "$ENVD/LOCK.tmp" "$ENVD/LOCK"
}
up_running() { local st b ts x _; [ -f "$UPF" ] && read -r st b ts x _ < "$UPF" && [ "$st" = running ] && kill -0 "$x" 2>/dev/null; }
# A background `suite.sh run` (its state line in work/suite/.e2e/state/) still drives the product.
suite_running() { local f st l ts x _
  for f in "$WORK"/suite/.e2e/state/*; do
    [ -f "$f" ] && read -r st l ts x _ < "$f" && [ "$st" = running ] && kill -0 "$x" 2>/dev/null && { echo "$l"; return 0; }
  done; return 1; }
cmd_unlock() {
  local owner="${1:?owner}" held ts sess
  [ -f "$ENVD/LOCK" ] || return 0
  read -r held ts sess _ < "$ENVD/LOCK"
  lock_mine "$held" "${sess:--}" "$owner" || return 0
  up_running && { echo "env: an install still runs — env.sh wait until it ends, then unlock" >&2; exit 1; }
  local run; run="$(suite_running)" && { echo "env: the suite run $run still runs — suite.sh wait $run until it ends, or stop its background task, then unlock" >&2; exit 1; }
  rm -f "$ENVD/LOCK"
  return 0
}

# The profile's bin/env where the product runs: in an Environment over its link, from a fresh
# copy of the profile, the engines and the credentials (init always runs here: the
# credentials are this VM's).
run_bin() { # <cmd> [args]
  local n
  if [ "$1" != init ] && n="$(target_name)"; then
    [ -f "$ENVD/credentials.env" ] || profile_run env init >&2 || return 1
    env_sync "$n" || { echo "env: cannot copy the profile into Environment $n" >&2; return 1; }
    env_run "$n" "$@"
  else
    profile_run env "$@"
  fi
}
# The profile's operator-filled credentials (docs/profile-contract.md → `operator_credentials`):
# add each missing `E2E_<NAME>=` line once — empty, mode 600 — and say what to fill. Idempotent; an
# existing line is never touched and no value is ever printed.
seed_operator_credentials() {
  local f="$ENVD/credentials.env" n what req
  [ -f "$f" ] || return 0
  while IFS=$'\t' read -r n what req; do
    operator_credential_name_ok "$n" || continue
    grep -qE "^(export[[:space:]]+)?E2E_$n=" "$f" && continue
    if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then echo >> "$f"; fi
    ( umask 077; printf 'E2E_%s=\n' "$n" >> "$f" ) || { echo "env: cannot write work/env/credentials.env" >&2; return 1; }
    chmod 600 "$f"
    echo "env: fill E2E_$n in work/env/credentials.env — $what (never in chat)" >&2
  done < <(operator_credentials 2>/dev/null)
  return 0
}

delegate() { # <cmd> [args]
  mkdir -p "$ENVD" && chmod 700 "$ENVD"
  local t0 rc; t0="$(date -u +%s)"
  [ "$1" = reset ] && ( umask 077; printf 'env.sh reset at %s\n' "$(now)" > "$ENVD/last-reset.log" )
  case "$1" in
    (up|reset) run_bin "$@" 2>&1 | tee -a "$(outlog "$1")"; rc=${PIPESTATUS[0]} ;;
    (*) run_bin "$@"; rc=$? ;;
  esac
  case "$rc" in
    (0) [ "$1" = up ] && logev info env_up "product at build ${2:-?} took_s=$(( $(date -u +%s) - t0 ))"
        [ "$1" = reset ] && logev info env_reset "product data wiped"
        [ "$1" = init ] && { seed_operator_credentials || rc=1; } ;;
    (*) logev error env_failed "profile bin/env $1 exited $rc (output: work/env/last-$1.log)" ;;
  esac
  return "$rc"
}
# work/env/last-<cmd>.log — started anew by each `up` (cmd_up) and `reset` (delegate); a
# resume's `up` writes work/env/last-resume.log (OUTLOG_AS).
outlog() { local f="$ENVD/last-${OUTLOG_AS:-$1}.log"; [ -f "$f" ] || ( umask 077; : > "$f" ); printf '%s' "$f"; }
# The last <n> lines of an output log, each credential value of work/env/credentials.env masked.
outtail() { # <cmd> <n>
  local f="$ENVD/last-$1.log" out
  [ -s "$f" ] || { echo "  (no output kept)"; return 0; }
  out="$(tail -n "$2" "$f" | node "$SCRIPT_DIR/lib/secrets.mjs" filter "$ENVD/credentials.env" 2>/dev/null)" \
    || { echo "  (cannot mask the credential values — read work/env/last-$1.log, never quote it)"; return 0; }
  printf '%s\n' "$out" | sed 's/^/  | /'
}

cmd_between() { # <from> <to>
  local out rc
  out="$(profile_run versions --between "$1" "$2")"; rc=$?
  [ "$rc" = 2 ] && { echo "env: the profile cannot list builds between two builds" >&2; return 2; }
  [ "$rc" = 0 ] || { echo "env: bin/versions --between exited $rc" >&2; return 1; }
  printf '%s' "$out" | jq -ce 'if type == "array" then . else error("not an array") end' 2>/dev/null \
    || { echo "env: bin/versions ignores --between (no JSON array) — treated as not implemented" >&2; return 2; }
}

# An install needs room for images and data: refuse `up` below min_free_disk_gi free on
# the home volume — an environment failure, never a verdict. Unmeasurable → go ahead.
disk_gate() {
  local min free
  min="$(cfg min_free_disk_gi)"; case "$min" in (''|*[!0-9]*) min=10;; esac
  free="$(df -Pk "$HOME_DIR" 2>/dev/null | awk 'NR==2 && $4 ~ /^[0-9]+$/ {print int($4/1048576)}')"
  [ -n "$free" ] || { echo "env: free disk space not measurable — continuing" >&2; return 0; }
  [ "$free" -ge "$min" ] && return 0
  echo "env: only ${free}Gi free on the home volume, min_free_disk_gi is $min — free space before an install (docs/nested-env.md → Failures)" | tee -a "$(outlog up)" >&2
  logev error env_failed "up refused: ${free}Gi free on the home volume, below min_free_disk_gi $min"
  exit 1
}

# up <build>, its result kept for `wait`: `running <build> <ISO> <pid> <session>`, then
# `done <build> <ISO> <exit> <session>` — so a wait never reads an earlier run's result.
cmd_up() {
  local rc
  mkdir -p "$ENVD" && chmod 700 "$ENVD"
  printf 'running %s %s %s %s\n' "$1" "$(now)" "$$" "${ME:--}" > "$UPF"
  resume_wait
  ( umask 077; printf 'env.sh up %s at %s\n' "$1" "$(now)" > "$ENVD/last-up.log" )
  ( up_where "$1" ); rc=$?
  printf 'done %s %s %s %s\n' "$1" "$(now)" "$rc" "${ME:--}" > "$UPF"
  return "$rc"
}
# Where this `up` runs (lib/environment.sh → target_choose): the active Environment when it
# still exists, else a new one; this VM when an Environment is not possible — the reason in the
# output and the log. Moving from this VM stops the product here (its port is the forward's);
# moving back deletes the active Environment (a kept one is never active). A profile that sets
# kvm needs /dev/kvm in the Environment too: none there → it is deleted, and this VM runs the
# product; a link that does not answer that check (3 tries, each time-bound) fails `up` and
# deletes nothing. With nested_target environment there is no fallback: `up` fails with the reason.
up_where() { # <build>
  local choice reason cur n
  read -r choice reason <<<"$(target_choose)"
  cur="$(target_name)"
  if [ "$choice" = environment ]; then
    if [ -n "$cur" ] && env_exists "$cur"; then n="$cur"
    else
      [ -z "$cur" ] && profile_run env down >/dev/null 2>&1
      n="qi-$(date -u +%m%d-%H%M%S)"
      if env_create "$n"; then
        target_set environment "$n"
        logev info env_target "the product runs in Environment $n"
      else
        choice=vm; reason="the platform did not create an Environment"; n=""
      fi
    fi
  fi
  if [ "$choice" = environment ] && profile_kvm; then
    local kvm i
    for i in 1 2 3; do kvm="$(env_has_kvm "$n")"; case "$kvm" in (yes|no) break;; esac; [ "$i" = 3 ] || sleep 3; done
    if [ "$kvm" != yes ] && [ "$kvm" != no ]; then
      echo "env: the link to Environment $n did not answer the /dev/kvm check (3 tries) — it stays; up again later" | tee -a "$(outlog up)" >&2
      logev error env_failed "the link to Environment $n did not answer the /dev/kvm check"
      return 1
    fi
    if [ "$kvm" = no ]; then
      reason="the profile sets kvm, and Environment $n has no /dev/kvm"
      fwd_stop; penv delete "$n" >/dev/null 2>&1 || true; rm -f "$TARGET_F"
      logev warn env_released "Environment $n deleted: $reason"
      choice=vm; [ "$cur" = "$n" ] && cur=""; n=""
    fi
  fi
  if [ "$choice" = environment ]; then
    echo "env: the product runs in Environment $n ($(env_url "$n")); tests reach it at $(profile_field '.app.url')" | tee -a "$(outlog up)" >&2
    penv extend "$n" "$ACTIVE_EXPIRES" >/dev/null 2>&1 || true
    delegate up "$1" || return 1
    fwd_start "$n"
    return
  fi
  if [ "$(cfg nested_target)" = environment ]; then
    echo "env: nested_target is environment, and no Environment runs the product: $reason" | tee -a "$(outlog up)" >&2
    logev error env_target "no Environment for nested_target environment: $reason"
    return 1
  fi
  if [ -n "$cur" ]; then fwd_stop; penv delete "$cur" >/dev/null 2>&1 || true; fi
  target_set vm
  echo "env: the product runs in this VM ($reason)" | tee -a "$(outlog up)" >&2
  logev info env_target "the product runs in this VM: $reason"
  disk_gate && delegate up "$1"
}
cmd_status() {
  local n out
  if n="$(target_name)"; then
    fwd_start "$n" >/dev/null 2>&1
    out="$(delegate status)" || return 1
    jq -c --arg n "$n" --argjson f "$(fwd_alive "$n" && echo true || echo false)" '. + {target: "environment", environment: $n, forward: $f}' <<<"$out"
  else
    out="$(delegate status)" || return 1
    jq -c '. + {target: "vm"}' <<<"$out"
  fi
}
cmd_down() { if target_name >/dev/null; then fwd_stop; else delegate down; fi; }

# A VM restart stops k3s and the product with it, and the Environment's forward; nothing in the
# VM starts them again (a boot service is the platform's to refuse). So the first session after
# a boot does: the build of the last `up` that succeeded, from before this boot, unless `down`
# or `reset` came after it. work/env/RESUME: `running <build> <ISO> <pid>`, `done <build> <ISO>
# <exit>`, or `off - <ISO> -` (down, reset). Never a verdict; a failed resume leaves the next
# `up` to install as usual.
RESF="$ENVD/RESUME"
iso_epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s 2>/dev/null; }
boot_epoch() { [ -n "${QI_BOOT_EPOCH:-}" ] && { echo "$QI_BOOT_EPOCH"; return; }; awk '$1 == "btime" {print $2}' /proc/stat 2>/dev/null; }
# A `running` record from before this boot is dead: after a restart its pid can be another process's.
resume_running() {
  local st b ts x _ boot
  [ -f "$RESF" ] && read -r st b ts x _ < "$RESF" && [ "$st" = running ] || return 1
  boot="$(boot_epoch)"; ts="$(iso_epoch "$ts")"
  [ -n "$boot" ] && [ -n "$ts" ] && [ "$ts" -lt "$boot" ] && return 1
  kill -0 "$x" 2>/dev/null
}
resume_off() { mkdir -p "$ENVD" && printf 'off - %s -\n' "$(now)" > "$RESF"; }
# The build to bring back, or nothing (exit 1).
resume_due() {
  local boot st b ts x _ up rs rts rx
  boot="$(boot_epoch)"; [ -n "$boot" ] || return 1
  [ -f "$UPF" ] && read -r st b ts x _ < "$UPF" || return 1
  [ "$st" = done ] && [ "$x" = 0 ] || return 1
  up="$(iso_epoch "$ts")" && [ -n "$up" ] && [ "$up" -lt "$boot" ] || return 1
  if [ -f "$RESF" ] && read -r rs _ rts rx _ < "$RESF"; then
    rts="$(iso_epoch "$rts")" || return 1
    [ "$rs" = off ] && [ "$rts" -ge "$up" ] && return 1
    [ "$rs" != off ] && [ "$rts" -ge "$boot" ] && return 1
  fi
  echo "$b"
}
cmd_resume() {
  local b pid
  mkdir -p "$ENVD" && chmod 700 "$ENVD"
  lock_mutex "$ENVD/RESUME.mutex" || return 0
  b="$(resume_due)" || { rm -f "$ENVD/RESUME.mutex"; return 0; }
  ( umask 077; printf 'env.sh resume %s at %s\n' "$b" "$(now)" > "$ENVD/last-resume.log" )
  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$0" resume-run "$b" </dev/null >/dev/null 2>&1 & pid=$!
  else
    nohup bash "$0" resume-run "$b" </dev/null >/dev/null 2>&1 & pid=$!
  fi
  printf 'running %s %s %s\n' "$b" "$(now)" "$pid" > "$RESF"
  rm -f "$ENVD/RESUME.mutex"
  logev info env_resume "the VM started again: bringing build $b back in the background"
  echo "quality-inspector: this VM started again after a restart, so the product was down; env.sh resume brings build $b back in the background (a few minutes; work/env/last-resume.log). env.sh status says when it answers; a Browser Panel tab open before the restart is empty — open the product's URL again (env.sh watch)."
}
# A resume keeps the target of the last `up` (work/env/TARGET): it never chooses one
# (target_choose), never makes or deletes an Environment. That Environment gone → exit 4, nothing
# resumed; the next `up` chooses where.
resume_up() { # <build>
  local n
  if n="$(target_name)"; then
    env_exists "$n" || { echo "env: Environment $n of the last up is gone — nothing resumed; the next up chooses where" | tee -a "$(outlog up)" >&2; return 4; }
    delegate up "$1" || return 1
    fwd_start "$n"
  else
    disk_gate && delegate up "$1"
  fi
}
cmd_resume_run() { # <build>
  local rc
  ME="" OUTLOG_AS=resume
  ( resume_up "$1" ) >/dev/null 2>&1; rc=$?   # its output goes to last-resume.log (outlog)
  case "$rc" in
    (0) logev info env_resume "build $1 answers again" ;;
    (4) logev warn env_resume "the Environment of the last up is gone: build $1 not resumed" ;;
    (*) logev error env_failed "resume of build $1 exited $rc (output: work/env/last-resume.log)" ;;
  esac
  printf 'done %s %s %s\n' "$1" "$(now)" "$rc" > "$RESF"
}
# An `up`, `reset` or `down` waits for a resume to end (at most 15 minutes — QI_RESUME_WAIT_S,
# tests —, then stops it and records exit 143).
resume_wait() {
  local st b ts x _ max="${QI_RESUME_WAIT_S:-900}" end
  case "$max" in (''|*[!0-9]*) max=900;; esac
  end=$(( $(date -u +%s) + max ))
  while resume_running; do
    if [ "$(date -u +%s)" -ge "$end" ]; then
      read -r st b ts x _ < "$RESF"; kill -- -"$x" 2>/dev/null || kill "$x" 2>/dev/null
      printf 'done %s %s 143\n' "$b" "$(now)" > "$RESF"
      logev warn env_resume "resume of build $b stopped after $((max / 60)) minutes"; break
    fi
    sleep 5
  done
}

cmd_wait() { # <build> [<seconds>]
  local want="$1" max="${2:-540}" end st b ts x who
  case "$max" in (''|*[!0-9]*) max=540;; esac
  end=$(( $(date -u +%s) + max ))
  while :; do
    st=""; [ -f "$UPF" ] && read -r st b ts x who < "$UPF"
    if [ -z "$st" ] || [ "$b" != "$want" ] || { [ -n "$ME" ] && [ "${who:--}" != "$ME" ]; }; then
      echo "env: this session started no install of $want — env.sh up $want first" >&2; return 1
    fi
    case "$st" in
      (done) [ "$x" = 0 ] && { echo "env: $b is up ($ts)" >&2; return 0; }
             echo "env: the install of $b failed (exit $x, $ts) — docs/nested-env.md → Failures; its last lines (all: work/env/last-up.log):" >&2
             outtail up 30 >&2; return 1;;
      (running) kill -0 "$x" 2>/dev/null || { echo "env: the install of $b (started $ts) died without a result; its last lines (all: work/env/last-up.log):" >&2; outtail up 30 >&2; return 1; };;
      (*) echo "env: unreadable work/env/UP" >&2; return 1;;
    esac
    [ "$(date -u +%s)" -lt "$end" ] || { echo "env: $b still installing (since $ts) — run env.sh wait again" >&2; return 3; }
    sleep 5
  done
}

case "${1:-}" in
  between) [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: $0 between <from> <to>" >&2; exit 1; }; cmd_between "$2" "$3" ;;
  lock)   cmd_lock "${2:-}" ;;
  unlock) cmd_unlock "${2:-}" ;;
  init)   delegate init ;;
  reset)  resume_wait; resume_off; delegate reset ;;
  status) cmd_status ;;
  down)   resume_wait; resume_off; cmd_down ;;
  resume) cmd_resume ;;
  resume-run) [ -n "${2:-}" ] || exit 2; cmd_resume_run "$2" ;;
  where)  cmd_where ;;
  keep)   [ -n "${2:-}" ] || { echo "usage: $0 keep <label> [<days>]" >&2; exit 2; }; cmd_keep "$2" "${3:-}" ;;
  extend) [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "usage: $0 extend <label> <days>" >&2; exit 2; }; cmd_extend "$2" "$3" ;;
  release) [ -n "${2:-}" ] || { echo "usage: $0 release <label|name>" >&2; exit 2; }; cmd_release "$2" ;;
  kept)   cmd_kept ;;
  up)     [ -n "${2:-}" ] || { echo "usage: $0 up <build>" >&2; exit 2; }; cmd_up "$2" ;;
  wait)   [ -n "${2:-}" ] || { echo "usage: $0 wait <build> [<seconds>]" >&2; exit 2; }; cmd_wait "$2" "${3:-}" ;;
  watch)  live_link "$(profile_field '.app.url')" ;;
  *) echo "usage: $0 lock <owner>|unlock <owner>|init|up <build>|wait <build> [<seconds>]|reset|status|down|resume|where|keep <label> [<days>]|extend <label> <days>|release <label|name>|kept|between <from> <to>|watch" >&2; exit 2 ;;
esac
