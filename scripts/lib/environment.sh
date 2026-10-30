#!/usr/bin/env bash
# environment.sh — where the nested product runs: in this agent's VM (`vm`) or in a platform
# Environment of this agent's own (`environment`), and the Environments kept for a person to
# look at after a run (docs/nested-env.md → Where the product runs). Sourced by env.sh after
# lib/config.sh, lib/profile.sh and log.sh; needs ENVD, WORK and SCRIPT_DIR.
#
# The choice (nested_target: auto | vm | environment, default auto) is made at `env.sh up`:
# an Environment when the profile declares one (`environment` in profile.json), the agent does
# not lend its model (an Environment holds no connection), this VM has /dev/kvm when the profile
# sets `engine_config.kvm` (the platform gives an Environment the device on the same terms as
# this VM, and its tools say nothing of it), and the platform's Environment tools answer; else
# this VM, with the reason logged (with `environment`, env.sh up fails instead). With kvm,
# env.sh up then looks for /dev/kvm in the Environment itself (env_has_kvm): none there → the
# Environment is deleted and the product runs in this VM (with `environment`, up fails); no
# answer → up fails, and the Environment stays.
# In an Environment the profile's `bin/env` runs over the Environment Link (`ssh env-<name>`),
# from a copy of the profile and the engines in ~/qi there, and one `ssh -L` keeps the product
# at the profile's app.url on this VM — so every test, CLI and API call addresses localhost in
# both. Credentials are made here by `init` and copied over at every call; nothing else of
# work/ leaves this VM.
#
# State: work/env/TARGET (`vm` or `environment <name>`), work/env/FORWARD (`<pid> <name>
# <port>`), work/ENVIRONMENTS.json (the kept ones: [{name, label, build, url, account,
# kept_utc, expires_utc}]; account = the username of the profile's `environment.account`
# role, never a password).

TARGET_F="$ENVD/TARGET"
FWD_F="$ENVD/FORWARD"
KEPT_F="$WORK/ENVIRONMENTS.json"
KEEP_DAYS_DEFAULT=3
ACTIVE_EXPIRES=2d
KVM_DEV="${QI_KVM_DEVICE:-/dev/kvm}"   # this VM's device; the tests point it at a file
KVM_PROBE_S="${QI_KVM_PROBE_S:-30}"    # one /dev/kvm check in an Environment, at most; the tests shorten it

penv() { node "$SCRIPT_DIR/lib/platform-env.mjs" "$@"; }
# One SSH master per Environment for the commands (not the forward), so each call after the
# first skips the link's set-up; it closes after ten idle minutes, as an open link keeps both
# machines awake.
essh() { local n="$1"; shift
  ssh -o ControlMaster=auto -o "ControlPath=$ENVD/ssh-%C" -o ControlPersist=10m -o BatchMode=yes "env-$n" "$@"; }

target_now() { local t; t="$(cat "$TARGET_F" 2>/dev/null)"; printf '%s\n' "${t:-vm}"; }
target_name() { local t n; read -r t n < <(target_now); [ "$t" = environment ] && [ -n "${n:-}" ] && printf '%s\n' "$n"; }
target_set() { mkdir -p "$ENVD"; printf '%s\n' "$*" > "$TARGET_F"; }

app_port() { local u; u="$(profile_field '.app.url')"; u="${u#*://}"; u="${u%%/*}"; case "$u" in (*:*) echo "${u##*:}";; (*) echo 80;; esac; }

# `environment` or `vm <reason>`.
target_choose() {
  local pref; pref="$(cfg nested_target)"
  case "$pref" in (vm|environment|auto) ;; (*) pref=auto;; esac
  [ "$pref" = vm ] && { echo "vm nested_target is vm"; return; }
  [ "$(profile_field '.environment.endpoints | length')" -gt 0 ] 2>/dev/null \
    || { echo "vm the profile declares no environment"; return; }
  [ "$(cfg lend_model)" = enabled ] && { echo "vm lend_model is enabled, and an Environment holds no connection"; return; }
  profile_kvm && [ ! -e "$KVM_DEV" ] && { echo "vm the profile sets kvm, and this VM has no /dev/kvm, so an Environment has none either"; return; }
  command -v ssh >/dev/null 2>&1 || { echo "vm no ssh client"; return; }
  local why; why="$(penv available 2>&1 >/dev/null)" || { echo "vm the platform's Environments do not answer: ${why#platform-env: }"; return; }
  echo environment
}

profile_kvm() { [ "$(profile_field '.engine_config.kvm')" = true ]; }
# Whether the Environment has /dev/kvm: `yes` or `no`; anything else (empty) — its link did not
# answer. Time-bound (10 s to connect, KVM_PROBE_S in all), so a link that hangs is a no-answer try.
env_has_kvm() {
  timeout "$KVM_PROBE_S" ssh -o ConnectTimeout=10 -o ControlMaster=auto -o "ControlPath=$ENVD/ssh-%C" -o ControlPersist=10m \
    -o BatchMode=yes "env-$1" 'if test -e /dev/kvm; then echo yes; else echo no; fi' 2>/dev/null
}

env_exists() { penv list 2>/dev/null | jq -e --arg n "$1" 'any(.[]; .name == $n)' >/dev/null; }
env_url() { penv list 2>/dev/null | jq -r --arg n "$1" --arg e "${2:-app}" '.[] | select(.name == $n) | .endpoints[]? | select(.name == $e) | .url // empty' | head -1; }

# A new Environment for this run. At the platform's cap, the oldest kept one goes first, once.
env_create() { # <name>
  local spec rc
  spec="$(jq -c --arg exp "$ACTIVE_EXPIRES" '.environment | {endpoints, expires: $exp,
      start: "bash $HOME/qi/boot.sh"} + (if .storage then {storage} else {} end)' "$(profile_dir)/profile.json")"
  penv create "$1" "$spec" >/dev/null; rc=$?
  if [ "$rc" = 4 ]; then
    local oldest; oldest="$(jq -r 'sort_by(.kept_utc) | .[0].name // empty' "$KEPT_F" 2>/dev/null)"
    [ -n "$oldest" ] || return 1
    echo "env: the platform's Environment cap is reached — releasing the oldest kept one, $oldest" >&2
    logev warn env_released "kept Environment $oldest released for a new run (cap reached)"
    kept_drop "$oldest"; penv delete "$oldest" >/dev/null 2>&1 || true
    penv create "$1" "$spec" >/dev/null || return 1
  fi
  [ "$rc" = 0 ] || [ "$rc" = 4 ] || return 1
  return 0
}

# Copy the profile, the engines, the credentials and the three wrappers into ~/qi on the
# Environment: run.sh runs a profile command with the contract's environment, kubectl.sh is
# `k3s kubectl` for read-only diagnosis, boot.sh brings the recorded build back up at every
# boot (the Environment's `start`). A plain ssh shell there can miss k3s on its PATH: both
# run.sh and kubectl.sh set it first (ENV_PATH_SETUP).
ENV_PATH_SETUP='command -v k3s >/dev/null 2>&1 || eval "$(MISE_SYSTEM_DATA_DIR=/usr/share/mise /usr/local/bin/mise env -s bash 2>/dev/null)"'
env_sync() { # <name>
  local n="$1" dir core stage eps exe rel first
  local -a run
  dir="$(profile_dir)" || return 3
  core="$(cd "$SCRIPT_DIR/.." && pwd)"
  exe="$(profile_bin env)" || { echo "profile has no bin/env and its engine none either" >&2; return 3; }
  case "$exe" in ("$dir"/*) rel="profile/${exe#"$dir"/}";; ("$core"/*) rel="core/${exe#"$core"/}";; (*) return 3;; esac
  run=(bash)
  if IFS= read -r first < "$exe" && [ "${first#'#!'}" != "$first" ]; then read -r -a run <<<"${first#'#!'}"; fi
  eps="$(penv list | jq -c --arg n "$n" '[.[] | select(.name == $n) | .endpoints[]? | {(.name): (.url // "")}] | add // {}')" || return 1
  stage="$(mktemp -d "${TMPDIR:-/tmp}/quality-inspector-envsync.XXXXXX")" || return 1
  mkdir -p "$stage/profile" "$stage/core/engines" "$stage/env"
  cp -R "$dir/." "$stage/profile/" && cp -R "$core/engines/." "$stage/core/engines/" \
    && ( umask 077; cp "$ENVD/credentials.env" "$stage/env/credentials.env" ) || { rm -rf "$stage"; return 1; }
  {
    echo '#!/usr/bin/env bash'
    echo '# Written by quality-inspector env.sh (lib/environment.sh) at every call; do not edit.'
    echo 'export QI_WORK="$HOME/qi" QI_ENV_DIR="$HOME/qi/env" QI_PROFILE_DIR="$HOME/qi/profile" QI_NESTED_TARGET=environment'
    printf 'export QI_PROFILE_CONFIG=%q QI_ENGINE_CONFIG=%q QI_ENV_ENDPOINTS=%q\n' \
      "$(profile_config)" "$(jq -c '.engine_config // {}' "$dir/profile.json")" "$eps"
    printf 'export QI_CANDIDATE_CHANNEL=%q QI_BASELINE_CHANNEL=%q\n' "$(cfg candidate_channel)" "${QI_BASELINE_OVERRIDE:-$(cfg baseline_channel)}"
    echo 'export QI_MODEL_KEY= QI_MODEL_KIND= QI_MODEL_BASE_URL='
    printf '%s\n' "$ENV_PATH_SETUP"
    echo 'cd "$QI_WORK" || exit 1'
    printf 'exec %s "$HOME/qi/%s" "$@"\n' "$(printf '%q ' "${run[@]}")" "$rel"
  } > "$stage/run.sh"
  { echo '#!/usr/bin/env bash'
    echo '# Read-only diagnosis there: k3s kubectl with the PATH of run.sh (security-checks.mjs, the docs).'
    printf '%s\n' "$ENV_PATH_SETUP"
    echo 'exec k3s kubectl "$@"'
  } > "$stage/kubectl.sh"
  cat > "$stage/boot.sh" <<'SH'
#!/usr/bin/env bash
# The Environment's start command: the build recorded last comes back up after a boot.
b="$(jq -r '.build // empty' "$HOME/qi/env/STATE.json" 2>/dev/null)"
[ -n "$b" ] || exit 0
exec bash "$HOME/qi/run.sh" up "$b" >> "$HOME/qi/boot.log" 2>&1
SH
  tar -C "$stage" -czf - . | essh "$n" 'mkdir -p qi && cd qi && rm -rf profile core && umask 077 && tar -xzf - && chmod 700 env'
  local rc=$?; rm -rf "$stage"; return "$rc"
}

env_run() { # <name> <cmd> [args…]
  local n="$1"; shift
  essh "$n" "bash qi/run.sh $(printf '%q ' "$@")"
}

# The forward that keeps the product at app.url on this VM.
fwd_alive() { local p n x _; [ -f "$FWD_F" ] && read -r p n x _ < "$FWD_F" && [ "$n" = "$1" ] && kill -0 "$p" 2>/dev/null; }
fwd_start() { # <name>
  local n="$1" port i; port="$(app_port)"
  fwd_alive "$n" && return 0
  fwd_stop
  ( umask 077; : > "$ENVD/forward.log" )
  setsid nohup ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o BatchMode=yes \
    -L "127.0.0.1:$port:127.0.0.1:$port" "env-$n" >> "$ENVD/forward.log" 2>&1 < /dev/null &
  printf '%s %s %s\n' "$!" "$n" "$port" > "$FWD_F"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    fwd_alive "$n" || break
    curl -s -o /dev/null --noproxy '*' --max-time 3 "http://127.0.0.1:$port/" && return 0
    sleep 2
  done
  fwd_alive "$n" && return 0
  echo "env: the forward of port $port to Environment $n did not hold (work/env/forward.log)" >&2
  return 1
}
fwd_stop() { local p _; [ -f "$FWD_F" ] && read -r p _ < "$FWD_F" && kill "$p" 2>/dev/null; rm -f "$FWD_F"; return 0; }

# ---------------------------------------------------------------- kept ----
kept_rows() { [ -s "$KEPT_F" ] && jq -c '.[]' "$KEPT_F" 2>/dev/null; }
kept_write() { mkdir -p "$WORK"; jq -s '.' > "$KEPT_F.tmp" && mv -f "$KEPT_F.tmp" "$KEPT_F"; }
kept_drop() { kept_rows | jq -c --arg n "$1" 'select(.name != $n)' | kept_write; }

# keep <label> [<days>]: the active Environment stays as the run left it, for <days> (default
# 3, at most 30), under <label> (issue-<n>, scenario-s-<k>, regression-<build>); an earlier
# one of the same label is released. The next `up` makes a new Environment.
cmd_keep() { # <label> [<days>]
  local label="$1" days="${2:-$KEEP_DAYS_DEFAULT}" n url build old role acct=""
  printf '%s' "$label" | grep -qE '^[a-z0-9][a-z0-9.-]{0,47}$' || { echo "env: keep: '$label' is not a label ([a-z0-9.-])" >&2; return 2; }
  case "$days" in (''|*[!0-9]*) echo "env: keep: days must be a whole number" >&2; return 2;; esac
  [ "$days" -ge 1 ] && [ "$days" -le 30 ] || { echo "env: keep: days must be 1 to 30" >&2; return 2; }
  n="$(target_name)" || { echo "env: nothing to keep — the product runs in this VM (env.sh where); env.sh extend gives a kept one more days" >&2; return 1; }
  for old in $(kept_rows | jq -r --arg l "$label" --arg n "$n" 'select(.label == $l and .name != $n) | .name'); do
    penv delete "$old" >/dev/null 2>&1 || true; kept_drop "$old"
  done
  penv extend "$n" "${days}d" || return 1
  url="$(env_url "$n")"
  build="$(awk '{print $2}' "$ENVD/UP" 2>/dev/null)"
  role="$(profile_field '.environment.account')"
  [ -n "$role" ] && acct="$(sed -n "s/^\(export[[:space:]]*\)\{0,1\}E2E_USER_$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')_USERNAME=//p" "$ENVD/credentials.env" 2>/dev/null | head -1 | tr -d "\"'")"
  { kept_rows | jq -c --arg n "$n" 'select(.name != $n)'
    jq -nc --arg n "$n" --arg l "$label" --arg b "$build" --arg u "$url" --arg a "$acct" --arg k "$(now)" \
      --arg e "$(date -u -d "+$days days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+"$days"d +%Y-%m-%dT%H:%M:%SZ)" \
      '{name: $n, label: $l, build: $b, url: $u, account: $a, kept_utc: $k, expires_utc: $e}'
  } | kept_write
  fwd_stop; rm -f "$TARGET_F"
  logev info env_kept "Environment $n kept as $label for $days days"
  jq -c --arg n "$n" '.[] | select(.name == $n)' "$KEPT_F"
}

# extend <label> <days>: a kept Environment stays <days> more from now (the operator's "keep #N
# for <d> days").
cmd_extend() { # <label> <days>
  local label="$1" days="$2" n
  case "$days" in (''|*[!0-9]*) echo "env: extend: days must be a whole number" >&2; return 2;; esac
  [ "$days" -ge 1 ] && [ "$days" -le 30 ] || { echo "env: extend: days must be 1 to 30" >&2; return 2; }
  n="$(kept_rows | jq -r --arg l "$label" 'select(.label == $l or .name == $l) | .name' | head -1)"
  [ -n "$n" ] || { echo "env: extend: nothing kept as $label (env.sh kept)" >&2; return 1; }
  penv extend "$n" "${days}d" || return 1
  kept_rows | jq -c --arg n "$n" --arg e "$(date -u -d "+$days days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+"$days"d +%Y-%m-%dT%H:%M:%SZ)" \
    'if .name == $n then .expires_utc = $e else . end' | kept_write
  logev info env_kept "Environment $n kept $days days more"
  jq -c --arg n "$n" '.[] | select(.name == $n)' "$KEPT_F"
}

# release <label|name>: delete the kept Environment(s) of that label or name, or the active one.
cmd_release() { # <label|name>
  local key="$1" n hit=0
  for n in $(kept_rows | jq -r --arg k "$key" 'select(.label == $k or .name == $k) | .name'); do
    penv delete "$n" >/dev/null 2>&1 || true; kept_drop "$n"; hit=1
    logev info env_released "kept Environment $n released"
  done
  n="$(target_name)" && [ "$n" = "$key" ] && { fwd_stop; penv delete "$n" >/dev/null 2>&1 || true; rm -f "$TARGET_F"; hit=1; }
  [ "$hit" = 1 ] || { echo "env: release: no Environment named or labelled $key" >&2; return 1; }
}

# kept: the kept Environments, each with `exists`; a row whose Environment the platform
# deleted (its expiry passed) is dropped.
cmd_kept() {
  local live; live="$(penv list 2>/dev/null)" || live=''
  if [ -n "$live" ]; then
    kept_rows | jq -c --argjson l "$live" 'select(.name as $n | any($l[]; .name == $n))' | kept_write
  fi
  kept_rows | jq -sc --argjson l "${live:-null}" 'map(. + {exists: (if $l == null then null else (.name as $n | any($l[]; .name == $n)) end)})'
}

cmd_where() {
  local n
  if n="$(target_name)"; then
    jq -nc --arg n "$n" --arg u "$(env_url "$n")" --argjson f "$(fwd_alive "$n" && echo true || echo false)" \
      '{target: "environment", name: $n, url: $u, forward: $f}'
  else echo '{"target":"vm"}'; fi
}
