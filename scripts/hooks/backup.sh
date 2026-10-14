#!/usr/bin/env bash
# backup.sh — Claude Code Stop hook: back up work/ to `work_repo` after every turn of the main
# agent (docs/persistence.md → Backup & restore). Registered by scripts/hooks/install.sh.
#
# It never influences the model or the turn: its input is read and discarded, it prints
# nothing, and it always exits 0 at once (exit 2 would make the agent continue). The persist
# runs fully detached, so it neither delays the turn nor dies with a headless run's teardown;
# its lock serializes overlapping turns. The harness runs this, not the agent, so no injected
# instruction can skip or redirect it; work-backup.sh takes its destination from
# work/CONFIG.md alone and is a no-op without `work_repo`.

cat >/dev/null 2>&1
wb="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/work-backup.sh"
if command -v setsid >/dev/null 2>&1; then
  LOG_JOB=backup setsid nohup bash "$wb" persist </dev/null >/dev/null 2>&1 &
else
  LOG_JOB=backup nohup bash "$wb" persist </dev/null >/dev/null 2>&1 &
fi
exit 0
