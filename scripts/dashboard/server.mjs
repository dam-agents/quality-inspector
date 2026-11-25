#!/usr/bin/env node
// The dashboard server: the Artifact API of the dashboard page (docs/catalog.md → The server).
// A Login item starts it at every boot (kit.yaml → startupItems); supervise-daemon restarts it
// when it exits. The same pattern as Design Desk's Desk server.
//
// The page is published once and asks this server for everything it shows:
//   GET  /api/me              who is looking (the platform's verified caller), their role, the page's switches
//   GET  /api/catalog?have=h  the newest catalog data (work/catalog/data.json, written by catalog.mjs)
//   GET  /api/images/<id>     one picture of that data, as a data URI
//   GET  /api/videos/<id>?part=k  one part of a report's video (VIDEO_PART bytes, base64), with its size
//   GET  /api/asks            the caller's own questions from the page's chat, each with its answer
//   POST /api/asks            {text, context, command?, request?}: a question or a request to Quality Inspector,
//                             recorded with who asked; its ping the page sends to the agent — the page's
//                             command as it is, or `answer dashboard question A-<n>` for a question — and
//                             `ping_conversation`, the page's own session (`request: true`: the request's own)
//   POST /api/act             {command}: an action done without the model — a setting, a focus area (an
//                             admin's), dismiss, reopen or categorize D-<k>, dismiss or reopen a problem F-<k>,
//                             add to or remove from a collection — written by this server itself (not a viewer)
//   POST /api/settings        {module, key, value} or {focus}: an admin's change of a module's setting,
//                             written at once through modules.sh; the new state back
//   POST /api/jobs            {command, label?, item?, note?}: work for Quality Inspector, a job J-<n> recorded with
//                             who pressed and their role (lib/jobs.mjs); its ping `do dashboard job J-<n>`
//   GET  /api/jobs            the newest jobs, each with its state; whose: "you" or a role, never an email
//   GET  /api/people          the roster (lib/people.mjs; an admin sees the emails)
//   POST /api/people          {email, role|null}: an admin gives a person a role, or takes the row out
//   GET  /api/notifications   what happened in the last 30 days, newest first, read or not, for the caller
//   POST /api/notifications/read {id} · /api/notifications/seen   the caller reads one, or every one
//   GET  /api/status          what the agent does now, read live from work/ (the lock, rows in progress)
//   POST /api/commands        a command of the page: checked against the page's own patterns,
//                             recorded with who sent it, then handed back as the ping the page sends
//   GET  /api/commands        the caller's own commands from the page, newest first
//
// Only the platform relay reaches /api/: it sets x-platform-caller-role/-email/-sub on every
// request from the page, which the page cannot forge. Loopback only. The caller's role is the roster's
// (lib/people.mjs; the platform's owner is an admin). Nothing sent here is executed here but the actions
// of POST /api/act, /api/settings and /api/people, which this server writes itself for a role that may;
// a job is stored as data and goes to the agent as the page's message, `do dashboard job J-<n>`.
import { createServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { changeCollection } from '../lib/collections.mjs';
import { changeProblem, dismissedProblems, orderedRuns } from '../lib/problems.mjs';
import { jobs as jobsOf, queue as queueJob, STATES as JOB_STATES } from '../lib/jobs.mjs';
import { may, people, roleOf, setRole, ROLES } from '../lib/people.mjs';
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, readdirSync, readSync, realpathSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, extname, join, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPTS = join(HERE, '..');
const WORK = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const PORT = Number(process.env.QI_DASHBOARD_PORT || 5555);
const DIR = join(WORK, 'dashboard');
const DATA = join(WORK, 'catalog', 'data.json');
const VIEWER = join(SCRIPTS, 'catalog', 'viewer.html');
const MAX_BODY = 64 * 1024;

const log = (level, event, msg) => { try { process.stderr.write(`${new Date().toISOString()} ${level} ${event} ${msg}\n`); } catch { /* ignore */ } };
class Said extends Error { constructor(status, msg) { super(msg); this.status = status; } }
const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
const mtime = (p) => { try { return statSync(p).mtimeMs; } catch { return 0; } };
const utc = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const cfg = (k) => {
  const m = (read(join(WORK, 'CONFIG.md')) ?? '').match(new RegExp(`^- ${k.replace('.', '\\.')}:[ \\t]*(.*)$`, 'm'));
  return m ? m[1].replace(/\s+#.*$/, '').trim().replace(/^[`"']|[`"']$/g, '') : '';
};

// ------------------------------------------------------------------ the page's commands
// The closed set of the page's commands, read from the page itself, as lib/channel.sh reads them
// (CMD_RE, SCEN_RE, WALK_RE, DISCUSS_RE): the server and the page never disagree. Read again
// when the page file changes (a definition update).
let patterns = { at: -1, list: [] };
export function commandPatterns(src) {
  return ['CMD_RE', 'SCEN_RE', 'WALK_RE', 'DISCUSS_RE'].map((n) => {
    const m = String(src ?? '').match(new RegExp(`^const ${n} = /(.+)/([a-z]*);$`, 'm'));
    try { return m ? new RegExp(m[1], m[2]) : null; } catch { return null; }
  }).filter(Boolean);
}
const allowed = (text) => {
  const t = mtime(VIEWER);
  if (t !== patterns.at) patterns = { at: t, list: commandPatterns(read(VIEWER)) };
  return patterns.list.length === 4 && patterns.list.some((re) => re.test(text));
};

// Per caller: at most WRITES_PER_WINDOW commands in WINDOW_MS, so one person (or one script in a
// browser) cannot flood the agent. The operator's own presses count too: a loop is a loop.
const WRITES_PER_WINDOW = 20; const WINDOW_MS = 10 * 60 * 1000;
const usage = new Map();
function spend(key) {
  const now = Date.now();
  const list = (usage.get(key) ?? []).filter((t) => now - t < WINDOW_MS);
  if (list.length >= WRITES_PER_WINDOW) throw new Said(429, `That is ${WRITES_PER_WINDOW} messages in 10 minutes. Wait some minutes and try again.`);
  list.push(now); usage.set(key, list);
  for (const [k, v] of usage) if (!v.some((t) => now - t < WINDOW_MS)) usage.delete(k);
}

// ------------------------------------------------------------------ the catalog data
// data.json is read again only when it changes on disk; its hash is the page's "have".
// A setting changed after the data shows at once: when work/CONFIG.md is newer than data.json, each
// module setting's value is read from its CONFIG bullet (one that fits the setting's values or range,
// as modules.sh wrote it), and a module's state follows its switch. The next build of the catalog
// (modules.sh status) is the whole truth again.
let cache = { at: '', data: null, hash: null };
const CONFIG = join(WORK, 'CONFIG.md');
const MODULES_SH = join(SCRIPTS, 'modules.sh');
function withConfig(modules) {
  if (!modules || !Array.isArray(modules.modules)) return modules;
  const bullet = new Map((read(CONFIG) ?? '').split('\n').map((l) => /^- ([a-z_][a-z0-9_.]{0,60}):[ \t]*(.*?)[ \t]*$/.exec(l)).filter(Boolean).map((m) => [m[1], m[2].replace(/[ \t]+#.*$/, '').replace(/^(['"`])(.*)\1$/, '$2')]));
  const fits = (spec, v) => (spec.type === 'cadence' ? (modules.cadences || []).includes(v) : spec.type === 'enum' ? (spec.values || []).includes(v)
    : spec.type === 'int' ? /^\d{1,6}$/.test(v) && +v >= +spec.min && +v <= +spec.max : spec.type === 'viewports' ? /^\d{3,4}x\d{3,4}(,\d{3,4}x\d{3,4}){0,3}$/.test(v) : false);
  const patch = (settings) => Object.fromEntries(Object.entries(settings || {}).map(([k, spec]) => {
    const v = bullet.get(k);
    return [k, v !== undefined && spec && fits(spec, v) ? { ...spec, value: v, invalid: false } : spec];
  }));
  return { ...modules, global: patch(modules.global), modules: modules.modules.map((m) => {
    const settings = patch(m.settings), sw = m.switch && settings[m.switch];
    return { ...m, settings, state: sw && m.kind !== 'schedule' && m.kind !== 'core' ? sw.value : m.state };
  }) };
}
// The operator's actions on the page show at once too: a dismissal or a reopened finding from
// work/design/DISMISSED.md, the collections from work/CATALOG.md, when the file is newer than the data.
// The dismissed problems (work/PROBLEMS.md) are always the file's: the catalog build does not read it.
const DISMISSED = join(WORK, 'design', 'DISMISSED.md'), COLLECTIONS = join(WORK, 'CATALOG.md'), PROBLEMS = join(WORK, 'PROBLEMS.md'), NAMES = join(WORK, 'TEST-NAMES.md');
const tableOf = (text) => (text ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2).map((l) => l.split('|').slice(1, -1).map((x) => x.trim()));
function catalog() {
  const t = mtime(DATA), c = mtime(CONFIG), d = mtime(DISMISSED), k = mtime(COLLECTIONS), p = mtime(PROBLEMS), n = mtime(NAMES), key = `${t}|${c}|${d}|${k}|${p}|${n}`;
  if (key !== cache.at) {
    let data = null;
    try { data = JSON.parse(readFileSync(DATA, 'utf8')); } catch { data = null; }
    data = data && typeof data === 'object' && !Array.isArray(data) ? data : null;
    const newer = [c, d, k, p, n].filter((x) => data && x > t);
    if (data && c > t) data.modules = withConfig(data.modules);
    if (data && d > t && Array.isArray(data.design)) {
      const off = new Map(tableOf(read(DISMISSED)).filter(([id]) => /^D-\d+$/.test(id ?? '')).map(([id, , reason]) => [id, reason || null]));
      data.design = data.design.map((f) => (off.has(f.id) ? { ...f, status: 'dismissed', dismiss_reason: off.get(f.id) } : f.status === 'dismissed' ? { ...f, status: 'open', dismiss_reason: null } : f));
    }
    if (data && k > t) data.collections = tableOf(read(COLLECTIONS)).filter(([n]) => n).map(([name, members]) => ({ name, members: String(members ?? '').split(',').map((x) => x.trim()).filter(Boolean) }));
    if (data && n > t && Array.isArray(data.items)) {
      const names = new Map(tableOf(read(NAMES)).filter(([key, name]) => key && name));
      data.items = data.items.map((i) => (names.has(i.key) ? { ...i, name: names.get(i.key), renamed: true } : i));
    }
    if (data) data.problems_dismissed = dismissedProblems(PROBLEMS);
    cache = { at: key, data, hash: data ? `${data.hash ?? t}${newer.length ? `-${Math.round(Math.max(...newer))}` : ''}` : null };
  }
  return cache;
}
// The operator's own actions, done at once without the model (docs/modules.md → Control). This server
// writes them itself — the scripts that change these files stay the direct session's — after
// `modules.sh valid` checked a setting read-only: CONFIG.md's bullet, FOCUS.md, a design finding's
// dismissal or category, CATALOG.md's collections. The same rows and headers as modules.sh writes.
const NOW = () => utc();
const FOCUS = join(WORK, 'FOCUS.md'), CATEGORIES = join(WORK, 'design', 'CATEGORIES.md');
const writeFile = (f, text) => { mkdirSync(dirname(f), { recursive: true }); writeFileSync(`${f}.tmp`, text); renameSync(`${f}.tmp`, f); };
const tableFile = (f, header) => { const t = read(f); return t && t.trim() ? t.replace(/\n*$/, '\n') : `${header}\n|${header.split('|').slice(1, -1).map(() => ' --- |').join('')}\n`; };
const cell1 = (l) => (l.startsWith('|') ? l.split('|')[1].trim() : null);
function logEvent(msg) {
  try { execFileSync('bash', ['-c', '. "$1"; logev info module_set "$2"', '_', join(SCRIPTS, 'log.sh'), `${msg} via=dashboard`], { env: { ...process.env, WORK_DIR: WORK }, stdio: 'ignore', timeout: 10000 }); } catch { /* the log is not the action */ }
}
function setSetting(id, key, value) {
  try { execFileSync('bash', [MODULES_SH, 'valid', id, `${key}=${value}`], { encoding: 'utf8', env: { ...process.env, WORK_DIR: WORK }, stdio: ['ignore', 'pipe', 'pipe'], timeout: 60000 }); } catch (e) {
    const why = String(e.stderr || '').split('\n').find((l) => l.startsWith('modules.sh:')) || 'The setting was not changed.';
    throw new Said(400, why.replace(/^modules\.sh: /, '').replace(/^./, (x) => x.toUpperCase()));
  }
  const text = read(CONFIG) ?? '', line = `- ${key}: ${value}`, re = new RegExp(`^- ${key}:.*$`, 'm');
  const old = (re.exec(text)?.[0] ?? '').replace(`- ${key}:`, '').trim();
  writeFile(CONFIG, re.test(text) ? text.replace(re, line) : `${text.replace(/\n*$/, '\n')}${line}\n`);
  logEvent(`module=${id} key=${key} old=${old || '-'} new=${value}`);
  return { module: id, set: [{ key, old: old || null, new: value }] };
}
const ACTIONS = [
  [/^module ([a-z][a-z-]{1,30}) set ([a-z_]+)=([A-Za-z0-9,._-]{1,40})$/, (m) => setSetting(m[1], m[2], m[3])],
  [/^focus ([A-Za-z0-9][A-Za-z0-9 _.\/-]{0,39})$/, (m) => {
    const t = tableFile(FOCUS, '| area | queued_utc | status | build |');
    if (t.split('\n').some((l) => cell1(l) === m[1] && l.split('|')[3]?.trim() === 'queued')) return { area: m[1], queued: false, reason: 'already queued' };
    writeFile(FOCUS, `${t}| ${m[1]} | ${NOW()} | queued | - |\n`); logEvent(`module=feature-focus key=focus old=- new=${m[1]}`); return { area: m[1], queued: true }; }],
  [/^dismiss (D-\d{1,6})(?: as (false-positive|wont-fix|duplicate|by-design))?$/, (m) => {
    const t = tableFile(DISMISSED, '| id | dismissed_utc | reason |');
    if (t.split('\n').some((l) => cell1(l) === m[1])) return { id: m[1], dismissed: false, reason: 'already dismissed' };
    writeFile(DISMISSED, `${t}| ${m[1]} | ${NOW()} | ${m[2] || '-'} |\n`); logEvent(`module=ui-sweep key=dismiss old=- new=${m[1]}:${m[2] || '-'}`); return { id: m[1], dismissed: true }; }],
  [/^reopen (D-\d{1,6})$/, (m) => {
    const t = read(DISMISSED) ?? ''; if (!t.split('\n').some((l) => cell1(l) === m[1])) return { id: m[1], reopened: false, reason: 'not dismissed' };
    writeFile(DISMISSED, t.split('\n').filter((l, k) => k < 2 || cell1(l) !== m[1]).join('\n')); logEvent(`module=ui-sweep key=dismiss old=${m[1]} new=-`); return { id: m[1], reopened: true }; }],
  [/^categorize (D-\d{1,6}) ([a-z0-9][a-z0-9-]{0,29}|-)$/, (m) => {
    const t = tableFile(CATEGORIES, '| id | category | updated_utc |'), lines = t.split('\n'), old = lines.find((l) => cell1(l) === m[1])?.split('|')[2]?.trim() ?? null;
    const kept = lines.filter((l, k) => k < 2 || cell1(l) !== m[1]).join('\n').replace(/\n*$/, '\n');
    writeFile(CATEGORIES, m[2] === '-' ? kept : `${kept}| ${m[1]} | ${m[2]} | ${NOW()} |\n`); logEvent(`module=ui-sweep key=category old=${old || '-'} new=${m[1]}:${m[2]}`);
    return { id: m[1], old, category: m[2] === '-' ? null : m[2] }; }],
  [/^(dismiss|reopen) (F-\d{1,6})(?: as (false-positive|wont-fix|duplicate|by-design))?$/, (m) => {
    if (m[1] === 'reopen' && m[3]) throw new Said(400, 'A problem opens again without a reason.');
    let done;
    try { done = changeProblem(PROBLEMS, catalog().data?.runs, m[1], m[2], m[3] ?? null, NOW()); } catch (e) { throw new Said(400, e.message); }
    if (done.dismissed || done.reopened) logEvent(`module=problems key=dismiss old=${m[1] === 'dismiss' ? '-' : m[2]} new=${m[1] === 'dismiss' ? `${m[2]}:${m[3] || '-'}` : '-'}`);
    return done; }],
  // A test's new name (docs/dashboard-page.md → Rename a test): work/TEST-NAMES.md, one row a test, the last name wins.
  [/^rename (#\d{1,7} (?:AC|IN)-\d{1,3}|S-\d{1,6} AC-\d{1,3}|P-[a-z0-9][a-z0-9-]{0,40} AC-\d{1,3}) to: ([^\u0000-\u001f\u007f|]{1,80})$/, (m) => {
    const [ref, id] = m[1].split(' '), key = `${ref.startsWith('#') ? `issue-${ref.slice(1)}` : ref.startsWith('S-') ? `scenario-${ref.slice(2)}` : `profile-${ref.slice(2)}`}/${id}`;
    const name = m[2].trim(); if (!name) throw new Said(400, 'Write a name.');
    if (!(catalog().data?.items ?? []).some((i) => i.key === key)) throw new Said(404, 'There is no such test.');
    const lines = tableFile(NAMES, '| key | name | renamed_utc |').split('\n'), old = lines.find((l) => cell1(l) === key)?.split('|')[2]?.trim() ?? null;
    writeFile(NAMES, `${lines.filter((l, j) => j < 2 || (l && cell1(l) !== key)).join('\n').replace(/\n*$/, '\n')}| ${key} | ${name} | ${NOW()} |\n`);
    logEvent(`module=catalog key=rename old=${key} new=${name.replace(/\s+/g, '_')}`);
    return { key, old, name }; }],
  [/^(add|remove) (#\d+(?: (?:AC|IN)-\d+)?|S-\d+(?: AC-\d+)?) (?:to|from) the collection ([A-Za-z0-9][A-Za-z0-9 _.-]{0,39})$/, (m) => {
    try { return { collection: m[3], members: changeCollection(COLLECTIONS, m[1], m[3], [m[2]]) }; } catch (e) { throw new Said(400, e.message); } }],
];

// A picture of the data: its `images` map names a file under work/ (catalog.mjs → refs). Only an
// image file inside work/catalog/thumbs/ or work/design/ is read — a resolved path, links followed.
const IMAGE_ROOTS = ['catalog/thumbs', 'design'];
const MIME = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp' };
export function imagePath(work, rel) {
  if (typeof rel !== 'string' || !rel || rel.includes('\0')) return null;
  const mime = MIME[extname(rel).toLowerCase()];
  if (!mime) return null;
  let real;
  try { real = realpathSync(resolve(work, rel)); } catch { return null; }
  let base;
  try { base = realpathSync(work); } catch { return null; }
  return IMAGE_ROOTS.some((r) => real.startsWith(join(base, r) + sep)) ? { path: real, mime } : null;
}

// A report's video: its `videos` map names a file under work/ (catalog.mjs → videoRefs). Only a video
// inside the e2e runs (work/suite/.e2e/runs/) is read. It goes in parts, so no answer of the relay is
// large: the page joins them and plays the video on the page.
const VIDEO_ROOT = join('suite', '.e2e', 'runs');
const VIDEO_MIME = { '.webm': 'video/webm', '.mp4': 'video/mp4' };
export const VIDEO_PART = 1536 * 1024;
export function videoPath(work, rel) {
  if (typeof rel !== 'string' || !rel || rel.includes('\0')) return null;
  const mime = VIDEO_MIME[extname(rel).toLowerCase()];
  if (!mime) return null;
  let real, base;
  try { real = realpathSync(resolve(work, rel)); base = realpathSync(work); } catch { return null; }
  return real.startsWith(join(base, VIDEO_ROOT) + sep) ? { path: real, mime } : null;
}

// ------------------------------------------------------------------ live status
// What the agent does now: the environment lock's holder and since (never its session), and the
// issue and scenario rows in progress or awaiting delivery — the same as the page's build-time
// Activity, read at the moment of the question.
const tableRows = (text) => (text ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2)
  .map((l) => l.split('|').slice(1, -1).map((c) => c.trim()));
export function status(work) {
  const line = (read(join(work, 'env', 'LOCK')) ?? '').trim().split(/\s+/);
  const lock = /^[A-Za-z][A-Za-z0-9-]{0,40}$/.test(line[0] ?? '') && /^\d{4}-\d\d-\d\dT[\d:]{8}Z$/.test(line[1] ?? '') ? { owner: line[0], since: line[1] } : null;
  const busy = (st) => st === 'in_progress' || st === 'report_pending';
  const issues = tableRows(read(join(work, 'QA.md'))).filter(([n, , , , , st]) => /^\d+$/.test(n ?? '') && busy(st))
    .map(([n, , candidate, , , st, at]) => ({ issue: +n, status: st, build: candidate && candidate !== '-' ? candidate : null, utc: at || null }));
  const scenarios = tableRows(read(join(work, 'SCENARIOS.md'))).filter(([id, , , , , , , st]) => /^S-\d+$/.test(id ?? '') && busy(st))
    .map(([id, , , , , build, , st, at]) => ({ id, status: st, build: build && build !== '-' ? build : null, utc: at || null }));
  return { utc: utc(), lock, issues, scenarios };
}

// ------------------------------------------------------------------ commands from the page
const LOG = join(DIR, 'commands.jsonl');
// The page's chat (docs/catalog.md → The server → Questions): each question one line of asks.jsonl, with
// who asked; the agent's answers lines of answers.jsonl, written by scripts/dashboard/asks.mjs.
const ASKS = join(DIR, 'asks.jsonl'), ANSWERS = join(DIR, 'answers.jsonl');
const jsonl = (f) => (read(f) ?? '').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
const asksOf = () => jsonl(ASKS);
const answersOf = () => new Map(jsonl(ANSWERS).filter((a) => /^A-\d+$/.test(a.id ?? '') && typeof a.text === 'string').map((a) => [a.id, { text: a.text.slice(0, 6000), utc: a.utc ?? null }]));
function recordAsk(who, text, context, command = null, id = `A-${asksOf().length + 1}`, request = false) {
  mkdirSync(DIR, { recursive: true });
  const row = { id, utc: utc(), role: who.role, email: who.email, text, context, ...(command ? { command } : {}), ...(request ? { request: true } : {}) };
  appendFileSync(ASKS, `${JSON.stringify(row)}\n`, { mode: 0o600 });
  return row;
}
// Each page has its own chat and its own platform session, as on Design Desk: the page sends its
// ping with this conversation key (docs/dashboard-page.md → The chat). The key is the open item, else
// the tab and its page; the platform allows [A-Za-z0-9._-]{1,64}, so another character becomes "-"
// and a key that changed or ran long gets a short hash of the whole, so two items never share one.
export function conversationOf(context) {
  const c = context ?? {};
  if (/^A-\d{1,6}$/.test(c.item ?? '')) return c.item;
  const whole = c.item ? `item.${c.item}` : `page.${c.page || c.tab || 'home'}`;
  const slug = whole.replace(/[^A-Za-z0-9._-]+/g, '-');
  if (slug === whole && slug.length <= 64) return slug;
  return `${slug.slice(0, 55)}.${createHash('sha256').update(whole).digest('hex').slice(0, 8)}`;
}
// A scenario request from Ask for a test has a page of its own (docs/dashboard-page.md → A request's
// page): its chat row is the page, its ping goes to a session of its own, and the agent links the row
// to the scenario it records (asks.mjs link A-<n> S-<k>). What the page shows is read from what the
// pipeline writes: the SCENARIOS.md row, the frozen criteria, the test file, the runs, the report.
export const REQUEST_CMD = /^(?:test this scenario|walk these steps live): /;
const LINKS = join(DIR, 'links.jsonl');
const linksOf = () => new Map(jsonl(LINKS).filter((l) => /^A-\d+$/.test(l.id ?? '') && /^S-\d+$/.test(l.scenario ?? '')).map((l) => [l.id, l.scenario]));
export function scenarioProgress(work, sid) {
  if (!/^S-\d+$/.test(sid ?? '')) return null;
  const row = tableRows(read(join(work, 'SCENARIOS.md'))).find(([id]) => id === sid) ?? [];
  const [, , , , , build, verdict, st, at] = row, dir = join(work, 'scenarios', sid);
  let files = []; try { files = readdirSync(dir); } catch { /* not recorded yet */ }
  const crit = files.filter((f) => /^criteria-[A-Za-z0-9]+\.md$/.test(f)).sort((a, b) => mtime(join(dir, b)) - mtime(join(dir, a)))[0];
  const criteria = crit ? (read(join(dir, crit)) ?? '').split('\n').map((l) => /^## (AC-\d{1,3})\s*[—–-]\s*(.{1,160})$/.exec(l.trim())).filter(Boolean).slice(0, 30).map((m) => ({ id: m[1], name: m[2].trim() })) : [];
  const val = (v) => (v && v !== '-' ? v : null);
  return { id: sid, status: val(st), verdict: val(verdict), build: val(build), updated: val(at), criteria,
    test: existsSync(join(work, 'suite', 'tests', `scenario-${sid.slice(2)}.e2e.ts`)), ran: files.includes('runs.json'), report: files.some((f) => f.startsWith('report-')) };
}
const commandsOf = () => (read(LOG) ?? '').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
function record(who, text) {
  mkdirSync(DIR, { recursive: true });
  const n = commandsOf().length + 1;
  const row = { id: `Q-${n}`, utc: utc(), role: who.role, email: who.email, command: text };
  appendFileSync(LOG, `${JSON.stringify(row)}\n`, { mode: 0o600 });
  return row;
}

// ------------------------------------------------------------------ roles, jobs, notifications
// The ping of a job: never a command of its own from the chat or the old commands route.
const JOB_PING = /^do dashboard job /;
const refusal = (access) => (access === 'viewer' ? 'You can read the dashboard and ask questions. An admin gives you a role to do more.'
  : 'Only an admin does this. Ask an admin.');
// A job as the page shows it: whose is "you" or a role, never another person's email.
const jobView = (j, who) => ({ id: j.id, utc: j.utc, command: j.command, label: j.label, item: j.item, state: j.state, state_word: JOB_STATES[j.state],
  started: j.started, finished: j.finished, text: j.text, mine: !!who.email && j.email === who.email, by: !!who.email && j.email === who.email ? 'you' : `a${j.role === 'admin' ? 'n' : ''} ${j.role}` });
const readNotes = () => { try { const o = JSON.parse(read(NOTES) ?? '{}'); return o && typeof o === 'object' && !Array.isArray(o) ? o : {}; } catch { return {}; } };
// What happened in the last 30 days, built from what the server keeps anyway (docs/dashboard-page.md →
// Notifications): a job ended, a question answered, a run finished. For you: the caller's own jobs and
// questions; the rest is under All. Read: clicked, or before the caller's "Mark as read".
const NOTE_DAYS = 30;
export function notifications(work, who, data) {
  const since = new Date(Date.now() - NOTE_DAYS * 864e5).toISOString(), out = [];
  const mine = (e) => !!who.email && e === who.email;
  for (const j of jobsOf(join(work, 'dashboard', 'jobs.jsonl'))) {
    if (!j.finished || j.finished < since) continue;
    out.push({ id: `job:${j.id}`, utc: j.finished, kind: j.state === 'done' ? 'done' : 'failed', mine: mine(j.email),
      title: `${j.state === 'done' ? 'Done' : 'Did not work'}: ${j.label || j.command}`, text: j.text, who: mine(j.email) ? 'you' : `a${j.role === 'admin' ? 'n' : ''} ${j.role}`, item: j.item, ref: j.id });
  }
  const asked = new Map(jsonl(join(work, 'dashboard', 'asks.jsonl')).filter((r) => mine(r.email)).map((r) => [r.id, r]));
  for (const a of jsonl(join(work, 'dashboard', 'answers.jsonl'))) {
    const q = asked.get(a.id); if (!q || !a.utc || a.utc < since) continue;
    out.push({ id: `ans:${a.id}`, utc: a.utc, kind: 'answer', mine: true, title: 'Quality Inspector answered your question', text: String(a.text ?? '').slice(0, 300), quote: String(q.text ?? '').slice(0, 160), item: q.context?.item ?? null, ref: a.id });
  }
  for (const r of orderedRuns(data?.runs)) {
    if (!r.utc || r.utc < since) continue;
    const probs = (r.analysis?.problems || []).length;
    out.push({ id: `run:${r.id}`, utc: r.utc, kind: probs ? 'run-problems' : 'run', mine: false, title: `${RUN_WORD[r.type] || 'Run'} ${r.ref ? `of ${r.ref} ` : ''}finished${probs ? `: ${probs === 1 ? 'one problem' : `${probs} problems`}` : ''}`,
      text: r.analysis?.summary ? String(r.analysis.summary).slice(0, 300) : null, item: r.id, ref: r.id });
  }
  return out.sort((a, b) => b.utc.localeCompare(a.utc)).slice(0, 50);
}
const RUN_WORD = { regression: 'Nightly regression', issue: 'Issue run', scenario: 'Scenario run', rerun: 'Run by hand', feature: 'Feature run', security: 'Security run' };
function notificationsFor(who) {
  const list = notifications(WORK, who, catalog().data), n = who.email ? readNotes()[who.email] ?? {} : {};
  const read = new Set(n.read ?? []);
  const rows = list.map((x) => ({ ...x, unread: !read.has(x.id) && (!n.seen || x.utc > n.seen) }));
  return { notifications: rows, unread_mine: rows.filter((x) => x.unread && x.mine).length, unread: rows.filter((x) => x.unread).length };
}

// ------------------------------------------------------------------ http
const HOSTS = new Set([`127.0.0.1:${PORT}`, `localhost:${PORT}`, `[::1]:${PORT}`]);
const PEOPLE = join(DIR, 'PEOPLE.md'), JOBS = join(DIR, 'jobs.jsonl'), NOTES = join(DIR, 'notes.json');
function callerOf(req) {
  const role = req.headers['x-platform-caller-role'];
  if (role !== 'owner' && role !== 'viewer') return null;
  const email = String(req.headers['x-platform-caller-email'] || '').trim().toLowerCase() || null;
  // `access`: admin, developer, tester or viewer — the roster's word (lib/people.mjs).
  return { role, email, sub: String(req.headers['x-platform-caller-sub'] || ''), access: roleOf(PEOPLE, role, email) };
}
async function body(req) {
  const chunks = []; let n = 0;
  for await (const c of req) { n += c.length; if (n > MAX_BODY) throw new Said(413, 'The message is too long.'); chunks.push(c); }
  if (!n) return {};
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new Said(400, 'The body is not JSON.'); }
}
const send = (res, code, obj) => {
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  res.end(JSON.stringify(obj));
};
const version = () => (read(join(SCRIPTS, '..', 'VERSION')) ?? '').trim() || null;

async function route(req, res, url, who) {
  const p = url.pathname.split('/').filter(Boolean); // ['api', …]
  const m = req.method;
  if (m === 'GET' && p[1] === 'me') {
    // The dashboard's share link (work/catalog/artifact.url, written at its publish): the page builds an
    // item's link from it ("Copy link"); none → the page uses its own address.
    const link = (read(join(WORK, 'catalog', 'artifact.url')) ?? '').trim();
    return send(res, 200, { role: who.access, owner: who.role === 'owner', email: who.email, name: cfg('display_name') || 'Quality Inspector', version: version(),
      link: /^https:\/\/[^\s#]{1,500}$/.test(link) ? link : null });
  }
  if (m === 'GET' && p[1] === 'catalog') {
    const c = catalog();
    if (!c.data) return send(res, 200, { hash: null, data: null, note: 'The agent has not built the dashboard data yet. It builds it at the end of its next run.' });
    if (url.searchParams.get('have') === c.hash) return send(res, 200, { hash: c.hash, unchanged: true });
    return send(res, 200, { hash: c.hash, data: c.data });
  }
  if (m === 'GET' && p[1] === 'images' && p[2] && !p[3]) {
    const id = decodeURIComponent(p[2]);
    const rel = Object.prototype.hasOwnProperty.call(catalog().data?.images ?? {}, id) ? catalog().data.images[id] : null;
    const img = imagePath(WORK, rel);
    if (!img) throw new Said(404, 'There is no such picture.');
    return send(res, 200, { id, uri: `data:${img.mime};base64,${readFileSync(img.path).toString('base64')}` });
  }
  if (m === 'GET' && p[1] === 'videos' && p[2] && !p[3]) {
    const id = decodeURIComponent(p[2]);
    const rel = Object.prototype.hasOwnProperty.call(catalog().data?.videos ?? {}, id) ? catalog().data.videos[id] : null;
    const v = videoPath(WORK, rel);
    if (!v) throw new Said(404, 'This video is no longer kept here. Its report keeps it.');
    const size = statSync(v.path).size, parts = Math.max(1, Math.ceil(size / VIDEO_PART));
    const part = Number(url.searchParams.get('part') ?? 0);
    if (!Number.isInteger(part) || part < 0 || part >= parts) throw new Said(400, 'There is no such part of the video.');
    const fd = openSync(v.path, 'r');
    try {
      const buf = Buffer.alloc(Math.min(VIDEO_PART, size - part * VIDEO_PART));
      readSync(fd, buf, 0, buf.length, part * VIDEO_PART);
      return send(res, 200, { id, mime: v.mime, size, parts, part, b64: buf.toString('base64') });
    } finally { closeSync(fd); }
  }
  if (m === 'POST' && p[1] === 'act') {
    const b = await body(req);
    const text = typeof b.command === 'string' ? b.command : '';
    const hit = ACTIONS.map(([re, fn]) => [re.exec(text), fn]).find(([x]) => x);
    if (!hit || !allowed(text)) throw new Said(400, 'This is not an action the dashboard does by itself.');
    if (!may(who.access, text)) throw new Said(403, refusal(who.access));
    spend(`act:${who.email}`);
    const out = JSON.stringify(hit[1](hit[0]));
    log('info', 'dashboard_act', `${text} by=${who.email || '-'}`);
    cache.at = '';
    const c = catalog();
    return send(res, 200, { ok: true, done: (out || '').trim().slice(0, 400), hash: c.hash, data: c.data });
  }
  if (m === 'POST' && p[1] === 'settings') {
    // An admin's press is their word (docs/modules.md → Control): this server writes it, after
    // `modules.sh valid` checked the key and the value. Anyone else's is refused.
    if (who.access !== 'admin') throw new Said(403, 'Only an admin changes the settings. Ask an admin.');
    const b = await body(req);
    spend(`settings:${who.email}`);
    const command = typeof b.focus === 'string' ? `focus ${b.focus}`
      : typeof b.module === 'string' && typeof b.key === 'string' && typeof b.value === 'string' ? `module ${b.module} set ${b.key}=${b.value}` : '';
    const hit = command.length <= 120 && ACTIONS.slice(0, 2).map(([re, fn]) => [re.exec(command), fn]).find(([x]) => x);
    if (!hit) throw new Said(400, 'This is not a setting of the dashboard.');
    const args = command.split(' ');
    const out = JSON.stringify(hit[1](hit[0]));
    log('info', 'dashboard_setting', `${args.join(' ')} by=${who.email || '-'}`);
    cache.at = '';
    const c = catalog();
    return send(res, 200, { ok: true, done: (out || '').trim().slice(0, 400), hash: c.hash, modules: c.data?.modules ?? null });
  }
  if (m === 'GET' && p[1] === 'status') return send(res, 200, status(WORK));
  if (m === 'GET' && p[1] === 'commands') {
    const mine = commandsOf().filter((r) => r.email && r.email === who.email).slice(-20).reverse()
      .map(({ id, utc: at, command }) => ({ id, utc: at, command }));
    return send(res, 200, { commands: mine });
  }
  if (m === 'GET' && p[1] === 'asks') {
    const answers = answersOf(), links = linksOf();
    const mine = asksOf().filter((r) => r.email && r.email === who.email).slice(-60)
      .map(({ id, utc: at, text, context, command, request }) => ({ id, utc: at, text, context, command: command ?? null, answer: answers.get(id) ?? null,
        ...(request ? { request: { scenario: scenarioProgress(WORK, links.get(id)) } } : {}) }));
    return send(res, 200, { asks: mine });
  }
  if (m === 'POST' && p[1] === 'asks') {
    const b = await body(req);
    const command = typeof b.command === 'string' && b.command ? b.command : null;
    if (command && (command.length > 2200 || !allowed(command) || JOB_PING.test(command))) throw new Said(400, 'This is not a command of the dashboard. Use a button of the page.');
    if (command && !may(who.access, command)) throw new Said(403, refusal(who.access));
    const text = typeof b.text === 'string' && b.text.trim() ? b.text.trim() : command ?? '';
    if (!text || text.length > 2000 || /[\u0000-\u0008\u000b-\u001f\u007f]/.test(text)) throw new Said(400, 'Write a question of at most 2000 letters.');
    spend(who.email || who.sub || who.role);
    const c = b.context && typeof b.context === 'object' ? b.context : {};
    const id = `A-${asksOf().length + 1}`, request = b.request === true && command !== null && REQUEST_CMD.test(command);
    // A scenario request is its own page: its context is the request itself.
    const context = request ? { tab: 'tests', page: 'tests/scenarios', item: id, label: `Scenario request ${id}` }
      : { tab: /^[a-z]{1,20}$/.test(c.tab ?? '') ? c.tab : null, page: /^[a-z]{1,20}(?:\/[a-z-]{1,20})?$/.test(c.page ?? '') ? c.page : null,
        item: typeof c.item === 'string' && c.item.length <= 200 && !/[\u0000-\u001f]/.test(c.item) ? c.item : null,
        label: typeof c.label === 'string' ? c.label.replace(/[\u0000-\u001f]/g, ' ').slice(0, 200) : null };
    const row = recordAsk(who, text, context, command, id, request);
    log('info', 'dashboard_ask', `${row.id} from ${who.role}${request ? ' a scenario request' : command ? ' with a command' : ''}`);
    // A command goes to the agent in its exact words, as the page's commands always did (a viewer's
    // channel turn reads them so); the agent answers it in the chat (docs/on-demand.md). The ping goes
    // to the page's own session: one platform session per page, and one per scenario request.
    return send(res, 201, { id: row.id, ping: command ?? `answer dashboard question ${row.id}`, ping_conversation: conversationOf(context) });
  }
  if (m === 'POST' && p[1] === 'commands') {
    const b = await body(req);
    const text = typeof b.command === 'string' ? b.command : '';
    if (!text || text.length > 2200 || !allowed(text) || JOB_PING.test(text)) throw new Said(400, 'This is not a command of the dashboard. Use a button of the page.');
    if (!may(who.access, text)) throw new Said(403, refusal(who.access));
    spend(who.email || who.sub || who.role);
    const row = record(who, text);
    log('info', 'dashboard_command', `${row.id} from ${who.role}`);
    // The page sends `ping` as its message to the agent: the command, exactly as recorded.
    return send(res, 201, { id: row.id, ping: text });
  }
  if (m === 'POST' && p[1] === 'jobs' && !p[2]) {
    const b = await body(req);
    const command = typeof b.command === 'string' ? b.command : '';
    // A job is work for the model: the page's own command, not one this server does itself (POST /api/act).
    if (!command || command.length > 2200 || !allowed(command) || JOB_PING.test(command) || ACTIONS.some(([re]) => re.test(command)))
      throw new Said(400, 'This is not work the dashboard gives Quality Inspector. Use a button of the page.');
    if (!may(who.access, command)) throw new Said(403, refusal(who.access));
    spend(who.email || who.sub || who.role);
    const clean = (v, n) => (typeof v === 'string' && v.trim() ? v.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, n) : null);
    const id = queueJob(JOBS, { command, label: clean(b.label, 80), item: clean(b.item, 200), note: clean(b.note, 1000), role: who.access, platform: who.role, email: who.email }, utc());
    log('info', 'dashboard_job', `${id} from ${who.access}`);
    return send(res, 201, { id, ping: `do dashboard job ${id}` });
  }
  if (m === 'GET' && p[1] === 'jobs' && !p[2]) return send(res, 200, { jobs: jobsOf(JOBS).slice(-80).reverse().map((j) => jobView(j, who)) });
  if (m === 'GET' && p[1] === 'people' && !p[2]) {
    const list = people(PEOPLE);
    return send(res, 200, { roles: ROLES, people: who.access === 'admin' ? list : [], counts: Object.fromEntries(ROLES.map((r) => [r, list.filter((x) => x.role === r).length])) });
  }
  if (m === 'POST' && p[1] === 'people' && !p[2]) {
    if (who.access !== 'admin') throw new Said(403, 'Only an admin gives people their roles.');
    const b = await body(req);
    spend(`people:${who.email}`);
    let done;
    try { done = setRole(PEOPLE, b.email, b.role === null ? null : String(b.role ?? ''), utc()); } catch (e) { throw new Said(400, e.message); }
    log('info', 'dashboard_people', `role ${done.old ?? '-'} → ${done.role ?? '-'} by=${who.email || '-'}`);
    return send(res, 200, { ok: true, ...done, people: people(PEOPLE) });
  }
  if (m === 'GET' && p[1] === 'notifications' && !p[2]) return send(res, 200, notificationsFor(who));
  if (m === 'POST' && p[1] === 'notifications' && (p[2] === 'read' || p[2] === 'seen') && !p[3]) {
    if (!who.email) return send(res, 200, { ok: true });
    const b = p[2] === 'read' ? await body(req) : {};
    const notes = readNotes(), mine = notes[who.email] ?? { seen: null, read: [] };
    if (p[2] === 'read') {
      if (typeof b.id !== 'string' || !/^(?:job|ans|run):[A-Z]-\d{1,6}$/.test(b.id)) throw new Said(400, 'There is no such notification.');
      if (!mine.read.includes(b.id)) mine.read = [...mine.read, b.id].slice(-500);
    } else { mine.seen = utc(); mine.read = []; }
    notes[who.email] = mine; writeFile(NOTES, JSON.stringify(notes));
    return send(res, 200, { ok: true });
  }
  throw new Said(404, `There is no route ${m} ${url.pathname}.`);
}

export const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://dashboard.local');
  try {
    if (!HOSTS.has(String(req.headers.host || ''))) throw new Said(421, 'The dashboard server answers only on its loopback address.');
    if (url.pathname === '/health') return send(res, 200, { ok: true, version: version(), data: existsSync(DATA) });
    if (url.pathname.startsWith('/api/')) {
      const who = callerOf(req);
      if (!who) throw new Said(401, "The dashboard server answers only the platform's relay.");
      return await route(req, res, url, who);
    }
    throw new Said(404, 'Not found.');
  } catch (e) {
    const code = e instanceof Said ? e.status : 500;
    // An unexpected error stays in the log: its text can name paths on the agent's machine.
    if (code >= 500) log('error', 'dashboard_error', `${req.method} ${url.pathname}: ${e.stack || e}`);
    send(res, code, { error: code >= 500 ? 'Something went wrong on the dashboard server. The operator sees it in its log.' : e.message });
  }
});

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  server.listen(PORT, '127.0.0.1', () => log('info', 'dashboard_start', `listening on 127.0.0.1:${PORT}, data ${DATA}`));
  for (const s of ['SIGTERM', 'SIGINT']) process.on(s, () => server.close(() => process.exit(0)));
}
