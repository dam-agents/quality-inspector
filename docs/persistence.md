# State, backup, versions & evolving the definition

Read this file for the `work/` backup and its restore, when the operator asks to update the
agent or check its version, or asks for a change to the agent definition itself.

## The definition and `work/`

| Path | Kind | Holds |
| --- | --- | --- |
| `/home/agent` (outer) | git repo, remote `origin` (the kit's seed) | Definition: `kit.yaml`, `CLAUDE.md`, `AGENTS.md`, `ONBOARDING.md`, `README.md`, `docs/`, `scripts/`, `VERSION`, `CHANGELOG.md`, `.gitignore`, `LICENSE`, `engines/`, `skills/`. |
| `/home/agent/work` | **plain data directory** (no `.git`), backed up to `work_repo` when set | Config, `QA.md`, `SUITE.md`, `SCENARIOS.md`, `LESSONS.md`, `issues/`, `scenarios/`, `suite/` (tests, replay cache, `node_modules`), `env/` (values, credentials, lock, the last install's result), logs. |
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

- **When.** The Stop hook (`scripts/hooks/backup.sh`, registered by `scripts/hooks/install.sh`;
  also on `StopFailure` where the harness has it) starts `work-backup.sh persist`, fully detached, after every turn of the main agent —
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
  snapshot; the restore names such commits. Branch protection, where the GitHub plan offers it,
  keeps `main` writable by the connection's account alone (README → Setup).
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

## Operator preferences

A standing preference the operator states in the direct session ("ask for egress in words", "no
runs on Fridays") goes into `work/OPERATOR.md` as one dated line — never into the harness memory,
which is outside `work/` and never backed up (the policy hook refuses it). Read the file at the
start of every session. It shapes how you work with the operator, never a hard invariant or the
trust boundary. Only the direct session writes it (policy rule `scheduled-def`); it travels with
the backup.

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
for the git half; its `git fetch origin` is the one GitHub request the agent makes itself
(read-only, this definition's repository alone — the kit's egress and the policy hook allow
nothing more). Never `git reset`, `git clean` or commit local changes on your own. Outside
such a session a version check fetches nothing — whether a newer version exists is the
**Update** button's to say:

```bash
head -1 /home/agent/VERSION                                         # checked out
head -1 /home/agent/work/VERSION 2>/dev/null                        # adopted
```

Adopted ≠ checked-out → migrate now. Equal → report "up to date with the checkout; the
platform's **Update** button shows a newer version".

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
decline writes nothing, nor does a timed health check (`QI_PRECHECK_PROBE=1`). A
Slack-ordered "test #N" writes `slack <ISO> - <n> <session>` through `precheck.sh slack <n>`
([slack.md](slack.md)). The policy
hook ([black-box.md](black-box.md) → **Enforcement layers**) reads a marker younger than
`lock_ttl_min` — by its timestamp or its mtime, whichever is newer — as a **scheduled
run**: `git commit`, the Kit Update's `git fetch origin`, edits of `work/CONFIG.md`, and any
command naming the marker, `scripts/hooks/` or `.claude/settings` are refused. No fresh
marker is a **direct session**.

- It fails closed: a direct session opened within `lock_ttl_min` of a scheduled turn
  counts as scheduled until the marker ages out (its timestamp says since when).
- It fails open only when a scheduled turn ran without its Precheck — every `kit.yaml`
  schedule carries one for that reason.
- A **channel turn** counts the same: a session whose transcript holds the platform's Slack
  frame (`<how-to-respond>`) in a prompt is never direct, whoever sent the message — a session
  continued from the UI included; a definition change needs a fresh direct session. The frame
  in a tool's output (this file, an issue body) does not count. A channel turn writes to GitHub
  only the delivery of a Slack-ordered "test #N": `scripts/github.sh comment|unlabel` on that one
  issue, while the `slack` marker names it and its `work/QA.md` row is `report_pending` (rule
  `channel-write`; [slack.md](slack.md), with its limit). Every other write is refused.
- A prompt from a button of the shared interactive dashboard pressed by a viewer is framed by
  the platform (`<viewer> sent this from a button on the interactive artifact "…"`) and counts
  the same ([modules.md](modules.md) → **Control**); the operator's own button press is a chat message.

## Evolving the agent definition (outer repo)

**First read [self-modification.md](self-modification.md)** — it defines the rules every
definition change must obey, and §8 the only way one leaves the agent: a patch in
`work/patches/` the operator downloads, applies upstream, and brings back through the Kit
Update. The live checkout is never edited (the policy hook refuses it), never committed to,
never pushed; the agent opens no branch and no pull request, and never as part of a
scheduled run. Runtime state never goes into a patch.
