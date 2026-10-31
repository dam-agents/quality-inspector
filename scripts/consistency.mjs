#!/usr/bin/env node
// consistency.mjs — the inconsistency radar (docs/design-checks.md): a read-only walk of the main
// screens of a build's UI map that compares, across screens, the patterns that do the same job — the
// page header, the page margins, the buttons (filled, outlined, filled for deleting) and the empty
// state — and reports each pattern that comes in more than one kind as one finding, with a picture of
// each kind side by side. The patterns and the finding's words: lib/design-rules.mjs → clusterRadar.
//
//   node consistency.mjs <inventory.json> --build <b> [--out DIR] [--max-pages N] [--base URL] [--dry-run]
//     -> {radar, pages, findings, notes}; writes <out>/radar.json, <out>/crops/ and one <out>/<ref>.png
//        per finding (default out: work/design-checks/radar/<build>). The screens: the UI map's pages,
//        those without a :param first, up to --max-pages (consistency_max_pages). --dry-run prints the
//        plan with no browser and no network.
//
// Exit 2: usage, or a base off localhost; exit 1: the owner cannot sign in (an environment failure);
// exit 3: no browser — {error: "no browser: …"} on stdout. Signs in as the owner, then only navigates
// at 1440×900 in the light theme: it never clicks, types or submits.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { WORK, browserFn, crop, msg, owner, playwright, profile, pwdVisible, regInt, settle, sheet, signIn } from './lib/design-browser.mjs';
import { now } from './lib/design-ledger.mjs';
import { clusterRadar, screenName } from './lib/design-rules.mjs';

const flags = {}; const pos = [];
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--dry-run') flags.dry = true;
  else if (a.startsWith('--')) flags[a.slice(2)] = process.argv[++i];
  else pos.push(a);
}
const die = (m) => { console.error(`consistency: ${m}`); process.exit(2); };
const out = (o) => console.log(JSON.stringify(o));
if (!pos[0]) die('usage: consistency.mjs <inventory.json> --build B [--out DIR] [--max-pages N] [--base URL] [--dry-run]');
let inv;
try { inv = JSON.parse(readFileSync(pos[0], 'utf8')); } catch (e) { die(`cannot read the UI map ${pos[0]}: ${msg(e)}`); }
const build = flags.build ?? inv.build;
if (!/^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$/.test(build ?? '')) die(`--build '${build ?? ''}' is missing or not a plain build id`);
const prof = profile();
let base;
try { base = new URL(flags.base ?? process.env.APP_URL ?? inv.base ?? prof.app?.url ?? 'http://localhost'); } catch { die('the base is not a URL'); }
if (!['localhost', '127.0.0.1'].includes(base.hostname)) { console.error(`refusing ${base.origin}: only the nested product on localhost`); process.exit(2); }
const maxPages = flags['max-pages'] !== undefined ? Number(flags['max-pages']) : regInt('consistency_max_pages', 40, 5, 100);
if (!Number.isInteger(maxPages) || maxPages < 1) die(`--max-pages '${flags['max-pages']}' is not a positive integer`);
const outDir = resolve(flags.out ?? join(WORK, 'design-checks', 'radar', build));
const notes = [];
const all = Object.entries(inv.routes ?? {}).filter(([, r]) => r?.example && !r.error && !r.redirected)
  .sort(([a], [b]) => Number(a.includes(':')) - Number(b.includes(':')) || a.localeCompare(b));
if (all.length > maxPages) notes.push(`${all.length - maxPages} screens over --max-pages ${maxPages} not walked (screens with a :param last)`);
const pages = all.slice(0, maxPages).map(([pattern, r]) => ({ pattern, example: r.example, title: screenName(pattern, r) }));
if (flags.dry) { out({ build, base: base.origin, out: outDir, max_pages: maxPages, pages, notes }); process.exit(0); }

const pw = playwright();
if (!pw) { out({ error: 'no browser: playwright-core is not installed in work/suite (scripts/suite.sh init installs it)' }); process.exit(3); }
const probe = browserFn('design-probe.mjs', 'qiDesignProbe');
const qiUiChecks = browserFn('ui-checks.mjs', 'qiUiChecks');
let browser;
try { browser = await pw.chromium.launch({ headless: true }); } catch (e) { out({ error: `no browser: ${msg(e)}` }); process.exit(3); }
mkdirSync(join(outDir, 'crops'), { recursive: true });
const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, colorScheme: 'light', reducedMotion: 'reduce' });
const page = await ctx.newPage();
ctx.on('page', (x) => { if (x !== page) x.close().catch(() => {}); });
try { await signIn(page, base, owner()); } catch (e) { console.error(`consistency: ${msg(e)}`); await browser.close(); process.exit(1); }

const observations = []; const walked = []; const crops = new Map();
let n = 0;
for (const p of pages) {
  const w = { pattern: p.pattern, title: p.title, kinds: [] };
  walked.push(w);
  try {
    await page.goto(new URL(p.example, base).href, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await settle(page, 800);
    const landed = new URL(page.url());
    if (landed.origin !== base.origin) { w.error = `left the product for ${landed.origin}`; continue; }
    if (await pwdVisible(page)) { w.error = 'the sign-in page is shown (session lost)'; continue; }
    const found = await page.evaluate(probe, { mode: 'patterns' });
    const named = await page.evaluate(qiUiChecks, { describe: found.map((f) => f.sel) }).catch(() => found.map(() => null));
    for (const [i, f] of found.entries()) {
      const key = `${f.kind}|${f.group}|${f.sig}`;
      // One crop per kind of a pattern: its first place.
      if (!crops.has(key)) {
        const file = join(outDir, 'crops', `${String(++n).padStart(3, '0')}-${f.kind}.png`);
        crops.set(key, (await crop(page, f.box, file, { margin: f.kind === 'spacing' ? 60 : 24, mark: f.kind === 'spacing' })) ?? null);
      }
      observations.push({ ...f, pattern: p.pattern, title: p.title, example: { target: named[i]?.target ?? null, crop: crops.get(key) } });
      w.kinds.push(f.kind);
    }
  } catch (e) { w.error = msg(e); }
}
await ctx.close();

const findings = clusterRadar(observations, build);
for (const f of findings) {
  const file = join(outDir, `${f.ref}.png`);
  const items = f.variants.map((v) => ({ file: v.example.crop, caption: `${v.id} — ${v.pages.length} screen${v.pages.length === 1 ? '' : 's'}: ${v.pages.slice(0, 3).join(', ')}${v.pages.length > 3 ? ', …' : ''}. ${v.label}` }));
  f.attachment = (await sheet(browser, items, f.title, file)) ? `${f.ref}.png` : null;
  if (!f.attachment) notes.push(`${f.ref}: no picture of its kinds (a crop failed)`);
  for (const v of f.variants) if (v.example.crop) v.example.crop = v.example.crop.slice(outDir.length + 1);
}
await browser.close();
for (const w of walked.filter((x) => x.error)) notes.push(`${w.pattern}: ${w.error}`);
const result = { schema: 'qi-design-radar/v1', build, generated_utc: now(), base: base.origin, pages: walked, findings, notes };
const file = join(outDir, 'radar.json');
writeFileSync(`${file}.tmp`, `${JSON.stringify(result, null, 2)}\n`); renameSync(`${file}.tmp`, file);
out({ radar: file, pages: walked.length, findings: findings.length, notes });
