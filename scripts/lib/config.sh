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

# Rows of a `## <heading>` config table, bounded at the NEXT `## ` heading —
# an unbounded range would swallow every later table in the file.
cfg_table() { sed -n "/^## $1\$/,/^## /p" "$CONFIG" 2>/dev/null \
              | grep '^|' | tail -n +3; }

# live_cdp: the live_browser CDP endpoint when a run may attach to it — set, on this VM, in a
# direct session (no run marker younger than lock_ttl_min: scheduled and Slack turns run
# headless), and answering. Prints it, or nothing (docs/test-authoring.md → Watching live).
live_cdp() {
  local u ttl m; u="$(cfg live_browser)"
  case "$u" in (''|disabled) return 1;; (http://127.0.0.1:*|http://localhost:*) ;;
    (*) echo "live_browser '$u' is not a CDP endpoint on this VM — running headless" >&2; return 1;; esac
  ttl="$(cfg lock_ttl_min)"; case "$ttl" in (''|*[!0-9]*) ttl=180;; esac
  m="${WORK_DIR:-${HOME:-/home/agent}/work}/env/RUN_MODE"
  [ -f "$m" ] && [ -n "$(find "$m" -mmin -"$ttl" 2>/dev/null)" ] && return 1
  curl -fsS --noproxy '*' --max-time 3 -o /dev/null "${u%/}/json/version" 2>/dev/null \
    || { echo "live_browser $u does not answer — running headless" >&2; return 1; }
  printf '%s\n' "${u%/}"
}
