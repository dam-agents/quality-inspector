#!/usr/bin/env bash
# work-backup.sh — durable backup / restore of work/ to the private `work_repo` of
# work/CONFIG.md (docs/persistence.md → Backup & restore). All git plumbing happens in a
# disposable clone on tmpfs: a .git mutated on the NFS-backed home volume breaks.
#
#   work-backup.sh persist [--allow-delete]   snapshot work/ -> commit -> push; always
#                                             exits 0. The Stop hook (scripts/hooks/backup.sh)
#                                             runs it after every turn of the main agent.
#   work-backup.sh restore [--force]          the backup -> work/ (data only), then verifies
#                                             every file. Exit 0 restored · 2 nothing to
#                                             restore · 1 failed or refused.
#   work-backup.sh check                      read-only: one JSON object for the audit and
#                                             verify-onboarding.sh --live.
#
# The one script that pushes (docs/self-modification.md §4). The destination comes only
# from `work_repo`; persist refuses unless that repository is private, is neither the target
# nor a fork of it, and the snapshot holds no credential value or token. Never force-pushes.
# QI_WORK_BACKUP_REMOTE / _LOCAL / _VERIFIED exist for the offline tests; the policy hook
# denies any agent command that names them.
# Requires: git, tar, jq, gh, node. Sources scripts/log.sh for events.
set -u
export LC_ALL=C

MODE="${1:-}"; OPT="${2:-}"
HOME_DIR="${HOME:-/home/agent}"
WORK="${WORK_DIR:-$HOME_DIR/work}"
CONFIG="$WORK/CONFIG.md"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_JOB="${LOG_JOB:-session}"
if ! . "$SCRIPT_DIR/log.sh" 2>/dev/null; then logev() { :; }; fi
. "$SCRIPT_DIR/lib/config.sh" || { echo "work-backup: cannot source lib/config.sh" >&2; exit 1; }

LOCAL="${QI_WORK_BACKUP_LOCAL:-/dev/shm/qi-work-backup}"   # tmpfs: the pod's only non-NFS disk
LOCK="$LOCAL.lock"; AGAIN="$LOCAL.again"; STAMP="$LOCAL.stamp"; VERIFIED="$LOCAL.verified"
LOCK_TTL_MIN=10; RETRIES=3; MAX_FILE_KB=20480
BRANCH=main
HEAD_FILE="$WORK/env/backup-head"   # "<sha> <work_repo>" this instance pushed last; env/ never travels
NAME="quality-inspector"; EMAIL="quality-inspector@agents.local"
# Never carried: credentials and pod-local state (env/), installs, raw runs, caches,
# transient files, the rebuilt catalog page, and evidence media (it lives in the artifacts; a
# git history keeps it forever) — except the catalog's small thumbnails, which nothing rebuilds.
PRUNE_DIRS="env suite/node_modules suite/.e2e/runs .cache"
SKIP_NAMES='.nfs* *.lock *.tmp *.tmp.* *.qi-tmp.* *.qi-mask *.webm *.mp4 *.mov *.png *.jpg *.jpeg *.gif *.webp *.zip'
SKIP_PATHS='./catalog/index.html'
KEEP_PATHS='./catalog/thumbs/*.jpg'
# A snapshot that deletes one of these, or more than half of the backed-up files, comes from an
# unhydrated work/ (restore first). Any other deletion is mirrored: the history keeps it.
PROTECTED="CONFIG.md VERSION QA.md SUITE.md SCENARIOS.md HEALS.md FLAKY.md LESSONS.md"

say() { echo "work-backup: $*"; }
iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
tmo() { if command -v timeout >/dev/null 2>&1; then timeout "$@"; else shift; "$@"; fi; }
nsegs() { printf '%s' "$1" | tr -cd '/' | wc -c | tr -d ' '; }

REF="$(cfg work_repo)"
TARGET="${QI_TARGET_REPO:-$(cfg target_repo)}"
host_of() { [ "$(nsegs "$1")" = 2 ] && printf '%s' "${1%%/*}" || printf github.com; }
slug_of() { [ "$(nsegs "$1")" = 2 ] && printf '%s' "${1#*/}" || printf '%s' "$1"; }
if [ -n "$REF" ]; then
  HOST="$(host_of "$REF")"; SLUG="$(slug_of "$REF")"
  REMOTE="${QI_WORK_BACKUP_REMOTE:-https://$HOST/$SLUG.git}"
fi

# --------------------------------------------------------------- the file set
# Relative paths of every file that travels, one per line; oversize files are left out and
# named on stderr. One find walks the set; `-size +N` names the oversize ones apart.
find_set() { # <find tests…> — files of the set that also match the tests
  local prune=() skip=() d n
  for d in $PRUNE_DIRS; do prune+=(-path "./$d" -o); done
  for n in $SKIP_NAMES; do skip+=(-name "$n" -o); done
  for n in $SKIP_PATHS; do skip+=(-path "$n" -o); done
  ( cd "$WORK" && find . \( "${prune[@]}" -false \) -prune -o -type f \( -path "$KEEP_PATHS" -o ! \( "${skip[@]}" -false \) \) "$@" -print ) \
    | sed 's|^\./||' | LC_ALL=C sort
}
file_list() {
  find_set -size +"${MAX_FILE_KB}"k | sed 's/^/oversize: /' >&2
  find_set ! -size +"${MAX_FILE_KB}"k
}

# Anything in the set (or a directory of it) newer than the last completed persist to this
# work_repo. logs/ does not count: the persist's own events land there, and they travel with the
# next change.
changed_since_stamp() {
  [ "$(cat "$STAMP" 2>/dev/null)" = "$REF" ] || return 0
  local prune=() d
  for d in $PRUNE_DIRS logs; do prune+=(-path "./$d" -o); done
  [ -n "$( cd "$WORK" && find . \( "${prune[@]}" -false \) -prune -o -newer "$STAMP" -print 2>/dev/null | head -1)" ]
}

# The last pushed commit, only when it was pushed to this work_repo; then the record of a push.
known_head() { local sha ref; read -r sha ref < "$HEAD_FILE" 2>/dev/null; [ "$ref" = "$REF" ] && printf '%s' "$sha"; }
record_head() { mkdir -p "$WORK/env" && printf '%s %s\n' "$1" "$REF" > "$HEAD_FILE.tmp" && mv -f "$HEAD_FILE.tmp" "$HEAD_FILE"; }
stamp_done() { mv -f "$1" "$STAMP"; }   # the stamp's mtime stays the persist's start

# ---------------------------------------------------------------- the guards
# The destination: private, not the target, not a fork of it. A positive answer is cached a
# day; a failed lookup is "could not look" and refuses.
verify_repo() {
  local now meta t tl parent
  now="$(date -u +%s)"
  if [ -f "$VERIFIED" ] && [ "$(sed -n 1p "$VERIFIED")" = "$REF" ] \
     && [ $(( now - $(sed -n 2p "$VERIFIED" 2>/dev/null || echo 0) )) -lt 86400 ]; then return 0; fi
  WHY=""
  t="$(lower "$(slug_of "$TARGET")")"; tl="$(lower "$(host_of "$TARGET")")"
  if [ -n "$TARGET" ] && [ "$(lower "$SLUG")" = "$t" ] && [ "$(lower "$HOST")" = "$tl" ]; then
    WHY="work_repo is the target repository"; return 1; fi
  local ha=(); [ "$HOST" = github.com ] || ha=(--hostname "$HOST")
  meta="$(tmo 20 gh api ${ha[@]+"${ha[@]}"} "repos/$SLUG" 2>/dev/null)" \
    && jq -e 'type == "object" and has("private")' >/dev/null 2>&1 <<<"$meta" \
    || { WHY="could not read the repository's metadata (gh api repos/$SLUG)"; return 1; }
  [ "$(jq -r .private <<<"$meta")" = true ] || { WHY="$REF is not private"; return 1; }
  if [ -n "$TARGET" ]; then
    parent="$(jq -r '[.parent.full_name, .source.full_name] | map(select(. != null) | ascii_downcase) | join(" ")' <<<"$meta")"
    case " $parent " in (*" $t "*) WHY="$REF is a fork of the target"; return 1;; esac
  fi
  printf '%s\n%s\n' "$REF" "$now" > "$VERIFIED"
}

# Credential values (work/env/credentials.env) and well-known token shapes anywhere in the
# snapshot; prints the offending paths. A scan that cannot run refuses.
scan_secrets() {
  local out
  out="$(node "$SCRIPT_DIR/lib/secrets.mjs" scan-all "$WORK/env/credentials.env" "$LOCAL" 2>/dev/null)" \
    && jq -e '.files | type == "array"' >/dev/null 2>&1 <<<"$out" || { echo "(the scan did not run)"; return 1; }
  jq -e '.files == []' >/dev/null <<<"$out" && return 0
  jq -r --arg l "$LOCAL/" '.files[:5] | map(ltrimstr($l)) | join(", ")' <<<"$out"; return 1
}

# -------------------------------------------------------------------- the lock
HELD=0
acquire_lock() {
  mkdir -p "$(dirname "$LOCK")" 2>/dev/null
  if mkdir "$LOCK" 2>/dev/null; then HELD=1; return 0; fi
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin "+$LOCK_TTL_MIN" 2>/dev/null)" ]; then
    local dead="$LOCK.stale.$$"
    if mv "$LOCK" "$dead" 2>/dev/null; then
      rm -rf "$dead"; mkdir "$LOCK" 2>/dev/null && { HELD=1; logev warn work_backup "stale persist lock taken over"; return 0; }
    fi
  fi
  return 1
}
release_lock() { [ "$HELD" = 1 ] && rm -rf "$LOCK" 2>/dev/null; HELD=0; return 0; }
trap 'release_lock' EXIT
trap 'exit' INT TERM

# ------------------------------------------------------------------- the clone
git_l() { git -C "$LOCAL" "$@"; }
seed_clone() {
  if [ "$(git_l remote get-url origin 2>/dev/null)" != "$REMOTE" ]; then
    rm -rf "$LOCAL"
    if ! git clone -q "$REMOTE" "$LOCAL" 2>/dev/null; then
      rm -rf "$LOCAL"; mkdir -p "$LOCAL" && git_l init -q && git_l remote add origin "$REMOTE" || return 1
    fi
  fi
  git_l config user.name "$NAME"; git_l config user.email "$EMAIL"
  git_l rev-parse -q --verify HEAD >/dev/null 2>&1 || git_l checkout -q -B "$BRANCH" 2>/dev/null
  return 0
}

# Mirror the file set into the clone's worktree, deletions included. tar only reads work/.
sync_in() {
  local list; list="$(file_list 2>"$LOCAL.oversize")"
  find "$LOCAL" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} + 2>/dev/null
  [ -z "$list" ] && return 0
  ( cd "$WORK" && printf '%s\n' "$list" | tar -cf - -T - ) | ( cd "$LOCAL" && tar -xf - )
}

# ----------------------------------------------------------------------- persist
persist() {
  [ -n "$REF" ] || return 0                       # local-only: silent, the hook fires every turn
  command -v git >/dev/null 2>&1 && command -v tar >/dev/null 2>&1 \
    || { logev warn work_backup "git/tar unavailable — persist skipped"; return 0; }
  changed_since_stamp || return 0
  if ! acquire_lock; then
    : > "$AGAIN"; logev info work_backup "persist deferred — another persist holds the lock and runs again"; return 0
  fi
  local pass=0
  while [ "$pass" -lt 2 ]; do
    pass=$((pass + 1)); rm -f "$AGAIN"
    do_persist
    [ -f "$AGAIN" ] || break
  done
  release_lock
}

do_persist() {
  local attempt=0 gone hits tree known tip foreign sha n stamp_new="$LOCAL.stamp.new"
  printf '%s\n' "$REF" > "$stamp_new"
  while [ "$attempt" -lt "$RETRIES" ]; do
    attempt=$((attempt + 1)); touch "$LOCK"
    seed_clone || { logev warn work_backup "clone of $REF failed (attempt $attempt)"; continue; }
    sync_in || { logev warn work_backup "snapshot copy failed (attempt $attempt)"; continue; }
    [ -s "$LOCAL.oversize" ] && logev warn work_backup "left out, over ${MAX_FILE_KB} KiB: $(sed 's/^oversize: //' "$LOCAL.oversize" | head -5 | paste -sd, -)"
    git_l add -A >/dev/null 2>&1 || { logev warn work_backup "git add failed (attempt $attempt)"; continue; }
    if git_l diff --cached --quiet 2>/dev/null; then stamp_done "$stamp_new"; return 0; fi
    if [ "$OPT" != --allow-delete ]; then
      # shellcheck disable=SC2086 # PROTECTED is a path list by design
      gone="$(git_l diff --cached --diff-filter=D --name-only -- $PROTECTED 2>/dev/null | head -5 | paste -sd' ' -)"
      n="$(git_l diff --cached --diff-filter=D --name-only | wc -l | tr -d ' ')"
      [ -z "$gone" ] && [ "$n" -gt 0 ] && [ $(( n * 2 )) -gt "$(git_l ls-tree -r --name-only HEAD 2>/dev/null | wc -l)" ] \
        && gone="$n of the backed-up files"
      if [ -n "$gone" ]; then
        git_l reset -q --hard; say "refused: the snapshot deletes protected records ($gone) — restore work/ first"
        logev error work_backup "persist refused — the snapshot deletes protected records: $gone (restore first)"; return 0
      fi
    fi
    if ! hits="$(scan_secrets)"; then
      git_l reset -q --hard; say "refused: credential or token in $hits"
      logev error work_backup "persist refused — a credential value or token in: $hits"; return 0
    fi
    if ! verify_repo; then
      git_l reset -q --hard; say "refused: $WHY"; logev error work_backup "persist refused — $WHY"; return 0
    fi
    # Onto the remote tip: the snapshot is the tree, the remote's history its parent.
    if git_l fetch -q origin "$BRANCH" 2>/dev/null; then
      tip="$(git_l rev-parse FETCH_HEAD)"
      known="$(known_head)"
      if [ -n "$known" ] && [ "$tip" != "$known" ] && ! git_l cat-file -e "$known^{commit}" 2>/dev/null; then
        logev error work_backup "the commit this instance pushed last is gone from $REF@$BRANCH — its history was rewritten"
      elif [ -n "$known" ] && [ "$tip" != "$known" ]; then
        foreign="$(git_l log --format='%h %an' "$known..$tip" 2>/dev/null | grep -v " $NAME\$" | head -5 | paste -sd, -)"
        [ -n "$foreign" ] && logev error work_backup "foreign commits on $REF@$BRANCH, reverted by this snapshot: $foreign"
      fi
      git_l reset -q --soft "$tip"
      if git_l diff --cached --quiet 2>/dev/null; then
        record_head "$tip"; stamp_done "$stamp_new"; return 0
      fi
    fi
    n="$(git_l diff --cached --name-only | wc -l | tr -d ' ')"
    git_l commit -q -m "chore(work): persist state $(iso)" || { logev warn work_backup "commit failed (attempt $attempt)"; continue; }
    sha="$(git_l rev-parse HEAD)"; tree="$(git_l rev-parse 'HEAD^{tree}' | cut -c1-12)"
    logev info external_write "surface=backup action=intent issue=- key=$tree target=$REF"
    if git_l push -q origin "HEAD:$BRANCH" 2>/dev/null; then
      logev info external_write "surface=backup action=done issue=- key=$tree target=$REF"
      record_head "$sha"; stamp_done "$stamp_new"
      logev info work_backup "pushed ${sha:0:12} to $REF ($n file(s) changed, attempt $attempt)"; return 0
    fi
    logev error external_write "surface=backup action=failed issue=- key=$tree target=$REF"
    git_l reset -q --soft HEAD~1 2>/dev/null || true
    logev warn work_backup "push rejected (attempt $attempt) — refetching the remote tip"
  done
  rm -f "$stamp_new"
  logev error work_backup "push to $REF failed after $RETRIES attempts — the next turn retries"
  return 0
}

# ----------------------------------------------------------------------- restore
restore() {
  local heads rows n=0 bad=0 f w=0 foreign pending
  [ -n "$REF" ] || { say "no work_repo in work/CONFIG.md — nothing to restore"; return 2; }
  rows="$( { table_rows_n "$WORK/QA.md"; table_rows_n "$WORK/SUITE.md"; } | awk '{s+=$1} END {print s+0}')"
  if [ "$rows" -gt 0 ] && [ "$OPT" != --force ]; then
    say "refused: work/ already holds state ($rows QA/SUITE rows) — restore only onto a fresh volume (--force continues a failed restore)"
    return 1
  fi
  while ! acquire_lock; do w=$((w + 1)); [ "$w" -ge 5 ] && break; sleep 1; done
  if ! heads="$(git ls-remote "$REMOTE" "refs/heads/$BRANCH" 2>/dev/null)"; then
    say "could not reach $REF — work/ left as it is"; logev warn work_backup "restore: $REF unreachable"; return 1
  fi
  [ -n "$heads" ] || { say "$REF holds no backup yet — nothing to restore"; return 2; }
  rm -rf "$LOCAL"
  git clone -q --branch "$BRANCH" "$REMOTE" "$LOCAL" 2>/dev/null \
    || { say "clone of $REF failed — work/ left as it is"; logev warn work_backup "restore: clone failed"; return 1; }
  [ -f "$LOCAL/CONFIG.md" ] || { say "$REF holds no CONFIG.md — no agent state to restore"; return 2; }
  mkdir -p "$WORK"
  ( cd "$LOCAL" && git ls-files -z | tar --null -cf - -T - ) | ( cd "$WORK" && tar -xf - ) \
    || { say "copy into work/ failed"; logev error work_backup "restore: copy failed"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue; n=$((n + 1)); cmp -s "$LOCAL/$f" "$WORK/$f" || bad=$((bad + 1))
  done < <(git_l -c core.quotepath=off ls-files)
  if [ "$bad" -gt 0 ]; then
    say "restore incomplete: $bad of $n files differ from $REF"; logev error work_backup "restore incomplete: $bad of $n files differ"; return 1
  fi
  record_head "$(git_l rev-parse HEAD)"
  say "restored $n files from $REF@$(git_l rev-parse --short HEAD) ($(git_l log -1 --format=%cI))"
  foreign="$(git_l log --format='%h %an %cI' | grep -v " $NAME " | head -5)"
  [ -n "$foreign" ] && say "commits not made by this script (inspect before trusting them): $(printf '%s' "$foreign" | paste -sd';' -)"
  pending="$( { table_rows "$WORK/QA.md" | awk -F'|' '$7 ~ /report_pending/ {gsub(/ /,"",$2); printf "#%s ", $2}'
               table_rows "$WORK/SCENARIOS.md" | awk -F'|' '$9 ~ /report_pending/ {gsub(/ /,"",$2); printf "%s ", $2}'; } )"
  [ -n "$pending" ] && say "report_pending without their media (never backed up) — re-test before delivery: ${pending% }"
  logev info work_backup "restored $n files from $REF"
  printf '%s\n' "$REF" > "$STAMP"
  return 0
}
table_rows() { grep '^|' "$1" 2>/dev/null | tail -n +3; }
table_rows_n() { table_rows "$1" | grep -c . ; }

# ------------------------------------------------------------------------- check
# {"configured", "repo", "problem", "last_push_utc", "last_error", "unbacked"}: problem is null
# when the destination is fine; unbacked counts files of the set (logs/ aside) changed after the
# last push and more than an hour ago. Reads only: metadata, ls-remote, the event logs, mtimes.
check() {
  local problem="" last_push last_err ref unbacked prune=() d
  if [ -z "$REF" ]; then jq -nc '{configured:false}'; return 0; fi
  rm -f "$VERIFIED"
  verify_repo || problem="$WHY"
  [ -n "$problem" ] || tmo 30 git ls-remote "$REMOTE" >/dev/null 2>&1 || problem="$REF is unreachable (git ls-remote)"
  last_push="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -rs '[.[] | select(.event == "external_write" and (.msg | test("surface=backup action=done")))] | last | .ts // empty' 2>/dev/null)"
  last_err="$(cat "$WORK"/logs/events-*.jsonl 2>/dev/null | jq -cs --arg p "${last_push:-}" \
    '[.[] | select(.event == "work_backup" and .level == "error" and .ts > $p)] | last | if . then {ts, msg} else null end' 2>/dev/null)"
  ref="$(mktemp)"
  TZ=UTC touch -t "$(date -u -d "${last_push:-1970-01-01T00:00:00Z}" +%Y%m%d%H%M.%S 2>/dev/null \
    || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${last_push:-1970-01-01T00:00:00Z}" +%Y%m%d%H%M.%S)" "$ref" 2>/dev/null
  for d in $PRUNE_DIRS logs; do prune+=(-path "./$d" -o); done
  unbacked="$(cd "$WORK" && find . \( "${prune[@]}" -false \) -prune -o -type f -newer "$ref" -mmin +60 -print 2>/dev/null | wc -l | tr -d ' ')"
  rm -f "$ref"
  jq -nc --arg r "$REF" --arg p "$problem" --arg l "${last_push:-}" --argjson e "${last_err:-null}" --argjson u "${unbacked:-0}" \
    '{configured:true, repo:$r, problem:(if $p == "" then null else $p end),
      last_push_utc:(if $l == "" then null else $l end), last_error:$e, unbacked:$u}'
}

case "$MODE" in
  (persist) persist; exit 0 ;;
  (restore) restore; exit $? ;;
  (check)   check; exit 0 ;;
  (*) echo "usage: work-backup.sh persist [--allow-delete] | restore [--force] | check" >&2; exit 2 ;;
esac
