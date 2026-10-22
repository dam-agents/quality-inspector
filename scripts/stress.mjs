#!/usr/bin/env node
// stress.mjs — bounded, local load against the nested product only: the mapped GET requests
// replayed by concurrent workers, the mapped pages loaded by a few browser contexts, then a
// health probe. The one exception to docs/security.md → Out of scope (load and DoS); the
// oracles, caps and reading are frozen in docs/stress.md. No model calls.
//
//   node stress.mjs <inventory.json> --build <c> [--out <dir>] [--previous <stress.json>] [--concurrency N]
//                   [--duration S] [--pages N] [--base URL] [--skip-signin] [--dry-run]
//
// Writes <out>/stress.json ({build, generated_utc, base, config, counts, checks:[{id, target, status,
// severity, evidence, reason}], metrics:{api, ui}, notes}) and prints {stress, checks, failed, notes}.
// Default <out>: work/stress/<build>. --dry-run prints the plan: no network, no browser.
//
// Only GETs are replayed — never a write. Hard caps hold whatever the flags or the config say:
// concurrency <= 50, duration <= 300 s, <= 20 000 requests, <= 5 browser contexts. Signs in as
// OWNER (work/env/credentials.env) like security-checks.mjs; --skip-signin replays anonymously.
// Evidence holds counts and timings only — never a header, cookie, body or credential.

import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const flags = {}; const pos = [];
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--dry-run') flags.dry = true;
  else if (a === '--skip-signin') flags.skipSignin = true;
  else if (a.startsWith('--')) flags[a.slice(2)] = process.argv[++i];
  else pos.push(a);
}
const usage = 'usage: stress.mjs <inventory.json> --build C [--out DIR] [--previous stress.json] [--concurrency N] [--duration S] [--pages N] [--base URL] [--skip-signin] [--dry-run]';
if (!pos[0]) { console.error(usage); process.exit(2); }

const CAP = { concurrency: 50, duration_s: 300, requests: 20000, contexts: 5, endpoints: 30 };
const WORK = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const sh = (expr) => {
  try {
    return execFileSync('bash', ['-c', `CONFIG="$WORK/CONFIG.md"; . "$LIB/config.sh"; . "$LIB/profile.sh"; ${expr}`],
      { env: { ...process.env, WORK, LIB: join(here, 'lib') }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return ''; }
};
const profileDir = sh('profile_dir');
const profile = (() => { try { return JSON.parse(readFileSync(join(profileDir, 'profile.json'), 'utf8')); } catch { return {}; } })();
const LOCAL = ['localhost', '127.0.0.1'];
const base = (() => { try { return new URL(flags.base ?? process.env.APP_URL ?? profile.app?.url ?? 'http://localhost'); } catch { return null; } })();
if (!base || !LOCAL.includes(base.hostname)) { console.error(`refusing ${base?.origin ?? flags.base}: only the nested product on localhost`); process.exit(2); }
let inv;
try { inv = JSON.parse(readFileSync(pos[0], 'utf8')); } catch (e) { console.error(`stress: cannot read ${pos[0]}: ${e.message}`); process.exit(2); }
const build = flags.build ?? inv.build;
if (!build) { console.error(`stress: no --build and the map names none\n${usage}`); process.exit(2); }

// ------------------------------------------------------------------ the plan (pure) ----
const notes = [];
const num = (flag, key, dflt) => {
  const raw = flags[flag] ?? (key ? sh(`cfg ${key}`) : '');
  const n = Math.floor(Number(raw));
  if (raw !== undefined && raw !== '' && !(Number.isFinite(n) && n >= 0)) notes.push(`--${flag}/${key ?? '-'} "${raw}" is not a number: default ${dflt}`);
  return raw !== undefined && raw !== '' && Number.isFinite(n) && n >= 0 ? n : dflt;
};
const clamp = (name, v, lo, hi) => {
  if (v > hi) { notes.push(`${name} ${v} clamped to the hard cap ${hi}`); return hi; }
  if (v < lo) { notes.push(`${name} ${v} raised to ${lo}`); return lo; }
  return v;
};

function buildPlan(map, o) {
  const endpoints = []; const seen = new Set(); const nonGet = new Set();
  for (const q of Array.isArray(map.api_requests) ? map.api_requests : []) {
    const method = String(q?.method ?? '').toUpperCase();
    const pat = q?.path_pattern ?? q?.path; const path = q?.example_path ?? q?.example ?? pat;
    if (!pat || !path) continue;
    if (method !== 'GET') { nonGet.add(method); continue; }
    const target = `GET ${pat}`;
    if (seen.has(target) || seen.has(`@${path}`)) continue;
    let url; try { url = new URL(path, o.base); } catch { continue; }
    if (url.origin !== o.base.origin) { o.notes.push(`${target}: example leaves the product's origin, not replayed`); continue; }
    seen.add(target); seen.add(`@${path}`);
    endpoints.push({ method: 'GET', target, path });
  }
  if (nonGet.size) o.notes.push(`writes are never replayed: ${[...nonGet].sort().join(', ')} requests left out`);
  if (endpoints.length > CAP.endpoints) { o.notes.push(`${endpoints.length} GET endpoints, the first ${CAP.endpoints} replayed`); endpoints.length = CAP.endpoints; }
  const pages = Object.entries(map.routes ?? {}).filter(([, r]) => r?.example && !r.error && !r.redirected)
    .slice(0, o.pages).map(([target, r]) => ({ target, path: r.example }));
  return { endpoints, pages };
}

const concurrency = clamp('concurrency', num('concurrency', 'stress_max_concurrency', 10), 1, CAP.concurrency);
const duration = clamp('duration', num('duration', 'stress_duration_s', 60), 1, CAP.duration_s);
const pagesN = num('pages', null, 5);
const contexts = Math.min(concurrency, CAP.contexts);
const { endpoints, pages } = buildPlan(inv, { base, pages: pagesN, notes });
const config = { concurrency, duration_s: duration, pages: pagesN, requests_cap: CAP.requests, contexts };
if (flags.dry) {
  console.log(JSON.stringify({ base: base.origin, build, config, skip_signin: !!flags.skipSignin, endpoints, pages, notes }, null, 2));
  process.exit(0);
}

const previous = (() => {
  if (!flags.previous) return null;
  try { return JSON.parse(readFileSync(flags.previous, 'utf8')).metrics ?? null; } catch (e) { notes.push(`--previous unreadable (${e.message.split('\n')[0]}): no comparison`); return null; }
})();

// ------------------------------------------------------------------ the run ----
const SEV = { 'STRESS-API-1': 'high', 'STRESS-API-2': 'high', 'STRESS-API-3': 'medium', 'STRESS-UI-1': 'high', 'STRESS-UI-2': 'medium', 'STRESS-HEALTH-1': 'critical' };
const checks = [];
const add = (id, target, status, evidence = {}, reason = '') => checks.push({ id, target, status, severity: SEV[id], evidence, ...(reason ? { reason } : {}) });
const msg = (e) => String(e?.message ?? e).split('\n')[0].slice(0, 160);
const pct = (a, p) => { if (!a.length) return null; const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.ceil((p / 100) * s.length) - 1)]; };
const sameOrigin = (u) => { try { return new URL(u).origin === base.origin; } catch { return false; } };
const local = (u) => { try { const x = new URL(u); return !/^https?:$/.test(x.protocol) || LOCAL.includes(x.hostname); } catch { return false; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Playwright only when a sign-in or the ui phase needs it.
let pw = null; let pwWhy = '';
const loadPw = () => {
  if (pw || pwWhy) return pw;
  try {
    const req = createRequire(process.env.QI_PLAYWRIGHT_FROM ?? join(WORK, 'suite', 'package.json'));
    try { pw = req('playwright-core'); } catch { pw = createRequire(req.resolve('@e2e-dev/web'))('playwright-core'); }
  } catch (e) { pwWhy = msg(e); }
  return pw;
};
let browser = null;
const launch = async () => {
  if (browser) return browser;
  if (!loadPw()) throw new Error(`playwright unavailable (${pwWhy})`);
  try { browser = await pw.chromium.launch({ headless: true }); } catch (e) { throw new Error(`playwright unavailable (${msg(e)})`); }
  return browser;
};

// Owner sign-in, as security-checks.mjs does it: cookies and the authorization header kept in memory.
let session = null;
if (!flags.skipSignin) {
  try {
    const credFile = (() => {
      const o = {};
      try {
        for (const l of readFileSync(join(WORK, 'env', 'credentials.env'), 'utf8').split('\n')) {
          const m = /^\s*(?:export\s+)?([A-Z0-9_]+)=(.*)$/.exec(l);
          if (m) o[m[1]] = m[2].trim().replace(/^(['"])(.*)\1$/, '$2');
        }
      } catch { /* no file: env only */ }
      return o;
    })();
    const user = process.env.E2E_USER_OWNER_USERNAME ?? credFile.E2E_USER_OWNER_USERNAME;
    const pass = process.env.E2E_USER_OWNER_PASSWORD ?? credFile.E2E_USER_OWNER_PASSWORD;
    if (!user || !pass) throw new Error('no OWNER account (E2E_USER_OWNER_*)');
    const b = await launch();
    const context = await b.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    const settle = async () => { await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {}); await page.waitForTimeout(500); };
    const pwdVisible = async () => (await page.locator('input[type=password]').filter({ visible: true }).count()) > 0;
    let auth = null;
    page.on('request', (r) => { const h = r.headers().authorization; if (!auth && h && sameOrigin(r.url())) auth = h; });
    await page.goto(base.href, { waitUntil: 'domcontentloaded' }); await settle();
    const pwd = page.locator('input[type=password]');
    if (await pwd.count()) {
      await page.locator('input[type=text]:visible, input[type=email]:visible, input[name=username]').first().fill(user);
      await pwd.first().fill(pass);
      await Promise.all([page.waitForURL((u) => u.origin === base.origin, { timeout: 30000 }), pwd.first().press('Enter')]);
      await settle();
    }
    if (await pwdVisible()) throw new Error('OWNER sign-in failed');
    const first = Object.values(inv.routes ?? {}).find((r) => r?.example && r.example !== '/');
    if (!auth && first) { await page.goto(new URL(first.example, base).href, { waitUntil: 'domcontentloaded' }).catch(() => {}); await settle(); }
    session = { auth, cookies: await context.cookies(base.href), state: await context.storageState() };
    await context.close();
  } catch (e) {
    console.error(`stress: cannot sign in: ${msg(e)}`);
    await browser?.close().catch(() => {});
    process.exit(1);
  }
}

async function http(path, timeoutMs = 20000) {
  const url = new URL(path, base);
  if (url.origin !== base.origin) throw new Error(`refusing ${url.origin}`);
  const headers = { accept: 'application/json, text/html;q=0.9, */*;q=0.1' };
  if (session?.cookies?.length) headers.cookie = session.cookies.map((c) => `${c.name}=${c.value}`).join('; ');
  if (session?.auth) headers.authorization = session.auth;
  const res = await fetch(url, { method: 'GET', headers, redirect: 'manual', signal: AbortSignal.timeout(timeoutMs) });
  await res.arrayBuffer().catch(() => {});
  return res;
}

// Phase api — `concurrency` workers, round-robin over the endpoints, until the duration or the request cap.
const api = Object.fromEntries(endpoints.map((e) => [e.target, { count: 0, errors: 0, net_errors: 0, s5xx: 0, classes: {}, lat: [] }]));
if (endpoints.length) {
  let next = 0; let sent = 0; let capAt = null;
  const t0 = Date.now(); const end = t0 + duration * 1000;
  const worker = async () => {
    while (Date.now() < end) {
      if (sent >= CAP.requests) { capAt ??= Date.now() - t0; return; }
      sent++;
      const e = endpoints[next++ % endpoints.length]; const m = api[e.target];
      const s = Date.now();
      try {
        const res = await http(e.path);
        const cls = `${Math.floor(res.status / 100)}xx`;
        m.count++; m.classes[cls] = (m.classes[cls] ?? 0) + 1; m.lat.push(Date.now() - s);
        if (res.status >= 500) m.s5xx++;
        if (res.status < 200 || res.status >= 400) m.errors++;
      } catch { m.count++; m.errors++; m.net_errors++; }
    }
  };
  await Promise.all(Array.from({ length: concurrency }, worker));
  if (capAt != null) notes.push(`the request cap ${CAP.requests} was reached after ${Math.round(capAt / 1000)} s`);
}
const metricsApi = Object.fromEntries(Object.entries(api).map(([k, m]) => [k,
  { count: m.count, errors: m.errors, s5xx: m.s5xx, p50: pct(m.lat, 50), p95: pct(m.lat, 95), max: m.lat.length ? Math.max(...m.lat) : null, net_errors: m.net_errors, classes: m.classes }]));

const slower = (id, target, cur, prev, unit) => {
  if (!previous) return add(id, target, 'skipped', {}, 'no previous run (--previous)');
  if (typeof prev !== 'number') return add(id, target, 'skipped', {}, `not in the previous run's ${unit}`);
  if (typeof cur !== 'number') return add(id, target, 'skipped', { previous_p95_ms: prev }, 'no timing in this run');
  const ev = { p95_ms: cur, previous_p95_ms: prev, factor: prev > 0 ? Number((cur / prev).toFixed(1)) : null };
  const bad = cur > prev * 2.0 && cur - prev >= 1000;
  add(id, target, bad ? 'fail' : 'pass', ev, bad ? `p95 ${cur} ms vs ${prev} ms before (> 2.0x and >= +1000 ms)` : '');
};
if (!endpoints.length) for (const id of ['STRESS-API-1', 'STRESS-API-2', 'STRESS-API-3']) add(id, '*', 'skipped', {}, 'the UI map recorded no replayable GET requests');
for (const [t, m] of Object.entries(metricsApi)) {
  if (!m.count) { for (const id of ['STRESS-API-1', 'STRESS-API-2', 'STRESS-API-3']) add(id, t, 'skipped', {}, 'no request was sent'); continue; }
  const rate = m.errors / m.count;
  const ev = { requests: m.count, errors: m.errors, network_errors: m.net_errors, s5xx: m.s5xx, classes: m.classes, error_rate: Number(rate.toFixed(4)) };
  add('STRESS-API-1', t, rate <= 0.01 ? 'pass' : 'fail', ev, rate <= 0.01 ? '' : `error rate ${(rate * 100).toFixed(1)}% > 1%`);
  add('STRESS-API-2', t, m.s5xx ? 'fail' : 'pass', { requests: m.count, s5xx: m.s5xx }, m.s5xx ? `${m.s5xx} 5xx answers under load` : '');
  slower('STRESS-API-3', t, m.p95, previous?.api?.[t]?.p95, 'api metrics');
}

// Phase ui — up to 5 contexts (the owner's storage state) load the pages for duration/3 seconds.
const ui = Object.fromEntries(pages.map((p) => [p.target, { loads: 0, failed: 0, s5xx: 0, page_errors: 0, lat: [] }]));
let uiSkip = !pages.length ? 'no pages' : '';
if (!uiSkip) {
  try {
    const b = await launch();
    const end = Date.now() + Math.max(1, Math.round(duration / 3)) * 1000;
    let blocked = 0;
    const runner = async (k) => {
      const context = await b.newContext({ viewport: { width: 1280, height: 800 }, ...(session ? { storageState: session.state } : {}) });
      await context.route('**/*', (r) => (local(r.request().url()) ? r.continue() : (blocked++, r.abort())));
      const page = await context.newPage();
      let cur = null;
      page.on('response', (r) => { if (cur && r.status() >= 500 && sameOrigin(r.url())) ui[cur].s5xx++; });
      page.on('pageerror', () => { if (cur) ui[cur].page_errors++; });
      for (let i = k; Date.now() < end; i++) {
        const p = pages[i % pages.length]; cur = p.target; const m = ui[cur];
        const s = Date.now();
        try {
          const res = await page.goto(new URL(p.path, base).href, { waitUntil: 'load', timeout: 30000 });
          if (!res || res.status() >= 400) m.failed++; else { m.loads++; m.lat.push(Date.now() - s); }
        } catch { m.failed++; }
      }
      cur = null;
      await context.close();
    };
    await Promise.all(Array.from({ length: contexts }, (_, k) => runner(k)));
    if (blocked) notes.push(`${blocked} requests to hosts other than localhost were blocked in the ui phase`);
  } catch (e) { uiSkip = msg(e).startsWith('playwright unavailable') ? 'playwright unavailable' : `ui phase failed: ${msg(e)}`; }
}
const metricsUi = Object.fromEntries(Object.entries(ui).map(([k, m]) => [k,
  { loads: m.loads, failed: m.failed, p50: pct(m.lat, 50), p95: pct(m.lat, 95), s5xx: m.s5xx, page_errors: m.page_errors }]));
if (uiSkip) { add('STRESS-UI-1', '*', 'skipped', {}, uiSkip); add('STRESS-UI-2', '*', 'skipped', {}, uiSkip); }
else {
  for (const [t, m] of Object.entries(metricsUi)) {
    if (!m.loads && !m.failed) { add('STRESS-UI-1', t, 'skipped', {}, 'no load was attempted'); add('STRESS-UI-2', t, 'skipped', {}, 'no load was attempted'); continue; }
    const bad = m.failed + m.s5xx + m.page_errors;
    add('STRESS-UI-1', t, bad ? 'fail' : 'pass', { loads: m.loads, failed: m.failed, s5xx: m.s5xx, page_errors: m.page_errors, contexts },
      bad ? `${m.failed} failed loads, ${m.s5xx} same-origin 5xx, ${m.page_errors} page errors under ${contexts} contexts` : '');
    slower('STRESS-UI-2', t, m.p95, previous?.ui?.[t]?.p95, 'ui metrics');
  }
}
await browser?.close().catch(() => {});

// Phase health — 5 s after the load, the app root must answer 2xx/3xx within 10 s.
await sleep(5000);
{
  const s = Date.now();
  try {
    const res = await http(base.pathname || '/', 10000);
    const ok = res.status >= 200 && res.status < 400;
    add('STRESS-HEALTH-1', base.pathname || '/', ok ? 'pass' : 'fail', { status: res.status, ms: Date.now() - s }, ok ? '' : `answered ${res.status} after the load`);
  } catch (e) {
    add('STRESS-HEALTH-1', base.pathname || '/', 'fail', { status: null, ms: Date.now() - s }, `no answer within 10 s after the load (${e.name === 'TimeoutError' ? 'timeout' : 'network error'})`);
  }
}

// ------------------------------------------------------------------ output ----
const counts = Object.fromEntries(['critical', 'high', 'medium', 'low'].map((s) => [s, checks.filter((c) => c.status === 'fail' && c.severity === s).length]));
counts.skipped = checks.filter((c) => c.status === 'skipped').length;
counts.passed = checks.filter((c) => c.status === 'pass').length;
const out = flags.out ?? join(WORK, 'stress', build);
mkdirSync(out, { recursive: true });
const file = join(out, 'stress.json');
const doc = { build, generated_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), base: base.origin,
  config: { concurrency, duration_s: duration, pages: pagesN, requests_cap: CAP.requests }, counts, checks,
  metrics: { api: metricsApi, ui: metricsUi }, notes };
writeFileSync(`${file}.tmp`, `${JSON.stringify(doc, null, 2)}\n`);
renameSync(`${file}.tmp`, file);
console.log(JSON.stringify({ stress: file, checks: checks.length, failed: checks.filter((c) => c.status === 'fail').length, notes }));
