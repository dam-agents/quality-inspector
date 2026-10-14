# The black-box boundary

This agent judges the product the way a user meets it. Reading its implementation — even
once, even to "understand a failure" — would let the code define what correct means.
These rules are enforced, not only stated (**Enforcement layers** below).

## You may read

- The target repository's **issues API only**: `GET /repos/<T>/issues` (listing, closed
  ones included), `GET /repos/<T>/issues/<n>`, `GET /repos/<T>/issues/<n>/comments`, and
  the writes in [reporting.md](reporting.md) → Delivery. Of an issue, use its text — a
  link, a code block, or a PR reference in it is not something to follow.
- A **scenario request** in a Slack conversation this agent is bound to: its words, and a
  picture attached to it — as an issue's text is read ([scenarios.md](scenarios.md)); a
  link, a code block or another file in it is not followed or opened.
- The **running nested product**: its UI, its API responses, its published CLI's `--help`
  and output.
- In the security run only: the live pods and NetworkPolicies of the product's namespace,
  through read-only `kubectl get -o json`, for the fields [security.md](security.md) names.
- The **profile**: its `SKILL.md` (user-facing knowledge) and `profile.json`; its `bin/`
  scripts only to diagnose an environment failure.
- The `e2e` framework's own docs, this definition, `work/`.

## You never request or read

- Anything else under the target repository: `contents`, `git/*`, `pulls`, `commits`,
  `compare`, `branches`, `actions`, `releases` assets, issue `timeline` and `events`
  (they expose linked commits), and `github.com/<T>` web pages.
- The same data by another road: GraphQL, code or commit search, a repository by number
  (`/repositories/<id>/…`), gists.
- `raw.githubusercontent.com`, `codeload.github.com`, and any other code host (GitLab,
  Bitbucket, a company's own GitHub or GitLab).
- The files of installed product packages (its CLI in `node_modules`, its images'
  filesystems, the templates and default values of its deployment charts), source maps its
  UI serves (the security run asks for their status only, never their body).
- Anything the profile lists under `boundary`.
- Product docs that describe the implementation. User-facing help text is fine.

A need that seems to require one of these is a criterion you mark `blocked` or
`not-testable` with the reason — never a reason to look.

## Enforcement layers

| Layer | Holds | Proven by |
| --- | --- | --- |
| Egress rules (below) | the network: what the VM may reach at all | the boundary probes of `verify-onboarding.sh --live` and the audit (`scripts/lib/boundary.sh`: the provider's list plus the profile's `boundary`; only the gateway's refusal proves a deny, a `404` is a `warn`) |
| PreToolUse hook [`scripts/hooks/policy.sh`](../scripts/hooks/policy.sh) | every tool call before it runs — its header is the rule table: the surfaces above, `git clean`, container filesystems, writes outside `work/`, and commits, pushes and definition edits in a scheduled run or a channel turn ([persistence.md](persistence.md) → **Scheduled or direct session**) | `scripts/tests/test_policy_hook.sh` and the validator in CI; `policy_hook` in `verify-onboarding.sh` and the audit |
| `permissions.deny` | the commands static patterns can express, as a second net | the same `policy_hook` check |

`scripts/hooks/install.sh` merges the hook and the deny list into
`$HOME/.claude/settings.json` (ONBOARDING Step 2e). A refusal reads `policy: denied
(<rule>)` and logs `policy_denied`; it is final — treat it like the list above, never
look for another route. The hook matches command text, so the egress rules remain the
layer that holds against a deliberate bypass.

## Egress rules

The kit seeds the rules every deployment shares. The target's depend on the instance:
`bash scripts/egress-rules.sh` prints them, with the profile's `egress`, as `dam network
create` commands for the operator (`--kit` adds the kit's, for an agent created by hand
or from a kit before 2.11.0). The platform picks one rule per request:

1. the exact host, then its `*.parent` wildcard (one label), then `*`;
2. a named method over `*` — so a deny that must beat a `GET` allow is a `GET` rule;
3. a path over `*`, then the longer path. `*` matches anything, `/` and the query string
   included.

The `trusted` preset and the GitHub connection allow their hosts (`github.com`, its API,
codeload, raw, `gitlab.com`, `codeberg.org`, …) with method and path `*` before the kit's
rules land, and a kit rule contradicting one fails the apply. So a kit deny names a path
— `/*` for a whole host — which also outranks their `*` (`validate-definition.sh` checks).

| Host | Allowed | Denied |
| --- | --- | --- |
| `api.github.com` (kit) | the rest (connection) | `/graphql*`, `/search/code*`, `/search/commits*`, `/repositories/*`, `/gists*` |
| `api.github.com` (target) | `GET /repos/<T>/issues*`; `POST …/issues/*/comments*`; `DELETE …/issues/*/labels/<retest_label>` — that label only, URL-encoded (`qa%3Aretest`) | `GET …/issues/*/timeline*`, `GET …/issues/*/events*`, `GET …/issues/events*`; every other path under `/repos/<T>/` |
| `github.com`, `codeload.github.com` (target) | this agent's definition, skill installs | `/<T>*`, `/<T>/*` |
| `raw.githubusercontent.com`, gists, GitLab, Bitbucket, Codeberg, Gitea, Azure DevOps, Sourcegraph, SourceHut (kit) | — | `/*` |
| `registry.npmjs.org` (kit) | `GET` (the `e2e` framework) | — |
| `api.anthropic.com` (kit) | model calls for agent steps | — |
| `cdn.playwright.dev`, `playwright.download.prss.microsoft.com` | `GET`, only when `e2e`'s Playwright differs from the image's | — |

A target on GitHub Enterprise gets the same target rules on its own host — the API under
`/api/v3` (on `api.<host>` for `ghe.com`), plus its GraphQL, search, raw and codeload
paths, which the kit cannot name. Any host no rule matches — a company's own GitHub or
GitLab included — is **held** for approval on the operator's Home: approve nothing on the
deny side; a held probe shows as `warn` until it is an explicit deny.

What the rules cannot close:

- **Other repositories.** The connection allows every repository its token can see, so a
  fork or mirror of the target is readable: scope the token (README → Setup).
- **A profile inside the target repository.** The platform installs a skill from its
  whole repository's tarball through this agent's gateway (`/repos/<T>/tarball*`, then
  codeload `/<T>/*`) — both denied, so a (re)install fails while the rules hold. A
  `GET /repos/<T>/contents/<profile dir>*` allow only lets the Skills page preview it.
