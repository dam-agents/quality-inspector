#!/usr/bin/env node
// ui-inventory.mjs — a read-only map of the nested platform's UI for one build: every
// reachable page pattern with its headings, navigation, buttons, tabs, form fields and
// links, plus an accessibility snapshot and a screenshot. Two maps diff into what was
// added, removed, renamed or moved (ui-diff.mjs). Rationale: docs/change-awareness.md.
//
//   node ui-inventory.mjs <out-dir> [--base <app url>] [--max-pages 60] [--depth 3]
//
// Signs in with E2E_USER_OWNER_USERNAME / _PASSWORD (work/env/credentials.env), then only
// navigates: it follows same-origin links and clicks navigation items and tabs (each name
// once). It never clicks anything else, types, or submits.

import { mkdirSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join } from 'node:path';

const args = process.argv.slice(2);
const out = args.find((a) => !a.startsWith('--') && !/^\d+$/.test(a) && !a.startsWith('http'));
const opt = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d; };
if (!out) { console.error('usage: ui-inventory.mjs <out-dir> [--base URL] [--max-pages N] [--depth N]'); process.exit(2); }
const base = new URL(opt('base', process.env.APP_URL ?? 'http://localhost'));
if (!['localhost', '127.0.0.1'].includes(base.hostname)) { console.error(`refusing ${base}: only the nested platform`); process.exit(2); }
const maxPages = Number(opt('max-pages', 60));
const maxDepth = Number(opt('depth', 3));
const user = process.env.E2E_USER_OWNER_USERNAME;
const pass = process.env.E2E_USER_OWNER_PASSWORD;

const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const req = createRequire(process.env.QI_PLAYWRIGHT_FROM ?? join(work, 'suite', 'package.json'));
let pw;
try { pw = req('playwright-core'); } catch { pw = createRequire(req.resolve('@e2e-dev/web'))('playwright-core'); }

// One pattern per page shape: ids, numbers and hashes in the path collapse to :id.
const ID = /^(?:[0-9]+|[0-9a-f]{8,}|[0-9a-f-]{32,36}|[a-z]+-[0-9a-f]{12,}|[A-Za-z0-9_-]{20,})$/;
const pattern = (u) => u.pathname.split('/').map((s) => (ID.test(s) ? ':id' : s)).join('/') || '/';
const SKIP = /(log-?out|sign-?out|logout|\/api\/|\/auth\/|download|\.(zip|tar|gz|png|jpg|pdf|json)$)/i;

mkdirSync(join(out, 'shots'), { recursive: true });
mkdirSync(join(out, 'aria'), { recursive: true });
const slug = (p) => (p === '/' ? 'root' : p.replace(/^\//, '').replace(/[^A-Za-z0-9]+/g, '_')).slice(0, 80);

const browser = await pw.chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
const page = await context.newPage();
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

// Navigation items and tabs: clicked once per distinct name, from the page they appear on.
const NAV = 'nav button,[role=navigation] button,nav [role=link],[role=navigation] [role=link],[role=tab],[role=menuitem]';
const DANGER = /(log ?out|sign ?out|delete|remove|revoke|reset|disconnect|uninstall)/i;
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
const queue = [[new URL(base.href), 0]];
const seen = new Set();
while (queue.length && Object.keys(routes).length < maxPages) {
  const [url, depth] = queue.shift();
  const pat = pattern(url);
  if (seen.has(pat)) continue;
  seen.add(pat);
  try {
    await page.goto(url.href, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await settle();
  } catch (e) { routes[pat] = { example: url.pathname, error: String(e.message).slice(0, 200) }; continue; }
  const landed = new URL(page.url());
  if (landed.origin !== base.origin) { routes[pat] = { example: url.pathname, redirected: landed.origin }; continue; }
  const data = await page.evaluate(extract);
  const s = slug(pat);
  await page.screenshot({ path: join(out, 'shots', `${s}.png`) }).catch(() => {});
  const aria = await page.locator('body').ariaSnapshot({ timeout: 10000 }).catch(() => '');
  writeFileSync(join(out, 'aria', `${s}.yml`), aria);
  const { hrefs, ...rest } = data;
  routes[pat] = { example: url.pathname, landed: landed.pathname === url.pathname ? undefined : landed.pathname, ...rest, shot: `shots/${s}.png`, aria: `aria/${s}.yml` };
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

const inventory = { base: base.origin, generated_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), sign_in: signIn_, build: process.env.QI_BUILD ?? null, routes };
writeFileSync(join(out, 'inventory.json'), `${JSON.stringify(inventory, null, 2)}\n`);
console.log(JSON.stringify({ out, routes: Object.keys(routes).length, sign_in: signIn_ }));
