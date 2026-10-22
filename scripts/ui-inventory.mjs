#!/usr/bin/env node
// ui-inventory.mjs — a read-only map of the nested product's UI for one build: every
// reachable page pattern with its headings, navigation, buttons, tabs, form fields and
// links, plus an accessibility snapshot and a screenshot, and the page's signals: console
// errors, failed same-origin requests and load timing. Two maps diff into what was added,
// removed, renamed or moved, and which signals are new (ui-diff.mjs). Rationale:
// docs/change-awareness.md.
//
//   node ui-inventory.mjs <out-dir> [--base <app url>] [--max-pages 60] [--depth 3] [--timing-samples 1]
//
// Signs in with E2E_USER_OWNER_USERNAME / _PASSWORD (work/env/credentials.env), then only
// navigates: it follows same-origin links and clicks navigation items and tabs (each name
// once). It never clicks anything else, types, or submits. Signals are only listened to
// while a page is visited; --timing-samples > 1 reloads the page for more timing samples.
// Every same-origin API request the signed-in pages make is recorded once per method and
// path shape (`api_requests`) — method and path only, never headers or bodies — for the
// security run's replay (docs/security.md). Each page's forms (`forms`: name, submit button,
// fields with their DOM constraints) are read from attributes only, for the validation planner
// (validation-plan.mjs, docs/validation.md).

import { mkdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { examplePath, pattern, STATIC } from './lib/url-pattern.mjs';
import { DANGER } from './lib/danger.mjs';

const args = process.argv.slice(2);
const out = args.find((a) => !a.startsWith('--') && !/^\d+$/.test(a) && !a.startsWith('http'));
const opt = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d; };
if (!out) { console.error('usage: ui-inventory.mjs <out-dir> [--base URL] [--max-pages N] [--depth N]'); process.exit(2); }
const base = new URL(opt('base', process.env.APP_URL ?? 'http://localhost'));
if (!['localhost', '127.0.0.1'].includes(base.hostname)) { console.error(`refusing ${base}: only the nested product`); process.exit(2); }
const maxPages = Number(opt('max-pages', 60));
const maxDepth = Number(opt('depth', 3));
const samples = Math.max(1, Number(opt('timing-samples', 1)) || 1);
const user = process.env.E2E_USER_OWNER_USERNAME;
const pass = process.env.E2E_USER_OWNER_PASSWORD;

const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const req = createRequire(process.env.QI_PLAYWRIGHT_FROM ?? join(work, 'suite', 'package.json'));
let pw;
try { pw = req('playwright-core'); } catch { pw = createRequire(req.resolve('@e2e-dev/web'))('playwright-core'); }

const SKIP = /(log-?out|sign-?out|logout|\/api\/|\/auth\/|download|\.(zip|tar|gz|png|jpg|pdf|json)$)/i;

mkdirSync(join(out, 'shots'), { recursive: true });
mkdirSync(join(out, 'aria'), { recursive: true });
const slug = (p) => (p === '/' ? 'root' : p.replace(/^\//, '').replace(/[^A-Za-z0-9]+/g, '_')).slice(0, 80);

const browser = await pw.chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
// Time to the first visible h1 / main landmark from navigation start; sets one window field only.
await context.addInitScript(() => {
  const mark = () => {
    const e = document.querySelector('h1,main,[role=main]');
    if (!e || !(e.checkVisibility?.() ?? !!e.offsetParent)) return false;
    window.__qiFirstContent = Math.round(performance.now());
    return true;
  };
  if (!mark()) { const o = new MutationObserver(() => { if (mark()) o.disconnect(); }); o.observe(document, { childList: true, subtree: true }); }
});
const page = await context.newPage();

// Signals of the page being visited (null between pages): console errors and uncaught
// exceptions, and same-origin requests that ended >= 400 or failed. Volatile parts (URLs,
// ids, numbers) collapse the way page patterns do, so one build yields the same set twice.
// Chromium's "Failed to load resource" console line repeats a failed request, and an
// aborted request is a side effect of navigating: both are skipped.
let sig = null;
const vol = (s) => String(s ?? '')
  .replace(/https?:\/\/[^\s'"()<>]+/g, (x) => { try { const u = new URL(x); return (u.origin === base.origin ? '' : u.origin) + pattern(u); } catch { return x; } })
  .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, ':id')
  .replace(/\b(?=[0-9a-f]*\d)[0-9a-f]{8,}\b/gi, ':id')
  .replace(/\d+/g, 'N').replace(/\s+/g, ' ').trim().slice(0, 300);
const sameOrigin = (u) => { try { return new URL(u).origin === base.origin; } catch { return false; } };
const failed = (method, url, status, error) => JSON.stringify({ method, path: pattern(new URL(url)), status, ...(error ? { error } : {}) });
page.on('console', (m) => { if (sig && m.type() === 'error' && !/^Failed to load resource/.test(m.text())) sig.errors.add(vol(m.text())); });
page.on('pageerror', (e) => { if (sig) sig.errors.add(vol(`${e?.name || 'Error'}: ${String(e?.message ?? e).split('\n')[0]}`)); });
page.on('response', (r) => { if (sig && r.status() >= 400 && sameOrigin(r.url())) sig.requests.add(failed(r.request().method(), r.url(), r.status())); });
page.on('requestfailed', (r) => {
  const err = r.failure()?.errorText ?? 'failed';
  if (sig && sameOrigin(r.url()) && !/ERR_ABORTED/.test(err)) sig.requests.add(failed(r.method(), r.url(), 'failed', err));
});
const timing = () => page.evaluate(() => {
  const n = performance.getEntriesByType('navigation')[0];
  const ms = (x) => (n && x > 0 ? Math.round(x - n.startTime) : null);
  return { dcl: ms(n?.domContentLoadedEventEnd), load: ms(n?.loadEventEnd), first: window.__qiFirstContent ?? null };
}).catch(() => ({}));
const median = (xs) => {
  const s = xs.filter((x) => typeof x === 'number').sort((p, q) => p - q);
  if (!s.length) return null;
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : Math.round((s[m - 1] + s[m]) / 2);
};
const settle = async () => { await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {}); await page.waitForTimeout(500); };

async function signIn() {
  await page.goto(base.href, { waitUntil: 'domcontentloaded' });
  await settle();
  const pwd = page.locator('input[type=password]');
  if (!(await pwd.count())) return 'already';
  if (!user || !pass) throw new Error('sign-in page shown but E2E_USER_OWNER_USERNAME/PASSWORD are not set');
  await page.locator('input[type=text]:visible, input[type=email]:visible, input[name=username]').first().fill(user);
  await pwd.first().fill(pass);
  await Promise.all([page.waitForURL((u) => u.origin === base.origin, { timeout: 30000 }), pwd.first().press('Enter')]);
  await settle();
  return 'signed-in';
}

// Everything the user can see and act on, outside repeated data rows (lists, tables).
const extract = () => {
  const vis = (e) => e.checkVisibility?.({ visibilityProperty: true, opacityProperty: true }) ?? !!e.offsetParent;
  const clean = (s) => (s ?? '').replace(/\s+/g, ' ').trim().slice(0, 80);
  const name = (e) => clean(e.getAttribute('aria-label') || (e.getAttribute('aria-labelledby') && document.getElementById(e.getAttribute('aria-labelledby'))?.innerText) || e.innerText || e.getAttribute('title') || e.getAttribute('placeholder') || e.value);
  // Repeated data — list rows, table rows, and cards (a clickable that wraps a heading) — is
  // the instance's content, not the product's UI.
  const card = (e) => { const c = e.closest('button,[role=button],a'); return !!c && !!c.querySelector('h1,h2,h3,h4,[role=heading]'); };
  const inData = (e) => !e.closest('nav,[role=navigation]') && (!!e.closest('li,tr,[role=row],[role=listitem],[role=gridcell],[role=option],[role=article],[role=group]') || card(e) || (e.matches('h1,h2,h3,h4,[role=heading]') && card(e.parentElement ?? e)));
  const pick = (sel, f = name) => [...document.querySelectorAll(sel)].filter((e) => vis(e) && !inData(e)).map(f).filter(Boolean);
  const label = (e) => clean((e.id && document.querySelector(`label[for="${CSS.escape(e.id)}"]`)?.innerText) || e.getAttribute('aria-label') || e.getAttribute('placeholder') || e.getAttribute('name'));
  const uniq = (a) => [...new Set(a)];
  return {
    title: document.title,
    headings: uniq(pick('h1,h2,h3,[role=heading]')),
    nav: uniq([...document.querySelectorAll('nav a,[role=navigation] a,aside a')].filter(vis).map(name).filter(Boolean)),
    buttons: uniq(pick('button,[role=button],input[type=submit]')),
    tabs: uniq(pick('[role=tab]')),
    inputs: uniq(pick('input:not([type=hidden]):not([type=submit]),textarea,select,[role=combobox],[role=switch],[role=checkbox]', label)),
    links: uniq([...document.querySelectorAll('a[href]')].filter((e) => vis(e) && !inData(e)).map((e) => `${name(e)} → ${new URL(e.href, location.href).pathname}`).filter((s) => !s.startsWith(' →'))),
    hrefs: [...document.querySelectorAll('a[href]')].map((e) => e.href),
  };
};

// Forms and their fields' constraints, from DOM attributes only (never typed into or submitted),
// for validation-plan.mjs. Label and repeated-data rules as in extract(), but a field labelled
// only by its name attribute is left out: a test cannot reach it by label. A trailing required
// asterisk is dropped from a label. A dialog without a <form> whose fields share one primary
// button counts as a form too.
const extractForms = () => {
  const vis = (e) => e.checkVisibility?.({ visibilityProperty: true, opacityProperty: true }) ?? !!e.offsetParent;
  const clean = (s) => (s ?? '').replace(/\s+/g, ' ').trim().slice(0, 80);
  const name = (e) => clean(e.getAttribute('aria-label') || (e.getAttribute('aria-labelledby') && document.getElementById(e.getAttribute('aria-labelledby'))?.innerText) || e.innerText || e.getAttribute('title') || e.getAttribute('placeholder') || e.value);
  const card = (e) => { const c = e.closest('button,[role=button],a'); return !!c && !!c.querySelector('h1,h2,h3,h4,[role=heading]'); };
  const inData = (e) => !e.closest('nav,[role=navigation]') && (!!e.closest('li,tr,[role=row],[role=listitem],[role=gridcell],[role=option],[role=article],[role=group]') || card(e));
  const label = (e) => clean((e.id && document.querySelector(`label[for="${CSS.escape(e.id)}"]`)?.innerText) || e.getAttribute('aria-label') || e.getAttribute('placeholder')).replace(/\s*\*+$/, '');
  const num = (v) => (v == null || v === '' ? null : Number.isFinite(Number(v)) ? Number(v) : v);
  const FIELD = 'input:not([type=hidden]):not([type=submit]):not([type=file]):not([type=button]):not([type=reset]):not([type=image]),textarea,select';
  const fields = (root) => [...root.querySelectorAll(FIELD)].filter((e) => vis(e) && !inData(e) && label(e)).map((e) => {
    const len = (k) => { const v = Number(e.getAttribute(k)); return e.hasAttribute(k) && v >= 0 ? v : null; };
    return { label: label(e), type: e.tagName === 'INPUT' ? (e.getAttribute('type') || 'text').toLowerCase() : e.tagName.toLowerCase(),
      name: e.getAttribute('name') || null, required: e.required || e.getAttribute('aria-required') === 'true', minlength: len('minlength'), maxlength: len('maxlength'),
      min: num(e.getAttribute('min')), max: num(e.getAttribute('max')), step: num(e.getAttribute('step')), pattern: e.getAttribute('pattern') || null };
  });
  const buttons = (root) => [...root.querySelectorAll('button,[role=button],input[type=submit]')].filter(vis);
  const submitOf = (f) => {
    const own = buttons(f).concat(f.id ? [...document.querySelectorAll(`[form="${CSS.escape(f.id)}"]`)].filter(vis) : []);
    const s = own.filter((b) => (b.tagName === 'BUTTON' && (b.getAttribute('type') ?? 'submit') === 'submit') || b.matches('input[type=submit]'));
    const b = s.length ? s[0] : own.length === 1 ? own[0] : null;
    return b ? name(b) || null : null;
  };
  const title = (f, i) => clean(f.getAttribute('aria-label') || (f.getAttribute('aria-labelledby') && document.getElementById(f.getAttribute('aria-labelledby'))?.innerText)
    || f.querySelector('h1,h2,h3,h4,legend,[role=heading]')?.innerText) || `form-${i}`;
  const out = [];
  [...document.querySelectorAll('form,[role=form]')].filter((f) => vis(f) && !f.parentElement?.closest('form,[role=form]')).forEach((f) => {
    const fs = fields(f);
    if (fs.length) out.push({ name: title(f, out.length + 1), submit: submitOf(f), fields: fs });
  });
  for (const d of [...document.querySelectorAll('dialog[open],[role=dialog],[role=alertdialog]')].filter(vis)) {
    if (d.querySelector('form,[role=form]')) continue;
    const fs = fields(d);
    const primary = buttons(d).filter((b) => !/cancel|close|back|dismiss|^×$|^x$/i.test(name(b)) && name(b));
    if (fs.length && primary.length === 1) out.push({ name: title(d, out.length + 1), submit: name(primary[0]), fields: fs, dialog: true });
  }
  return out;
};

// Navigation items and tabs: clicked once per distinct name, from the page they appear on.
const NAV = 'nav button,[role=navigation] button,nav [role=link],[role=navigation] [role=link],[role=tab],[role=menuitem]';
const clicked = new Set();
// An item that opens a new window leaves the app (external docs): close it, keep crawling.
context.on('page', (p) => { if (p !== page) p.close().catch(() => {}); });
async function discover(url) {
  const found = [];
  const names = await page.locator(NAV).evaluateAll((els) => els.filter((e) => e.checkVisibility?.() ?? !!e.offsetParent)
    .map((e) => (e.getAttribute('aria-label') || e.innerText || '').replace(/\s+/g, ' ').trim()).filter(Boolean));
  for (const n of [...new Set(names)]) {
    if (clicked.has(n) || DANGER.test(n) || /expand|collapse|toggle|menu/i.test(n)) continue;
    clicked.add(n);
    try {
      // A fresh load per click: a dialog or drawer an earlier item opened must not cover this one.
      await page.goto(url.href, { waitUntil: 'domcontentloaded' }); await settle();
      await page.locator(NAV).filter({ visible: true }).and(page.getByRole(/tab/.test(n) ? 'tab' : 'button', { name: n, exact: true })
        .or(page.getByRole('tab', { name: n, exact: true })).or(page.getByRole('link', { name: n, exact: true }))
        .or(page.getByRole('menuitem', { name: n, exact: true }))).first().click({ timeout: 5000 });
      await settle();
      const u = new URL(page.url());
      if (u.origin === base.origin) { u.hash = ''; u.search = ''; found.push([u, n]); }
    } catch (e) { if (process.env.QI_DEBUG) console.error(`nav ${n}: ${String(e.message).split("\n")[0]}`); }
  }
  return found;
}

const routes = {};
const signIn_ = await signIn();
const api = new Map();
page.on('request', (r) => {
  if (!['xhr', 'fetch'].includes(r.resourceType()) || api.size >= 200) return;
  let u; try { u = new URL(r.url()); } catch { return; }
  if (u.origin !== base.origin || STATIC.test(u.pathname)) return;
  const k = `${r.method()} ${pattern(u)}`;
  if (!api.has(k)) api.set(k, { method: r.method(), path_pattern: pattern(u), example_path: examplePath(u) });
});
const queue = [[new URL(base.href), 0]];
const seen = new Set();
while (queue.length && Object.keys(routes).length < maxPages) {
  const [url, depth] = queue.shift();
  const pat = pattern(url);
  if (seen.has(pat)) continue;
  seen.add(pat);
  sig = { errors: new Set(), requests: new Set() };
  try {
    await page.goto(url.href, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await settle();
  } catch (e) { sig = null; routes[pat] = { example: url.pathname, error: String(e.message).slice(0, 200) }; continue; }
  const landed = new URL(page.url());
  if (landed.origin !== base.origin) { sig = null; routes[pat] = { example: url.pathname, redirected: landed.origin }; continue; }
  const times = [await timing()];
  const data = await page.evaluate(extract);
  const s = slug(pat);
  await page.screenshot({ path: join(out, 'shots', `${s}.png`) }).catch(() => {});
  const aria = await page.locator('body').ariaSnapshot({ timeout: 10000 }).catch(() => '');
  writeFileSync(join(out, 'aria', `${s}.yml`), aria);
  for (let i = 1; i < samples; i++) {
    try { await page.reload({ waitUntil: 'load', timeout: 30000 }); await settle(); times.push(await timing()); } catch { break; }
  }
  const { hrefs, ...rest } = data;
  const med = (k) => median(times.map((t) => t[k]));
  routes[pat] = { example: url.pathname, landed: landed.pathname === url.pathname ? undefined : landed.pathname, ...rest, shot: `shots/${s}.png`, aria: `aria/${s}.yml`,
    console_errors: [...sig.errors].sort(), failed_requests: [...sig.requests].sort().map((x) => JSON.parse(x)),
    timing: { dom_content_loaded_ms: med('dcl'), load_ms: med('load'), first_content_ms: med('first'), samples: times.length } };
  routes[pat].forms = await page.evaluate(extractForms).catch(() => []);
  sig = null;
  if (depth >= maxDepth) continue;
  for (const [u, via] of await discover(url)) {
    if (!seen.has(pattern(u))) { queue.push([u, depth + 1]); routes[pat].navigates ??= {}; routes[pat].navigates[via] = pattern(u); }
  }
  for (const h of hrefs) {
    let u; try { u = new URL(h); } catch { continue; }
    if (u.origin !== base.origin || SKIP.test(u.pathname)) continue;
    u.hash = ''; u.search = '';
    if (!seen.has(pattern(u))) queue.push([u, depth + 1]);
  }
}
await browser.close();

const api_requests = [...api.values()].sort((a, b) => `${a.path_pattern} ${a.method}`.localeCompare(`${b.path_pattern} ${b.method}`));
const inventory = { base: base.origin, generated_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), sign_in: signIn_, build: process.env.QI_BUILD ?? null, routes, api_requests };
writeFileSync(join(out, 'inventory.json'), `${JSON.stringify(inventory, null, 2)}\n`);
console.log(JSON.stringify({ out, routes: Object.keys(routes).length, api_requests: api_requests.length, sign_in: signIn_ }));
