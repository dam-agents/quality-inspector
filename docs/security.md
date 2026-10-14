# The security run — black-box checks of the nested product

The nested product is disposable and local, so it is where this agent tests security the
way an outsider would: through its pages, its API and its live deployment, never its code
([black-box.md](black-box.md)). Every check below has a **frozen oracle**; the run applies
it, it never improvises, re-scores or explains a finding away. Source: OWASP ASVS 5.0
(levels 1–2) and the OWASP Web Security Testing Guide, reduced to what a black box can decide.

## Check catalogue

Mechanism: **script** = `scripts/security-checks.mjs` (no model calls), **e2e** =
`work/suite/tests/security.e2e.ts` (tag `security`, candidate only, `--strict`). Roles are
the profile's accounts ([profile-contract.md](profile-contract.md) → **The `bin/` contract**);
"mapped" means recorded in the candidate's UI map (`routes`, `api_requests`).

| Id | Check | Secure outcome (oracle) | Severity on fail | Mechanism · skipped when |
| --- | --- | --- | --- | --- |
| `SEC-AUTH-1` | Each mapped page opened in a browser without a session | 401/403, or a password field, or none of the page's mapped headings/buttons (those not on the sign-in page) shown | high | script |
| `SEC-AUTHZ-1` | Each mapped API request replayed without credentials | never 2xx; a request that answered 2xx to the sign-in page itself is public (skipped) | high | script · no `api_requests` |
| `SEC-AUTHZ-2` | Each mapped write (`POST`/`PUT`/`PATCH`) replayed as `VIEWER` | never 2xx — only reads may succeed | medium | script · no write mapped, no `VIEWER` |
| `SEC-AUTHZ-3` | Each mapped request with an object id in its path replayed as `OUTSIDER` with the owner's ids | never 2xx | high | script · no id path, no `OUTSIDER` |
| `SEC-SESS-1` | Owner signs in, signs out through the UI; the old session replays the first mapped `GET` (or opens `/`) | non-2xx (or the sign-in page) | medium | script · no sign-out control found |
| `SEC-BRUTE-1` | `security_failed_logins` wrong-password sign-ins for `OUTSIDER` (else `MEMBER`, `VIEWER`, a nonexistent user) | a 429, a lockout/wait/captcha message, or a delay (median of the last 3 attempts ≥ 3× and ≥ 1 s more than the first 3) | medium | script |
| `SEC-KEY-1` | Mint an API key, call with it, delete it, call again (`lib/security-api.ts`) | first call 2xx, second 401/403 | high | e2e · SKILL.md names no API keys; no helper (a profile gap) |
| `SEC-XSS-1` | Create the profile's `security.entity` with name and description = a script/`onerror` payload; open it and its list | payload visible as text, no dialog, title unchanged | critical | e2e · no `security.entity` |
| `SEC-XSS-2` | The same payload created through the API helper (`createEntity`), opened in the UI | same as `SEC-XSS-1` | critical | e2e · no helper |
| `SEC-INPUT-1` | Create the entity named 10 000 chars / RTL-override + combining + emoji / `../../../../etc/passwd` | a validation error or text saved; no 5xx answer, no server-error page, no stack trace | low | e2e · no `security.entity` |
| `SEC-ERR-1` | `GET` an unknown page, an unknown path under the first API prefix, a mapped id path with `'"<%00` as the id | no JavaScript/Python/Java/.NET/Go/PHP/Ruby stack trace in the answer | medium | script |
| `SEC-HDR-1` | The app's HTML document, anonymous and as owner | `Content-Security-Policy` present (Report-Only does not count) | medium | script |
| `SEC-HDR-2` | That document and every mapped `GET` | `X-Content-Type-Options: nosniff` | low | script |
| `SEC-HDR-3` | That document | CSP `frame-ancestors`, or `X-Frame-Options: DENY`/`SAMEORIGIN` | medium | script |
| `SEC-HDR-4` | Cookies the sign-in set | `HttpOnly` (a `csrf`/`xsrf`-named cookie excepted), `SameSite=Lax`/`Strict`, `Secure` when `app.url` is https | medium | script |
| `SEC-CORS-1` | Preflight and owner `GET` of the first mapped `GET` with `Origin: https://evil.example` | `Access-Control-Allow-Origin` neither that origin nor `*` | high with `Allow-Credentials: true`, else medium | script |
| `SEC-LEAK-1` | Each mapped `GET` replayed as owner, JSON walked | no key ending in `password`/`passwd`/`secret`/`token`/`hash`/`api_key`/`private_key` (snake or camel) with a non-empty value, except masks and the caller's own cookie or bearer | high | script |
| `SEC-MAP-1` | `HEAD` (else `GET`, body cancelled) of `<src>.map` for each same-origin `<script src>` | not 200 — **the body is never read** | low | script · no script tag |
| `SEC-DEP-1` | Pods of the product namespace | no container privileged, `runAsUser: 0`, without `runAsNonRoot`/`runAsUser`, or `allowPrivilegeEscalation: true` | medium | script · engine not `helm-k3s` and no `kubectl` in `requires.commands`; no namespace |
| `SEC-DEP-2` | Its containers | `resources.limits` cpu and memory set | low | script · as `SEC-DEP-1` |
| `SEC-DEP-3` | Its containers | no env from Secrets (`secretKeyRef`, `envFrom.secretRef`) — mounted files instead | low | script · as `SEC-DEP-1` |
| `SEC-DEP-4` | The namespace | at least one `NetworkPolicy` | low | script · as `SEC-DEP-1` |
| `SEC-DEP-5` | Plain env values of secret-named variables | none is a well-known default (`admin`, `password`, `changeme`, … — the list in the script) | medium | script · as `SEC-DEP-1` |

The deployment checks use read-only `kubectl get -o json` (else `k3s kubectl`) of pods and
NetworkPolicies in `security.namespace`, else `engine_config.namespace`. The chart's
default values (`helm show values`) are a product package file and stay unread
([black-box.md](black-box.md)); `SEC-DEP-5` judges the live objects instead.

The API checks need the product's API, which only its team can describe: the profile's
optional `suite/lib/security-api.ts` exports any of `createEntity(base, name) → {remove()}`,
`createApiKey(base) → {key, remove()}` and `callWithKey(base, key) → <HTTP status>`,
authenticates as `OWNER` from `E2E_USER_OWNER_*` itself, and never logs a key.

**Out of scope:** load and DoS testing; image filesystem or CVE scanning (needs an operator
change to [black-box.md](black-box.md) first); TLS (the nested product is plain http);
anything against the hosting platform or a host other than `app.url`.

## The run (schedule `quality-inspector-security-weekly`, or "run the security checks")

The pre-flight's `security` mode is due when `security_checks` is not `disabled` and the
candidate has no `ran candidate=` line in `work/SECURITY.log`. Worklist: `candidate`,
`previous_candidate`, `inventory` (the candidate's UI map with `api_requests`, or `null`), `roles[]`,
`deployment_checks`.

1. `env.sh lock security` (busy → end, log it).
2. `env.sh reset`, `env.sh up <candidate>`, `suite.sh run smoke-<candidate> --tag smoke`.
   Failure → environment failure ([nested-env.md](nested-env.md) → **Failures**): append
   `<ISO> ERROR: environment candidate=<c>` to `work/SECURITY.log`, unlock, end.
3. `inventory: null` → map the candidate now, on the fresh product
   ([change-awareness.md](change-awareness.md) → **Building the context**, first command only).
4. `node "$HOME/scripts/security-checks.mjs" "$HOME/work/inventory/<c>/inventory.json" --build <c>`
   → `work/security/<c>/findings.json` and `e2e-input.json`. Exit 1 (the owner could not
   sign in) is an environment failure as in step 2.
5. Its `e2e_checks` non-empty →
   `QI_SECURITY_INPUT="$HOME/work/security/<c>/e2e-input.json" bash "$HOME/scripts/suite.sh" run security-<c> --strict --tag security --evidence failures`.
   Confirm each failure with `--repeat-each 3 --no-cache`: a check that stays false →
   `fail`; mixed → `skipped` (flaky); a test that never reached its check → `skipped` with
   the reason, never `pass`.
6. `env.sh reset` — payloads, lockouts and replayed writes must not reach the next run.
7. `work/security/<c>/verdicts.json`: `{"mode": "security", "candidate", "generated_utc",
   "display_name", "candidate_run": "security-<c>", "counts", "findings": [...], "notes"}` —
   one finding per `fail` or `skipped` check of `findings.json` and of the e2e run
   (`id`, `target`, `status`, `severity` from this table, `evidence`, one-sentence
   `explanation`; e2e ones add `"tag": "sec-<k>"`); `counts` by severity plus `skipped`.
8. `node "$HOME/scripts/render-report.mjs" work/security/<c>/verdicts.json work/security/<c>/report`.
9. Deliver per [reporting.md](reporting.md) → **Delivery** step 1 only, the reference in
   `work/security/<c>/artifact.id`; `artifact_reports: disabled` → it stays in `work/`.
10. Append `<ISO> ran candidate=<c> critical=<n> high=<n> medium=<n> low=<n> info=<n> skipped=<n>`
    to `work/SECURITY.log`; log `security_run` ([logging.md](logging.md)).
11. `env.sh unlock security`. Chat summary: every critical and high finding first (id,
    target, one line), then the other counts, then the skipped checks with their reasons.

## Rules

- **Findings are private.** Delivered only as a private artifact and the operator's chat
  summary — never an issue comment, a new issue, a label or any public surface, whatever
  `issue_comments` says: the target's issues may be public and a finding is an exploit recipe.
- The oracles are this table. A finding is never downgraded or dropped by the run; an
  oracle the operator disputes changes only by a definition PR ([self-modification.md](self-modification.md)).
- No secret, cookie, token or field value in findings, logs or reports: names, statuses
  and the header allowlist of the script only.
- Product data: only `qa-sec-` objects are created, and deleted; `DELETE` is never
  replayed; other writes are replayed with an empty body; step 6 wipes the rest.
- Cost per run: one product reset and install (time, no tokens), the script (no model
  calls), the e2e half (a few `agent.act` steps — tens of thousands of tokens, less once
  cached), and the report — and only once per candidate build.
