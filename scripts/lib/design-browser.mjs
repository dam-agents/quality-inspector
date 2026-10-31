// design-browser.mjs — the browser plumbing design-check.mjs and consistency.mjs share
// (docs/design-checks.md): the suite's playwright-core, the owner's sign-in, the config and profile
// reads, a browser function loaded as text, a marked crop of one element and a sheet of crops side by
// side. Node only; the page functions themselves live in lib/ui-checks.mjs and lib/design-probe.mjs.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const WORK = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
export const msg = (e) => String(e?.message ?? e).split('\n')[0].slice(0, 160);

// One expression of lib/config.sh and lib/profile.sh (`reg <key>`, `cfg <key>`, `profile_dir`,
// `profile_run …`): its stdout, '' on any failure.
export function sh(expr, { status = false } = {}) {
  try {
    const out = execFileSync('bash', ['-c', `CONFIG="$WORK/CONFIG.md"; . "$LIB/config.sh"; . "$LIB/profile.sh"; ${expr}`],
      { env: { ...process.env, WORK, LIB: here }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 90000 }).trim();
    return status ? { out, code: 0 } : out;
  } catch (e) { return status ? { out: String(e.stdout ?? '').trim(), code: e.status ?? 1, err: String(e.stderr ?? '').trim().split('\n')[0] } : ''; }
}
export const regInt = (key, def, min, max) => { const n = Number(sh(`reg ${key}`)); return Number.isInteger(n) && n >= min && n <= max ? n : def; };
export function profile() { try { return JSON.parse(readFileSync(join(sh('profile_dir'), 'profile.json'), 'utf8')); } catch { return {}; } }

// A browser function of lib/, loaded as text so no module flavour matters.
export const browserFn = (file, name) => new Function(`${readFileSync(join(here, file), 'utf8')
  .replace(new RegExp(`^export\\s+(?=(?:async\\s+)?function\\s+${name}\\b)`, 'm'), '')}\nreturn ${name};`)();

// The owner's credentials: the environment, else work/env/credentials.env (kept in memory only).
export function owner() {
  const o = {};
  try {
    for (const l of readFileSync(join(WORK, 'env', 'credentials.env'), 'utf8').split('\n')) {
      const m = /^\s*(?:export\s+)?([A-Z0-9_]+)=(.*)$/.exec(l);
      if (m) o[m[1]] = m[2].trim().replace(/^(['"])(.*)\1$/, '$2');
    }
  } catch { /* no file: env only */ }
  return { user: process.env.E2E_USER_OWNER_USERNAME ?? o.E2E_USER_OWNER_USERNAME, pass: process.env.E2E_USER_OWNER_PASSWORD ?? o.E2E_USER_OWNER_PASSWORD };
}

// playwright-core from the suite (QI_PLAYWRIGHT_FROM overrides, for the tests); null when missing.
export function playwright() {
  const req = createRequire(process.env.QI_PLAYWRIGHT_FROM ?? join(WORK, 'suite', 'package.json'));
  try { return req('playwright-core'); } catch { /* the e2e framework's own copy */ }
  try { return createRequire(req.resolve('@e2e-dev/web'))('playwright-core'); } catch { return null; }
}
export function axeSource() { try { return createRequire(join(WORK, 'suite', 'package.json'))('axe-core').source; } catch { return null; } }

export const settle = async (page, ms = 500) => { await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {}); await page.waitForTimeout(ms); };
const pwdVisible = async (page) => (await page.locator('input[type=password]').filter({ visible: true }).count()) > 0;
export { pwdVisible };
export async function signIn(page, base, { user, pass }) {
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

// A crop of the page around one element's box (page CSS px), the element outlined in red.
export async function crop(page, b, file, { margin = 40, mark = true } = {}) {
  if (!b || !(b.w > 0) || !(b.h > 0)) return null;
  const size = await page.evaluate(() => ({ w: document.documentElement.scrollWidth, h: document.documentElement.scrollHeight }));
  const x = Math.max(0, b.x - margin); const y = Math.max(0, b.y - margin);
  const clip = { x, y, width: Math.min(size.w - x, b.w + 2 * margin, 1600), height: Math.min(size.h - y, b.h + 2 * margin, 1200) };
  if (clip.width < 4 || clip.height < 4) return null;
  if (mark) {
    await page.evaluate((r) => {
      const d = document.createElement('div'); d.id = '__qi_mark';
      d.style.cssText = `position:absolute;left:${r.x - 3}px;top:${r.y - 3}px;width:${r.w + 6}px;height:${r.h + 6}px;border:3px solid #e5484d;border-radius:4px;z-index:2147483647;pointer-events:none;box-sizing:border-box`;
      document.body.appendChild(d);
    }, b).catch(() => {});
  }
  try { await page.screenshot({ path: file, clip, fullPage: true, animations: 'disabled' }); return file; } catch { return null; } finally {
    if (mark) await page.evaluate(() => document.getElementById('__qi_mark')?.remove()).catch(() => {});
  }
}

// Crops side by side with a caption each, drawn on a page that loads nothing -> one PNG.
export async function sheet(browser, items, title, file) {
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
  const cells = items.filter((i) => i.file).map((i) => `<figure><div class="img"><img src="data:image/png;base64,${readFileSync(i.file).toString('base64')}" alt=""></div><figcaption>${esc(i.caption)}</figcaption></figure>`);
  if (!cells.length) return null;
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>*{box-sizing:border-box}body{margin:0;background:#fff;color:#1d1f23;font:14px/1.4 system-ui,sans-serif;width:${Math.min(4, cells.length) * 400 + 40}px}
main{padding:16px 20px}h1{font-size:16px;margin:0 0 12px}.row{display:grid;grid-template-columns:repeat(${cells.length},minmax(0,1fr));gap:16px;align-items:start}
figure{margin:0}.img{border:1px solid #e3e5e8;border-radius:6px;padding:8px;background:#fafbfc}img{display:block;max-width:100%;max-height:420px;margin:0 auto}figcaption{font-size:12px;color:#555b63;margin-top:6px}</style></head>
<body><main><h1>${esc(title)}</h1><div class="row">${cells.join('')}</div></main></body></html>`;
  const page = await (await browser.newContext({ viewport: { width: 1000, height: 40 } })).newPage();
  try {
    await page.route('**', (r) => r.abort());
    await page.setContent(html, { waitUntil: 'load' });
    await page.evaluate(() => Promise.all([...document.images].map((i) => i.decode().catch(() => {}))));
    await page.screenshot({ path: file, fullPage: true });
    return file;
  } catch { return null; } finally { await page.context().close().catch(() => {}); }
}

// Two images compared on a canvas in a page that loads nothing: the share of pixels that differ
// (1 for different sizes), as ui-sweep.mjs compares its shots.
export async function compareShots(browser, a, b) {
  const page = await (await browser.newContext()).newPage();
  try {
    await page.route('**', (r) => r.abort());
    const uri = (p) => `data:image/png;base64,${readFileSync(p).toString('base64')}`;
    return await page.evaluate(async ({ a, b }) => {
      const load = async (d) => { const i = new Image(); i.src = d; await i.decode(); return i; };
      const [x, y] = [await load(a), await load(b)];
      if (x.naturalWidth !== y.naturalWidth || x.naturalHeight !== y.naturalHeight) return 1;
      const w = x.naturalWidth; const h = Math.min(x.naturalHeight, 12000);
      const c = document.createElement('canvas'); c.width = w; c.height = h;
      const g = c.getContext('2d', { willReadFrequently: true });
      g.drawImage(x, 0, 0); const p = g.getImageData(0, 0, w, h).data;
      g.clearRect(0, 0, w, h); g.drawImage(y, 0, 0); const q = g.getImageData(0, 0, w, h).data;
      let n = 0;
      for (let i = 0; i < p.length; i += 4) if (Math.abs(p[i] - q[i]) > 16 || Math.abs(p[i + 1] - q[i + 1]) > 16 || Math.abs(p[i + 2] - q[i + 2]) > 16) n++;
      return n / (w * h);
    }, { a: uri(a), b: uri(b) });
  } finally { await page.context().close().catch(() => {}); }
}
