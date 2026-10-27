#!/usr/bin/env node
// ui-sweep.mjs — a read-only walk of every page of the UI map at a few viewports, hunting UI
// and visual defects: the deterministic checks of lib/ui-checks.mjs, layout shift, console
// errors, failed same-origin requests, axe-core's WCAG 2 A/AA rules (when the suite has it),
// a full-page screenshot per page and viewport, and whether that shot changed since the
// previous sweep. The design findings register is built from it (design-findings.mjs).
// Rationale: docs/ui-sweep.md.
//
//   node ui-sweep.mjs <inventory.json> --build <c> [--out <dir>] [--previous <dir>]
//        [--viewports 1440x900,768x1024,390x844] [--base URL] [--max-pages 60] [--pattern P] [--dry-run]
//
// --pattern sweeps only that page of the UI map (a design finding's recheck, docs/ui-sweep.md →
// Recheck); a pattern the map does not have, or that the map skips (no example, an error, a
// redirect), is exit 2.
// --dry-run prints the plan (pages × viewports, out paths) with no browser and no network.
// Default --out: work/design/<build>; --viewports: config `ui_sweep_viewports`, else the above
// (WxH, at most 4; a viewport under 600 px wide is a touch phone). Writes <out>/sweep.json
// ({build, generated_utc, base, viewports, axe, pages:[{pattern, example, viewport, shot,
// changed, diff, cls, axe, findings, error?}], counts:{major, minor, pages}, notes}) and
// <out>/shots/; prints {sweep, pages, findings, major, minor, changed, new, notes}. `changed`
// is null for a page the previous sweep has no shot of; a page's `axe` is true only when
// axe-core ran on it (the top-level `axe`: axe-core was available). Exit 2: usage, or a base
// off localhost; exit 1: the owner cannot sign in (an environment failure); exit 3: no browser
// (playwright-core missing or Chromium does not launch) — {error: "no browser: …"} on stdout.
//
// Signs in as the owner (E2E_USER_OWNER_*, env or work/env/credentials.env; kept in memory),
// then only navigates: it never clicks, types or submits.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pattern } from './lib/url-pattern.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const flags = {}; const pos = [];
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--dry-run') flags.dry = true;
  else if (a.startsWith('--')) flags[a.slice(2)] = process.argv[++i];
  else pos.push(a);
}
const usage = 'usage: ui-sweep.mjs <inventory.json> --build B [--out DIR] [--previous DIR] [--viewports WxH,…] [--base URL] [--max-pages N] [--pattern P] [--dry-run]';
const die = (m) => { console.error(`ui-sweep: ${m}`); process.exit(2); };
if (!pos[0]) { console.error(usage); process.exit(2); }

const WORK = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const sh = (expr) => {
  try {
    return execFileSync('bash', ['-c', `CONFIG="$WORK/CONFIG.md"; . "$LIB/config.sh"; . "$LIB/profile.sh"; ${expr}`],
      { env: { ...process.env, WORK, LIB: join(here, 'lib') }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return ''; }
};
const notes = [];
const DEFAULT_VP = '1440x900,768x1024,390x844';
const parseVp = (s) => {
  const list = [...new Set(String(s).split(',').map((x) => x.trim()).filter(Boolean))];
  if (!list.length || list.length > 4 || !list.every((x) => /^\d{3,4}x\d{3,4}$/.test(x))) return null;
  return list.map((x) => { const [w, h] = x.split('x').map(Number); return { w, h, id: x }; });
};
let viewports;
if (flags.viewports !== undefined) {
  viewports = parseVp(flags.viewports);
  if (!viewports) die(`--viewports '${flags.viewports}': 1 to 4 of WxH (3-4 digits each), comma-separated`);
} else {
  const c = sh('reg ui_sweep_viewports');
  viewports = c ? parseVp(c) : null;
  if (c && !viewports) notes.push(`ui_sweep_viewports '${c}' is invalid — the default ${DEFAULT_VP} is used`);
  viewports ??= parseVp(DEFAULT_VP);
}
const maxPages = Number(flags['max-pages'] ?? 60);
if (!Number.isInteger(maxPages) || maxPages < 1) die(`--max-pages '${flags['max-pages']}' is not a positive integer`);

let inv;
try { inv = JSON.parse(readFileSync(pos[0], 'utf8')); } catch (e) { die(`cannot read the UI map ${pos[0]}: ${String(e.message).split('\n')[0]}`); }
const profile = (() => { try { return JSON.parse(readFileSync(join(sh('profile_dir'), 'profile.json'), 'utf8')); } catch { return {}; } })();
let base;
try { base = new URL(flags.base ?? process.env.APP_URL ?? inv.base ?? profile.app?.url ?? 'http://localhost'); } catch { die('the base is not a URL'); }
if (!['localhost', '127.0.0.1'].includes(base.hostname)) { console.error(`refusing ${base.origin}: only the nested product on localhost`); process.exit(2); }
const build = flags.build ?? inv.build;
if (!build || !/^[A-Za-z0-9._+-]+$/.test(build) || build.startsWith('.')) die(`--build '${build ?? ''}' is missing or not a plain build id`);
const out = resolve(flags.out ?? join(WORK, 'design', build));
const previous = flags.previous ? resolve(flags.previous) : null;

const slug = (p) => (p === '/' ? 'root' : p.replace(/^\//, '').replace(/[^A-Za-z0-9]+/g, '_')).slice(0, 80);
const routes = Object.entries(inv.routes ?? {}).filter(([p]) => flags.pattern === undefined || p === flags.pattern);
if (flags.pattern !== undefined && !routes.length) die(`--pattern '${flags.pattern}' is not a page of the UI map ${pos[0]}`);
const skipped = routes.filter(([, r]) => !r?.example || r.error || r.redirected)
  .map(([p, r]) => ({ pattern: p, reason: !r?.example ? 'no example path' : r.error ? `errored in the UI map: ${String(r.error).slice(0, 80)}` : `redirected to ${r.redirected}` }));
const pages = routes.filter(([, r]) => r?.example && !r.error && !r.redirected).slice(0, maxPages);
if (flags.pattern !== undefined && !pages.length) die(`--pattern '${flags.pattern}' cannot be swept: ${skipped[0].reason}`);
if (routes.length - skipped.length > maxPages) notes.push(`${routes.length - skipped.length - maxPages} pages over --max-pages ${maxPages} not swept`);
const shotOf = (p, v) => `shots/${slug(p)}@${v.id}.png`;
const visits = viewports.flatMap((v) => pages.map(([p, r]) => ({ pattern: p, example: r.example, vp: v, shot: shotOf(p, v) })));

if (flags.dry) {
  console.log(JSON.stringify({
    build, base: base.origin, out, previous, viewports: viewports.map((v) => v.id), max_pages: maxPages,
    pages: visits.map((x) => ({ pattern: x.pattern, example: x.example, viewport: x.vp.id, shot: join(out, x.shot),
      previous_shot: previous && existsSync(join(previous, x.shot)) ? join(previous, x.shot) : null })),
    skipped, notes,
  }, null, 2));
  process.exit(0);
}

// ------------------------------------------------------------------ the run ----
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

const msg = (e) => String(e?.message ?? e).split('\n')[0].slice(0, 160);
// No browser is this module's failure, not the environment's: exit 3, never 1.
const noBrowser = (e) => { console.log(JSON.stringify({ error: `no browser: ${msg(e)}` })); process.exit(3); };
const req = createRequire(process.env.QI_PLAYWRIGHT_FROM ?? join(WORK, 'suite', 'package.json'));
let pw;
try {
  try { pw = req('playwright-core'); } catch { pw = createRequire(req.resolve('@e2e-dev/web'))('playwright-core'); }
} catch { noBrowser('playwright-core is not installed in work/suite (scripts/suite.sh init installs it)'); }
let axeSource = null;
try { axeSource = createRequire(join(WORK, 'suite', 'package.json'))('axe-core').source; } catch { notes.push('axe-core unavailable: no a11y rules run (scripts/suite.sh init installs it)'); }
// The checks are one self-contained browser function, loaded as text so no module flavour matters.
const qiUiChecks = new Function(`${readFileSync(join(here, 'lib', 'ui-checks.mjs'), 'utf8').replace(/^export\s+(?=(?:async\s+)?function\s+qiUiChecks\b)/m, '')}\nreturn qiUiChecks;`)();

const sameOrigin = (u) => { try { return new URL(u).origin === base.origin; } catch { return false; } };
// Volatile parts of a console line collapse as in ui-inventory.mjs (URLs to their pattern, ids,
// numbers): one target per error kind, and no query string (a token) is carried over.
const vol = (s) => String(s ?? '')
  .replace(/https?:\/\/[^\s'"()<>]+/g, (x) => { try { const u = new URL(x); return (u.origin === base.origin ? '' : u.origin) + pattern(u); } catch { return x; } })
  .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, ':id')
  .replace(/\b(?=[0-9a-f]*\d)[0-9a-f]{8,}\b/gi, ':id')
  .replace(/\d+/g, 'N').replace(/\s+/g, ' ').trim().slice(0, 200);

let browser;
try { browser = await pw.chromium.launch({ headless: true }); } catch (e) { noBrowser(e); }
const settle = async (page) => { await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {}); await page.waitForTimeout(500); };
const pwdVisible = async (page) => (await page.locator('input[type=password]').filter({ visible: true }).count()) > 0;
// Cumulative layout shift, as the web-vitals session windows (gap < 1 s, window <= 5 s).
const clsInit = () => {
  window.__qiCls = 0;
  let sum = 0; let first = 0; let last = 0;
  try {
    new PerformanceObserver((l) => {
      for (const e of l.getEntries()) {
        if (e.hadRecentInput) continue;
        if (sum && e.startTime - last < 1000 && e.startTime - first < 5000) sum += e.value; else { sum = e.value; first = e.startTime; }
        last = e.startTime; window.__qiCls = Math.max(window.__qiCls, sum);
      }
    }).observe({ type: 'layout-shift', buffered: true });
  } catch { window.__qiCls = null; }
};

async function signIn(page) {
  await page.goto(base.href, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await settle(page);
  if (!(await pwdVisible(page))) return;
  if (!user || !pass) throw new Error('the sign-in page is shown but E2E_USER_OWNER_USERNAME/PASSWORD are not set');
  const pwd = page.locator('input[type=password]');
  await page.locator('input[type=text]:visible, input[type=email]:visible, input[name=username]').first().fill(user);
  await pwd.first().fill(pass);
  await Promise.all([page.waitForURL((u) => u.origin === base.origin, { timeout: 30000 }), pwd.first().press('Enter')]);
  await settle(page);
  if (await pwdVisible(page)) throw new Error('owner sign-in failed');
}

// Two shots compared on a canvas in a page that loads nothing (every request aborted).
let cmpPage = null;
async function compare(a, b) {
  if (!cmpPage) { cmpPage = await (await browser.newContext()).newPage(); await cmpPage.route('**', (r) => r.abort()); }
  const uri = (p) => `data:image/png;base64,${readFileSync(p).toString('base64')}`;
  return cmpPage.evaluate(async ({ a, b }) => {
    const load = async (d) => { const i = new Image(); i.src = d; await i.decode(); return i; };
    const [x, y] = [await load(a), await load(b)];
    if (x.naturalWidth !== y.naturalWidth || x.naturalHeight !== y.naturalHeight) return 1;
    const w = x.naturalWidth; const h = Math.min(x.naturalHeight, 12000); // canvas limits: the top 12000 rows
    const c = document.createElement('canvas'); c.width = w; c.height = h;
    const g = c.getContext('2d', { willReadFrequently: true });
    g.drawImage(x, 0, 0); const p = g.getImageData(0, 0, w, h).data;
    g.clearRect(0, 0, w, h); g.drawImage(y, 0, 0); const q = g.getImageData(0, 0, w, h).data;
    let n = 0;
    for (let i = 0; i < p.length; i += 4) {
      if (Math.abs(p[i] - q[i]) > 16 || Math.abs(p[i + 1] - q[i + 1]) > 16 || Math.abs(p[i + 2] - q[i + 2]) > 16 || Math.abs(p[i + 3] - q[i + 3]) > 16) n++;
    }
    return n / (w * h);
  }, { a: uri(a), b: uri(b) });
}

const AXE_SEV = { critical: 'major', serious: 'major' };
async function axe(page) {
  await page.evaluate(axeSource); // CDP evaluation: a strict CSP does not block it
  const res = await page.evaluate(async () => {
    const r = await window.axe.run(document, { runOnly: ['wcag2a', 'wcag2aa'], resultTypes: ['violations'] });
    return r.violations.map((v) => ({ id: v.id, impact: v.impact, help: v.help,
      nodes: v.nodes.slice(0, 40).map((n) => (n.target.length === 1 && typeof n.target[0] === 'string' ? n.target[0] : null)) }));
  });
  const found = [];
  for (const v of res) {
    const desc = await page.evaluate(qiUiChecks, { describe: v.nodes.map((s) => s ?? ':not(*)') });
    const seen = new Set();
    for (const d of desc) {
      const target = d?.target ?? 'an element in a frame or shadow root';
      if (seen.has(target) || seen.size >= 20) continue;
      seen.add(target);
      found.push({ check: `a11y:${v.id}`, severity: AXE_SEV[v.impact] ?? 'minor', target, text: d?.text ?? '', box: d?.box ?? null, detail: v.help });
    }
  }
  return found;
}

mkdirSync(join(out, 'shots'), { recursive: true });
const results = [];
let state; // the owner's session, signed in once and carried to the next viewport's context
for (const vp of viewports) {
  const mobile = vp.w < 600;
  const context = await browser.newContext({ viewport: { width: vp.w, height: vp.h }, deviceScaleFactor: 1, isMobile: mobile,
    hasTouch: mobile, reducedMotion: 'reduce', storageState: state });
  await context.addInitScript(clsInit);
  const page = await context.newPage();
  // A link that opens a new window leaves the app: closed, the sweep goes on.
  context.on('page', (p) => { if (p !== page) p.close().catch(() => {}); });
  try { await signIn(page); state = await context.storageState(); } catch (e) { console.error(`ui-sweep: ${msg(e)}`); await browser.close(); process.exit(1); }
  let sig = null;
  page.on('console', (m) => { if (sig && m.type() === 'error' && !/^Failed to load resource/.test(m.text())) sig.errors.add(vol(m.text())); });
  page.on('pageerror', (e) => { if (sig) sig.errors.add(vol(`${e?.name || 'Error'}: ${String(e?.message ?? e).split('\n')[0]}`)); });
  page.on('response', (r) => { if (sig && r.status() >= 400 && sameOrigin(r.url())) sig.requests.set(`${r.request().method()} ${pattern(new URL(r.url()))} → ${r.status()}`, String(r.status())); });
  page.on('requestfailed', (r) => {
    const err = r.failure()?.errorText ?? 'failed';
    if (sig && sameOrigin(r.url()) && !/ERR_ABORTED/.test(err)) sig.requests.set(`${r.method()} ${pattern(new URL(r.url()))} → failed`, err);
  });
  for (const v of visits.filter((x) => x.vp === vp)) {
    const entry = { pattern: v.pattern, example: v.example, viewport: vp.id, shot: null, changed: null, diff: null, cls: null, axe: false, findings: [] };
    results.push(entry);
    sig = { errors: new Set(), requests: new Map() };
    try {
      await page.goto(new URL(v.example, base).href, { waitUntil: 'domcontentloaded', timeout: 30000 });
      await settle(page);
      const landed = new URL(page.url());
      if (landed.origin !== base.origin) { entry.error = `left the product for ${landed.origin}`; continue; }
      if (await pwdVisible(page)) { entry.error = 'the sign-in page is shown (session lost)'; continue; }
      const f = await page.evaluate(qiUiChecks, { mobile, minTap: 24 });
      entry.cls = await page.evaluate(() => (window.__qiCls == null ? null : Math.round(window.__qiCls * 1000) / 1000));
      if (entry.cls > 0.1) f.push({ check: 'layout-shift', severity: 'minor', target: 'the page', text: '', box: null, detail: `CLS ${entry.cls}` });
      // entry.axe: the a11y checks ran here — only then can a sweep resolve an a11y finding of this page.
      if (axeSource) { try { f.push(...await axe(page)); entry.axe = true; } catch (e) { notes.push(`axe on ${v.pattern} @${vp.id}: ${msg(e)}`); } }
      await page.screenshot({ path: join(out, v.shot), fullPage: true, animations: 'disabled' });
      entry.shot = v.shot;
      for (const e of [...sig.errors].sort().slice(0, 20)) f.push({ check: 'console-error', severity: 'minor', target: `console: ${e.slice(0, 120)}`, text: e, box: null, detail: e });
      for (const [k, s] of [...sig.requests].sort().slice(0, 20)) f.push({ check: 'failed-request', severity: 'minor', target: k, text: '', box: null, detail: s });
      entry.findings = f;
      const prev = previous && join(previous, v.shot);
      if (prev && existsSync(prev)) {
        try { const d = await compare(prev, join(out, v.shot)); entry.diff = Math.round(d * 10000) / 10000; entry.changed = d > 0.005; } catch (e) { notes.push(`compare ${v.shot}: ${msg(e)}`); }
      }
    } catch (e) { entry.error = msg(e); } finally { sig = null; }
  }
  await context.close();
}
await browser.close();

const all = results.flatMap((p) => p.findings);
const counts = { major: all.filter((f) => f.severity === 'major').length, minor: all.filter((f) => f.severity === 'minor').length, pages: results.length };
for (const p of results.filter((x) => x.error)) notes.push(`${p.pattern} @${p.viewport}: ${p.error}`);
const sweep = { build, generated_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), base: base.origin, viewports: viewports.map((v) => v.id),
  axe: !!axeSource, pages: results, counts, notes };
const file = join(out, 'sweep.json');
writeFileSync(`${file}.tmp`, `${JSON.stringify(sweep, null, 2)}\n`); renameSync(`${file}.tmp`, file);
console.log(JSON.stringify({ sweep: file, pages: results.length, findings: all.length, major: counts.major, minor: counts.minor,
  changed: results.filter((p) => p.changed === true).length, new: results.filter((p) => p.shot && p.changed === null).length, notes }));
