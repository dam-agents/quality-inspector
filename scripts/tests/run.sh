#!/usr/bin/env bash
# run.sh [test-file…] — offline test runner for the quality-inspector scripts:
# the named files (a name in this directory or a path from the caller's
# directory), or every scripts/tests/test_*.sh. A test file exits non-zero on
# failure; run.sh exits 0 iff every file passed.
#
# Test conventions (each test_*.sh):
#   - Sandbox: create its own WORK_DIR under a temp dir — never touch a real
#     work/ or $HOME; clean up on exit.
#   - Offline: stub external CLIs by prepending scripts/tests/bin to PATH and
#     placing fake executables there (e.g. a `gh` printing canned JSON per
#     argument pattern). Tests must pass with no network and no credentials.
#   - Determinism: pre-flight logic is pure detection, so identical stub output
#     must yield an identical worklist — assert on the emitted JSON (jq).
#
# A behavior change in a script updates its test case in the same PR
# (docs/self-modification.md §9).
#
# Files are sandbox-isolated, so they run concurrently: QI_TEST_JOBS workers, by
# default one per core clamped to 2..8 (QI_TEST_JOBS=1 = serial, for isolating a
# failure). Output is buffered per file and printed in order, so a parallel run
# reads like a serial one; each worker names its file on stderr as it starts, so
# a hung run still names the file it waits for. One suite runs per host at a
# time (suite-lock.sh: QI_TEST_LOCK, QI_TEST_LOCK_WAIT).
#
# On macOS the run moves into docker.sh's container, where it runs at CI speed;
# it stays on the host when no container engine answers, or with
# QI_TEST_DOCKER=0. A run on the host exports QI_TEST_DOCKER=0, so a run.sh
# that a test starts stays on the host too.
set -u
if [ "${QI_TEST_DOCKER:-1}" != 0 ] && [ "$(uname -s 2>/dev/null)" = Darwin ]; then
  exec bash "$(dirname "$0")/docker.sh" --or-native "$@"
fi
export QI_TEST_DOCKER=0
CALLER_DIR="$(pwd)"
cd "$(dirname "$0")" || exit 1
CHECKOUT="$(cd ../.. && pwd)"

# Resolve the named files before anything waits on the lock: a typo fails now.
PICKED=""
for a in "$@"; do
  # a bare name is a file of this directory; anything else is a path
  p="$a"
  if [ "${a#*/}" != "$a" ] || [ ! -f "$a" ]; then
    case "$p" in (/*) ;; (*) p="$CALLER_DIR/$a";; esac
  fi
  case "$p" in (*[[:space:]]*) echo "tests: test file path has whitespace: $p"; exit 1;; esac
  [ -f "$p" ] || { echo "tests: no such test file: $a"; exit 1; }
  PICKED="$PICKED $p"
done

# The work is subprocess-bound: below 2 workers is the serial wall clock, above
# 8 every file starts at once.
jobs="${QI_TEST_JOBS:-}"
if [ -z "$jobs" ]; then
  jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  case "$jobs" in (''|*[!0-9]*) jobs=4;; esac
  [ "$jobs" -lt 2 ] && jobs=2
  [ "$jobs" -gt 8 ] && jobs=8
fi
case "$jobs" in (''|*[!0-9]*|0) jobs=1;; esac

# Long poles first, longest to shortest (measured in docker.sh's container,
# 2026-10-14), so the tail does not decide the wall clock. A name that no longer
# exists is skipped; a file not listed still runs, after these.
SLOWEST="test_policy_hook.sh test_secrets.sh test_engine_helm_k3s.sh test_ledger.sh test_iface.sh"

ORDER="$PICKED"
if [ -z "$ORDER" ]; then
  for t in $SLOWEST; do
    [ -f "$t" ] && ORDER="$ORDER $t"
  done
  for t in test_*.sh; do
    [ -e "$t" ] || { echo "no tests found in $(pwd)"; exit 0; }
    case " $ORDER " in (*" $t "*) continue;; esac
    ORDER="$ORDER $t"
  done
fi

. ./suite-lock.sh
trap 'rm -rf "${OUT_DIR:-}"; release_lock' EXIT
take_lock || exit 1

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qi-run.XXXXXX")" \
  || { echo "tests: no output directory"; exit 1; }

# one worker: run the file, keep its output and its exit code side by side
run_one() { # <test-file>
  local k="${1//\//_}"   # a path's slashes would point outside OUT_DIR
  printf '.. %s\n' "$(basename "$1")" >&2
  bash "$1" > "$OUT_DIR/$k.out" 2>&1
  printf '%s' "$?" > "$OUT_DIR/$k.rc"
  return 0   # the verdict travels in the .rc file, never in the worker's status
}

# Throttle to $jobs workers by waiting on the oldest one: `wait -n` needs bash
# 4.3, and macOS ships 3.2, where a bare `wait` would drain every worker and run
# the rest one at a time. Slowest-first keeps the oldest worker the longest one.
PIDS=""
for t in $ORDER; do
  run_one "$t" &
  PIDS="$PIDS $!"
  set -- $PIDS
  if [ "$#" -ge "$jobs" ]; then
    wait "$1"
    shift
    PIDS="$*"
  fi
done
wait

pass=0; fail=0
for t in $ORDER; do
  k="${t//\//_}"
  [ -f "$OUT_DIR/$k.out" ] && cat "$OUT_DIR/$k.out"
  # no .rc means the worker died without reporting — a failure, not a pass
  if [ "$(cat "$OUT_DIR/$k.rc" 2>/dev/null)" = 0 ]; then
    echo "PASS  $(basename "$t")"; pass=$((pass + 1))
  else
    echo "FAIL  $(basename "$t")"; fail=$((fail + 1))
  fi
done
echo "tests: $pass pass, $fail fail"
[ "$fail" -eq 0 ] || exit 1
