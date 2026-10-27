---
name: qi-test-sync
description: >-
  Keep a product's quality-inspector profile and its QA tests in step with a change to the
  product: read a pull request or branch of the product's repository, find what the
  black-box QA agent depends on that the change moves, renames, replaces or removes — a
  label, a dialog, a flow, a route, an API field, a CLI flag, a sign-in step, a third-party
  surface — and update the profile under .quality-inspector/ (its suite/ helpers, scenarios,
  SKILL.md, profile.json egress) in the same change, plus a "QA impact" note in the pull
  request text that the agent reads. Use it whenever a product change may break the
  quality inspector's tests: "does this PR need a QI update", "sync the QA profile",
  "update the quality-inspector scenarios", "check QA impact", or as a review rule (a code
  reviewer checking that a UI or API change kept the profile current). Not for writing a
  new profile (qi-profile-creator), never inside a quality-inspector agent.
argument-hint: "[pull request number or branch; default: the current branch against its base]"
---

# Quality-inspector test sync

The quality inspector tests a product black-box: it knows the product only from its
running UI, the issue and pull request **text**, and the profile the product team keeps in
`.quality-inspector/<profile>/`. When a change moves something a test uses, the agent's
nightly triage can rewrite the steps before a frozen check only if a completed issue or a
merged pull request **states** the new flow, and it can drive only what the profile gives
it. This skill makes the product change carry both. Every file you write is in English;
your replies are in the conversation's language.

## Ground rules

- **Never inside a quality-inspector agent.** `$HOME/.quality-inspector-onboarded` exists →
  stop: the profile is read-only there.
- **You may read the source; the profile must not leak it.** `SKILL.md` and scenarios hold
  what a user could see or be told, never code paths, internal names or configuration.
- **A scenario is the oracle.** Change its Given or When when the way to reach the state
  changed on purpose. Change a Then only when the change alters that behaviour on purpose,
  and quote the issue or PR sentence that says so. Never weaken a Then to make a test pass.
- **The contract is the core's.** `docs/profile-contract.md` of the quality-inspector
  definition (this skill's directory two levels up, or `QI_CORE`) wins over this file.
- **Least privilege.** A new egress rule names the exact host, method and path the helper
  needs, in the profile's own `profile.json`; never a product-wide or kit-wide allow.

## Workflow

1. **Scope.** The diff of the pull request or branch against its base. No
   `.quality-inspector/*/profile.json` in the repository → say so and stop.
2. **What QA depends on.** Read the profile: `scenarios/*.md|.feature` (quoted labels,
   pages, Given/When steps), `suite/` helpers (locators, labels, routes, API calls),
   `SKILL.md` (flows, labels, testability limits), `profile.json` (`engine_config`,
   `egress`, `sandbox`, `interfaces`).
3. **Match the change against it.** For each item of step 2 the diff touches, one line:
   what changed (old → new), where the profile uses it (file:line), and the kind —
   `label`, `flow` (a dialog, a sequence, a sign-in step), `route`, `api`, `cli`,
   `third-party` (a step now happens in another product's surface: a chat client, a
   mailbox, an OAuth page), `deploy` (`engine_config` values). Also note product UI or API
   changes the profile does not cover yet but a scenario's Given relies on.
4. **Update the profile in the same change.**
   - `label`, `route`, `api`, `cli`: the helper's locator or call, and every scenario and
     `SKILL.md` line that quotes the old text.
   - `flow`: rewrite the helper so it reaches the same state through the new flow; update
     the scenario's Given/When words and `SKILL.md`.
   - `third-party`: a helper that drives the step through the sandbox account the profile
     already has (`sandbox`, `credentials.env` names), plus its egress. No automatable way →
     a testability limit in `SKILL.md`, and tell the person which product-side test hook
     would make it testable.
   - `deploy`: `engine_config`, checked with the engine's `bin/check`.
   Then run `node <QI_CORE>/skills/qi-profile-creator/scripts/check-profile.mjs <profile dir>`.
5. **Write the QA impact note** into the pull request body (or give it to the person to
   paste): a `QA impact` section in plain words that names each old and new label, field,
   dialog and step — *"The 'Channel ID' field of the 'Connect Slack channels' dialog is
   removed; the user now runs /dam bind in the Slack channel."* The agent's change radar and
   its issue matching read this text; a named old label is what pairs it with the tests that
   use it. No change touches QA → one line: `QA impact: none`.

## Review mode

When a reviewer (a person or a review agent) runs this skill on a pull request, it changes
nothing: it reports each step-3 item that step 4 left undone as a finding — the product file
and line, the profile file and line, and the edit it needs — and a missing `QA impact`
section as one finding when any item exists.
