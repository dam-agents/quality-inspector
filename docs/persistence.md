# State, backup, versions & evolving the definition

Read this file for the `work/` backup and its restore, when the operator asks to update the
agent or check its version, or asks for a change to the agent definition itself.

## The definition and `work/`

| Path | Kind | Holds |
| --- | --- | --- |
| `/home/agent` (outer) | git repo, remote `origin` (the kit's seed) | Definition: `kit.yaml`, `CLAUDE.md`, `AGENTS.md`, `ONBOARDING.md`, `README.md`, `docs/`, `scripts/`, `VERSION`, `CHANGELOG.md`, `.gitignore`, `LICENSE`, `engines/`, `skills/`. |
| `/home/agent/work` | **plain data directory** (no `.git`), backed up to `work_repo` when set | Config, `QA.md`, `SUITE.md`, `SCENARIOS.md`, `LESSONS.md`, `issues/`, `scenarios/`, `suite/` (tests, replay cache, `node_modules`), `env/` (values, credentials, lock), logs. |
| `work_repo` (`work/CONFIG.md`) | private git remote | The durable, versioned backup of `work/` — **Backup & restore** below. |
| `$HOME/.agents/skills/<profile>` | the product profile skill | Reinstalled from its source; never edited here. |
| the profile's own paths (its README) | the nested product's state and tools | Rebuildable by `scripts/env.sh` through the profile. |

`work/` is never a git repo: the home volume is virtiofs over NFS, and a `.git` mutated
there under concurrent runs corrupts. The outer `.gitignore` is an allowlist, so `work/`
and the home secrets are invisible to the definition repo; **never run `git clean` in
`/home/agent`** and never `git add` outside the allowlist.

Without `work_repo` a lost volume loses the suite, the replay cache, the criteria files and
the reports; only `QA.md` rows come back, from issue comment markers when `issue_comments` was
enabled (ONBOARDING Step 4). The nested product is always rebuildable through the profile.

## Backup & restore

`scripts/work-backup.sh` backs `work/` up to `work_repo` — a **private** repository the
connection can push to, never the target or a fork of it — and restores it on a fresh volume.

- **When.** The Stop hook (`scripts/hooks/backup.sh`, registered by `scripts/hooks/install.sh`)
  starts `work-backup.sh persist`, fully detached, after every turn of the main agent —
  scheduled, channel or direct. No turn waits for it, no instruction can skip or redirect it.
  In a scheduled run or a channel turn the agent never runs the script itself (policy rule
  `backup-direct`); in the direct session "back up now" runs `persist`.
- **How.** A clone on tmpfs (`/dev/shm/qi-work-backup`) is refilled from `work/`, committed as
  `quality-inspector` and pushed to `main`, never forced; a rejected push refetches the tip and
  retries (3 attempts), a failure is logged and the next turn retries. Overlapping turns share a
  lock; a deferred one makes the holder run once more. Nothing changed since the last persist
  (by mtime, `logs/` aside) → no git at all.
- **What travels:** all of `work/` except `env/` (credentials, locks, the run marker),
  `suite/node_modules`, `suite/.e2e/runs`, `.cache`, transient files (`*.lock`, `*.tmp`, …),
  the rebuilt catalog page, evidence media (videos, images, trace zips — they live in the
  artifacts; the catalog's small thumbnails do travel) and any file over 20 MiB (logged).
- **Refused** (logged as an error, nothing pushed): the repository is not private, is the
  target or a fork of it, or its metadata cannot be read; the snapshot holds a credential value
  of `work/env/credentials.env` or a token (`secrets.mjs scan-all`); the snapshot deletes
  `CONFIG.md`, `VERSION`, a state table or more than half of the backed-up files — an unhydrated
  `work/`: restore first. `persist --allow-delete` passes a deletion the operator asked for.
- **A backup, never an input.** Nothing reads it but a restore. A commit not made by the
  script is logged as an error at the next persist (`foreign commits …`) and reverted by its
  snapshot; the restore names such commits. Branch protection keeps `main` writable by the
  connection's account alone (README → Setup).
- Every push is ledgered (surface `backup`, [logging.md](logging.md)); the audit's
  `work_backup` check and `verify-onboarding.sh --live` report the destination and anything
  left unpushed.

**Restore** — direct session, fresh volume (ONBOARDING Step 2a):
`bash "$HOME/scripts/work-backup.sh" restore` copies `main` into `work/` and verifies every file:
exit `0` restored · `2` nothing to restore (no `work_repo`, an empty repository, no `CONFIG.md`
in it) · `1` failed, or refused because `work/` already holds QA or SUITE rows (`--force` only
continues a failed restore). Then:

1. Onboarding goes on: Step 2b seeds only what is missing, Step 2d recreates
   `work/env/credentials.env` and the suite's `node_modules`, Step 3 keeps the restored values,
   Step 7 migrates from the restored `work/VERSION` instead of overwriting it.
2. Commits the restore names as not made by the script: show them to the operator before
   any run.
3. A `report_pending` row it names lost its media: re-test it before delivery — an issue by
   "test #N", a scenario from step 5 of [scenarios.md](scenarios.md) → The pipeline.
4. Restored `artifact.id` files keep working: any agent of the same owner revises them.

## Definition version & upgrade

`VERSION` (repo root, one line, semver) identifies the definition; `work/VERSION` is the
version this instance last adopted (missing = `1.0.0`). Scheduled runs never touch
versioning (the weekly audit only *reports* drift); acting happens **in the direct
session only**: an operator-requested update or version check, and always before any
self-modification (self-modification.md §8).

**Updating the checkout is the platform's Kit Update.** The platform detects a newer
commit on the definition's branch, shows the operator an **Update** button, and opens a
session whose briefing says exactly how to move the checkout: the operator picks which
upstream changes to take, their local changes are set aside and put back (never
committed, never pushed), and every conflict is theirs to decide. Follow that briefing
for the git half; never `git reset`, `git clean` or commit local changes on your own.
Outside such a session, a version check only reports:

```bash
git -C /home/agent fetch -q origin main
git -C /home/agent show origin/main:VERSION 2>/dev/null | head -1   # latest
head -1 /home/agent/VERSION                                         # checked out
head -1 /home/agent/work/VERSION 2>/dev/null                        # adopted
```

Checked-out < latest → **tell the operator the agent is not up to date** (state both
versions) and point them at the **Update** button. Adopted ≠ checked-out → migrate now.
All equal → report "up to date".

**Migration** (`from` = adopted, `to` = checked-out):

1. Apply the `CHANGELOG.md` **Upgrade** blocks of every version in `(from, to]`, oldest
   first. Steps are idempotent (check before create), so re-running a partial attempt is
   safe; an operator-only step is surfaced, never guessed at.
2. **Offer every optional feature the crossed versions add.** An **Upgrade** block that
   introduces an off-by-default feature names the `work/CONFIG.md` key that enables it
   and its one-line effect (self-modification.md §12); upgrading never adopts it by
   itself. Collect them across all crossed versions and ask the operator **once, in one
   message**. A yes writes that key; a no or no answer writes nothing — the missing key
   is the documented off default — and the migration continues either way. Never enable
   a feature the operator did not confirm.
3. Only after every applicable step succeeded, write `to` into `work/VERSION` and log
   `definition upgraded <from> → <to> (<n> step(s))`, naming the features offered and
   the answers. A failed step: log + tell the operator, leave `work/VERSION` unchanged
   (re-offered at the next check).
4. Rollback (`to` < `from`) → apply nothing, offer nothing; just write `to`.

Whenever an upgrade changes what onboarding produces, its **Upgrade** block runs
`bash "$HOME/scripts/verify-onboarding.sh"` and applies every `FAIL` line's `fix:` — the
same verification onboarding ends with, and the only thing that keeps a long-deployed
instance the same shape as a fresh one.

## Scheduled or direct session

Only a schedule runs a Precheck before the agent wakes. Every `scripts/precheck.sh` exit
that lets the turn run writes `work/env/RUN_MODE` = `scheduled <ISO> <schedule id>`; a
decline writes nothing, nor does a timed health check (`QI_PRECHECK_PROBE=1`). The policy
hook ([black-box.md](black-box.md) → **Enforcement layers**) reads a marker younger than
`lock_ttl_min` — by its timestamp or its mtime, whichever is newer — as a **scheduled
run**: `git commit`/`push`, `gh pr create`/`merge`, a `gh api` write outside the
target's issues, edits of definition files and of `work/CONFIG.md`, and any command
naming the marker, `scripts/hooks/` or `.claude/settings` are refused. No fresh marker is
a **direct session**.

- It fails closed: a direct session opened within `lock_ttl_min` of a scheduled turn
  counts as scheduled until the marker ages out (its timestamp says since when).
- It fails open only when a scheduled turn ran without its Precheck — every `kit.yaml`
  schedule carries one for that reason.
- A **channel turn** counts the same: a session whose transcript holds the platform's Slack
  frame (`<how-to-respond>`) in a prompt is never direct, whoever sent the message — a session
  continued from the UI included; a definition change needs a fresh direct session. The frame
  in a tool's output (this file, an issue body) does not count. A channel turn also writes
  nothing to GitHub (rule `channel-write`).

## Evolving the agent definition (outer repo)

**First read [self-modification.md](self-modification.md)** — it defines the rules every
definition change must obey.

Definition changes go through **branch + PR on the definition repository — never a direct push
to `main`, never auto-merge**, and only when deliberately asked — never as part of a
scheduled run:

```bash
git -C /home/agent fetch origin main
git -C /home/agent checkout -b "fix/<short-slug>" origin/main
git -C /home/agent add -- kit.yaml CLAUDE.md AGENTS.md ONBOARDING.md README.md VERSION CHANGELOG.md .gitignore LICENSE docs scripts engines skills
git -C /home/agent commit -m "<describe the change>"
git -C /home/agent push -u origin "fix/<short-slug>"
o="$(git -C /home/agent remote get-url origin)"; o="${o#https://}"; o="${o%.git}"; pulls="repos/${o#*/}/pulls"
gh api --hostname "${o%%/*}" "$pulls" -f base=main -f head="fix/<short-slug>" \
  -f title="<title>" -f body="<what and why>" --jq .html_url
```

The agent's job ends at "PR opened". Use fresh descriptive branch names; runtime state
never goes to this repo.

The definition repository may sit on a different GitHub host than the target: the PR
call takes the host from `origin`; plain `git fetch`/`push` need only the allows
`egress-rules.sh` prints for this repository when it shares the target's host. It is
REST on purpose — `gh pr create` speaks GraphQL, which the egress denies
([black-box.md](black-box.md) → **Egress rules**); the path sits in a variable because the
policy hook reads `repos/<variable>/…` as the target's.
