#!/usr/bin/env node
// design-check.mjs — the design check of a pull request that changes the UI (docs/design-checks.md):
// which labelled pull requests have a build to check, the ledger of the builds checked, and the check
// itself on the nested product running that build: the screens the pull request changed, each looked
// at for its missing states (error, loading, empty, long text, a 390 px screen), for accessibility
// (axe-core and the keyboard focus, light and dark theme) and for consistency with the design system
// (colours and sizes that are no design token, words the product retired). Black-box: a pull request is
// its labels, its merge time and a build alone — never its diff, files or commits (docs/black-box.md).
//
//   node design-check.mjs due <prs.json> --candidate <c>
//     -> {"due": [{kind, prs, build, against, label, updated_at}], "waiting": [{pr, reason}], "logs"}
//        <prs.json> is `github.sh prs` output; the pull requests carrying `design_label` (default qa:design):
//        - `merged`: merged in the last 30 days and never checked (no PRS.md row): one entry for all of
//          them on the candidate <c> once it was published after their merge (bin/build-time), `against`
//          the newest mapped build (work/inventory/) published before the first of those merges;
//        - `pr-build`: open, not draft, the 10 updated last, each on its newest own build
//          (`bin/versions --prs`) that PRS.md does not have, at most `design_check_max_prs` a run.
//          A profile without builds of pull requests leaves them to their merge.
//   node design-check.mjs done <pr>[,<pr>…] <build> --findings <n>   one PRS.md row per pull request
//   node design-check.mjs run <inventory.json> --against <base-inventory.json> --pr <n> [--pr <n>]… --build <b>
//        [--on-main] [--out DIR] [--max-pages N] [--pattern P]… [--base URL] [--dry-run]
//        -> {check, pages, findings, high, medium, low, notes}; writes <out>/check.json and <out>/shots/.
//        A pull request's own build: label `PR #<n>`, out work/design-checks/pr-<n>/<build>; --on-main
//        (merged pull requests on a main build): label `<build> (PR #<n>, …)`, out
//        work/design-checks/main/<build>. The screens: --pattern, else the pages of the map that are new
//        or whose controls differ from the base build's map, then those whose map screenshot differs, up
//        to --max-pages (design_check_max_pages). --dry-run prints the plan with no browser and no network.
//
// Exit 2: usage, or a base off localhost; exit 1: the owner cannot sign in (an environment failure);
// exit 3: no browser — {error: "no browser: …"} on stdout. Signs in as the owner and only navigates,
// presses Tab and answers the screen's own data requests in the browser (an error, a delay, empty
// lists, longer names); it never clicks, types or submits.

import { existsSync, mkdirSync, readFileSync, readdirSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { append, now, rows } from './lib/design-ledger.mjs';
import { WORK, axeSource, browserFn, compareShots, crop, msg, owner, playwright, profile, pwdVisible, regInt, settle, sh, signIn } from './lib/design-browser.mjs';
import { changedPages, findRetired, offTokens, parseDesign, refOf, screenName, sevRank, valueText } from './lib/design-rules.mjs';

const [cmd, ...argv] = process.argv.slice(2);
const flags = { pattern: [], pr: [] }; const pos = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--dry-run') flags.dry = true;
  else if (a === '--on-main') flags.main = true;
  else if (a === '--pattern' || a === '--pr') flags[a.slice(2)].push(argv[++i]);
  else if (a.startsWith('--')) flags[a.slice(2)] = argv[++i];
  else pos.push(a);
}
const usage = 'usage: design-check.mjs due <prs.json> --candidate C | done <pr>[,<pr>…] <build> --findings N | run <inventory.json> --against <base-inventory.json> --pr N [--pr N]… --build B [--on-main] [--out DIR] [--max-pages N] [--pattern P]… [--base URL] [--dry-run]';
const die = (m) => { console.error(`design-check: ${m}`); process.exit(2); };
const out = (o) => console.log(JSON.stringify(o));
const BUILD_RE = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$/;
const PR_RE = /^[1-9][0-9]{0,6}$/;
const UTC = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const LOOKUP = 10;
const MERGED_DAYS = 30;
const prList = (xs) => xs.map((n) => `#${n}`).join(', ');

// ------------------------------------------------------------------ due
if (cmd === 'due') {
  if (!pos[0]) die(usage);
  const cand = flags.candidate;
  if (!BUILD_RE.test(cand ?? '')) die('due needs --candidate <build>');
  let listing;
  try { listing = JSON.parse(readFileSync(pos[0], 'utf8')); } catch (e) { die(`cannot read ${pos[0]}: ${msg(e)}`); }
  const label = sh('cfg design_label') || 'qa:design';
  const max = regInt('design_check_max_prs', 1, 1, 5);
  let ledger;
  try { ledger = rows('prs'); } catch (e) { die(msg(e)); }
  const logs = []; const due = []; const waiting = [];
  const mine = (listing.prs ?? []).filter((p) => (p.labels ?? []).includes(label) && PR_RE.test(String(p.number)));
  const buildTime = (b) => { const t = sh(`profile_run build-time ${b}`); return UTC.test(t) ? t : null; };

  // Merged, never checked: all of them on the candidate, once it carries every one.
  const since = new Date(Date.now() - MERGED_DAYS * 86400000).toISOString().replace(/\.\d+Z$/, 'Z');
  const merged = mine.filter((p) => p.state === 'merged' && UTC.test(p.merged_at ?? '') && p.merged_at >= since && !ledger.some((x) => x.pr === String(p.number)))
    .sort((a, b) => a.merged_at.localeCompare(b.merged_at));
  if (merged.length) {
    const ct = buildTime(cand);
    const carried = ct ? merged.filter((p) => p.merged_at <= ct) : [];
    if (!ct) for (const p of merged) waiting.push({ pr: p.number, reason: `the publish time of ${cand} is unknown (bin/build-time)` });
    else for (const p of merged.filter((x) => x.merged_at > ct)) waiting.push({ pr: p.number, reason: `merged after ${cand} was published: the next main build carries it` });
    if (carried.length) {
      // The base: the newest mapped build published before the first of these merges.
      const first = carried[0].merged_at;
      let maps = [];
      try {
        maps = readdirSync(join(WORK, 'inventory')).filter((b) => b !== cand && BUILD_RE.test(b) && existsSync(join(WORK, 'inventory', b, 'inventory.json')))
          .sort((a, b) => statSync(join(WORK, 'inventory', b)).mtimeMs - statSync(join(WORK, 'inventory', a)).mtimeMs).slice(0, LOOKUP);
      } catch { maps = []; }
      const before = maps.map((b) => ({ b, t: buildTime(b) })).filter((x) => x.t && x.t < first).sort((a, b) => b.t.localeCompare(a.t))[0];
      if (!before) for (const p of carried) waiting.push({ pr: p.number, reason: 'no UI map of a build published before its merge (the nightly regression maps each build)' });
      else due.push({ kind: 'merged', prs: carried.map((p) => p.number), build: cand, against: before.b,
        label: `${cand} (PR ${prList(carried.map((p) => p.number))})`, updated_at: carried[carried.length - 1].merged_at });
    }
  }

  // Open, on their own builds — when the profile names builds of pull requests.
  const open = mine.filter((p) => p.state === 'open' && !p.draft).sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)));
  if (open.length > LOOKUP) logs.push(`${open.length - LOOKUP} more open pull requests carry ${label}: only the ${LOOKUP} updated last are looked at`);
  const look = open.slice(0, LOOKUP);
  if (look.length) {
    const r = sh(`profile_run versions --prs ${look.map((p) => p.number).join(' ')}`, { status: true });
    let builds = null;
    try { builds = r.code === 0 ? JSON.parse(r.out) : null; } catch { builds = null; }
    // A bin/versions that ignores --prs answers its candidate and baseline: that counts as not implemented.
    const asked = new Set(look.map((p) => String(p.number)));
    if (builds && (typeof builds !== 'object' || Array.isArray(builds) || Object.entries(builds).some(([k, v]) => !asked.has(k) || (v !== null && typeof v !== 'string')))) builds = null;
    if (!builds && (r.code === 2 || r.code === 0)) logs.push(`the profile names no build of a pull request (bin/versions --prs): ${prList(look.map((p) => p.number))} ${look.length === 1 ? 'is' : 'are'} checked after the merge, on a main build`);
    else if (!builds) for (const p of look) waiting.push({ pr: p.number, reason: `the profile cannot list the builds of pull requests: ${r.err || `exit ${r.code}`}` });
    else {
      const checked = new Set(ledger.map((x) => `${x.pr}|${x.build}`));
      let n = 0;
      for (const p of look) {
        const b = builds[String(p.number)];
        if (!b) { waiting.push({ pr: p.number, reason: 'no build of this pull request yet' }); continue; }
        if (!BUILD_RE.test(b)) { waiting.push({ pr: p.number, reason: `the profile named a build that is not a plain id: ${String(b).slice(0, 40)}` }); continue; }
        if (checked.has(`${p.number}|${b}`)) { logs.push(`PR #${p.number}: build ${b} already checked`); continue; }
        if (n >= max) { waiting.push({ pr: p.number, reason: `over design_check_max_prs (${max}) this run` }); continue; }
        n++;
        due.push({ kind: 'pr-build', prs: [p.number], build: b, against: cand, label: `PR #${p.number}`, updated_at: p.updated_at ?? null });
      }
    }
  }
  if (!mine.length) logs.push(`no pull request carries ${label}`);
  out({ due, waiting, logs }); process.exit(0);
}

// ------------------------------------------------------------------ done
if (cmd === 'done') {
  const prs = String(pos[0] ?? '').split(','); const build = pos[1];
  const n = Number(flags.findings);
  if (!prs.every((x) => PR_RE.test(x)) || !BUILD_RE.test(build ?? '') || !Number.isInteger(n) || n < 0) die(usage);
  const recorded = [];
  try {
    for (const pr of prs) {
      if (rows('prs').some((x) => x.pr === pr && x.build === build)) continue;
      append('prs', { pr, build, findings: n, checked_utc: now() });
      recorded.push(+pr);
    }
  } catch (e) { console.error(`design-check: ${msg(e)}`); process.exit(1); }
  out({ prs: prs.map(Number), build, recorded }); process.exit(0);
}

if (cmd !== 'run' || !pos[0] || !flags.against) die(usage);

// ------------------------------------------------------------------ run: the plan
const load = (f) => { try { return JSON.parse(readFileSync(f, 'utf8')); } catch (e) { die(`cannot read the UI map ${f}: ${msg(e)}`); } };
const inv = load(pos[0]); const baseInv = load(flags.against);
if (!flags.pr.length || !flags.pr.every((x) => PR_RE.test(x ?? ''))) die(`--pr '${flags.pr.join(' ')}' is not a pull request number`);
if (flags.pr.length > 1 && !flags.main) die('several --pr only with --on-main (merged pull requests on one main build)');
const build = flags.build;
if (!BUILD_RE.test(build ?? '')) die(`--build '${build ?? ''}' is missing or not a plain build id`);
const prof = profile();
const design = parseDesign(prof);
const notes = [...design.notes];
let base;
try { base = new URL(flags.base ?? process.env.APP_URL ?? inv.base ?? prof.app?.url ?? 'http://localhost'); } catch { die('the base is not a URL'); }
if (!['localhost', '127.0.0.1'].includes(base.hostname)) { console.error(`refusing ${base.origin}: only the nested product on localhost`); process.exit(2); }
const maxPages = flags['max-pages'] !== undefined ? Number(flags['max-pages']) : regInt('design_check_max_pages', 6, 1, 20);
if (!Number.isInteger(maxPages) || maxPages < 1) die(`--max-pages '${flags['max-pages']}' is not a positive integer`);
const outDir = resolve(flags.out ?? (flags.main ? join(WORK, 'design-checks', 'main', build) : join(WORK, 'design-checks', `pr-${flags.pr[0]}`, build)));
const label = flags.main ? `${build} (PR ${prList(flags.pr)})` : `PR #${flags.pr[0]}`;
const routes = inv.routes ?? {};
let pages;
if (flags.pattern.length) {
  pages = flags.pattern.map((p) => {
    const r = routes[p];
    if (!r) die(`--pattern '${p}' is not a page of the UI map ${pos[0]}`);
    if (!r.example || r.error || r.redirected) die(`--pattern '${p}' cannot be checked: ${!r.example ? 'no example path' : r.error ? 'it errored in the UI map' : `it redirected to ${r.redirected}`}`);
    return { pattern: p, example: r.example, title: screenName(p, r), reason: 'asked for', score: 0 };
  });
} else pages = changedPages(baseInv, inv);
const VIEW = { desktop: { width: 1440, height: 900 }, phone: { width: 390, height: 844 } };
if (flags.dry) {
  out({ prs: flags.pr.map(Number), build, label, base: base.origin, out: outDir, max_pages: maxPages, dark_theme: design.dark, retired_words: design.retired.map((w) => w.word),
    tokens: design.tokens, pages: pages.slice(0, maxPages), over: Math.max(0, pages.length - maxPages),
    notes: [...notes, ...(flags.pattern.length ? [] : ['a dry run compares the controls of the two maps only; the run also compares their screenshots'])] });
  process.exit(0);
}

// ------------------------------------------------------------------ run: the browser
const noBrowser = (e) => { out({ error: `no browser: ${msg(e)}` }); process.exit(3); };
const pw = playwright();
if (!pw) noBrowser('playwright-core is not installed in work/suite (scripts/suite.sh init installs it)');
const axe = axeSource();
if (!axe) notes.push('axe-core unavailable: no accessibility rules run (scripts/suite.sh init installs it)');
const qiUiChecks = browserFn('ui-checks.mjs', 'qiUiChecks');
const probe = browserFn('design-probe.mjs', 'qiDesignProbe');
let browser;
try { browser = await pw.chromium.launch({ headless: true }); } catch (e) { noBrowser(e); }

// The screens that only look different: the two maps' screenshots of the same page.
if (!flags.pattern.length) {
  const have = new Set(pages.map((p) => p.pattern));
  for (const [p, r] of Object.entries(routes)) {
    const b = baseInv.routes?.[p];
    if (have.has(p) || !r?.example || r.error || r.redirected || !r.shot || !b?.shot) continue;
    const x = join(dirname(resolve(flags.against)), b.shot); const y = join(dirname(resolve(pos[0])), r.shot);
    if (!existsSync(x) || !existsSync(y)) continue;
    try {
      const d = await compareShots(browser, x, y);
      if (d > 0.01) pages.push({ pattern: p, example: r.example, title: screenName(p, r), reason: `looks different (${Math.round(d * 1000) / 10}% of the screen)`, score: d });
    } catch (e) { notes.push(`compare ${p}: ${msg(e)}`); }
  }
}
if (pages.length > maxPages) notes.push(`${pages.length - maxPages} changed screens over --max-pages ${maxPages} not checked`);
pages = pages.slice(0, maxPages);
mkdirSync(join(outDir, 'shots'), { recursive: true });

const cred = owner();
const sameOrigin = (u) => { try { return new URL(u).origin === base.origin; } catch { return false; } };
// The screen's own data requests: same-origin fetch/XHR GETs, never the session, the user or settings.
const KEEP = /(^|\/)(auth|oauth|oidc|session|sessions|token|login|logout|me|user|userinfo|whoami|config|configuration|settings|features?|flags|health|csrf|version)(\/|$|\?|\.)/i;
const isData = (req) => ['fetch', 'xhr'].includes(req.resourceType()) && req.method() === 'GET' && sameOrigin(req.url()) && !KEEP.test(new URL(req.url()).pathname);
const LIST_KEYS = /^(items|data|results|records|rows|list|nodes|edges|entries|content|values|hits|elements)$/i;
const NAME_KEYS = /(name|title|label|description|summary|display|subject|text|message)$/i;
// What a JSON answer holds: lists of records, empty lists, names to lengthen.
const shape = (j) => {
  const s = { lists: 0, empty: 0, names: 0 };
  const walk = (v, key, depth) => {
    if (depth > 4 || v == null) return;
    if (Array.isArray(v)) {
      if (!v.length) { if (depth === 0 || LIST_KEYS.test(key ?? '')) s.empty++; return; }
      if (v.some((x) => x && typeof x === 'object' && !Array.isArray(x))) s.lists++;
      for (const x of v.slice(0, 50)) walk(x, key, depth + 1);
    } else if (typeof v === 'object') {
      for (const [k, x] of Object.entries(v)) { if (typeof x === 'string' && NAME_KEYS.test(k) && x.length >= 2 && x.length <= 80 && !/^(https?:|\/|\d{4}-\d\d-\d\d)/.test(x)) s.names++; else walk(x, k, depth + 1); }
    }
  };
  walk(j, null, 0);
  return s;
};
const LONG = 'Quarterly-planning-overview-for-the-north-eastern-regional-operations-team';
const transform = (j, how) => {
  const walk = (v, depth) => {
    if (depth > 6 || v == null) return v;
    if (Array.isArray(v)) return how === 'empty' && v.some((x) => x && typeof x === 'object' && !Array.isArray(x)) ? [] : v.map((x) => walk(x, depth + 1));
    if (typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, how === 'long' && typeof x === 'string' && NAME_KEYS.test(k) && x.length >= 2 && x.length <= 80 && !/^(https?:|\/|\d{4}-\d\d-\d\d)/.test(x) ? `${x} ${LONG} and the rest of a very long name` : walk(x, depth + 1)]));
    return v;
  };
  return walk(j, 0);
};

const findings = [];
const pageInfo = [];
let shotN = 0;
const shotFile = (p, kind) => join('shots', `${String(++shotN).padStart(3, '0')}-${(p === '/' ? 'root' : p.replace(/^\//, '').replace(/[^A-Za-z0-9]+/g, '_')).slice(0, 50)}-${kind}.png`);
const name = async (page, sels) => (sels.length ? page.evaluate(qiUiChecks, { describe: sels }).catch(() => sels.map(() => null)) : []);
const steps = (p, ...more) => ['Sign in as the owner.', `Open ${p.example}.`, ...more.filter(Boolean)];
// A target as a sentence names it: “Save” button -> the “Save” button; the page stays the page.
const the = (t) => (/^the /i.test(t) ? t : `the ${t}`);
const cap = (t) => `${t[0].toUpperCase()}${t.slice(1)}`;
const stop = (t) => (/[.!?]$/.test(t) ? t : `${t}.`);
// A Ref seen before in this run: the same problem on another screen, which joins its `also`.
const dup = (ref, pattern) => {
  const old = findings.find((x) => x.ref === ref);
  if (old && old.path !== pattern && !(old.also ??= []).includes(pattern)) old.also.push(pattern);
  return !!old;
};
const add = (f) => { if (!dup(f.ref, f.path)) findings.push({ build: label, ...f }); };
// Colour rules depend on the theme; every other rule is the same problem in both.
const THEMED = /^(color-contrast|color-contrast-enhanced|link-in-text-block)$/;
async function elShot(page, p, kind, b) { const f = shotFile(p.pattern, kind); return (await crop(page, b, join(outDir, f))) ? f : null; }
async function viewShot(page, p, kind) { const f = shotFile(p.pattern, kind); try { await page.screenshot({ path: join(outDir, f), animations: 'disabled' }); return f; } catch { return null; } }

async function context(viewport, scheme, state) {
  const mobile = viewport.width < 600;
  const ctx = await browser.newContext({ viewport, deviceScaleFactor: 1, isMobile: mobile, hasTouch: mobile, colorScheme: scheme === 'dark' && design.dark.mode === 'color_scheme' ? 'dark' : 'light', reducedMotion: 'reduce', storageState: state });
  if (scheme === 'dark' && design.dark.mode === 'local_storage') await ctx.addInitScript((d) => { try { localStorage.setItem(d.key, d.value); } catch { /* no storage */ } }, design.dark);
  if (scheme === 'dark' && (design.dark.mode === 'html_class' || design.dark.mode === 'html_attribute')) {
    await ctx.addInitScript((d) => {
      const set = () => { const e = document.documentElement; if (d.mode === 'html_class') e.classList.add(d.value); else if (d.name === 'class') e.classList.add(d.value); else e.setAttribute(d.name, d.value); };
      set(); document.addEventListener('DOMContentLoaded', set);
    }, design.dark);
  }
  const page = await ctx.newPage();
  ctx.on('page', (x) => { if (x !== page) x.close().catch(() => {}); });
  return { ctx, page };
}
async function open(page, p) {
  await page.goto(new URL(p.example, base).href, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await settle(page);
  const landed = new URL(page.url());
  if (landed.origin !== base.origin) throw new Error(`left the product for ${landed.origin}`);
  if (await pwdVisible(page)) throw new Error('the sign-in page is shown (session lost)');
}
const AXE_SEV = { critical: 'high', serious: 'medium' };
const LABEL_RULES = /^(label|button-name|link-name|image-alt|input-button-name|input-image-alt|select-name|aria-input-field-name|aria-toggle-field-name|aria-command-name|frame-title|svg-img-alt)$/;
async function a11y(page, p, theme) {
  if (!axe) return false;
  await page.evaluate(axe);
  const res = await page.evaluate(async () => {
    const pick = (r) => r.violations.map((v) => ({ id: v.id, impact: v.impact, help: v.help,
      nodes: v.nodes.slice(0, 10).map((n) => ({ sel: n.target.length === 1 && typeof n.target[0] === 'string' ? n.target[0] : null, why: String(n.failureSummary ?? '').split('\n').slice(1).join(' ').trim() })) }));
    const a = await window.axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa'] }, resultTypes: ['violations'] });
    const b = await window.axe.run(document, { runOnly: { type: 'rule', values: ['tabindex'] }, resultTypes: ['violations'] }).catch(() => ({ violations: [] }));
    return [...pick(a), ...pick(b)];
  });
  for (const v of res) {
    const nodes = v.nodes.filter((n) => n.sel).slice(0, 3);
    const desc = await name(page, nodes.map((n) => n.sel));
    for (const [i, n] of nodes.entries()) {
      const d = desc[i]; if (!d) continue;
      // Not the screen: the same element and rule on several screens is one problem (a shared header, a skip link).
      const ref = refOf('a11y', v.id, d.target, THEMED.test(v.id) ? theme : '');
      if (dup(ref, p.pattern)) continue;
      const expected = v.id === 'color-contrast' ? 'Text has a contrast of at least 4.5:1 (3:1 for large text) against its background.'
        : LABEL_RULES.test(v.id) ? 'Every control and image has a name that a screen reader announces.'
          : v.id === 'tabindex' ? 'The keyboard focus moves in the reading order: no positive tabindex.' : `The screen passes the WCAG 2 rule “${v.help}”.`;
      const themed = THEMED.test(v.id);
      add({ ref, check: 'accessibility', severity: AXE_SEV[v.impact] ?? 'low',
        title: `${cap(the(d.target))}: ${v.help}${themed && theme === 'dark' ? ' (dark theme)' : ''}`, screen: p.title, path: p.pattern,
        what: stop(`${themed ? `In the ${theme} theme, ${the(d.target)}` : cap(the(d.target))} fails the axe-core rule ${v.id}${n.why ? `: ${n.why}` : ''}`), expected,
        steps: steps(p, themed && theme === 'dark' ? 'Switch the product to the dark theme.' : null, `Look at ${the(d.target)}.`), attachment: await elShot(page, p, `a11y-${theme}`, d.box) });
    }
  }
  return true;
}
async function focusWalk(page, p) {
  await page.evaluate(() => { document.activeElement?.blur?.(); window.scrollTo(0, 0); });
  let prev = null; const seen = new Set(); let hidden = 0; let bare = 0;
  for (let k = 1; k <= 25; k++) {
    await page.keyboard.press('Tab');
    await page.waitForTimeout(80);
    const f = await page.evaluate(probe, { mode: 'focus', prev: prev?.sel ?? null }).catch(() => null);
    // The element before looks the same now that the focus left it: it showed no focus.
    if (prev?.shown && f?.prev_style != null && prev.style === f.prev_style && bare < 3) {
      bare++;
      const [d] = await name(page, [prev.sel]);
      const ref = d && refOf('focus', 'no-indicator', d.target);
      if (d && !dup(ref, p.pattern)) {
        await page.keyboard.press('Shift+Tab'); await page.waitForTimeout(80);
        const shot = await elShot(page, p, 'focus', prev.box);
        await page.keyboard.press('Tab'); await page.waitForTimeout(80);
        add({ ref, check: 'accessibility', severity: 'medium',
        title: `No visible keyboard focus on ${the(d.target)}`, screen: p.title, path: p.pattern,
        what: `When ${the(d.target)} has the keyboard focus (Tab pressed ${prev.k} time${prev.k === 1 ? '' : 's'}), it looks the same as without it.`,
        expected: 'The element that has the keyboard focus shows a visible focus ring or another visible change.',
        steps: steps(p, `Press Tab ${prev.k} time${prev.k === 1 ? '' : 's'}.`, `Look at ${the(d.target)}.`), attachment: shot });
      }
    }
    if (!f?.sel || seen.has(f.sel)) break; // the focus left the page or came round again: the walk is done
    seen.add(f.sel);
    if (!f.shown && hidden < 3) {
      hidden++;
      const [d] = await name(page, [f.sel]);
      if (d && !dup(refOf('focus', 'hidden', d.target), p.pattern)) add({ ref: refOf('focus', 'hidden', d.target), check: 'accessibility', severity: 'medium',
        title: `Keyboard focus goes to an element you cannot see: ${the(d.target)}`, screen: p.title, path: p.pattern,
        what: `Pressing Tab ${k} time${k === 1 ? '' : 's'} on this screen moves the keyboard focus to ${the(d.target)}, which is not visible on the screen.`,
        expected: 'Every element that takes the keyboard focus is visible while it has the focus.',
        steps: steps(p, `Press Tab ${k} time${k === 1 ? '' : 's'}.`, 'Look for the keyboard focus.'), attachment: await viewShot(page, p, 'focus-hidden') });
    }
    prev = { ...f, k };
  }
}
async function tokensAndWords(page, p, theme) {
  const t = await page.evaluate(probe, { mode: 'tokens', prefixes: design.tokens.prefixes, step: design.tokens.spacing_step });
  if (!t.colors.length && !t.lengths.length && !t.step) { if (theme === 'light') notes.push(`${p.pattern}: the page sets no design tokens (CSS custom properties on :root) — no token check`); }
  else {
    const used = await page.evaluate(probe, { mode: 'usage' });
    const off = offTokens(t, used, 4);
    const desc = await name(page, off.map((u) => u.sel));
    const WHAT = { color: 'Text colour', background: 'Background colour', border: 'Border colour', 'font-size': 'Font size', radius: 'Corner radius' };
    for (const [i, u] of off.entries()) {
      const d = desc[i]; if (!d) continue;
      const v = valueText(u);
      if (dup(refOf('token', u.prop, v), p.pattern)) continue;
      add({ ref: refOf('token', u.prop, v), check: 'consistency', severity: 'low',
        title: `${WHAT[u.prop]} ${v} on ${the(d.target)} is not a design token${theme === 'dark' ? ' (dark theme)' : ''}`, screen: p.title, path: p.pattern,
        what: `The ${WHAT[u.prop].toLowerCase()} ${v} is used on ${u.count} element${u.count === 1 ? '' : 's'} of this screen in the ${theme} theme, for example ${the(d.target)}. No design token of the product has this value.`,
        expected: 'Colours, font sizes and corner radii come from the design tokens of the product.',
        steps: steps(p, theme === 'dark' ? 'Switch the product to the dark theme.' : null, `Look at ${the(d.target)}.`), attachment: await elShot(page, p, `token-${theme}`, d.box) });
    }
  }
  if (theme !== 'light' || !design.retired.length) return;
  const hits = findRetired(await page.evaluate(probe, { mode: 'texts' }), design.retired);
  for (const h of hits.slice(0, 5)) {
    if (dup(refOf('word', h.word), p.pattern)) continue;
    add({ ref: refOf('word', h.word), check: 'consistency', severity: 'medium',
      title: `The screen says “${h.seen}”, a word the product retired`, screen: p.title, path: p.pattern,
      what: `“${h.text}” stands on this screen${h.count > 1 ? ` (${h.count} places)` : ''}. The glossary of the product retired “${h.word}”: say “${h.say}”.`,
      expected: `The screen uses the current words of the product: “${h.say}”, not “${h.word}”.`,
      steps: steps(p, `Look for “${h.seen}”.`), attachment: await elShot(page, p, 'word', h.box) });
  }
}
// The missing states: the screen's data requests answered with an error, late, with empty lists and
// with long names; each only where the normal screen made such a request.
async function states(page, p, seenData) {
  const normal = await page.evaluate(probe, { mode: 'state' });
  const layout = async () => (await page.evaluate(qiUiChecks, { mobile: false })).filter((f) => ['overflow-x', 'offscreen', 'clipped-text', 'overlap'].includes(f.check));
  const before = await layout();
  const data = [...seenData.values()];
  const info = { data_requests: data.length, error: null, loading: null, empty: null, long_text: null };
  const paths = [...new Set(data.map((d) => `GET ${d.path}`))].slice(0, 2).join(', ');
  // The screen with its data requests answered by <handler>, read (and shot) before the routes go:
  // once unrouted, a held request goes on.
  const variant = async (handler, kind, ms = 0) => {
    await page.route((u) => sameOrigin(u.href), async (route) => { if (!isData(route.request())) return route.fallback(); return handler(route); });
    try {
      await page.goto(new URL(p.example, base).href, { waitUntil: 'domcontentloaded', timeout: 30000 });
      if (ms) await page.waitForTimeout(ms); else await settle(page, 800);
      if (await pwdVisible(page)) return null;
      const st = await page.evaluate(probe, { mode: 'state' });
      return { ...st, shot: kind ? await viewShot(page, p, kind) : null };
    } finally { await page.unrouteAll?.({ behavior: 'ignoreErrors' }).catch(() => {}); }
  };
  if (!data.length) { info.error = info.loading = info.empty = info.long_text = 'no data request'; return info; }
  // error: the requests answer 500.
  const err = await variant((r) => r.fulfill({ status: 500, contentType: 'application/json', body: '{"error":"design check: simulated failure"}' }), 'error');
  if (!err) info.error = 'the sign-in page came back';
  else if (err.error && err.error.text !== normal.error?.text) info.error = 'shown';
  else {
    info.error = 'missing';
    add({ ref: refOf('state', 'error', p.pattern), check: 'missing-state', severity: 'high',
      title: `No error message when ${p.title} cannot load its data`, screen: p.title, path: p.pattern,
      what: `When the data requests of this screen fail (the server answers 500), the screen shows no error message${err.loading ? ' and keeps its loading sign' : ''}.`,
      expected: 'The screen says that its data did not load and offers a way to try again.',
      steps: steps(p, `Make the data requests of the screen fail (${paths} answers 500).`, 'Look at the screen.'), attachment: err.shot });
  }
  // loading: the requests answer 8 s late; the screen is read after 1.2 s.
  const late = await variant(async (r) => { await new Promise((ok) => setTimeout(ok, 8000)); await r.fallback().catch(() => {}); }, 'loading', 1200);
  if (!late) info.loading = 'the sign-in page came back';
  else if (late.loading) info.loading = 'shown';
  else if (normal.text >= 20 && late.text < normal.text * 0.5) {
    info.loading = 'missing';
    add({ ref: refOf('state', 'loading', p.pattern), check: 'missing-state', severity: 'medium',
      title: `No loading state on ${p.title}`, screen: p.title, path: p.pattern,
      what: `While the data of this screen loads (its requests answer late), the screen is ${late.text < 5 ? 'blank' : 'mostly empty'} and shows no loading sign.`,
      expected: 'While data loads, the screen shows a loading sign: a spinner, a skeleton or a “Loading” text.',
      steps: steps(p, `Make the data requests of the screen slow (${paths} answers after 8 seconds).`, 'Look at the screen in the first second.'), attachment: late.shot });
  } else info.loading = 'content shown at once';
  await page.goto('about:blank').catch(() => {});
  // empty: lists of records answer empty — or they already are, on a fresh product.
  // A fresh product's list is empty already: it counts when its request names the screen
  // (GET /api/agents for /agents), so a side panel's empty list is not taken for the screen's.
  const words = p.pattern.split('/').filter((x) => x.length >= 3 && !x.startsWith(':')).map((x) => x.toLowerCase().replace(/s$/, ''));
  const own = (d) => words.some((w) => d.path.toLowerCase().split('/').some((x) => x.replace(/s$/, '') === w));
  const lists = data.reduce((n, d) => n + d.shape.lists, 0);
  const fresh = !lists && normal.rows === 0 && data.some((d) => d.shape.empty && own(d));
  let emptyState = null;
  if (lists) emptyState = await variant(async (r) => { const res = await r.fetch(); let j; try { j = await res.json(); } catch { return r.fulfill({ response: res }); } return r.fulfill({ response: res, json: transform(j, 'empty') }); }, 'empty');
  else if (fresh) emptyState = { ...normal, shot: await viewShot(page, p, 'empty') };
  if (!lists && !fresh) info.empty = 'no list';
  else if (!emptyState) info.empty = 'the sign-in page came back';
  else if (emptyState.empty && (fresh || emptyState.empty.text !== normal.empty?.text)) info.empty = 'shown';
  else {
    info.empty = 'missing';
    add({ ref: refOf('state', 'empty', p.pattern), check: 'missing-state', severity: 'medium',
      title: `No empty state on ${p.title}`, screen: p.title, path: p.pattern,
      what: 'When the list of this screen has no items, the screen says nothing about it: no message that it is empty and no next step.',
      expected: 'An empty list says that there is nothing yet and what the user can do next.',
      steps: steps(p, lists ? `Make the lists of the screen empty (${paths} answers with no items).` : 'Have no items in the list (a new product).', 'Look at the screen.'),
      attachment: emptyState.shot });
  }
  // long text: names in the data become 120 characters long.
  const names = data.reduce((n, d) => n + d.shape.names, 0);
  if (!names) info.long_text = 'no names in the data';
  else {
    const lt = await variant(async (r) => { const res = await r.fetch(); let j; try { j = await res.json(); } catch { return r.fulfill({ response: res }); } return r.fulfill({ response: res, json: transform(j, 'long') }); }, null);
    if (!lt) info.long_text = 'the sign-in page came back';
    else {
      const after = await layout();
      const count = (l, c) => l.filter((f) => f.check === c).length;
      const worse = after.find((f) => count(after, f.check) > count(before, f.check) && !before.some((b) => b.check === f.check && b.target === f.target));
      info.long_text = worse ? 'breaks' : 'holds';
      if (worse) add({ ref: refOf('state', 'long-text', p.pattern), check: 'missing-state', severity: 'medium',
        title: `Long names break the layout of ${p.title}`, screen: p.title, path: p.pattern,
        what: `With long names in the data of this screen (about 120 characters), ${the(worse.target)} breaks the layout: ${worse.detail}.`,
        expected: 'A long name wraps or ends with an ellipsis, and the layout stays intact.',
        steps: steps(p, `Give the items long names (${paths} answers with names of 120 characters).`, 'Look at the list.'), attachment: await elShot(page, p, 'long', worse.box) });
    }
  }
  return info;
}
const SMALL = { 'overflow-x': ['high', 'the screen is wider than the phone and scrolls sideways'], offscreen: ['high', 'a control is outside the screen'],
  'clipped-text': ['medium', 'text is cut off'], overlap: ['medium', 'two controls cover each other'], 'tap-target': ['low', 'a control is too small to tap'] };
async function small(page, p) {
  const f = (await page.evaluate(qiUiChecks, { mobile: true, minTap: 24 })).filter((x) => SMALL[x.check]);
  for (const c of Object.keys(SMALL)) {
    const all = f.filter((x) => x.check === c); if (!all.length) continue;
    const x = all[0];
    add({ ref: refOf('state', 'small-screen', c, p.pattern), check: 'missing-state', severity: SMALL[c][0],
      title: `${p.title} does not fit a small screen (390 px): ${SMALL[c][1]}`, screen: p.title, path: p.pattern,
      what: `On a screen 390 px wide, ${SMALL[c][1]}: ${the(x.target)} (${x.detail})${all.length > 1 ? `, and ${all.length - 1} more` : ''}.`,
      expected: 'The screen fits 390 px: no sideways scrolling, every control inside the screen, readable and at least 24 × 24 px to tap.',
      steps: ['Sign in as the owner.', 'Make the browser window 390 px wide (a phone).', `Open ${p.example}.`, `Look at ${the(x.target)}.`], attachment: await elShot(page, p, 'small', x.box) });
  }
}

// ------------------------------------------------------------------ run: the pages
let state;
{
  const { ctx, page } = await context(VIEW.desktop, 'light');
  try { await signIn(page, base, cred); state = await ctx.storageState(); } catch (e) { console.error(`design-check: ${msg(e)}`); await browser.close(); process.exit(1); }
  for (const p of pages) {
    const info = { pattern: p.pattern, example: p.example, title: p.title, reason: p.reason, axe: { light: false, dark: false }, dark_applied: null, states: null };
    pageInfo.push(info);
    const seen = new Map();
    const onResp = async (r) => {
      try {
        if (!isData(r.request()) || r.status() >= 400 || !/json/i.test(r.headers()['content-type'] ?? '')) return;
        const u = new URL(r.url()); const k = u.pathname;
        if (!seen.has(k)) seen.set(k, { path: k, shape: shape(await r.json()) });
      } catch { /* a body that is not JSON */ }
    };
    page.on('response', onResp);
    try {
      await open(page, p);
      await page.waitForTimeout(300);
      page.off('response', onResp);
      try { info.axe.light = await a11y(page, p, 'light'); } catch (e) { notes.push(`axe on ${p.pattern} (light): ${msg(e)}`); }
      await tokensAndWords(page, p, 'light').catch((e) => notes.push(`tokens on ${p.pattern} (light): ${msg(e)}`));
      await focusWalk(page, p).catch((e) => notes.push(`focus on ${p.pattern}: ${msg(e)}`));
      await open(page, p);
      info.states = await states(page, p, seen).catch((e) => { notes.push(`states on ${p.pattern}: ${msg(e)}`); return null; });
      info.light_bg = (await page.evaluate(probe, { mode: 'state' }).catch(() => null))?.bg ?? null;
    } catch (e) { info.error = msg(e); page.off('response', onResp); }
  }
  await ctx.close();
}
if (design.dark.mode === 'none') notes.push('the profile says the product has no dark theme (design.dark_theme: none) — no dark checks');
else {
  const { ctx, page } = await context(VIEW.desktop, 'dark', state);
  for (const info of pageInfo.filter((x) => !x.error)) {
    const p = pages.find((x) => x.pattern === info.pattern);
    try {
      await open(page, p);
      const bg = (await page.evaluate(probe, { mode: 'state' })).bg;
      info.dark_applied = info.light_bg == null || bg < info.light_bg - 0.2;
      if (!info.dark_applied) { notes.push(`${p.pattern}: the dark theme did not apply (profile design.dark_theme) — no dark checks there`); continue; }
      try { info.axe.dark = await a11y(page, p, 'dark'); } catch (e) { notes.push(`axe on ${p.pattern} (dark): ${msg(e)}`); }
      await tokensAndWords(page, p, 'dark').catch((e) => notes.push(`tokens on ${p.pattern} (dark): ${msg(e)}`));
    } catch (e) { notes.push(`${p.pattern} (dark): ${msg(e)}`); }
  }
  await ctx.close();
}
{
  const { ctx, page } = await context(VIEW.phone, 'light', state);
  for (const info of pageInfo.filter((x) => !x.error)) {
    const p = pages.find((x) => x.pattern === info.pattern);
    try { await open(page, p); await small(page, p); } catch (e) { notes.push(`${p.pattern} (390 px): ${msg(e)}`); }
  }
  await ctx.close();
}
await browser.close();

for (const x of pageInfo.filter((i) => i.error)) notes.push(`${x.pattern}: ${x.error}`);
for (const f of findings.filter((x) => x.also?.length)) f.what = `${f.what} The same on ${f.also.length} more screen${f.also.length === 1 ? '' : 's'}: ${f.also.slice(0, 3).join(', ')}${f.also.length > 3 ? ', …' : ''}.`;
findings.sort((a, b) => sevRank(a.severity) - sevRank(b.severity));
const counts = Object.fromEntries(['high', 'medium', 'low'].map((s) => [s, findings.filter((f) => f.severity === s).length]));
const result = { schema: 'qi-design-check/v1', prs: flags.pr.map(Number), build, label, against: baseInv.build ?? null, generated_utc: now(), base: base.origin,
  pages: pageInfo.map(({ light_bg, ...x }) => x), findings, counts, notes };
const file = join(outDir, 'check.json');
writeFileSync(`${file}.tmp`, `${JSON.stringify(result, null, 2)}\n`); renameSync(`${file}.tmp`, file);
out({ check: file, pages: pageInfo.length, findings: findings.length, ...counts, notes });
