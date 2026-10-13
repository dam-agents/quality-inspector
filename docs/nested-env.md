# The nested product

The system under test runs **inside this agent's own VM**, at the build under test, brought
up by the profile ([profile-contract.md](profile-contract.md)). `scripts/env.sh` is the one
entry: it holds the lock and hands every other command to the profile's `bin/env`. This
file is the why and the recovery path; how one product is installed is the profile's.

## Shape

- **Inside the VM only.** The product answers at the profile's `app.url` on `localhost`;
  `suite.sh`, `e2e-mcp.sh` and `ui-inventory.mjs` refuse any other base URL, and no
  procedure ever drives the platform this agent itself runs on.
- **One user of the environment at a time** — `env.sh lock <owner>` / `unlock <owner>`;
  the pre-flight treats a live lock as an idle occurrence, and a lock past `lock_ttl_min`
  is the next holder's to take over.
- **Credentials are the profile's** — `env.sh init` makes it write
  `work/env/credentials.env` (mode 600). Tests reach them only as `e2e` credentials.
- **Builds move forward only.** To run an older build (the baseline) after a newer one,
  always `env.sh reset` first — a downgrade over newer data is undefined. The red-green
  order in [issue-qa.md](issue-qa.md) step 6 is built around that.
- What the nested product cannot do (no outbound network for its own components, no
  email, a single user…) is in the profile's `SKILL.md`; it decides `testable: no`
  ([acceptance-criteria.md](acceptance-criteria.md)).

## Network

The VM reaches the outside only through the paired gateway, by the agent's egress rules.
The hosts a profile needs are its `egress` list; the operator applies them. A pull that is
held or refused surfaces as a failing `env.sh up`, and the fix is the operator's.

## Failures

An `env.sh` exit other than 0, or a failing smoke run, is an **environment failure** —
never a verdict. Before giving up on the entry:

1. `bash "$HOME/scripts/env.sh" status`, then the diagnosis the profile's README names
   (read-only commands only).
2. One repair attempt the evidence supports — usually `env.sh reset`, then `up` again,
   for an install stuck half-way.
3. Still failing → abort the entry ([issue-qa.md](issue-qa.md) step 4) with the evidence
   in the log. A cause you reproduced goes to `work/LESSONS.md`; a profile defect is an
   issue on the profile's repository, never a local patch to the profile.

Never "fix" the product inside the environment (its files, its database, its
configuration beyond what the profile sets) to make a test pass — that tests your patch,
not the build.
