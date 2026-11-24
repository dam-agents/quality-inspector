#!/usr/bin/env node
// The dashboard server: the Artifact API of the dashboard page (docs/catalog.md → The server).
// A Login item starts it at every boot (kit.yaml → startupItems); supervise-daemon restarts it
// when it exits. The same pattern as Design Desk's Desk server.
//
// The page is published once and asks this server for everything it shows:
//   GET  /api/me              who is looking (the platform's verified caller), the page's switches
//   GET  /api/catalog?have=h  the newest catalog data (work/catalog/data.json, written by catalog.mjs)
//   GET  /api/images/<id>     one picture of that data, as a data URI
//   GET  /api/videos/<id>?part=k  one part of a report's video (VIDEO_PART bytes, base64), with its size
//   GET  /api/asks            the caller's own questions from the page's chat, each with its answer
//   POST /api/asks            {text, context, command?}: a question or a request to Quality Inspector,
//                             recorded with who asked; its ping the page sends to the agent — the page's
//                             command as it is, or `answer dashboard question A-<n>` for a question
//   POST /api/act             {command}: one of the operator's own actions that a script does without the
//                             model — dismiss, reopen or categorize D-<k>, retry B-<k>, add to or remove from
//                             a collection — run as this server's child (owner only)
//   POST /api/settings        {module, key, value} or {focus}: the operator's own change of a module's
//                             setting, written at once through modules.sh (owner only); the new state back
//   GET  /api/status          what the agent does now, read live from work/ (the lock, rows in progress)
//   POST /api/commands        a command of the page: checked against the page's own patterns,
//                             recorded with who sent it, then handed back as the ping the page sends
//   GET  /api/commands        the caller's own commands from the page, newest first
//
// Only the platform relay reaches /api/: it sets x-platform-caller-role/-email/-sub on every
// request from the page, which the page cannot forge. Loopback only. Nothing a viewer sends is
// executed here: a command is stored as data and goes to the agent as the page's message. The one
// write is the operator's own setting, through modules.sh, which checks it (POST /api/settings).
import { createServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readFileSync, readSync, realpathSync, statSync } from 'node:fs';
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
const DISMISSED = join(WORK, 'design', 'DISMISSED.md'), COLLECTIONS = join(WORK, 'CATALOG.md');
const tableOf = (text) => (text ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2).map((l) => l.split('|').slice(1, -1).map((x) => x.trim()));
function catalog() {
  const t = mtime(DATA), c = mtime(CONFIG), d = mtime(DISMISSED), k = mtime(COLLECTIONS), key = `${t}|${c}|${d}|${k}`;
  if (key !== cache.at) {
    let data = null;
    try { data = JSON.parse(readFileSync(DATA, 'utf8')); } catch { data = null; }
    data = data && typeof data === 'object' && !Array.isArray(data) ? data : null;
    const newer = [c, d, k].filter((x) => data && x > t);
    if (data && c > t) data.modules = withConfig(data.modules);
    if (data && d > t && Array.isArray(data.design)) {
      const off = new Map(tableOf(read(DISMISSED)).filter(([id]) => /^D-\d+$/.test(id ?? '')).map(([id, , reason]) => [id, reason || null]));
      data.design = data.design.map((f) => (off.has(f.id) ? { ...f, status: 'dismissed', dismiss_reason: off.get(f.id) } : f.status === 'dismissed' ? { ...f, status: 'open', dismiss_reason: null } : f));
    }
    if (data && k > t) data.collections = tableOf(read(COLLECTIONS)).filter(([n]) => n).map(([name, members]) => ({ name, members: String(members ?? '').split(',').map((x) => x.trim()).filter(Boolean) }));
    cache = { at: key, data, hash: data ? `${data.hash ?? t}${newer.length ? `-${Math.round(Math.max(...newer))}` : ''}` : null };
  }
  return cache;
}
// The operator's actions a script does without the model (docs/modules.md → Control): the command's
// words, as the page's own pattern allows them, to the script's arguments.
const ACTIONS = [
  [/^dismiss (D-\d{1,6})(?: as (false-positive|wont-fix|duplicate|by-design))?$/, (m) => ['bash', MODULES_SH, 'dismiss', m[1], ...(m[2] ? [m[2]] : [])]],
  [/^reopen (D-\d{1,6})$/, (m) => ['bash', MODULES_SH, 'reopen', m[1]]],
  [/^categorize (D-\d{1,6}) ([a-z0-9][a-z0-9-]{0,29}|-)$/, (m) => ['bash', MODULES_SH, 'categorize', m[1], m[2]]],
  [/^retry (B-\d{1,6})$/, (m) => [process.execPath, join(SCRIPTS, 'blockers.mjs'), 'retry', m[1]]],
  [/^add (#\d+(?: (?:AC|IN)-\d+)?|S-\d+(?: AC-\d+)?) to the collection ([A-Za-z0-9][A-Za-z0-9 _.-]{0,39})$/, (m) => [process.execPath, join(SCRIPTS, 'collections.mjs'), 'add', m[2], m[1]]],
  [/^remove (#\d+(?: (?:AC|IN)-\d+)?|S-\d+(?: AC-\d+)?) from the collection ([A-Za-z0-9][A-Za-z0-9 _.-]{0,39})$/, (m) => [process.execPath, join(SCRIPTS, 'collections.mjs'), 'remove', m[2], m[1]]],
  [/^module ([a-z][a-z-]{1,30}) set ([a-z_]+)=([A-Za-z0-9,._-]{1,40})$/, (m) => ['bash', MODULES_SH, 'set', m[1], `${m[2]}=${m[3]}`]],
  [/^focus ([A-Za-z0-9][A-Za-z0-9 _.\/-]{0,39})$/, (m) => ['bash', MODULES_SH, 'focus', m[1]]],
];
function runAction(args) {
  try {
    return execFileSync(args[0], args.slice(1), { encoding: 'utf8', env: { ...process.env, WORK_DIR: WORK, QI_DASHBOARD_WRITE: 'operator' }, stdio: ['ignore', 'pipe', 'pipe'], timeout: 60000 });
  } catch (e) {
    const why = String(e.stderr || '').split('\n').find((l) => /^(modules\.sh|blockers\.mjs|collections\.mjs|blockers):/.test(l)) || 'It was not done.';
    throw new Said(400, why.replace(/^[a-z.]+: /, '').replace(/^./, (x) => x.toUpperCase()));
  }
}

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
function recordAsk(who, text, context, command = null) {
  mkdirSync(DIR, { recursive: true });
  const row = { id: `A-${asksOf().length + 1}`, utc: utc(), role: who.role, email: who.email, text, context, ...(command ? { command } : {}) };
  appendFileSync(ASKS, `${JSON.stringify(row)}\n`, { mode: 0o600 });
  return row;
}
const commandsOf = () => (read(LOG) ?? '').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
function record(who, text) {
  mkdirSync(DIR, { recursive: true });
  const n = commandsOf().length + 1;
  const row = { id: `Q-${n}`, utc: utc(), role: who.role, email: who.email, command: text };
  appendFileSync(LOG, `${JSON.stringify(row)}\n`, { mode: 0o600 });
  return row;
}

// ------------------------------------------------------------------ http
const HOSTS = new Set([`127.0.0.1:${PORT}`, `localhost:${PORT}`, `[::1]:${PORT}`]);
function callerOf(req) {
  const role = req.headers['x-platform-caller-role'];
  if (role !== 'owner' && role !== 'viewer') return null;
  const email = String(req.headers['x-platform-caller-email'] || '').trim().toLowerCase() || null;
  return { role, email, sub: String(req.headers['x-platform-caller-sub'] || '') };
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
    return send(res, 200, { role: who.role === 'owner' ? 'operator' : 'viewer', email: who.email, name: cfg('display_name') || 'Quality Inspector', version: version() });
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
    if (who.role !== 'owner') throw new Said(403, 'Only the operator does this. Ask the operator.');
    const b = await body(req);
    const text = typeof b.command === 'string' ? b.command : '';
    const hit = ACTIONS.map(([re, args]) => [re.exec(text), args]).find(([x]) => x);
    if (!hit || !allowed(text)) throw new Said(400, 'This is not an action the dashboard does by itself.');
    spend(`act:${who.email}`);
    const out = runAction(hit[1](hit[0]));
    log('info', 'dashboard_act', `${text} by=${who.email || '-'}`);
    cache.at = '';
    const c = catalog();
    return send(res, 200, { ok: true, done: (out || '').trim().slice(0, 400), hash: c.hash, data: c.data });
  }
  if (m === 'POST' && p[1] === 'settings') {
    // The operator's own press is their word (docs/modules.md → Control): written at once by
    // modules.sh, which checks the key and the value. A viewer's press stays a request (POST /api/commands).
    if (who.role !== 'owner') throw new Said(403, 'Only the operator changes the settings. Ask the operator.');
    const b = await body(req);
    spend(`settings:${who.email}`);
    const args = typeof b.focus === 'string' ? ['focus', b.focus]
      : typeof b.module === 'string' && typeof b.key === 'string' && typeof b.value === 'string' ? ['set', b.module, `${b.key}=${b.value}`] : null;
    if (!args || args.some((a) => a.length > 80 || /[\u0000-\u001f\u007f]/.test(a))) throw new Said(400, 'This is not a setting of the dashboard.');
    let out;
    try {
      out = execFileSync('bash', [MODULES_SH, ...args], { encoding: 'utf8', env: { ...process.env, WORK_DIR: WORK, QI_DASHBOARD_WRITE: 'operator' }, stdio: ['ignore', 'pipe', 'pipe'], timeout: 60000 });
    } catch (e) {
      const why = String(e.stderr || '').split('\n').find((l) => l.startsWith('modules.sh:')) || 'The setting was not changed.';
      throw new Said(400, why.replace(/^modules\.sh: /, '').replace(/^./, (x) => x.toUpperCase()));
    }
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
    const answers = answersOf();
    const mine = asksOf().filter((r) => r.email && r.email === who.email).slice(-60)
      .map(({ id, utc: at, text, context, command }) => ({ id, utc: at, text, context, command: command ?? null, answer: answers.get(id) ?? null }));
    return send(res, 200, { asks: mine });
  }
  if (m === 'POST' && p[1] === 'asks') {
    const b = await body(req);
    const command = typeof b.command === 'string' && b.command ? b.command : null;
    if (command && (command.length > 2200 || !allowed(command))) throw new Said(400, 'This is not a command of the dashboard. Use a button of the page.');
    const text = typeof b.text === 'string' && b.text.trim() ? b.text.trim() : command ?? '';
    if (!text || text.length > 2000 || /[\u0000-\u0008\u000b-\u001f\u007f]/.test(text)) throw new Said(400, 'Write a question of at most 2000 letters.');
    spend(who.email || who.sub || who.role);
    const c = b.context && typeof b.context === 'object' ? b.context : {};
    const context = { tab: /^[a-z]{1,20}$/.test(c.tab ?? '') ? c.tab : null, item: typeof c.item === 'string' && c.item.length <= 200 && !/[\u0000-\u001f]/.test(c.item) ? c.item : null,
      label: typeof c.label === 'string' ? c.label.replace(/[\u0000-\u001f]/g, ' ').slice(0, 200) : null };
    const row = recordAsk(who, text, context, command);
    log('info', 'dashboard_ask', `${row.id} from ${who.role}${command ? ' with a command' : ''}`);
    // A command goes to the agent in its exact words, as the page's commands always did (a viewer's
    // channel turn reads them so); the agent answers it in the chat (docs/on-demand.md).
    return send(res, 201, { id: row.id, ping: command ?? `answer dashboard question ${row.id}` });
  }
  if (m === 'POST' && p[1] === 'commands') {
    const b = await body(req);
    const text = typeof b.command === 'string' ? b.command : '';
    if (!text || text.length > 2200 || !allowed(text)) throw new Said(400, 'This is not a command of the dashboard. Use a button of the page.');
    spend(who.email || who.sub || who.role);
    const row = record(who, text);
    log('info', 'dashboard_command', `${row.id} from ${who.role}`);
    // The page sends `ping` as its message to the agent: the command, exactly as recorded.
    return send(res, 201, { id: row.id, ping: text });
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
