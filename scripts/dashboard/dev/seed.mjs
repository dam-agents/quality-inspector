#!/usr/bin/env node
// Development only: writes a made-up work/ for the new dashboard page (docs/dashboard-page.md), so the
// page can be tuned on realistic amounts of data: about 50 tests, 40 runs, problems still there and gone,
// 10 screens with pictures, a run in progress. Dates are relative to now, so "Today" and "Yesterday" show.
//   node scripts/dashboard/dev/seed.mjs /tmp/qi-dev-work
//   WORK_DIR=/tmp/qi-dev-work node scripts/dashboard/dev/harness.mjs 5600 5599   → http://localhost:5600/?page=new
// Nothing here is real: the product "Tasklane", its issues and people are invented.
import { createHash } from 'node:crypto';
import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { deflateSync } from 'node:zlib';

const W = process.argv[2];
if (!W) { console.error('usage: seed.mjs <work dir>'); process.exit(2); }
rmSync(W, { recursive: true, force: true });
for (const d of ['catalog/thumbs', 'env', 'dashboard', 'logs']) mkdirSync(join(W, d), { recursive: true });

// A seeded random, so every seed gives the same data.
let seed = 7;
const rnd = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
const pick = (a) => a[Math.floor(rnd() * a.length)];
const NOW = Date.now();
const iso = (msAgo) => new Date(NOW - msAgo).toISOString().replace(/\.\d+Z$/, 'Z');
const H = 3600e3, DAY = 24 * H;
const nightUtc = (daysAgo) => { const d = new Date(NOW - daysAgo * DAY); d.setUTCHours(3, 0, 0, 0); return d.toISOString().replace(/\.\d+Z$/, 'Z'); };

// ------------------------------------------------------------------ builds: one a night, the newest today
const BUILDS = Array.from({ length: 12 }, (_, k) => ({ id: `r${1830 + k}`, utc: nightUtc(11 - k) }));
const buildAt = (daysAgo) => BUILDS[Math.max(0, Math.min(BUILDS.length - 1, 11 - Math.round(daysAgo)))].id;
const NEWEST = BUILDS.at(-1).id;

// ------------------------------------------------------------------ screens of the product
const SCREENS = [
  ['/', 'Home', 'regression'], ['/projects', 'Projects', 'regression'], ['/projects/:id', 'Project', 'regression'],
  ['/projects/:id/board', 'Board', 'exploratory'], ['/tasks/:id', 'Task', 'regression'], ['/files', 'Files', 'regression'],
  ['/inbox', 'Inbox', 'exploratory'], ['/reports', 'Reports', null], ['/settings/members', 'Members', 'regression'],
  ['/settings/billing', 'Billing', null], ['/sign-in', 'Sign in', 'regression'],
];

// ------------------------------------------------------------------ the tests
// [issue, title, area, page, [[AC name, given, when, then, quote], …]]
const ISSUES = [
  [101, 'Rename projects', 'projects', '/projects', [
    ['A renamed project keeps its tasks', 'a project with three tasks', 'the owner renames it to “Q4 plan”', 'the project shows the name “Q4 plan” with its three tasks', 'When I rename a project, its tasks must stay with it.'],
    ['An empty name is refused', 'a project', 'the owner clears its name and saves', 'the name field says “A name is required”', 'An empty name should not be allowed.']]],
  [104, 'Drag tasks between columns', 'board', '/projects/:id/board', [
    ['A dragged task moves to the new column', 'a board with the columns To do and Done', 'a member drags a task from To do to Done', 'the task shows in Done and not in To do', 'Dragging a card to another column moves it.'],
    ['The move stays after a reload', 'a task moved to Done', 'the member reloads the page', 'the task is still in Done', 'After refresh the card must stay where I put it.']]],
  [108, 'Upload files to a task', 'files', '/tasks/:id', [
    ['A file up to 50 MB uploads', 'a task', 'a member uploads a 48 MB PDF', 'the file is listed on the task with its size', 'Files up to 50 MB must upload.'],
    ['A larger file is refused with a reason', 'a task', 'a member uploads a 60 MB video', 'the page says “Files can be up to 50 MB”', 'Bigger files get a clear message.'],
    ['Upload shows its progress', 'a task', 'a member uploads a 30 MB file', 'a progress bar shows until the upload ends', 'I want to see how far the upload is.']]],
  [112, 'Invite members by email', 'members', '/settings/members', [
    ['An invited person gets an invitation', 'the members page', 'the owner invites “dana@example.com”', 'the list shows dana@example.com as Invited', 'The owner can invite people by email.'],
    ['A viewer cannot invite', 'a viewer on the members page', 'the viewer looks for the Invite button', 'there is no Invite button', 'Only owners and admins can invite.']]],
  [115, 'Due dates on tasks', 'tasks', '/tasks/:id', [
    ['A due date shows on the task', 'a task', 'a member sets the due date to Friday', 'the task shows “Due Fri”', 'Tasks need a due date.'],
    ['An overdue task is marked red', 'a task due yesterday', 'a member opens the project', 'the task’s date shows in red', 'Overdue should be obvious.']]],
  [117, 'Search across projects', 'search', '/', [
    ['Search finds a task by its words', 'a task named “Invoice for ACME”', 'a member searches for “acme”', 'the task is in the results', 'Search should find tasks by any word in the title.'],
    ['Search shows nothing found', 'no task with “zzz”', 'a member searches for “zzz”', 'the page says “No results”', 'An empty search needs a message.']]],
  [120, 'Notifications in the inbox', 'inbox', '/inbox', [
    ['A mention lands in the inbox', 'two members on a project', 'one mentions the other in a comment', 'the other sees the mention in the inbox', 'When someone @mentions me I see it in my inbox.']]],
  [122, 'Archive a project', 'projects', '/projects/:id', [
    ['An archived project leaves the list', 'a project', 'the owner archives it', 'the project is not in the project list', 'Archived projects disappear from the list.'],
    ['An archived project can be restored', 'an archived project', 'the owner restores it', 'the project is in the list again', 'Archiving must be reversible.']]],
  [125, 'Billing shows the plan', 'billing', '/settings/billing', [
    ['The current plan shows', 'an owner on the Team plan', 'the owner opens billing', 'the page shows “Team plan”', 'The billing page shows which plan we are on.']]],
  [127, 'Sign in with a magic link', 'sign-in', '/sign-in', [
    ['A magic link signs the person in', 'the sign-in page', 'a person asks for a link and opens it', 'the home page shows their name', 'People can sign in with a link from email.'],
    ['An old link is refused', 'a link older than 15 minutes', 'the person opens it', 'the page says “This link has expired”', 'Links expire after 15 minutes.']]],
  [129, 'Comments on tasks', 'tasks', '/tasks/:id', [
    ['A comment shows under the task', 'a task', 'a member writes “Looks good”', 'the comment “Looks good” shows with the member’s name', 'Members can comment on tasks.'],
    ['A comment can be edited', 'a comment by the member', 'the member edits it to “Looks great”', 'the comment says “Looks great” and “edited”', 'I can fix a typo in my comment.']]],
  [131, 'Export a report as CSV', 'reports', '/reports', [
    ['The export downloads a CSV', 'the reports page', 'a member presses Export', 'a CSV file with the tasks downloads', 'Reports can be exported to CSV.']]],
];
const SCENARIOS = [
  [3, 'A new member finds their first task', 'onboarding', '/', ['A new member sees the welcome steps', 'a member who signed in the first time', 'they open the home page', 'the page shows “Welcome” and three steps', null]],
  [5, 'A long project name does not break the board', 'board', '/projects/:id/board', ['The board header keeps a 120-character name readable', 'a project with a 120-character name', 'a member opens its board', 'the name is cut with “…” and the full name shows on hover', null]],
  [6, 'Two people move the same task at once', 'board', '/projects/:id/board', ['The last move wins and both see it', 'two members on one board', 'both move the same task at once', 'both boards show the task in the same column', null]],
  [8, 'Files with accents in the name', 'files', '/files', ['A file named “Účtenka září.pdf” uploads', 'the files page', 'a member uploads “Účtenka září.pdf”', 'the list shows “Účtenka září.pdf”', null]],
  [9, 'Inbox on a slow network', 'inbox', '/inbox', ['The inbox shows a loading state', 'a slow network', 'a member opens the inbox', 'a loading state shows, then the messages', null]],
];

// The story of each test over the nights: most pass; some broke, some are unstable or changed.
// [verdict now, earlier verdicts …] — the newest last.
const STORIES = {
  '#101 AC-1': ['verified', 'unchanged', 'unchanged', 'healed', 'unchanged', 'unchanged'],
  '#101 AC-2': ['verified', 'unchanged', 'unchanged', 'unchanged', 'regression'],
  '#104 AC-1': ['verified', 'unchanged', 'flaky', 'unchanged', 'flaky'],
  '#104 AC-2': ['verified', 'unchanged', 'unchanged', 'regression', 'regression', 'regression'],
  '#108 AC-1': ['verified', 'unchanged', 'unchanged', 'unchanged', 'unchanged'],
  '#108 AC-2': ['failed', 'failed'],
  '#108 AC-3': ['inconclusive'],
  '#112 AC-1': ['verified', 'unchanged', 'unchanged', 'needs-review'],
  '#112 AC-2': ['verified', 'unchanged', 'unchanged', 'unchanged'],
  '#115 AC-1': ['verified', 'unchanged', 'relearned', 'unchanged'],
  '#115 AC-2': ['verified', 'unchanged', 'drift'],
  '#117 AC-1': ['verified', 'unchanged', 'unchanged', 'unchanged', 'unchanged', 'unchanged', 'unchanged'],
  '#117 AC-2': ['verified', 'unchanged', 'unchanged', 'unchanged'],
  '#120 AC-1': ['verified', 'unchanged', 'blocked'],
  '#122 AC-1': ['verified', 'unchanged', 'unchanged'],
  '#122 AC-2': ['partial'],
  '#125 AC-1': ['not-testable'],
  '#127 AC-1': ['verified', 'unchanged', 'unchanged', 'unchanged', 'unchanged'],
  '#127 AC-2': ['verified', 'unchanged', 'regression', 'healed', 'unchanged'],
  '#129 AC-1': ['verified'],
  '#129 AC-2': ['verified'],
  '#131 AC-1': [],
  'S-3 AC-1': ['passed', 'unchanged', 'unchanged'],
  'S-5 AC-1': ['failed'],
  'S-6 AC-1': ['passed', 'flaky'],
  'S-8 AC-1': ['passed'],
  'S-9 AC-1': ['blocked'],
  'P-sign-in AC-1': ['passed', 'unchanged', 'unchanged', 'unchanged', 'unchanged', 'unchanged', 'unchanged', 'unchanged'],
};
const WHY = {
  regression: { '#101 AC-2': 'The new build saves an empty name and shows the project as “Untitled”.', '#104 AC-2': 'After a reload the task is back in To do: the move is not saved.', '#127 AC-2': 'An expired link signed the person in.' },
  healed: 'The button moved; the test was repaired to the new place.', relearned: 'The page changed its words; the test learned the new ones.',
  flaky: 'Passed 2 of 3 times: the board loads slowly now and then.', 'needs-review': 'The list now shows “Pending” where the test expects “Invited”. A person decides which is right.',
  drift: 'The date format changed from “Due Fri” to “Fri 28 Nov” since the test was kept.', blocked: 'The inbox did not load in 60 s; the run could not decide.',
  failed: { '#108 AC-2': 'A 60 MB file uploads without a message; the issue says it must be refused.', 'S-5 AC-1': 'The name runs over the column headers and hides the first column.' },
  inconclusive: 'The progress bar showed on the old build too, so this run cannot tell if the issue changed it.', partial: 'Restoring works, but the project comes back without its members.',
  'not-testable': 'The plan comes from the billing provider, which the test product does not have.',
};
const whyOf = (v, ref) => (typeof WHY[v] === 'object' ? WHY[v][ref] : WHY[v]) || null;

const items = [];
const addItem = (o, ac, k, page, tierHint) => {
  const ref = `${o.ref} AC-${k}`;
  const story = STORIES[ref] ?? ['verified'];
  const n = story.length, firstDays = Math.min(11, n + 1 + Math.floor(rnd() * 2));
  const history = story.map((v, j) => {
    const daysAgo = j === 0 ? firstDays : Math.max(0, firstDays - j * (firstDays / Math.max(1, n - 1 || 1)));
    const run = j === 0 ? (o.kind === 'issue' ? 'issue' : 'scenario') : 'regression';
    const utc = run === 'regression' ? nightUtc(Math.round(daysAgo)) : iso(daysAgo * DAY + 5 * H);
    const why = whyOf(v, ref);
    return { build: buildAt(daysAgo), run, value: v, utc, cause: null, ...(why ? { why } : {}) };
  });
  const tier = tierHint ?? (n >= 3 ? 'regression' : 'exploratory');
  const key = `${o.kind === 'issue' ? `issue-${o.number}` : o.kind === 'scenario' ? `scenario-${o.ref.slice(2)}` : o.ref.toLowerCase()}/AC-${k}`;
  items.push({
    key, file: `tests/${key.split('/')[0]}.e2e.ts`, origin: o, id: `AC-${k}`, kind: 'criterion', name: ac[0], goal: null,
    quote: ac[4], given: ac[1], when: ac[2], then: ac[3], surface: 'ui', testable: story[0] !== 'not-testable',
    tier, promoted_utc: tier === 'regression' ? history[1]?.utc ?? null : null, drift: story.at(-1) === 'drift', area: o.area,
    summary: null, session: 'owner', pages: [page], steps: [{ kind: 'open', text: page.replace(':id', '12') }, { kind: 'act', text: ac[2] }], checks: { expects: 1, agent_asserts: 0 },
    verdict: history.at(-1) ?? null, history, heals: [], flaky: [], duration_ms: [], still: null, marked: null, mark_saw: null,
    evidence: history.length ? `https://share.example/a/${key.replace(/\W/g, '')}` : null, still_sharp: null,
  });
};
for (const [number, title, area, page, acs] of ISSUES) {
  const o = { kind: 'issue', ref: `#${number}`, number, title, summary: null, labels: [`area:${area}`], state: number >= 129 ? 'open' : 'closed', area };
  acs.forEach((ac, j) => addItem(o, ac, j + 1, page));
}
for (const [n, title, area, page, ac] of SCENARIOS) addItem({ kind: 'scenario', ref: `S-${n}`, number: n, title, summary: null, labels: [], state: null, area }, ac, 1, page);
addItem({ kind: 'scenario', ref: 'P-sign-in', number: null, title: 'The owner signs in', summary: null, labels: [], state: null, area: 'sign-in' },
  ['The home page shows after sign-in', 'the sign-in page', 'the owner signs in', 'the home page shows “Good morning”', null], 1, '/sign-in', 'regression');

// ------------------------------------------------------------------ the runs
const runs = [];
const PROBLEMS = {
  emptyName: { title: 'An empty project name is saved', severity: 'high', certainty: 'high', about: ['#101 AC-2'],
    what: 'Clearing a project’s name and saving keeps the project as “Untitled”. No message shows.', where: '/projects',
    why: 'The new build stopped checking the name before it saves.', fix: 'Check the name again before saving and show “A name is required”.' },
  boardMove: { title: 'A moved task jumps back after a reload', severity: 'high', certainty: 'high', about: ['#104 AC-2'],
    what: 'A task dragged to Done is back in To do after the page reloads.', where: '/projects/:id/board',
    why: 'The move shows on the screen but is not saved.', fix: 'Save the move when the task is dropped.' },
  boardSlow: { title: 'The board loads slowly now and then', severity: 'low', certainty: 'medium', about: ['#104 AC-1'],
    what: 'One of three loads of the board took more than 8 s.', where: '/projects/:id/board', why: 'Not known.', fix: 'Not known yet.' },
  expiredLink: { title: 'An expired sign-in link still works', severity: 'high', certainty: 'high', about: ['#127 AC-2'],
    what: 'A link older than 15 minutes signed the person in.', where: '/sign-in', why: 'The link’s age was not checked on build r1836.', fix: 'Fixed on build r1838: the link is refused again.' },
  inboxDown: { title: 'The inbox does not load', severity: 'medium', certainty: 'medium', about: ['#120 AC-1'],
    what: 'The inbox shows a spinner for more than 60 s.', where: '/inbox', why: 'Not known: the product gave no error on the screen.', fix: 'Not known yet.' },
  invitedWord: { title: 'Invited people show as “Pending”', severity: 'low', certainty: 'high', about: ['#112 AC-1'],
    what: 'The member list says “Pending” where it said “Invited”.', where: '/settings/members', why: 'The word changed in the new build. It may be on purpose.', fix: 'A person decides which word is right.' },
};
const counts0 = () => ({ unchanged: 0, relearned: 0, healed: 0, 'needs-review': 0, superseded: 0, flaky: 0, regression: 0, blocked: 0, drift: 0 });
for (let d = 10; d >= 0; d--) {
  const build = buildAt(d), utc = nightUtc(d);
  if (d === 6) {
    runs.push({ type: 'regression', ref: null, build, utc, counts: counts0(), secs: 240, cost_usd: null, verdict: 'environment', previous: buildAt(d + 1), window: null, issues: [], ui_diff: null, signals: {}, report: null,
      analysis: null, trigger: { via: 'schedule', who: 'Regression run', why: `nightly regression of the new build ${build}` }, entries: [],
      failure: { cause: 'The test product did not start: its database took more than 10 minutes to come up.', repair: 'Started it again from the beginning: the same wait.', next: 'The next night tries again. If it repeats, the operator looks at the test machine.' } });
    continue;
  }
  const c = counts0(); c.unchanged = 14 + Math.floor(rnd() * 6);
  const probs = [];
  if (d <= 4) { c.regression++; probs.push(PROBLEMS.emptyName); }
  if (d <= 2) { c.regression++; probs.push(PROBLEMS.boardMove); }
  if (d === 4 || d === 2 || d === 0) { c.flaky++; probs.push(PROBLEMS.boardSlow); }
  if (d >= 4 && d <= 5) { c.regression++; probs.push(PROBLEMS.expiredLink); }
  if (d === 3) c.healed++;
  if (d === 0) { c.blocked++; probs.push(PROBLEMS.inboxDown); c['needs-review']++; probs.push(PROBLEMS.invitedWord); c.drift++; }
  const verdict = c.regression ? 'regression' : c.blocked ? 'blocked' : c['needs-review'] ? 'needs-review' : c.flaky ? 'flaky' : c.healed ? 'healed' : 'unchanged';
  const summary = probs.length ? `${probs.length === 1 ? 'One problem' : `${probs.length} problems`} on build ${build}. ${c.unchanged} tests passed as before.` : `All ${c.unchanged} tests passed on build ${build}.`;
  runs.push({ type: 'regression', ref: null, build, utc, counts: c, secs: 2400 + Math.floor(rnd() * 1800), cost_usd: null, verdict, previous: buildAt(d + 1), window: null,
    issues: d % 3 === 0 ? [{ number: 100 + d, title: pick(['Faster board', 'New colours for labels', 'Fix the date picker', 'Bulk move tasks']) }] : [],
    ui_diff: null, signals: {}, report: `https://share.example/a/night-${build}`,
    analysis: { summary, problems: probs, next: null }, trigger: { via: 'schedule', who: 'Regression run', why: `nightly regression of the new build ${build}` }, entries: [] });
}
for (const i of items) for (const h of i.history.filter((x) => x.run !== 'regression')) {
  const type = h.run, ref = i.origin.ref;
  if (runs.some((r) => r.type === type && r.ref === ref)) continue;
  const its = items.filter((x) => x.origin.ref === ref), first = its.map((x) => x.history[0]?.value);
  const verdict = first.includes('failed') ? 'failed' : first.includes('partial') ? 'partial' : first.includes('blocked') ? 'blocked' : first.includes('inconclusive') ? 'inconclusive' : type === 'issue' ? 'verified' : 'passed';
  const probs = [];
  if (ref === '#108') probs.push({ title: 'A file over 50 MB uploads without a message', severity: 'medium', certainty: 'high', about: ['#108 AC-2'], what: 'A 60 MB video uploaded. The issue says it must be refused with “Files can be up to 50 MB”.', where: '/tasks/:id', why: 'The size limit is not checked.', fix: 'Refuse files over 50 MB and say why.' });
  if (ref === '#122') probs.push({ title: 'A restored project loses its members', severity: 'high', certainty: 'high', about: ['#122 AC-2'], what: 'After restore the project has no members but the owner.', where: '/projects/:id', why: 'Not known.', fix: 'Not known yet.' });
  if (ref === 'S-5') probs.push({ title: 'A long project name covers the board', severity: 'medium', certainty: 'high', about: ['S-5 AC-1'], what: 'A 120-character name runs over the column headers.', where: '/projects/:id/board', why: 'The header does not cut long names.', fix: 'Cut the name with “…” and show it whole on hover.' });
  const n = its.length;
  runs.push({ type, ref, build: h.build, utc: h.utc, counts: {}, secs: 1200 + Math.floor(rnd() * 2400), cost_usd: null, verdict, previous: null, window: null, issues: [], ui_diff: null, signals: {},
    report: `https://share.example/a/${type}-${ref.replace(/\W/g, '')}`,
    analysis: { summary: probs.length ? `${probs.length === 1 ? 'One problem' : `${probs.length} problems`} in ${n === 1 ? 'the one check' : `${n} checks`}.` : `All ${n === 1 ? 'the one check passes' : `${n} checks pass`}.`, problems: probs, next: null },
    trigger: type === 'issue' ? { via: 'github', who: null, why: `label qa:ready on ${ref}` } : { via: 'slack', who: pick(['Dana Novák', 'Petr Malý', 'Eva Svobodová']), why: 'scenario request' }, entries: [] });
}

// ------------------------------------------------------------------ each run's report on the page (catalog.mjs → `rep`)
// Per result its test on the new build (c) and, for an issue or scenario run, on the last release (b):
// the status, the length, the error, the steps [api, label, status, ms] and screenshots of the screen.
const shotOf = (pattern) => `s${SCREENS.findIndex(([p]) => p === pattern)}`;
const STATUS = (v) => (['failed', 'regression', 'partial'].includes(v) ? 'failed' : v === 'flaky' ? 'flaky' : v === 'blocked' ? 'timed-out' : 'passed');
function side(i, v) {
  const st = STATUS(v), page = i.pages[0], why = i.history.find((h) => h.value === v)?.why;
  const last = st === 'failed' ? 'failed' : st === 'timed-out' ? 'timed-out' : 'passed';
  const steps = [['app.open', `Open ${page.replace(':id', '12')}`, 'passed', 700 + Math.floor(rnd() * 600)],
    ...(i.given ? [['agent.act', `Make sure: ${i.given}`, 'passed', 3000 + Math.floor(rnd() * 3000)]] : []),
    ['agent.act', i.when, st === 'timed-out' ? 'timed-out' : 'passed', 2500 + Math.floor(rnd() * 4000)],
    ...(st === 'timed-out' ? [] : [['app.screenshot', `${i.id}: ${i.name}`, 'passed', 300], ['agent.assert', i.then, last, 1500 + Math.floor(rnd() * 2000)]])];
  return { st, ms: steps.reduce((a, s) => a + s[3], 0), more: 0, steps,
    err: st === 'failed' ? `The check did not hold: ${i.then}. ${why || ''}`.trim() : st === 'timed-out' ? 'The page did not answer within 60 s.' : null,
    // Each shot at its step (`at`): after the page opened, the test's own screenshot, the screen at the failure.
    shots: [{ cap: 'After step 1', img: shotOf(page), at: 0 }, ...(st === 'timed-out' ? [] : [{ cap: `${i.id}: ${i.name}`, img: shotOf(page), at: steps.length - 2 }]),
      ...(st === 'passed' ? [] : [{ cap: 'The screen at the failure', img: shotOf(page), at: steps.length - 1, fail: true }])] };
}
for (const r of runs) {
  const results = {}, entries = [];
  for (const i of items) for (const h of i.history) {
    if (h.run !== r.type || (r.type === 'regression' ? h.utc !== r.utc : i.origin.ref !== r.ref) || h.value === 'not-testable') continue;
    if (r.type !== 'regression') h.utc = r.utc; // one issue or scenario run: its tests share its time
    entries.push({ key: i.key, value: h.value, cause: null, ...(h.why ? { why: h.why } : {}) });
    // Red-green: a verified test failed on the last release; an inconclusive one passed there too.
    results[i.key] = { c: side(i, h.value), b: r.type === 'regression' ? null : side(i, h.value === 'inconclusive' ? 'passed' : 'failed') };
  }
  r.entries = entries;
  if (r.type !== 'regression') r.baseline = 'r1829';
  if (Object.keys(results).length) r.rep = { results, side: r.type === 'regression' ? 'candidate' : 'both' };
}

// Each run's number, as catalog.mjs gives it: R-1 the oldest.
runs.slice().sort((a, b) => String(a.utc).localeCompare(String(b.utc)) || `${a.type}${a.ref}`.localeCompare(`${b.type}${b.ref}`)).forEach((r, n) => { r.id = `R-${n + 1}`; });

// ------------------------------------------------------------------ screens: a picture each, wired to the tests
// The picture and its controls ([kind, name, x, y, w, h, to?] in pixels), drawn from the same list.
const NAV = [['Projects', '/projects'], ['Files', '/files'], ['Inbox', '/inbox'], ['Reports', '/reports']];
const SIDE = [['Home', '/'], ['Projects', '/projects'], ['Board', '/projects/:id/board'], ['Files', '/files'], ['Inbox', '/inbox'], ['Reports', '/reports'], ['Members', '/settings/members'], ['Billing', '/settings/billing']];
const MAIN_BUTTON = { Home: 'New task', Projects: 'New project', Project: 'Rename', Board: 'Add a task', Task: 'Comment', Files: 'Upload', Inbox: 'Mark all read', Reports: 'Export', Members: 'Invite', Billing: 'Change plan' };
const ROWS = { Home: ['Invoice for ACME', 'Plan the offsite', 'Fix the login page'], Projects: ['Q4 plan', 'Website', 'Hiring', 'Mobile app'], Project: ['Write the brief', 'Review designs', 'Ship v2'],
  Task: ['Dana: Looks good', 'Petr: Updated the file'], Files: ['Účtenka září.pdf', 'Brief.docx', 'Logo.png'], Inbox: ['Dana mentioned you', 'Petr assigned you a task'],
  Reports: ['Tasks by project', 'Overdue tasks'], Members: ['dana@example.com', 'petr@example.com', 'eva@example.com'], Billing: ['Team plan', 'Invoice November'] };
const ROW_TO = { Home: '/tasks/:id', Projects: '/projects/:id', Project: '/tasks/:id', Files: null, Inbox: '/tasks/:id', Reports: null, Members: null, Billing: null, Task: null };
const images = {}, videos = {};
const pages = SCREENS.map(([pattern, title, covered], k) => {
  const id = `s${k}`, file = `catalog/thumbs/screen-${k}.png`;
  const { png, controls } = screenPng(title, k);
  writeFileSync(join(W, file), png);
  images[id] = file;
  // A short video of the screen, a box moving over it, when ffmpeg is here (else the reports have none).
  const vrel = `suite/.e2e/runs/seed/screen-${k}.webm`;
  try {
    mkdirSync(join(W, 'suite/.e2e/runs/seed'), { recursive: true });
    execFileSync('ffmpeg', ['-loglevel', 'error', '-loop', '1', '-i', join(W, file), '-t', '6', '-r', '12', '-vf', "scale=960:-2,drawbox=x='mod(t*140\,800)':y=150+t*40:w=160:h=40:color=purple@0.5:t=fill",
      '-c:v', 'libvpx-vp9', '-b:v', '250k', '-pix_fmt', 'yuv420p', '-y', join(W, vrel)], { stdio: 'ignore' });
    videos[`v${k}`] = vrel;
  } catch { /* no ffmpeg: no videos */ }
  const keys = items.filter((i) => i.pages.includes(pattern)).map((i) => i.key);
  const hotspots = controls.map(([kind, name, x, y, w, h, to]) => ({ kind, name, box: [x / 1280, y / 800, w / 1280, h / 800].map((n) => +n.toFixed(4)), ...(to ? { to } : {}),
    // Tests reach the page's own button, its heading and the first rows; the menus and most links no test goes through.
    items: kind === 'buttons' || kind === 'headings' || (kind === 'rows' && /(^Task [1-3]$)|Q4 plan|Invoice|Dana|Brief|Team plan/.test(name)) ? keys : [] }));
  return { pattern, title, nav: title.toLowerCase(), covered, items: keys, shot: id, golden_path: k < 3, viewport: [1280, 800], hotspots, shot_sharp: null };
});

const data = {
  schema: 'qi-catalog/v1', agent: 2, product: 'Tasklane', target: 'acme/tasklane', issue_url: 'https://github.com/acme/tasklane/issues/{n}',
  builds: BUILDS, collections: [], features: [], maintenance: [], blockers: [], items, pages, uncovered_nav: [], nights: [], runs,
  modules: {}, design: [], findings: [], activity: {}, areas: [], found: [], drafts: [], issue_labels: { found: 'qa:found', fix: 'fix:architect' }, interactive: true, images, videos, generated_utc: iso(0),
};
// A failing test's still with the error marked; one bug issue opened, one draft waiting (skills/create-issue).
for (const i of items) if (['failed', 'regression'].includes(i.verdict?.value)) { i.still = shotOf(i.pages[0]); i.marked = rnd() < 0.5 ? 'test' : 'agent'; i.mark_saw = i.marked === 'agent' ? 'The name field is empty, and the project was saved anyway.' : null; }
data.found = [{ ref: '#104 AC-2', issue: 140, url: 'https://github.com/acme/tasklane/issues/140', build: NEWEST, labels: ['qa:found', 'fix:architect'], utc: iso(2 * DAY), title: 'A moved task jumps back after a reload' }];
data.drafts = [{ id: '101-ac-2-r1841', refs: ['#101 AC-2'], title: 'An empty project name is saved', build: NEWEST, labels: ['qa:found'], utc: iso(3 * H),
  body: '<!-- quality-inspector-found refs="#101 AC-2" build=r1841 -->\n## The problem\n\nA member can save a project with an empty name. The check did not hold: **the page says “Name is required”**.\n\n## The correct function\n\n- Given a member on the new project form\n- When the member saves it without a name\n- Then the page says “Name is required”\n\n## Steps to reproduce\n\n- Open `/projects/new` on build r1841.\n- Leave the name empty.\n- Click **Save**.\n\n## Done when\n\n- Given an empty name, When a member saves, Then the page says “Name is required”.' }];
// ------------------------------------------------------------------ the modules (Settings) and the design findings (Product → Design)
const modules = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'seed-modules.json'), 'utf8'));
for (const m of modules.modules) {
  if (m.state === 'unknown') m.state = m.schedule?.enabled ? 'on' : 'off';
  if (['on', 'enabled', 'weekly', 'per-build', 'propose'].includes(m.state) && m.kind !== 'core' && m.kind !== 'config') m.last_run = { utc: nightUtc(m.id === 'regression' ? 0 : 2), candidate: m.id === 'regression' ? NEWEST : buildAt(2) };
}
modules.schedules_as_of = iso(2 * H);
data.modules = modules;
mkdirSync(join(W, 'design', 'crops'), { recursive: true });
const DESIGN = [
  ['D-1', 'sweep', 'clipped-text', 'major', '/projects', '390x844', '“New project” button', 'The text of the “New project” button is cut off on a phone.', 'open', 1],
  ['D-2', 'sweep', 'contrast', 'minor', '/inbox', '1440x900', 'the unread count', 'The unread count is light grey on white: hard to read.', 'open', 6],
  ['D-3', 'consistency', 'header', 'minor', '/settings/members', '1440x900', 'the page header', 'The page header is 8 px lower than on the other settings pages.', 'open', 8],
  ['D-4', 'sweep', 'overlap', 'major', '/projects/:id/board', '768x1024', 'the column headers', 'On a tablet the column headers overlap the first card.', 'open', 3],
  ['D-5', 'noticed', 'noticed', 'minor', '/files', '-', 'the empty state', 'The empty state says “undefined” instead of a sentence.', 'fixed', 5],
  ['D-6', 'sweep', 'focus', 'minor', '/sign-in', '1440x900', 'the “Send me a link” button', 'The button shows no focus ring when reached with Tab.', 'dismissed', 10],
];
data.design = DESIGN.map(([id, source, check, severity, pattern, viewport, target, saw, status, k], n) => {
  const crop = `design/crops/${id}.png`; copyFileSync(join(W, images[`s${k}`]), join(W, crop)); images[`d${n}`] = crop;
  return { id, source, check, severity, suspect: false, pattern, viewport, target, saw, first_seen: buildAt(6 - (n % 4)), last_seen: status === 'open' ? NEWEST : buildAt(3),
    status, resolved_build: status === 'fixed' ? buildAt(2) : null, category: null, dismiss_reason: status === 'dismissed' ? 'by-design' : null, crop: `d${n}`, field: null, desk: [] };
});
data.uncovered_nav = ['Reports', 'Billing'];
// Tests: their tiers beyond nightly and ran-once, the cause of each result that is not a pass, a still of
// each, the features and collections, and the open maintenance proposals (docs/maintenance.md).
const TIERS = { '#129 AC-1': 'promotable', '#129 AC-2': 'promotable', 'S-8 AC-1': 'promotable', '#115 AC-2': 'quarantined', 'S-6 AC-1': 'retired' };
const CAUSES = { '#108 AC-2': 'product', 'S-5 AC-1': 'product', '#112 AC-1': 'test', '#120 AC-1': 'environment', '#104 AC-1': 'environment', '#101 AC-2': 'product', '#104 AC-2': 'product', '#127 AC-2': 'product', 'S-9 AC-1': 'environment', '#122 AC-2': 'product' };
for (const i of items) {
  const ref = `${i.origin.ref} ${i.id}`;
  if (TIERS[ref]) i.tier = TIERS[ref];
  for (const h of i.history) if (CAUSES[ref] && !['verified', 'passed', 'unchanged', 'healed', 'relearned'].includes(h.value)) h.cause = CAUSES[ref];
  i.still = shotOf(i.pages[0]);
}
// A night runs every kept test that existed then: one without its own result that night passed as before.
for (const r of runs.filter((x) => x.type === 'regression' && x.verdict !== 'environment'))
  for (const i of items.filter((x) => x.tier === 'regression' && x.history[0]?.utc < r.utc))
    if (!r.entries.some((e) => e.key === i.key)) r.entries.push({ key: i.key, value: 'unchanged', cause: null });
for (const r of runs) for (const e of r.entries) { const i = items.find((x) => x.key === e.key); const h = i?.history.find((x) => x.utc === r.utc); if (h?.cause) e.cause = h.cause; }
data.features = [
  { id: 'projects', name: 'Projects', aliases: ['project list'], members: ['#101', '#122', 'P-sign-in AC-1'] },
  { id: 'board', name: 'Board', aliases: ['kanban'], members: ['#104', 'S-5', 'S-6'] },
  { id: 'files', name: 'Files and uploads', aliases: [], members: ['#108', 'S-8'] },
];
data.collections = [{ name: 'Smoke', members: ['#101 AC-1', '#117 AC-1', 'P-sign-in AC-1'] }, { name: 'Before a release', members: ['#104', '#108', '#127'] }];
data.maintenance = [
  { id: 'M-4', test: '#112 AC-1', kind: 'needs-review', build: NEWEST, basis: 'The list says “Pending” where the test expects “Invited”.', proposal: 'heal', opened_utc: iso(5 * H) },
  { id: 'M-5', test: '#115 AC-2', kind: 'quarantined', build: buildAt(2), basis: 'Flaky on two builds within 14 days.', proposal: 're-promote', opened_utc: iso(2 * DAY) },
  { id: 'M-6', test: '#117 AC-2', kind: 'predicted', build: NEWEST, basis: 'PR #140: Search shows suggestions while you type', proposal: 'review', opened_utc: iso(9 * H) },
];
// What changed since the night before: the UI map's difference and new console errors.
for (const r of runs.filter((x) => x.type === 'regression' && x.verdict !== 'environment')) {
  const d = Math.round((NOW - new Date(r.utc)) / DAY);
  r.ui_diff = d === 0 ? '+ added button "Export" on /reports\n~ renamed label "Invited" → "Pending" on /settings/members\n- removed link "Archive" on /projects/:id'
    : d === 2 ? '~ moved tab "Board" from the top bar to the side bar on /projects/:id' : d === 4 ? '+ added field "Due date" on /tasks/:id' : null;
  r.signals = d === 0 ? { console_errors_new: 2, slow_tests: 1 } : d === 2 ? { console_errors_new: 1, slow_tests: 0 } : {};
}
// Home: what runs now, what waits, the schedules, what stops Quality Inspector (catalog.mjs → activity,
// findings.requests and profile_queue, blockers).
data.activity = {
  lock: { owner: 'issues', since: iso(23 * 60e3) },
  issues: [{ issue: 131, title: 'Export a report as CSV', build: NEWEST, baseline: 'r1829', verdict: null, status: 'in_progress', utc: iso(20 * 60e3) },
    { issue: 129, title: 'Comments on tasks', build: buildAt(2), baseline: 'r1829', verdict: 'verified', status: 'report_pending', utc: iso(2 * DAY) }],
  waiting: [{ issue: 133, title: 'Bulk move tasks', kind: 'new' }, { issue: 134, title: 'Dark mode for the board', kind: 'new' }, { issue: 127, title: 'Sign in with a magic link', kind: 'retest' }],
  budget_min: 150,
  schedules: { taken_utc: iso(2 * H), list: [{ name: 'quality-inspector-issues-1h', enabled: true, cron: '7 * * * *' }, { name: 'quality-inspector-modules-nightly', enabled: true, cron: '30 4 * * *' },
    ...modules.modules.filter((m) => m.schedule?.name).map((m) => ({ name: m.schedule.name, enabled: m.schedule.enabled, cron: m.schedule.cron }))] },
};
data.findings = { requests: [{ id: 'S-11', source: 'slack', status: 'queued', build: null, verdict: null, utc: iso(40 * 60e3), title: 'Invite a member who already has an account' },
  { id: 'S-12', source: 'dashboard', status: 'queued', build: null, verdict: null, utc: iso(15 * 60e3), title: null }],
  profile_queue: { cap: 3, list: [{ id: 'P-upload', title: 'Upload a file', kind: 'new', when: 'next' }] } };
data.blockers = [
  { id: 'B-2', scope: 'tests', owner: 'unknown', tests: ['#120', 'S-9'], stage: 'replay', signature: 'the inbox page never finished loading', build: NEWEST, hits: 2, first_utc: iso(2 * DAY), retry_utc: iso(-3 * H) },
  { id: 'B-3', scope: 'delivery', owner: 'platform', tests: [], stage: 'upload', signature: 'video served application/octet-stream', build: NEWEST, hits: 1, first_utc: iso(5 * H), retry_utc: iso(-1 * H) },
];
for (const r of runs) for (const x of Object.values(r.rep?.results ?? {})) for (const sd of [x.c, x.b]) {
  const k = sd?.shots?.[0]?.img?.slice(1); if (sd && videos[`v${k}`]) sd.video = `v${k}`;
}
data.hash = createHash('sha256').update(JSON.stringify(data)).digest('hex').slice(0, 12);
// The settings behind the modules' state, so a change from the page (the server's modules.sh set)
// starts from the same values: each switch's bullet, the schedules as the platform listed them.
// Written before the data, so the server reads the modules live only after a change.
const bullets = modules.modules.filter((m) => m.switch && m.settings?.[m.switch]).map((m) => `- ${m.switch}: ${m.settings[m.switch].value}`);
writeFileSync(join(W, 'CONFIG.md'), ['- profile: stub', '- target_repo: acme/tasklane', '- display_name: Quality Inspector', '- dashboard_interactive: enabled', ...bullets, ''].join('\n'));
writeFileSync(join(W, 'CATALOG.md'), `# Catalog collections\n\n| collection | members |\n| --- | --- |\n${data.collections.map((c) => `| ${c.name} | ${c.members.join(', ')} |`).join('\n')}\n`);
writeFileSync(join(W, 'schedules.json'), JSON.stringify({ taken_utc: iso(2 * H), schedules: Object.fromEntries(modules.modules.filter((m) => m.schedule?.name).map((m) => [m.schedule.name, { enabled: m.schedule.enabled, cron: m.schedule.cron }])) }));
await new Promise((ok) => setTimeout(ok, 20));
writeFileSync(join(W, 'catalog', 'data.json'), JSON.stringify(data, null, 1));

// ------------------------------------------------------------------ what runs now: issue #131 on the newest build
writeFileSync(join(W, 'env', 'LOCK'), `issues ${iso(23 * 60e3)} dev-session\n`);
writeFileSync(join(W, 'QA.md'), `| issue | ac_hash | candidate | baseline | verdict | status | updated_utc |\n| --- | --- | --- | --- | --- | --- | --- |\n| 131 | x1 | ${NEWEST} | r1829 | - | in_progress | ${iso(20 * 60e3)} |\n`);
writeFileSync(join(W, 'SCENARIOS.md'), '| id | source | requester | thread | spec_hash | build | verdict | status | updated_utc |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |\n');
console.log(`${W}: ${items.length} tests, ${runs.length} runs, ${pages.length} screens, ${BUILDS.length} builds; newest build ${NEWEST}`);

// ------------------------------------------------------------------ a made-up screen, as a PNG
function screenPng(title, k) {
  const w = 1280, h = 800, px = Buffer.alloc(w * h * 3, 0xff);
  const rect = (x, y, rw, rh, [r, g, b]) => { for (let j = Math.max(0, y); j < Math.min(h, y + rh); j++) for (let i = Math.max(0, x); i < Math.min(w, x + rw); i++) { const o = (j * w + i) * 3; px[o] = r; px[o + 1] = g; px[o + 2] = b; } };
  const hues = [[59, 89, 152], [36, 120, 98], [140, 72, 160], [190, 96, 40], [40, 110, 170]];
  const acc = hues[k % hues.length];
  const controls = [];
  rect(0, 0, w, 56, [32, 36, 44]); rect(24, 18, 120, 20, acc);
  if (title !== 'Sign in') {
    NAV.forEach(([n, to], i) => { rect(200 + i * 110, 22, 80, 12, [120, 126, 140]); controls.push(['nav', n, 196 + i * 110, 14, 88, 28, to]); });
    rect(0, 56, 220, h - 56, [245, 246, 248]);
    SIDE.forEach(([n, to], i) => { rect(24, 88 + i * 40, 150 - (i % 3) * 20, 14, n === title ? acc : [200, 204, 212]); controls.push(['links', n, 16, 80 + i * 40, 180, 30, to]); });
    rect(260, 88, 360 + title.length * 8, 28, [40, 44, 52]); controls.push(['headings', title, 260, 88, 360 + title.length * 8, 28]);
    if (MAIN_BUTTON[title]) { rect(1100, 86, 150, 34, acc); controls.push(['buttons', MAIN_BUTTON[title], 1100, 86, 150, 34]); }
  }
  if (title === 'Board') ['To do', 'Doing', 'Review', 'Done'].forEach((col, c) => {
    rect(260 + c * 250, 150, 230, 600, [241, 243, 246]); rect(272 + c * 250, 160, 90, 12, [90, 96, 108]); controls.push(['headings', col, 268 + c * 250, 154, 100, 24]);
    for (let t = 0; t < 2 + ((c + k) % 3); t++) { rect(272 + c * 250, 186 + t * 96, 206, 80, [255, 255, 255]); rect(284 + c * 250, 200 + t * 96, 120, 10, acc); controls.push(['rows', `Task ${c * 4 + t + 1}`, 272 + c * 250, 186 + t * 96, 206, 80, '/tasks/:id']); }
  });
  else if (title === 'Sign in') {
    rect(440, 220, 400, 320, [246, 247, 249]); rect(480, 280, 320, 36, [255, 255, 255]); controls.push(['inputs', 'Email', 480, 280, 320, 36]);
    rect(480, 420, 320, 40, acc); controls.push(['buttons', 'Send me a link', 480, 420, 320, 40, '/']);
  } else {
    const rows = ROWS[title] || [];
    for (let r = 0; r < 10; r++) {
      rect(260, 150 + r * 58, 980, 48, r % 2 ? [255, 255, 255] : [248, 249, 251]); rect(280, 166 + r * 58, 260 + ((r * 37 + k * 13) % 200), 14, [70, 76, 88]); rect(1100, 162 + r * 58, 100, 22, [220, 224, 230]);
      if (rows[r]) controls.push(['rows', rows[r], 260, 150 + r * 58, 980, 48, ROW_TO[title] || undefined]);
    }
  }
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let j = 0; j < h; j++) px.copy(raw, j * (w * 3 + 1) + 1, j * w * 3, (j + 1) * w * 3);
  const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let i = 0; i < 8; i++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (t, d) => { const l = Buffer.alloc(4); l.writeUInt32BE(d.length); const td = Buffer.concat([Buffer.from(t), d]); const c = Buffer.alloc(4); c.writeUInt32BE(crc(td)); return Buffer.concat([l, td, c]); };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  return { png: Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]), controls };
}
