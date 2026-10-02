# The black-box boundary

This agent judges the product the way a user meets it. Reading its implementation — even
once, even to "understand a failure" — would let the code define what correct means. The
boundary is enforced twice: by these rules, and by the agent's egress rules, which
`verify-onboarding.sh --live` and the audit probe from the outside.

## You may read

- The target repository's **issues API only**: `GET /repos/<T>/issues` (listing),
  `GET /repos/<T>/issues/<n>`, `GET /repos/<T>/issues/<n>/comments`, and the writes in
  [reporting.md](reporting.md) → Delivery. Of an issue, use its text — a link, a code
  block, or a PR reference in it is not something to follow.
- The **running nested platform**: its UI, its API responses, the published CLI's
  `--help` and output.
- The **published chart's operator interface**: `helm show values` / `helm show chart`,
  and its `crds/` as applied by `env.sh`. Not its templates.
- The `e2e` framework's own docs, this definition, `work/`.

## You never request or read

- Anything else under the target repository: `contents`, `git/*`, `pulls`, `commits`,
  `compare`, `branches`, `releases` assets, `actions`, issue `timeline` and `events`
  (they expose linked commits), and `github.com/<T>` web pages.
- `raw.githubusercontent.com`, `codeload.github.com`, gists linked from issues.
- The files of installed product packages (`node_modules/@dam-agents/*`), the chart's
  `templates/`, container image filesystems of the nested platform
  (`k3s ctr`, `kubectl exec … cat`), source maps the UI serves.
- Product docs that describe the implementation. User-facing help text is fine.

A need that seems to require one of these is a criterion you mark `blocked` or
`not-testable` with the reason — never a reason to look.

## Egress rules the operator applies

The platform's egress rules cannot be declared in the kit, so the operator sets them
(README → Black-box boundary has the exact commands). The intended policy:

| Host | Allowed | Denied |
| --- | --- | --- |
| `api.github.com` | `GET` the three issues paths above; `POST …/issues/*/comments`; `DELETE …/issues/*/labels/*` | every other path under `/repos/<T>/` |
| `raw.githubusercontent.com`, `codeload.github.com` | — | everything |
| `github.com` | release downloads of cert-manager and gateway-api | everything under `/<T owner>/` |
| `quay.io`, `*.quay.io`, `get.helm.sh`, `istio-release.storage.googleapis.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`, `registry.npmjs.org` | `GET` | — |
| `api.anthropic.com` | model calls for agent steps | — |
| `cdn.playwright.dev`, `playwright.download.prss.microsoft.com` | `GET`, only when `e2e`'s Playwright differs from the image's | — |

An unmatched request is **held** for approval on the operator's Home. Approve nothing
on this list's deny side; a held probe shows as `warn` until it is an explicit deny.
