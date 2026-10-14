# Writing the profile's SKILL.md

The QA agent reads it at two moments: when it **freezes acceptance criteria** — deciding
for each one its `surface` (ui, cli, api) and whether it is `testable` — and when it
**writes tests**, finding its way through the UI, signing in and getting a token. It is
read for every issue, so every line is paid for again and again: stay under about 80
lines.

## The black-box filter

Ask of every sentence: could an attentive user have written it from the UI, the user
documentation or the published CLI's `--help`? If not, delete it.

- **Never**: source paths, module, class or function names, internal service names,
  database tables or columns, internal endpoints, feature flags a user cannot see,
  architecture, links to the repository, its CI or design documents. Not even "to help
  with a flaky screen".
- **Fine**: navigation labels exactly as the UI shows them, the terms users see,
  documented user-visible limits, the published CLI's package and verbs, the public API's
  base path and how a user is given a token.

The agent's rules already forbid it to read the implementation; a profile that describes
the code breaks the black box as surely as reading it would.

## Sections

Keep the template's order; drop a section that has nothing to say.

- **Intro** — two sentences: what the product does for its users; what the nested install
  is (a fresh instance at `app.url`, how many users, signed in as the test owner from
  `credentials.env`).
- **Vocabulary a user sees** — the nouns issues use, one bullet each, the UI's own label
  in bold, then what it is to a user. This is how the agent maps "Done when" sentences
  onto screens.
- **Where things are** — the main areas and how a user reaches them, by navigation label.
  Names only, no layout: positions change with every redesign, labels rarely do.
- **Test accounts** — `owner` and each further role (`member`, `viewer`, `outsider`, the
  contract's names): what it may do and what it may not. Explorations and the security
  run judge access against these sentences. Never a username or password; tests read
  them from the credentials.
- **What the nested install cannot do** — the section that decides verdicts. One bullet
  per limit: the limit, then the verdict in the core's words:
  - `testable: no — external dependency` for an outside service with no stand-in;
  - another reason after `testable: no —` for another cause (`single user`);
  - `blocked`, naming the `profile.<key>`, when an optional setting provides the stand-in
    — an instance without it reports such criteria blocked, not failed;
  - with a stand-in, how a user observes it (a scripted reply, a mail catcher's inbox) —
    that keeps those criteria testable.
- **CLI and API** — only when the product publishes them: the package name, how a test
  gets a token through the UI, the auth scheme, machine-readable output flags.
- **Builds** — what a build name looks like in a report (`0.0.0-main.<n>` after every
  merge, `X.Y.Z` releases).

## Style

English, present tense, one fact per bullet, UI labels exactly as shown, no marketing.
The frontmatter `description` says it is the quality-inspector profile of the product and
to load it when quality-inspector freezes acceptance criteria or writes tests for it.

## Before you hand it over

- [ ] `name` equals the directory name.
- [ ] Every outside service from the brief is under "cannot do" or has its stand-in.
- [ ] It says whether there is one user or several.
- [ ] Nothing fails the black-box filter.
- [ ] About 80 lines or fewer.
