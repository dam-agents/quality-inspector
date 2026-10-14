#!/usr/bin/env bash
# scripts/work-backup.sh: persist into a local bare remote (what travels, what never does,
# idempotence, the guards), the Stop hook wrapper, check, and restore onto a fresh work/.
. "$(dirname "$0")/lib.sh"
WB="$SCRIPTS/work-backup.sh"
REMOTE="$SANDBOX/remote.git"; git init -q --bare "$REMOTE"
export QI_WORK_BACKUP_REMOTE="$REMOTE" QI_WORK_BACKUP_LOCAL="$SANDBOX/shm/clone" HOME="$SANDBOX/home"
mkdir -p "$HOME" "$SANDBOX/shm"
git config --global user.name tester >/dev/null 2>&1; git config --global user.email t@example.invalid >/dev/null 2>&1
echo '{"private":true,"fork":false}' > "$STUB_DIR/repo-acme_widgets-qa.json"
persist() { rm -f "$QI_WORK_BACKUP_LOCAL.stamp"; bash "$WB" persist "$@" >/dev/null; }
commits() { git --git-dir="$REMOTE" rev-list --count main 2>/dev/null || echo 0; }
files() { git --git-dir="$REMOTE" ls-tree -r --name-only main 2>/dev/null; }
events() { cat "$WORK_DIR"/logs/events-*.jsonl 2>/dev/null | jq -sc "[.[] | select(.event == \"$1\")]"; }

seed_work
mkdir -p "$WORK_DIR/suite/tests" "$WORK_DIR/suite/node_modules/e2e" "$WORK_DIR/suite/.e2e/runs/r1" "$WORK_DIR/suite/.e2e/cache" \
         "$WORK_DIR/env" "$WORK_DIR/issues/7/report-abc-1/media" "$WORK_DIR/.cache"
printf -- '- profile: stub\n- target_repo: acme/widgets\n' > "$WORK_DIR/CONFIG.md"
echo 1.0.0 > "$WORK_DIR/VERSION"
for f in SCENARIOS.md HEALS.md FLAKY.md LESSONS.md; do echo "# $f" > "$WORK_DIR/$f"; done
printf '| 7 | abc | 1 | 0 | verified | report_pending | 2026-10-01T00:00:00Z |\n' >> "$WORK_DIR/QA.md"
echo 'test("#7 AC-1", async () => {});' > "$WORK_DIR/suite/tests/issue-7.e2e.ts"
echo '{"steps":[]}' > "$WORK_DIR/suite/.e2e/cache/replay.json"
echo 'module' > "$WORK_DIR/suite/node_modules/e2e/index.js"
echo 'video' > "$WORK_DIR/suite/.e2e/runs/r1/video.webm"
echo '<html>report</html>' > "$WORK_DIR/issues/7/report-abc-1/index.html"
echo 'png' > "$WORK_DIR/issues/7/report-abc-1/media/AC-1.png"
echo '# criteria' > "$WORK_DIR/issues/7/criteria-abc.md"
for i in 1 2 3 4 5 6 8 9 10 11 12 13; do mkdir -p "$WORK_DIR/issues/$i"; echo "# criteria $i" > "$WORK_DIR/issues/$i/criteria-x.md"; done
printf 'E2E_USER_OWNER_PASSWORD=s3cret-value\n' > "$WORK_DIR/env/credentials.env"
echo stamp > "$WORK_DIR/.cache/retention-x"
dd if=/dev/zero of="$WORK_DIR/issues/7/huge.json" bs=1048576 count=21 2>/dev/null
mkdir -p "$WORK_DIR/catalog/thumbs"; echo jpg > "$WORK_DIR/catalog/thumbs/issue-7-ac-1.jpg"; echo '<html>' > "$WORK_DIR/catalog/index.html"

# Local-only: a no-op that leaves nothing behind.
bash "$WB" persist; assert_eq "persist exits 0 without work_repo" 0 "$?"
[ -e "$QI_WORK_BACKUP_LOCAL" ] && { echo "  a clone was made without work_repo"; FAILED=1; }
assert "check without work_repo" '.configured == false' "$(bash "$WB" check)"

# First persist: the set travels, nothing else does.
printf -- '- work_repo: acme/widgets-qa\n' >> "$WORK_DIR/CONFIG.md"
persist
assert_eq "one commit pushed" 1 "$(commits)"
f="$(files)"
for want in CONFIG.md QA.md SUITE.md VERSION suite/tests/issue-7.e2e.ts suite/.e2e/cache/replay.json catalog/thumbs/issue-7-ac-1.jpg \
            issues/7/criteria-abc.md issues/7/report-abc-1/index.html; do
  printf '%s\n' "$f" | grep -qx "$want" || { echo "  missing from the backup: $want"; FAILED=1; }
done
for never in env/credentials.env suite/node_modules/e2e/index.js suite/.e2e/runs/r1/video.webm \
             issues/7/report-abc-1/media/AC-1.png .cache/retention-x issues/7/huge.json catalog/index.html; do
  printf '%s\n' "$f" | grep -qx "$never" && { echo "  must never travel: $never"; FAILED=1; }
done
assert_eq "backup-head records the push" "$(git --git-dir="$REMOTE" rev-parse main) acme/widgets-qa" "$(cat "$WORK_DIR/env/backup-head")"
assert "ledger pair" 'map(.msg) | (map(select(test("^surface=backup action=intent issue=- key=[0-9a-f]{12} target=acme/widgets-qa$"))) | length) == 1
                      and (map(select(test("action=done"))) | length) == 1' "$(events external_write)"
assert "oversize file named" 'map(.msg) | any(test("left out.*huge.json"))' "$(events work_backup)"
assert_eq "author is the script" quality-inspector "$(git --git-dir="$REMOTE" log -1 --format=%an main)"

# Idempotent: nothing changed (fast path), and a touch without a change.
bash "$WB" persist >/dev/null; assert_eq "fast path pushes nothing" 1 "$(commits)"
touch "$WORK_DIR/QA.md"; persist
assert_eq "an unchanged snapshot carries only the log lines since" "logs" \
  "$(git --git-dir="$REMOTE" diff --name-only main~1 main 2>/dev/null | cut -d/ -f1 | sort -u | paste -sd' ' -)"
base="$(commits)"

# A change travels; a deletion outside the protected records is mirrored.
echo 'test("#8 AC-1", async () => {});' > "$WORK_DIR/suite/tests/issue-8.e2e.ts"
rm "$WORK_DIR/issues/7/report-abc-1/index.html"
persist
assert_eq "a change is pushed" $((base + 1)) "$(commits)"
files | grep -qx suite/tests/issue-8.e2e.ts || { echo "  new test not backed up"; FAILED=1; }
files | grep -qx issues/7/report-abc-1/index.html && { echo "  deletion not mirrored"; FAILED=1; }

# Guards: a credential value, a deleted protected record, a public repo, the target itself.
echo 'const p = "s3cret-value";' > "$WORK_DIR/suite/tests/leak.e2e.ts"
persist; assert_eq "a credential value is refused" $((base + 1)) "$(commits)"
assert "refusal logged" 'map(select(.level == "error")) | any(.msg | test("credential value or token in: suite/tests/leak.e2e.ts"))' "$(events work_backup)"
rm "$WORK_DIR/suite/tests/leak.e2e.ts"
echo 'tok ghp_abcdefghijklmnopqrstuvwxyz0123456789AB' > "$WORK_DIR/LESSONS.md"
persist; assert_eq "a token is refused" $((base + 1)) "$(commits)"
echo '# LESSONS.md' > "$WORK_DIR/LESSONS.md"
mv "$WORK_DIR/SUITE.md" "$SANDBOX/SUITE.md"
persist; assert_eq "a deleted protected record is refused" $((base + 1)) "$(commits)"
assert "unhydrated refusal logged" 'any(.msg | test("deletes protected records: SUITE.md"))' "$(events work_backup)"
mv "$SANDBOX/SUITE.md" "$WORK_DIR/SUITE.md"
mkdir "$SANDBOX/aside" && mv "$WORK_DIR/issues" "$WORK_DIR/suite" "$SANDBOX/aside/"
persist; assert_eq "deleting most files is refused" $((base + 1)) "$(commits)"
assert "mass deletion logged" 'any(.msg | test("deletes protected records: [0-9]+ of the backed-up files"))' "$(events work_backup)"
mv "$SANDBOX/aside/issues" "$SANDBOX/aside/suite" "$WORK_DIR/"
echo '{"private":false}' > "$STUB_DIR/repo-acme_widgets-qa.json"; rm -f "$QI_WORK_BACKUP_LOCAL.verified"
echo x >> "$WORK_DIR/LESSONS.md"
persist; assert_eq "a public repository is refused" $((base + 1)) "$(commits)"
echo '{"private":true,"fork":true,"parent":{"full_name":"Acme/Widgets"}}' > "$STUB_DIR/repo-acme_widgets-qa.json"; rm -f "$QI_WORK_BACKUP_LOCAL.verified"
persist; assert_eq "a fork of the target is refused" $((base + 1)) "$(commits)"
assert "check names the problem" '.configured and (.problem | test("fork of the target"))' "$(bash "$WB" check)"
echo '{"private":true,"fork":false}' > "$STUB_DIR/repo-acme_widgets-qa.json"; rm -f "$QI_WORK_BACKUP_LOCAL.verified"
sed -i.bak 's|^- work_repo: .*|- work_repo: ACME/widgets|' "$WORK_DIR/CONFIG.md" && rm -f "$WORK_DIR/CONFIG.md.bak"
persist; assert_eq "the target is refused" $((base + 1)) "$(commits)"
sed -i.bak 's|^- work_repo: .*|- work_repo: acme/widgets-qa|' "$WORK_DIR/CONFIG.md" && rm -f "$WORK_DIR/CONFIG.md.bak"

# Busy lock: deferred, and the holder is told to run again.
mkdir -p "$QI_WORK_BACKUP_LOCAL.lock"; persist
assert_eq "a held lock defers" $((base + 1)) "$(commits)"; [ -f "$QI_WORK_BACKUP_LOCAL.again" ] || { echo "  no again flag"; FAILED=1; }
rmdir "$QI_WORK_BACKUP_LOCAL.lock"

# The Stop hook: silent, exit 0, and it persists.
out="$(echo '{"hook_event_name":"Stop","stop_hook_active":false}' | bash "$SCRIPTS/hooks/backup.sh")"; rc=$?
assert_eq "hook exits 0" 0 "$rc"; assert_eq "hook prints nothing" "" "$out"
for _ in $(seq 1 120); do [ "$(commits)" -gt $((base + 1)) ] && [ ! -d "$QI_WORK_BACKUP_LOCAL.lock" ] && break; sleep 1; done
assert_eq "hook pushed the pending change (detached)" $((base + 2)) "$(commits)"

# A foreign commit is logged and reverted by the next snapshot.
other="$SANDBOX/other"; git clone -q "$REMOTE" "$other"
echo edited > "$other/LESSONS.md"; git -C "$other" -c user.name=alice -c user.email=a@example.invalid commit -qam edit
git -C "$other" push -q origin HEAD:main
echo 'test("#9 AC-1", async () => {});' > "$WORK_DIR/suite/tests/issue-9.e2e.ts"
persist
assert_eq "pushed on top of the foreign commit" $((base + 4)) "$(commits)"
assert "foreign commit logged" 'map(select(.level == "error")) | any(.msg | test("foreign commits on acme/widgets-qa@main.*alice"))' "$(events work_backup)"
assert_eq "foreign edit reverted" "$(cat "$WORK_DIR/LESSONS.md")" "$(git --git-dir="$REMOTE" show main:LESSONS.md)"

# Another work_repo: the first persist there is no rewritten history, and it does not wait
# for a new change.
OTHER="$SANDBOX/other.git"; git init -q --bare "$OTHER"
echo '{"private":true,"fork":false}' > "$STUB_DIR/repo-acme_widgets-qa2.json"
sed -i.bak 's|^- work_repo: .*|- work_repo: acme/widgets-qa2|' "$WORK_DIR/CONFIG.md" && rm -f "$WORK_DIR/CONFIG.md.bak"
touch -t 202001010000 "$WORK_DIR/CONFIG.md"
QI_WORK_BACKUP_REMOTE="$OTHER" bash "$WB" persist >/dev/null
assert_eq "the new work_repo gets the full state at once" 1 "$(git --git-dir="$OTHER" rev-list --count main 2>/dev/null || echo 0)"
assert "no false rewrite alarm" 'map(select(.msg | test("history was rewritten"))) | length == 0' "$(events work_backup)"
sed -i.bak 's|^- work_repo: .*|- work_repo: acme/widgets-qa|' "$WORK_DIR/CONFIG.md" && rm -f "$WORK_DIR/CONFIG.md.bak"

c="$(bash "$WB" check)"
assert "check after a push" '.configured and .problem == null and (.last_push_utc | test("Z$")) and .unbacked == 0' "$c"

# Restore onto a fresh work/: verified, refuses over state, reports pending media.
FRESH="$SANDBOX/fresh"; mkdir -p "$FRESH"; printf -- '- target_repo: acme/widgets\n- work_repo: acme/widgets-qa\n' > "$FRESH/CONFIG.md"
out="$(WORK_DIR="$FRESH" bash "$WB" restore)"; rc=$?
assert_eq "restore exits 0" 0 "$rc"
case "$out" in (*"restored "*" files from acme/widgets-qa"*) ;; (*) echo "  restore summary: $out"; FAILED=1;; esac
case "$out" in (*"re-test before delivery: #7"*) ;; (*) echo "  pending report not named: $out"; FAILED=1;; esac
case "$out" in (*"commits not made by this script"*alice*) ;; (*) echo "  foreign commit not named: $out"; FAILED=1;; esac
cmp -s "$WORK_DIR/suite/tests/issue-9.e2e.ts" "$FRESH/suite/tests/issue-9.e2e.ts" || { echo "  restored test differs"; FAILED=1; }
[ -e "$FRESH/env/credentials.env" ] && { echo "  credentials restored"; FAILED=1; }
assert_eq "restore records the head" "$(git --git-dir="$REMOTE" rev-parse main) acme/widgets-qa" "$(cat "$FRESH/env/backup-head")"
WORK_DIR="$FRESH" bash "$WB" restore >/dev/null; assert_eq "restore refuses over state" 1 "$?"
EMPTY="$SANDBOX/empty.git"; git init -q --bare "$EMPTY"; E="$SANDBOX/e"; mkdir -p "$E"
printf -- '- work_repo: acme/widgets-qa\n' > "$E/CONFIG.md"
WORK_DIR="$E" QI_WORK_BACKUP_REMOTE="$EMPTY" bash "$WB" restore >/dev/null; assert_eq "empty remote: nothing to restore" 2 "$?"
exit $FAILED
