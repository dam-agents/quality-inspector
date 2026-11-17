#!/usr/bin/env node
// The dashboard server: the Artifact API of the dashboard page (docs/catalog.md → The server).
// A Login item starts it at every boot (kit.yaml → startupItems); supervise-daemon restarts it
// when it exits. The same pattern as Design Desk's Desk server.
//
// The page is published once and asks this server for everything it shows:
//   GET  /api/me              who is looking (the platform's verified caller), the page's switches
//   GET  /api/catalog?have=h  the newest catalog data (work/catalog/data.json, written by catalog.mjs)
//   GET  /api/images/<id>     one picture of that data, as a data URI
//   GET  /api/status          what the agent does now, read live from work/ (the lock, rows in progress)
//   POST /api/commands        a command of the page: checked against the page's own patterns,
//                             recorded with who sent it, then handed back as the ping the page sends
//   GET  /api/commands        the caller's own commands from the page, newest first
//
// Only the platform relay reaches /api/: it sets x-platform-caller-role/-email/-sub on every
// request from the page, which the page cannot forge. Loopback only. Nothing a viewer sends is
// executed here: a command is stored as data and goes to the agent as the page's message.
import { createServer } from 'node:http';
import { appendFileSync, existsSync, mkdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
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
let cache = { at: -1, data: null, hash: null };
function catalog() {
  const t = mtime(DATA);
  if (t !== cache.at) {
    let data = null;
    try { data = JSON.parse(readFileSync(DATA, 'utf8')); } catch { data = null; }
    cache = { at: t, data: data && typeof data === 'object' && !Array.isArray(data) ? data : null, hash: data?.hash ?? (t ? String(t) : null) };
  }
  return cache;
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
  if (m === 'GET' && p[1] === 'status') return send(res, 200, status(WORK));
  if (m === 'GET' && p[1] === 'commands') {
    const mine = commandsOf().filter((r) => r.email && r.email === who.email).slice(-20).reverse()
      .map(({ id, utc: at, command }) => ({ id, utc: at, command }));
    return send(res, 200, { commands: mine });
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
