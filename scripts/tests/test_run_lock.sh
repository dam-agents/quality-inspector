#!/usr/bin/env bash
# run.sh and its suite lock (suite-lock.sh): one suite per host — a live holder is
# waited for or named, a dead or ownerless one reclaimed; named files run alone and
# a failing file fails the run; QI_TEST_JOBS=1 runs files one at a time and 2 at
# once; a worker that dies without a verdict fails the run; docker.sh holds the lock
# too and maps file arguments into the container; on macOS run.sh moves into
# docker.sh, which starts a stopped Rancher Desktop and, with no engine, runs on the
# host. Every case points QI_TEST_LOCK into the sandbox — the suite running
# this file holds the host lock itself.
. "$(dirname "$0")/lib.sh"
FAKE_HOME="$SANDBOX/home"; mkdir -p "$FAKE_HOME"

# a test file that records it ran -> its path
dummy_test() { # <name> <exit-code>
  printf '#!/usr/bin/env bash\necho "dummy %s ran"\ntouch "%s/%s.ran"\nexit %s\n' \
    "$1" "$SANDBOX" "$1" "$2" > "$SANDBOX/$1.sh"
  printf '%s' "$SANDBOX/$1.sh"
}
hold_lock() { mkdir -p "$SANDBOX/lock"; printf '%s /checkouts/other\n' "$1" > "$SANDBOX/lock/owner"; }
reset() { rm -rf "$SANDBOX/lock" "$SANDBOX/dbin" "$SANDBOX"/*.ran "$SANDBOX"/docker-* "$SANDBOX"/engine-up \
            "$SANDBOX"/vm-state "$SANDBOX"/rdctl-started; }
run_suite() { # <lock-wait-seconds> <run.sh args…>
  local w="$1"; shift
  OUT="$(QI_TEST_DOCKER=0 QI_TEST_LOCK="$SANDBOX/lock" QI_TEST_LOCK_WAIT="$w" \
    bash "$TESTS_DIR/run.sh" "$@" 2>"$SANDBOX/err")"; RC=$?
}
has() { [ -e "$1" ] && echo yes || echo no; }
out_has() { case "$OUT" in (*"$1"*) echo yes;; (*) echo no;; esac; }

reset; f="$(dummy_test ok 0)"; run_suite 0 "$f"
assert_eq "free lock -> the run passes" 0 "$RC"
assert_eq "the named file ran" yes "$(has "$SANDBOX/ok.ran")"
assert_eq "the summary counts it" yes "$(out_has 'tests: 1 pass, 0 fail')"
assert_eq "the lock is released at exit" no "$(has "$SANDBOX/lock")"

reset; f="$(dummy_test ok 0)"; hold_lock "$$"; run_suite 0 "$f"
assert_eq "live holder, no wait budget -> fails" 1 "$RC"
assert_eq "the failure names the holder" yes "$(out_has "pid $$, checkout /checkouts/other")"
assert_eq "no test ran under a held lock" no "$(has "$SANDBOX/ok.ran")"
assert_eq "the holder keeps its lock" yes "$(has "$SANDBOX/lock/owner")"

reset; f="$(dummy_test ok 0)"; sleep 3 & holder=$!; hold_lock "$holder"; run_suite 30 "$f"
assert_eq "the run starts once the holder exits" 0 "$RC"
grep -q "waiting for the suite run of pid $holder" "$SANDBOX/err" || { echo "  the wait does not name the holder"; FAILED=1; }

reset; f="$(dummy_test ok 0)"; sleep 0 & dead=$!; wait "$dead"; hold_lock "$dead"; run_suite 0 "$f"
assert_eq "a dead holder is reclaimed" 0 "$RC"
assert_eq "the file ran after the reclaim" yes "$(has "$SANDBOX/ok.ran")"

reset; f="$(dummy_test ok 0)"; mkdir -p "$SANDBOX/lock"; touch -t 202001010000 "$SANDBOX/lock"; run_suite 0 "$f"
assert_eq "an ownerless lock older than a minute is reclaimed" 0 "$RC"

if [ "$(id -u)" -ne 0 ]; then   # root can delete a mode-555 dir
  reset; f="$(dummy_test ok 0)"; sleep 0 & dead=$!; wait "$dead"; hold_lock "$dead"; chmod 555 "$SANDBOX/lock"
  run_suite 0 "$f"; chmod 755 "$SANDBOX/lock"
  assert_eq "an undeletable dead lock is waited for, then fails" 1 "$RC"
  assert_eq "no test ran under it" no "$(has "$SANDBOX/ok.ran")"
fi

reset; dummy_test ok 0 >/dev/null; bad="$(dummy_test bad 1)"; run_suite 0 "$bad"
assert_eq "a failing named file fails the run" 1 "$RC"
assert_eq "it is reported as FAIL" yes "$(out_has 'FAIL  bad.sh')"
assert_eq "its output is shown" yes "$(out_has 'dummy bad ran')"
assert_eq "a file not named does not run" no "$(has "$SANDBOX/ok.ran")"

reset; run_suite 0 "$SANDBOX/missing.sh"
assert_eq "an unknown file fails the run" 1 "$RC"
assert_eq "the failure names the cause" yes "$(out_has 'no such test file')"
assert_eq "it fails before the lock is taken" no "$(has "$SANDBOX/lock")"

reset; ok="$(dummy_test ok 0)"; bad="$(dummy_test bad 1)"
OUT="$(QI_TEST_DOCKER=0 QI_TEST_JOBS=2 QI_TEST_LOCK="$SANDBOX/lock" QI_TEST_LOCK_WAIT=0 \
  bash "$TESTS_DIR/run.sh" "$bad" "$ok" 2>/dev/null)"; RC=$?
assert_eq "parallel: one failing file fails the run" 1 "$RC"
assert_eq "parallel: output keeps the given order" "dummy bad ran|FAIL  bad.sh|dummy ok ran|PASS  ok.sh|tests: 1 pass, 1 fail" \
  "$(printf '%s\n' "$OUT" | paste -sd '|' -)"

# slow.sh is busy for a second; peek.sh records "overlap" when it sees slow.sh busy
overlap_pair() {
  printf '#!/usr/bin/env bash\ntouch "%s/slow.busy"; sleep 1; rm -f "%s/slow.busy"; touch "%s/slow.done"\n' \
    "$SANDBOX" "$SANDBOX" "$SANDBOX" > "$SANDBOX/slow.sh"
  printf '#!/usr/bin/env bash\nfor i in $(seq 1 50); do\n  [ -e "%s/slow.busy" ] && { touch "%s/overlap"; exit 0; }\n  [ -e "%s/slow.done" ] && exit 0\n  sleep 0.1\ndone\n' \
    "$SANDBOX" "$SANDBOX" "$SANDBOX" > "$SANDBOX/peek.sh"
  rm -f "$SANDBOX"/slow.busy "$SANDBOX"/slow.done "$SANDBOX"/overlap
}
for j in 1 2; do
  reset; overlap_pair
  OUT="$(QI_TEST_DOCKER=0 QI_TEST_JOBS=$j QI_TEST_LOCK="$SANDBOX/lock" QI_TEST_LOCK_WAIT=0 \
    bash "$TESTS_DIR/run.sh" "$SANDBOX/slow.sh" "$SANDBOX/peek.sh" 2>/dev/null)"; RC=$?
  assert_eq "QI_TEST_JOBS=$j: both files pass" 0 "$RC"
  [ "$j" = 1 ] && want=no || want=yes
  assert_eq "QI_TEST_JOBS=$j: the files overlap = $want" "$want" "$(has "$SANDBOX/overlap")"
done

reset; printf '#!/usr/bin/env bash\necho "dying"\nkill -9 $PPID\n' > "$SANDBOX/die.sh"; run_suite 0 "$SANDBOX/die.sh"
assert_eq "a worker that dies without a .rc fails the run" 1 "$RC"
assert_eq "it is reported as FAIL" yes "$(out_has 'FAIL  die.sh')"

# docker stub: `info` answers once $SANDBOX/engine-up exists, `image inspect` passes,
# `run` records its args and whether the host lock was held, drains the archive, passes.
# rdctl reports the VM state of $SANDBOX/vm-state (none = the app is down) and brings
# the engine up on start; uname says Darwin.
stubs() { # up|down
  mkdir -p "$SANDBOX/dbin"
  printf '#!/usr/bin/env bash\necho Darwin\n' > "$SANDBOX/dbin/uname"
  printf '#!/usr/bin/env bash\ncase "$1" in\n  (info) [ -f "%s/engine-up" ];;\n  (run) shift; [ -f "%s/lock/owner" ] && touch "%s/docker-locked"; printf "%%s\\n" "$*" > "%s/docker-args"; cat >/dev/null; echo "tests: 1 pass, 0 fail";;\nesac\n' \
    "$SANDBOX" "$SANDBOX" "$SANDBOX" "$SANDBOX" > "$SANDBOX/dbin/docker"
  printf '#!/usr/bin/env bash\ncase "$1" in\n  (api) [ -f "%s/vm-state" ] && cat "%s/vm-state";;\n  (start) touch "%s/rdctl-started" "%s/engine-up";;\nesac\n' \
    "$SANDBOX" "$SANDBOX" "$SANDBOX" "$SANDBOX" > "$SANDBOX/dbin/rdctl"
  chmod +x "$SANDBOX/dbin/"*
  [ "$1" = up ] && touch "$SANDBOX/engine-up"
  return 0
}
run_mac() { # <QI_TEST_DOCKER value> <run.sh args…>
  local d="$1"; shift
  OUT="$(PATH="$SANDBOX/dbin:$PATH" HOME="$FAKE_HOME" QI_TEST_DOCKER="$d" QI_TEST_ENGINE_WAIT=4 \
    QI_TEST_LOCK="$SANDBOX/lock" QI_TEST_LOCK_WAIT=0 bash "$TESTS_DIR/run.sh" "$@" 2>"$SANDBOX/err")"; RC=$?
}

reset; stubs up; run_mac '' test_audit.sh
assert_eq "macOS: the run passes when the container passes" 0 "$RC"
assert_eq "macOS: the container runs under the host lock" yes "$(has "$SANDBOX/docker-locked")"
grep -q 'run.sh test_audit.sh' "$SANDBOX/docker-args" 2>/dev/null || { echo "  the named file does not reach run.sh in the container"; FAILED=1; }
assert_eq "macOS: an answering engine is not started again" no "$(has "$SANDBOX/rdctl-started")"
assert_eq "macOS: the lock is released at exit" no "$(has "$SANDBOX/lock")"

reset; stubs up; run_mac '' "$TESTS_DIR/test_audit.sh"
grep -q 'run.sh /home/tester/qi/scripts/tests/test_audit.sh' "$SANDBOX/docker-args" 2>/dev/null \
  || { echo "  a path in the checkout does not become its path in the container"; FAILED=1; }

reset; stubs up; f="$(dummy_test ok 0)"; run_mac '' "$f"
assert_eq "macOS: a file outside the checkout fails the run" 1 "$RC"
assert_eq "the failure names the cause" yes "$(out_has 'outside the checkout')"

reset; stubs up; run_mac '' test_no_such_file.sh
assert_eq "macOS: an unknown bare name fails the run" 1 "$RC"
assert_eq "the failure names the cause" yes "$(out_has 'no such test file')"
assert_eq "macOS: no container starts for an unknown name" no "$(has "$SANDBOX/docker-args")"

reset; stubs up; hold_lock "$$"; run_mac '' test_audit.sh
assert_eq "macOS: a live holder fails the container run" 1 "$RC"
assert_eq "macOS: no container starts under a held lock" no "$(has "$SANDBOX/docker-args")"

reset; stubs up; f="$(dummy_test ok 0)"; run_mac 0 "$f"
assert_eq "QI_TEST_DOCKER=0 runs on the host" 0 "$RC"
assert_eq "the file ran on the host" yes "$(has "$SANDBOX/ok.ran")"
assert_eq "no container starts" no "$(has "$SANDBOX/docker-args")"

reset; stubs down; run_mac '' test_audit.sh
assert_eq "a stopped Rancher Desktop is started, then the container passes" 0 "$RC"
assert_eq "rdctl start ran" yes "$(has "$SANDBOX/rdctl-started")"
grep -q 'starting Rancher Desktop' "$SANDBOX/err" || { echo "  the start is not announced"; FAILED=1; }

reset; stubs down; printf '{"vmState":"STARTED"}' > "$SANDBOX/vm-state"; f="$(dummy_test ok 0)"; run_mac '' "$f"
assert_eq "a started VM with no daemon falls back to the host" 0 "$RC"
assert_eq "a started VM is never started again" no "$(has "$SANDBOX/rdctl-started")"
grep -q 'the suite runs on the host' "$SANDBOX/err" || { echo "  the fallback is not announced"; FAILED=1; }
assert_eq "the file ran on the host" yes "$(has "$SANDBOX/ok.ran")"

reset; stubs down; printf '{"vmState":"STARTED"}' > "$SANDBOX/vm-state"
OUT="$(PATH="$SANDBOX/dbin:$PATH" HOME="$FAKE_HOME" QI_TEST_LOCK="$SANDBOX/lock" \
  bash "$TESTS_DIR/docker.sh" 2>/dev/null)"; RC=$?
assert_eq "docker.sh without --or-native fails with no engine" 1 "$RC"
assert_eq "the failure names the cause" yes "$(out_has 'the docker daemon does not answer')"
exit $FAILED
