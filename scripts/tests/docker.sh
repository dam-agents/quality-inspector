#!/usr/bin/env bash
# docker.sh [--rebuild] [--or-native] [test-file…] — run the offline suite
# (run.sh, same arguments) in an ubuntu:24.04 container, close to the CI runner.
# For a developer machine: run.sh on macOS comes here itself; CI and the agent's
# VM run run.sh directly.
#
# Environment workaround (docs/self-modification.md §5a): on a macOS host whose
# endpoint security agent authorizes every exec, one process start costs
# ~140 ms, and the exec-bound suite takes tens of minutes instead of ~15 s. The
# defect is on the host; its real fix is there (an exclusion for the test temp
# dirs, or a faster agent). In the container's VM the execs do not reach that
# agent, and the run also leaves the host's own Node, jq and git config behind.
# Delete this script and run.sh's delegation to it once the host runs the suite
# at CI speed again.
#
# The engine is the docker CLI's daemon. A Rancher Desktop that is not running
# is started (rdctl from PATH or ~/.rd/bin), and the run waits for its daemon up
# to QI_TEST_ENGINE_WAIT seconds (default 180). With no answering daemon the
# run fails — or, with --or-native, runs run.sh on the host instead.
#
# The image is built once and tagged with the hash of its Dockerfile, so a
# change to the Dockerfile builds a new one; --rebuild forces a fresh build.
# The checkout's files (tracked, plus untracked files git does not ignore) are
# copied into the container: the run never writes to the host checkout.
# QI_TEST_JOBS passes through. The run holds the host lock of suite-lock.sh for
# the build and the container, so it waits for any other suite run.
set -u
CALLER_DIR="$(pwd)"
cd "$(dirname "$0")" || exit 1
CHECKOUT="$(cd ../.. && pwd)"

REBUILD=0 OR_NATIVE=0
while :; do
  case "${1:-}" in
    (--rebuild) REBUILD=1; shift;;
    (--or-native) OR_NATIVE=1; shift;;
    (*) break;;
  esac
done

# Rancher Desktop's CLIs live in ~/.rd/bin, which a non-login shell can lack
if [ -d "$HOME/.rd/bin" ]; then
  case ":$PATH:" in (*":$HOME/.rd/bin:"*) ;; (*) PATH="$PATH:$HOME/.rd/bin";; esac
fi

engine_up() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

# Start Rancher Desktop only when its VM is down: `rdctl start` on a started VM
# restarts the backend under any container another run has open.
if ! engine_up && command -v rdctl >/dev/null 2>&1; then
  state="$(rdctl api /v1/backend_state 2>/dev/null)" || state=""
  case "$state" in
    (*STARTED*|*ERROR*) ;;   # the VM is up and its daemon still does not answer
    (*)
      case "$state" in
        (*STARTING*) ;;
        (*) echo ".. starting Rancher Desktop" >&2; (rdctl start >/dev/null 2>&1 &);;
      esac
      limit="${QI_TEST_ENGINE_WAIT:-180}"
      case "$limit" in (''|*[!0-9]*) limit=180;; esac
      waited=0
      until engine_up || [ "$waited" -ge "$limit" ]; do sleep 2; waited=$((waited + 2)); done;;
  esac
fi

if ! engine_up; then
  if [ "$OR_NATIVE" -eq 1 ]; then
    echo "warning: no container engine answers; the suite runs on the host, which on macOS can take tens of minutes" >&2
    cd "$CALLER_DIR" || exit 1
    QI_TEST_DOCKER=0 exec bash "$CHECKOUT/scripts/tests/run.sh" "$@"
  fi
  command -v docker >/dev/null 2>&1 \
    || { echo "tests: docker is not installed"; exit 1; }
  echo "tests: the docker daemon does not answer (start Docker / Rancher Desktop)"; exit 1
fi

# Resolve each argument as run.sh does — a bare name of this directory stays one,
# anything else is a path from the caller's directory — and map a path into the
# container's copy of the checkout. A typo fails here, before the lock.
ARGS=""
for a in "$@"; do
  case "$a" in (*[[:space:]]*) echo "tests: test file path has whitespace: $a"; exit 1;; esac
  if [ "${a#*/}" = "$a" ] && [ -f "$a" ]; then ARGS="$ARGS $a"; continue; fi
  p="$a"; case "$p" in (/*) ;; (*) p="$CALLER_DIR/$a";; esac
  [ -f "$p" ] || { echo "tests: no such test file: $a"; exit 1; }
  p="$(cd "$(dirname "$p")" && pwd)/$(basename "$p")"
  case "$p" in
    ("$CHECKOUT"/*) ARGS="$ARGS /home/tester/qi/${p#"$CHECKOUT"/}";;
    (*) echo "tests: test file is outside the checkout: $a"; exit 1;;
  esac
done

# procps: ps for the suite lock. A non-root user: as root, a test that expects
# an unwritable path could write it.
DOCKERFILE='FROM ubuntu:24.04
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git jq curl ca-certificates procps nodejs \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -m tester
USER tester
WORKDIR /home/tester'
IMAGE="qi-tests:$(printf '%s' "$DOCKERFILE" | git hash-object --stdin | cut -c1-12)"

. ./suite-lock.sh
trap 'release_lock' EXIT
take_lock || exit 1

if [ "$REBUILD" -eq 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo ".. building $IMAGE" >&2
  printf '%s\n' "$DOCKERFILE" | docker build -q -t "$IMAGE" - >/dev/null \
    || { echo "tests: docker build of $IMAGE failed"; exit 1; }
fi

# COPYFILE_DISABLE: macOS tar would add ._* metadata files to the archive; the
# container's tar warns about macOS xattr headers, hence its silenced stderr.
git -C "$CHECKOUT" ls-files -z --cached --others --exclude-standard \
  | (cd "$CHECKOUT" && COPYFILE_DISABLE=1 tar -c --null -T - -f -) \
  | docker run --rm -i -e QI_TEST_JOBS="${QI_TEST_JOBS:-}" "$IMAGE" bash -c '
      mkdir qi && tar -x -f - -C qi 2>/dev/null || { echo "tests: copy into the container failed"; exit 1; }
      exec bash qi/scripts/tests/run.sh "$@"' run.sh $ARGS
