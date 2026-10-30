#!/usr/bin/env bash
# resume.sh — Claude Code SessionStart hook: after the platform restarted this VM (it hibernates an
# idle one), bring the nested product back at the build it ran (scripts/env.sh resume,
# docs/nested-env.md → After a VM restart). Registered by scripts/hooks/install.sh.
#
# Its input is read and discarded; it exits 0 at once. The install runs detached; the one line
# env.sh prints when it starts one is the session's context, so the agent knows the product is
# coming back and an earlier Browser Panel tab is empty.

cat >/dev/null 2>&1
env_sh="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/env.sh"
LOG_JOB=env bash "$env_sh" resume 2>/dev/null </dev/null
exit 0
