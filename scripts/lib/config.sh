#!/usr/bin/env bash
# config.sh — the one reader for `work/CONFIG.md`. Sourced by every script that
# reads configuration: `preflight.sh` (the runtime) and `verify-onboarding.sh`
# (which judges the file the runtime will read).
#
# It lives here, once, because the two must agree byte for byte. A verifier that
# parses a value differently from the runtime passes a file the runtime then
# mis-parses — and two copies of a function drift silently, so there is one.
# Expects $CONFIG to be set by the caller.
#
# The contract these implement is stated in CLAUDE.md → **Runtime configuration**;
# change it here and there in the same PR, never in one alone.

# A scalar key: `- <key>: <value>`. The first match wins; a trailing `#` comment,
# surrounding whitespace and one layer of surrounding quotes/backticks are stripped.
cfg() { sed -n "s/^- $1:[[:space:]]*//p" "$CONFIG" 2>/dev/null | head -1 \
        | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' \
              -e 's/^[`"'"'"']//' -e 's/[`"'"'"']$//'; }

# The testing modules' registry (lib/modules.json, docs/modules.md) — the one home of its keys'
# types and ranges. `reg <key>` is how every script reads such a key: the bullet when it fits its
# type, else the default — never the raw bullet. Exit 2 for a key the registry does not name.
QI_REGISTRY="${BASH_SOURCE[0]%/*}/modules.json"
reg_spec() { jq -c --arg k "$1" '[.global, (.modules[].settings)] | add | .[$k] // empty' "$QI_REGISTRY" 2>/dev/null; }
reg_valid() { # <spec-json> <value> -> 0 when the value fits the spec's type
  local t v="$2" p w h; t="$(jq -r .type <<<"$1")"
  case "$t" in
    enum) jq -e --arg v "$v" '.values | index($v) != null' <<<"$1" >/dev/null ;;
    cadence) jq -e --arg v "$v" '.cadences | index($v) != null' "$QI_REGISTRY" >/dev/null ;;
    int) case "$v" in (''|*[!0-9]*) return 1;; esac
         [ "${#v}" -le 6 ] && jq -e --argjson v "$v" '$v >= .min and $v <= .max' <<<"$1" >/dev/null ;;
    viewports) [[ "$v" =~ ^[0-9]{3,4}x[0-9]{3,4}(\ *,\ *[0-9]{3,4}x[0-9]{3,4}){0,3}$ ]] || return 1
         for p in ${v//,/ }; do w="${p%x*}"; h="${p#*x}"
           [ "$w" -ge 320 ] && [ "$w" -le 3840 ] && [ "$h" -ge 480 ] && [ "$h" -le 2400 ] || return 1; done ;;
    *) return 1 ;;
  esac
}
reg_of() { # <key> <spec-json> — the effective value
  local v; v="$(cfg "$1")"
  if [ -n "$v" ] && reg_valid "$2" "$v"; then printf '%s\n' "$v"; else jq -r '.default' <<<"$2"; fi
}
reg() { local s; s="$(reg_spec "${1:-}")"; [ -n "$s" ] || return 2; reg_of "$1" "$s"; }

# Keys a version dropped: a restore deletes their lines (work-backup.sh), the verifier warns
# about one left behind. Space-separated.
CONFIG_OBSOLETE_KEYS="profile_source_path"

# agent_login [gh host args…]: the agent's own GitHub login — `github_login` when set (a
# GitHub App installation token gets 403 from `gh api user`; its comments are `<slug>[bot]`),
# else `gh api user`. Prints it, or nothing (exit 1).
agent_login() {
  local l; l="$(cfg github_login)"
  # gh prints an HTTP error's body to stdout and exits 1: trust the exit status, not the output.
  [ -n "$l" ] || l="$(gh api "$@" user --jq .login 2>/dev/null)" || l=""
  [ -n "$l" ] && printf '%s\n' "$l"
}

# Rows of a `## <heading>` config table, bounded at the NEXT `## ` heading —
# an unbounded range would swallow every later table in the file.
cfg_table() { sed -n "/^## $1\$/,/^## /p" "$CONFIG" 2>/dev/null \
              | grep '^|' | tail -n +3; }

# direct_session: 0 when this shell runs in the operator's direct session — no run marker
# younger than lock_ttl_min (a scheduled turn), not a channel turn (lib/channel.sh: Slack, or a
# viewer of the shared dashboard), and this session's transcript found. Fails closed; the
# reason is in $WHY_NOT_DIRECT. The scripts' own half of docs/persistence.md → Scheduled or
# direct session (the policy hook is the other).
WHY_NOT_DIRECT=""
direct_session() {
  local ttl m t
  ttl="$(cfg lock_ttl_min)"; case "$ttl" in (''|*[!0-9]*) ttl=180;; esac
  m="${WORK_DIR:-${HOME:-/home/agent}/work}/env/RUN_MODE"
  [ -f "$m" ] && [ -n "$(find "$m" -mmin -"$ttl" 2>/dev/null)" ] && { WHY_NOT_DIRECT="a scheduled turn"; return 1; }
  . "${BASH_SOURCE[0]%/*}/channel.sh" 2>/dev/null || { WHY_NOT_DIRECT="lib/channel.sh is missing"; return 1; }
  t="$(session_transcript)" || { WHY_NOT_DIRECT="this session's transcript is not found, so it cannot be shown direct"; return 1; }
  transcript_is_channel "$t" && { WHY_NOT_DIRECT="a channel turn"; return 1; }
  return 0
}

# live_cdp: the live_browser CDP endpoint when a run may attach to it — set, on this VM, in a
# direct session, and answering. Prints it, or nothing (docs/test-authoring.md → Watching
# live). Not direct = a run marker younger than lock_ttl_min (a scheduled turn), or a channel
# turn (lib/channel.sh), or a session whose transcript cannot be found: all run headless.
live_cdp() {
  local u ttl m t; u="$(cfg live_browser)"
  case "$u" in (''|disabled) return 1;; (http://127.0.0.1:*|http://localhost:*) ;;
    (*) echo "live_browser '$u' is not a CDP endpoint on this VM — running headless" >&2; return 1;; esac
  direct_session || { echo "live_browser: $WHY_NOT_DIRECT — running headless" >&2; return 1; }
  curl -fsS --noproxy '*' --max-time 3 -o /dev/null "${u%/}/json/version" 2>/dev/null \
    || { echo "live_browser $u does not answer — running headless" >&2; return 1; }
  printf '%s\n' "${u%/}"
}

# live_link <url>: the chat button that opens the Browser Panel on <url> (the platform's
# `platform://browser` link; one made in the last two minutes opens the panel by itself),
# only when live_cdp attaches. Prints it, or nothing (exit 1).
live_link() {
  case "${1:-}" in (http://*|https://*) ;; (*) return 1;; esac
  live_cdp >/dev/null || return 1
  printf '[Watch the test](platform://browser?url=%s&at=%s)\n' \
    "$(jq -rn --arg u "$1" '$u|@uri')" "$(( $(date +%s) * 1000 ))"
}
