# State, versions & evolving the definition

Read this file when the operator asks to update the agent or check its version, or asks
for a change to the agent definition itself.

## The definition and `work/`

| Path | Kind | Holds |
| --- | --- | --- |
| `/home/agent` (outer) | git repo, remote `origin` (the kit's seed) | Definition: `kit.yaml`, `CLAUDE.md`, `AGENTS.md`, `ONBOARDING.md`, `README.md`, `docs/`, `scripts/`, `VERSION`, `CHANGELOG.md`, `.gitignore`, `LICENSE`, `engines/`. |
| `/home/agent/work` | **plain data directory** (no `.git`), local-only | Config, `QA.md`, `SUITE.md`, `SCENARIOS.md`, `LESSONS.md`, `issues/`, `scenarios/`, `suite/` (tests, replay cache, `node_modules`), `env/` (values, credentials, lock), logs. |
| `$HOME/.agents/skills/<profile>` | the product profile skill | Reinstalled from its source; never edited here. |
| the profile's own paths (its README) | the nested product's state and tools | Rebuildable by `scripts/env.sh` through the profile. |

`work/` is never a git repo: the home volume is virtiofs over NFS, and a `.git` mutated
there under concurrent runs corrupts. The outer `.gitignore` is an allowlist, so `work/`
and the home secrets are invisible to the definition repo; **never run `git clean` in
`/home/agent`** and never `git add` outside the allowlist.

**There is no remote backup.** On a lost volume: `QA.md` rows can be rebuilt from issue
comment markers when `issue_comments` was enabled (ONBOARDING Step 4); the suite, the
replay cache, the criteria files and the reports cannot — the next issues run re-tests
from scratch. The nested product is always rebuildable through the profile.

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
run**: `git commit`/`push`, `gh pr create`/`merge`, edits of definition files and of
`work/CONFIG.md`, and any command naming the marker, `scripts/hooks/` or
`.claude/settings` are refused. No fresh marker is a **direct session**.

- It fails closed: a direct session opened within `lock_ttl_min` of a scheduled turn
  counts as scheduled until the marker ages out (its timestamp says since when).
- It fails open only when a scheduled turn ran without its Precheck — every `kit.yaml`
  schedule carries one for that reason.
- A **channel turn** counts the same: a session whose transcript holds the platform's Slack
  frame (`<how-to-respond>`) is never direct, whoever sent the message — a session continued
  from the UI included; a definition change needs a fresh direct session.

## Evolving the agent definition (outer repo)

**First read [self-modification.md](self-modification.md)** — it defines the rules every
definition change must obey.

Definition changes go through **branch + PR on the definition repository — never a direct push
to `main`, never auto-merge**, and only when deliberately asked — never as part of a
scheduled run:

```bash
git -C /home/agent fetch origin main
git -C /home/agent checkout -b "fix/<short-slug>" origin/main
git -C /home/agent add -- kit.yaml CLAUDE.md AGENTS.md ONBOARDING.md README.md VERSION CHANGELOG.md .gitignore LICENSE docs scripts engines
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
