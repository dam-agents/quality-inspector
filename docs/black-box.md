# The black-box boundary

This agent judges the product the way a user meets it. Reading its implementation — even
once, even to "understand a failure" — would let the code define what correct means. The
boundary is enforced twice: by these rules, and by the agent's egress rules, which
`verify-onboarding.sh --live` and the audit probe from the outside
(`scripts/lib/profile.sh` → `boundary_targets`: the provider's list plus the profile's
`boundary`).

## You may read

- The target repository's **issues API only**: `GET /repos/<T>/issues` (listing, closed
  ones included), `GET /repos/<T>/issues/<n>`, `GET /repos/<T>/issues/<n>/comments`, and
  the writes in [reporting.md](reporting.md) → Delivery. Of an issue, use its text — a
  link, a code block, or a PR reference in it is not something to follow.
- The **running nested product**: its UI, its API responses, its published CLI's `--help`
  and output.
- The **profile**: its `SKILL.md` (user-facing knowledge) and `profile.json`; its `bin/`
  scripts only to diagnose an environment failure.
- The `e2e` framework's own docs, this definition, `work/`.

## You never request or read

- Anything else under the target repository: `contents`, `git/*`, `pulls`, `commits`,
  `compare`, `branches`, `actions`, `releases` assets, issue `timeline` and `events`
  (they expose linked commits), and `github.com/<T>` web pages.
- `raw.githubusercontent.com`, `codeload.github.com`, gists linked from issues.
- The files of installed product packages (its CLI in `node_modules`, its images'
  filesystems, the templates of its deployment manifests), source maps its UI serves.
- Anything the profile lists under `boundary`.
- Product docs that describe the implementation. User-facing help text is fine.

A need that seems to require one of these is a criterion you mark `blocked` or
`not-testable` with the reason — never a reason to look.

## Egress rules the operator applies

Egress rules cannot be declared in the kit, so the operator sets them (README →
Black-box boundary has the commands). The core's own needs:

| Host | Allowed | Denied |
| --- | --- | --- |
| `api.github.com` | `GET /repos/<T>/issues*`; `POST …/issues/*/comments*`; `DELETE …/issues/*/labels/*` | `…/issues/*/timeline*`, `…/issues/*/events*` (longer, so they win), every other path under `/repos/<T>/` |
| `api.github.com` (profile in the target repo) | `GET /repos/<T>/contents/<profile dir>*` — the profile only; longer than the deny, so it wins | — |
| `codeload.github.com` | skill and definition downloads of other repositories | `/<T>/*` — the target's tarballs |
| `raw.githubusercontent.com` | — | everything |
| `github.com` | this agent's definition and profile repositories | everything under `/<T>` |
| `registry.npmjs.org` | `GET` (the `e2e` framework) | — |
| `api.anthropic.com` | model calls for agent steps | — |
| `cdn.playwright.dev`, `playwright.download.prss.microsoft.com` | `GET`, only when `e2e`'s Playwright differs from the image's | — |

Patterns end in `*` wherever a query string may follow: the matched path includes it.
Plus every entry of the profile's `egress`. An unmatched request is **held** for approval
on the operator's Home. Approve nothing on the deny side; a held probe shows as `warn`
until it is an explicit deny.
