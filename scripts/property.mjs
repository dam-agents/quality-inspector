#!/usr/bin/env node
// property.mjs — the property module (docs/property.md): the frozen invariants of properties.json,
// each tried with many generated inputs against the nested product on localhost — through its API,
// its CLI (the profile's `interfaces.cli`) or its UI — and a failure shrunk by fast-check to the
// smallest input that still breaks it. No model calls; the rules live in lib/property-rules.mjs.
//
//   node property.mjs <properties.json> --build <c> [--out <dir>] [--seed N] [--only PROP-k] [--path P]
//                     [--runs N] [--base URL] [--skip-signin] [--dry-run]
//
// Writes <out>/results.json ({schema, build, generated_utc, seed, runs, properties: [{id, kind,
// statement, surfaces, result, severity, oracle, message, counterexample, seed, path, num_runs,
// num_skips, num_shrinks, replay}], findings: [Design Desk findings], register: [design register
// entries], notes}) and prints {results, properties, ok, finding, flaky, vacuous, blocked, major,
// minor, seed}. Default <out>: work/property/<build>. --dry-run validates and prints the plan.
// --only and --path replay one property's counterexample from the recorded seed: no shrinking,
// written to results-replay-<id>.json beside results.json, which it never touches.
//
// Exit 0 written; 1 the owner's sign-in failed in a running browser (an environment failure);
// 2 usage, an invalid properties.json (printed {error, problems}) or a refused base; 3 no fast-check
// (`suite.sh init` installs it) or no browser where a property needs one (the module failed).
// Steps send only GET, POST, PUT and PATCH to the product's origin — never a delete — and run the CLI
// by its argv, never through a shell. The credential values of work/env/credentials.env are masked
// in the results (lib/secrets.mjs).

import { execFile, execFileSync } from 'node:child_process';
import { accessSync, constants, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { delimiter, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WORK, browserFn, crop, msg, owner, playwright, profile, regInt, settle, signIn } from './lib/design-browser.mjs';
import { CAP, DESIGN, arbitrary, check, designArbitrary, designRef, fill, fillPath, sampleText, validate } from './lib/property-rules.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const flags = {}; const pos = [];
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--dry-run') flags.dry = true;
  else if (a === '--skip-signin') flags.skipSignin = true;
  else if (a.startsWith('--')) flags[a.slice(2)] = process.argv[++i];
  else pos.push(a);
}
const usage = 'usage: property.mjs <properties.json> --build C [--out DIR] [--seed N] [--only PROP-k] [--path P] [--runs N] [--base URL] [--skip-signin] [--dry-run]';
const die = (code, o) => { console.log(JSON.stringify(o)); process.exit(code); };
if (!pos[0]) { console.error(usage); process.exit(2); }

const prof = profile();
const LOCAL = ['localhost', '127.0.0.1'];
const base = (() => { try { return new URL(flags.base ?? process.env.APP_URL ?? prof.app?.url ?? 'http://localhost'); } catch { return null; } })();
if (!base || !LOCAL.includes(base.hostname)) { console.error(`refusing ${base?.origin ?? flags.base}: only the nested product on localhost`); process.exit(2); }
let doc;
try { doc = JSON.parse(readFileSync(pos[0], 'utf8')); } catch (e) { die(2, { error: `cannot read ${pos[0]}: ${msg(e)}` }); }
const problems = validate(doc);
if (problems.length) die(2, { error: `${pos[0]} is not a valid properties file`, problems });
const build = flags.build ?? doc.build;
if (!build || !/^(?!\.)[A-Za-z0-9._+-]+$/.test(build)) { console.error(`property: no valid --build\n${usage}`); process.exit(2); }
if (doc.build && doc.build !== build) die(2, { error: `${pos[0]} was frozen for build ${doc.build}, not ${build}` });

const notes = [];
const intArg = (v, what) => { const n = Number(v); if (!Number.isInteger(n)) die(2, { error: `${what} '${v}' is not a whole number` }); return n; };
let runs = flags.runs !== undefined ? intArg(flags.runs, '--runs') : regInt('property_runs', 50, 1, CAP.runs);
if (runs > CAP.runs) { notes.push(`runs ${runs} clamped to the hard cap ${CAP.runs}`); runs = CAP.runs; }
if (runs < 1) die(2, { error: '--runs must be 1 or more' });
// A 32-bit seed: recorded, so a failure replays (--seed, --path).
const seed = flags.seed !== undefined ? intArg(flags.seed, '--seed') : (Math.random() * 2 ** 31) | 0;
const only = flags.only ?? null;
if (flags.path && !only) die(2, { error: '--path replays one property: give --only PROP-k' });
if (flags.path && flags.seed === undefined) die(2, { error: '--path needs the --seed it was recorded with' });
const maxProps = regInt('property_max_properties', 12, 1, CAP.properties);
let props = doc.properties.filter((p) => !only || p.id === only);
if (!props.length) die(2, { error: `no property ${only} in ${pos[0]}` });
if (props.length > maxProps) { notes.push(`${props.length} properties: the first ${maxProps} (property_max_properties) ran`); props = props.slice(0, maxProps); }
const surfaces = (p) => (p.kind === 'design' ? ['ui'] : [...new Set(p.steps.map((s) => ['api', 'cli', 'ui'].find((k) => k in s)))]);
const usesUi = (p) => surfaces(p).includes('ui');
const runsOf = (p) => (usesUi(p) ? Math.min(runs, CAP.uiRuns) : runs);
// Wall-clock per property: generation and shrinking stop there (fast-check interruptAfterTimeLimit).
const limitMs = regInt('property_max_seconds', 180, 10, 1800) * 1000;

if (flags.dry) {
  console.log(JSON.stringify({ build, base: base.origin, seed, runs, limit_s: limitMs / 1000, notes,
    properties: props.map((p) => ({ id: p.id, kind: p.kind, surfaces: surfaces(p), runs: runsOf(p) })) }, null, 2));
  process.exit(0);
}

// fast-check from the suite (QI_FASTCHECK_FROM overrides, for the tests).
let fc;
try { fc = createRequire(process.env.QI_FASTCHECK_FROM ?? join(WORK, 'suite', 'package.json'))('fast-check'); } catch (e) {
  die(3, { error: `no fast-check in work/suite (bash "$HOME/scripts/suite.sh" init installs it): ${msg(e)}` });
}

// ------------------------------------------------------------------ the browser and the session ----
const needUi = props.some(usesUi);
const needSession = props.some((p) => surfaces(p).includes('api')) && !flags.skipSignin;
let browser = null; let session = null;
const sameOrigin = (u) => { try { return new URL(u).origin === base.origin; } catch { return false; } };
// Every browser request to another host is aborted: the nested product is the only target.
const fence = (ctx) => ctx.route((u) => !sameOrigin(u.href) && !/^(data|blob|about):/.test(u.href), (r) => r.abort());
if (needUi || needSession) {
  const pw = playwright();
  try {
    if (!pw) throw new Error('playwright-core is not installed in work/suite');
    browser = await pw.chromium.launch({ headless: true });
  } catch (e) { die(3, { error: `no browser: ${msg(e)}` }); }
}
if (browser && !flags.skipSignin) {
  try {
    const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    await fence(ctx);
    const page = await ctx.newPage();
    let auth = null;
    page.on('request', (r) => { const h = r.headers().authorization; if (!auth && h && sameOrigin(r.url())) auth = h; });
    await signIn(page, base, owner());
    session = { auth, cookies: await ctx.cookies(base.href), state: await ctx.storageState() };
    await ctx.close();
  } catch (e) {
    console.error(`property: cannot sign in: ${msg(e)}`);
    await browser.close().catch(() => {});
    process.exit(1);
  }
}

// ------------------------------------------------------------------ one step ----
const cliCmd = (() => {
  const c = prof.interfaces?.cli;
  if (typeof c !== 'string' || !/^[A-Za-z0-9._/@-]+$/.test(c)) return null;
  if (c.includes('/')) return c.startsWith('/') ? c : null;
  for (const d of [...(process.env.PATH ?? '').split(delimiter), join(WORK, 'suite', 'node_modules', '.bin')]) {
    try { accessSync(join(d, c), constants.X_OK); return join(d, c); } catch { /* next */ }
  }
  return null;
})();
const parse = (t) => { try { return JSON.parse(t); } catch { return null; } };
async function api(s, ctx) {
  const url = new URL(fillPath(s.api.path, ctx), base);
  if (url.origin !== base.origin) throw new Error(`refusing ${url.origin}`);
  const headers = { accept: 'application/json' };
  if (session?.cookies?.length) headers.cookie = session.cookies.map((c) => `${c.name}=${c.value}`).join('; ');
  if (session?.auth) headers.authorization = session.auth;
  let body;
  if (s.api.body !== undefined) { headers['content-type'] = 'application/json'; body = JSON.stringify(fill(s.api.body, ctx)); }
  const res = await fetch(url, { method: s.api.method, headers, body, redirect: 'manual', signal: AbortSignal.timeout(30000) });
  const text = await res.text().catch(() => '');
  return { surface: 'api', status: res.status, body: parse(text), text: text.slice(0, 20000), request: `${s.api.method} ${url.pathname}` };
}
function cli(s, ctx) {
  if (!cliCmd) throw new Error('the profile names no CLI (interfaces.cli) on PATH or in work/suite');
  const argv = s.cli.map((a) => { const v = fill(a, ctx); return typeof v === 'string' ? v : JSON.stringify(v); });
  return new Promise((res) => {
    execFile(cliCmd, argv, { timeout: 60000, maxBuffer: 4 << 20, env: { ...process.env, APP_URL: base.origin } }, (err, stdout) => {
      const status = err ? (typeof err.code === 'number' ? err.code : 124) : 0;
      res({ surface: 'cli', status, body: parse(stdout), text: String(stdout).slice(0, 20000), request: `${prof.interfaces.cli} ${s.cli[0]}` });
    });
  });
}
async function ui(s, ctx) {
  const c = await browser.newContext({ viewport: { width: 1280, height: 800 }, ...(session ? { storageState: session.state } : {}) });
  try {
    await fence(c);
    const page = await c.newPage();
    const r = await page.goto(new URL(fillPath(s.ui.open, ctx), base).href, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await settle(page, 800);
    const text = await page.evaluate(() => document.body?.innerText ?? '');
    return { surface: 'ui', status: r?.status() ?? 0, body: null, text: text.slice(0, 50000), request: `open ${s.ui.open}` };
  } finally { await c.close().catch(() => {}); }
}
const ok = (a) => (a.surface === 'cli' ? a.status === 0 : a.status >= 200 && a.status < 300);

// One try of a functional property with one input -> {refused} | {broke: {oracle, message, request}} | {}.
let stampN = 0;
const runStamp = `${Date.now().toString(36)}`;
async function once(p, input) {
  const ctx = { input, stamp: `qa-prop-${runStamp}-${++stampN}` };
  for (const [i, s] of p.steps.entries()) {
    for (let k = 0; k < (s.repeat ?? 1); k++) {
      let a;
      try { a = s.api ? await api(s, ctx) : s.cli ? await cli(s, ctx) : await ui(s, ctx); } catch (e) {
        return { broke: { oracle: 'setup', message: `step '${s.as}': ${msg(e)}` } };
      }
      if (a.surface !== 'cli' && a.status >= 500) return { broke: { oracle: 'no-server-error', message: `${a.request} answered ${a.status}` } };
      // The first step refused the input (4xx, a non-zero exit): the product may refuse it — no try.
      if (i === 0 && k === 0 && !ok(a)) return { refused: true };
      ctx[s.as] = a;
    }
  }
  for (const e of p.expect) {
    const why = check(e, ctx);
    if (why) return { broke: { oracle: 'assertion', message: why } };
  }
  return {};
}

// One try of a design property with one sample -> {broke: {oracle, message, hits}} | {}; keep → the page stays open.
const qiUiChecks = browserFn('ui-checks.mjs', 'qiUiChecks');
const NAME_KEYS = /^(name|title|label|display_?name|description|summary|caption)$/i;
const LONG = 'Ünïcødé-Wörter-und-sehr-lange-Bezeichnungen-für-Überschriften ';
const lengthen = (v, n, d = 0) => {
  if (d > 6 || v == null) return v;
  if (Array.isArray(v)) return v.map((x) => lengthen(x, n, d + 1));
  if (typeof v === 'object') return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, typeof x === 'string' && NAME_KEYS.test(k) && !/^(https?:|\/)/.test(x)
    ? (x + ' ' + LONG.repeat(Math.ceil(n / LONG.length))).slice(0, Math.max(n, 1)) : lengthen(x, n, d + 1)]));
  return v;
};
async function look(p, sample, keep = false) {
  const width = Math.max(200, Math.round(sample.width / sample.zoom));
  const c = await browser.newContext({ viewport: { width, height: Math.round(900 / sample.zoom) }, deviceScaleFactor: sample.zoom,
    locale: sample.locale, extraHTTPHeaders: { 'accept-language': sample.locale }, ...(session ? { storageState: session.state } : {}) });
  let page;
  try {
    await fence(c);
    page = await c.newPage();
    if (sample.text_length > 0) {
      await page.route((u) => sameOrigin(u.href), async (r) => {
        const q = r.request();
        if (q.method() !== 'GET' || !['fetch', 'xhr'].includes(q.resourceType())) return r.fallback();
        const res = await r.fetch();
        let j; try { j = await res.json(); } catch { return r.fulfill({ response: res }); }
        return r.fulfill({ response: res, json: lengthen(j, sample.text_length) });
      });
    }
    await page.goto(new URL(p.page, base).href, { waitUntil: 'domcontentloaded', timeout: 30000 });
    await settle(page, 800);
    const all = await page.evaluate(qiUiChecks, { mobile: width < 600 });
    const want = new Map(p.invariants.map((x) => [DESIGN[x].check, x]));
    const hits = all.filter((f) => want.has(f.check)).map((f) => ({ ...f, invariant: want.get(f.check) }));
    const out = hits.length ? { broke: { oracle: 'design', message: hits.slice(0, 3).map((h) => `${h.invariant}: ${h.target} — ${h.detail}`).join('; '), hits } } : {};
    if (keep) return { ...out, page, close: () => c.close().catch(() => {}) };
    return out;
  } finally { if (!keep) await c.close().catch(() => {}); }
}

// ------------------------------------------------------------------ the run ----
class Broke extends Error { constructor(b) { super(`[${b.oracle}] ${b.message}`); this.broke = b; } }
const SEVERITY = { 'no-server-error': 'major', assertion: 'major' };
const outDir = flags.out ?? join(WORK, 'property', String(build));
mkdirSync(outDir, { recursive: true });
const results = []; const findings = []; const register = [];
let shotN = 0;
for (const p of props) {
  const base0 = { id: p.id, kind: p.kind, statement: p.statement, surfaces: surfaces(p) };
  let arb;
  try { arb = p.kind === 'design' ? designArbitrary(fc, p.vary) : arbitrary(fc, p.input ?? { type: 'text' }); } catch (e) {
    results.push({ ...base0, result: 'blocked', severity: null, oracle: null, message: `no input generator: ${msg(e)}`, counterexample: null }); continue;
  }
  const tryOne = p.kind === 'design' ? (x) => look(p, x) : (x) => once(p, x);
  let refused = 0;
  const prop = fc.asyncProperty(arb, async (x) => {
    const r = await tryOne(x);
    if (r.refused) { refused++; fc.pre(false); }
    if (r.broke) throw new Broke(r.broke);
  });
  // maxSkipsPerRun: a property the product refuses nearly every input for stops early (vacuous).
  const opts = { numRuns: runsOf(p), seed, maxSkipsPerRun: 3, interruptAfterTimeLimit: limitMs, markInterruptAsFailure: false,
    ...(flags.path ? { path: flags.path, endOnFailure: true } : {}) };
  let out;
  try { out = await fc.check(prop, opts); } catch (e) { results.push({ ...base0, result: 'blocked', severity: null, message: msg(e) }); continue; }
  const counts = { seed: out.seed ?? seed, path: out.counterexamplePath ?? null, num_runs: out.numRuns ?? null, num_skips: out.numSkips ?? null, num_shrinks: out.numShrinks ?? null };
  const replay = (path) => `node "$HOME/scripts/property.mjs" ${pos[0]} --build ${build} --only ${p.id} --seed ${counts.seed}${path ? ` --path ${path}` : ''}`;
  if (!out.failed) {
    const vacuous = (out.numRuns ?? 0) === 0;
    if (out.interrupted) notes.push(`${p.id}: stopped after ${limitMs / 1000} s with ${out.numRuns} tries`);
    results.push({ ...base0, result: vacuous ? 'vacuous' : 'ok', severity: null, oracle: null,
      message: vacuous ? `the product refused every generated input (${refused} refusals)` : null, counterexample: null, ...counts, replay: replay(null) });
    continue;
  }
  const err = out.errorInstance ?? out.error;
  const broke = err?.broke ?? null;
  const cx = Array.isArray(out.counterexample) ? out.counterexample[0] : out.counterexample;
  if (!broke && refused > 0 && !(out.numRuns > 0)) { // every input refused: fast-check gave up on its skips
    results.push({ ...base0, result: 'vacuous', severity: null, oracle: null, message: `the product refused every generated input (${refused} refusals)`, counterexample: null, ...counts, replay: replay(null) });
    continue;
  }
  if (!broke) { // fast-check itself gave up (an internal error)
    results.push({ ...base0, result: 'blocked', severity: null, oracle: null, message: msg(err ?? 'the property did not run'), counterexample: cx ?? null, ...counts, replay: replay(null) });
    continue;
  }
  // Confirm: the shrunk counterexample twice more; one pass = flaky, not a finding.
  // A design sample keeps its last page open: its elements are cropped for the finding.
  let flaky = false; let again = null;
  for (let k = 0; k < 2 && !flaky; k++) {
    if (p.kind === 'design') {
      const r = await look(p, cx, true).catch(() => null);
      await again?.close?.();
      again = r;
      if (!r?.broke) flaky = true;
    } else {
      const r = await once(p, cx).catch((e) => ({ broke: { oracle: 'setup', message: msg(e) } }));
      if (!r.broke) flaky = true;
    }
  }
  const severity = flaky ? null : p.kind === 'design' ? (broke.hits ?? []).some((h) => DESIGN[h.invariant].severity === 'major') ? 'major' : 'minor' : SEVERITY[broke.oracle] ?? null;
  const result = flaky ? 'flaky' : broke.oracle === 'setup' ? 'blocked' : 'finding';
  results.push({ ...base0, result, severity: result === 'finding' ? severity : null, oracle: broke.oracle, message: broke.message, counterexample: cx, ...counts, replay: replay(counts.path) });
  // A design finding: one per element and invariant at the shrunk sample, for the register and the Design Desk.
  if (p.kind === 'design' && again?.broke && result === 'finding') {
    const seen = new Set();
    for (const h of again.broke.hits) {
      const key = `${h.invariant}|${h.target}`;
      if (seen.has(key) || seen.size >= 5) continue;
      seen.add(key);
      const d = DESIGN[h.invariant];
      const shot = join('shots', `${String(++shotN).padStart(3, '0')}-${p.id}-${h.check}.png`);
      mkdirSync(join(outDir, 'shots'), { recursive: true });
      const file = await crop(again.page, h.box, join(outDir, shot)).catch(() => null);
      const steps = [`Open ${p.page} in a window ${sampleText(cx).replace(/, texts of 0 characters$/, '')}.`,
        ...(cx.text_length > 0 ? [`Give the names and titles in its data ${cx.text_length} characters.`] : []), `Look at ${h.target}.`];
      findings.push({ ref: designRef(p.page, h.invariant, h.target), check: 'property', severity: d.desk, title: `${p.statement} — ${h.invariant} breaks on ${p.page}`,
        screen: p.page, path: p.page, what: `At ${sampleText(cx)} (the smallest case of ${counts.num_runs} generated cases, seed ${counts.seed}): ${h.target} — ${h.detail}.`,
        expected: `${cap(d.expected)} at every window width, zoom, text length and locale.`, steps, build, attachment: file ? resolve(outDir, shot) : null });
      register.push({ property: p.id, pattern: p.page, invariant: h.invariant, check: h.check, severity: d.severity, target: h.target, detail: h.detail,
        box: h.box ?? null, shot: file ? shot : null, sample: cx, seed: counts.seed, path: counts.path });
    }
  }
  await again?.close?.();
}
function cap(s) { return s.charAt(0).toUpperCase() + s.slice(1); }
await browser?.close().catch(() => {});

const count = (f) => results.filter(f).length;
const replayOnly = Boolean(flags.path);
const file = join(outDir, replayOnly ? `results-replay-${only}.json` : 'results.json');
const ran = props.map((p) => ({ id: p.id, kind: p.kind, page: p.page ?? null, invariants: p.invariants ?? null }));
const out = { schema: 'qi-property/v1', build, generated_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), properties_file: pos[0],
  replay: replayOnly, seed, runs, ran, properties: results, findings, register, notes };
writeFileSync(`${file}.tmp`, JSON.stringify(out, null, 2)); renameSync(`${file}.tmp`, file);
// The credential values never stay in a result (a CLI's or an API's answer could echo one).
const cred = join(WORK, 'env', 'credentials.env');
if (existsSync(cred)) { try { execFileSync('node', [join(here, 'lib', 'secrets.mjs'), 'mask', cred, outDir], { stdio: 'ignore' }); } catch { notes.push('secrets mask failed'); } }
console.log(JSON.stringify({ results: file, properties: results.length, ok: count((r) => r.result === 'ok'), finding: count((r) => r.result === 'finding'),
  flaky: count((r) => r.result === 'flaky'), vacuous: count((r) => r.result === 'vacuous'), blocked: count((r) => r.result === 'blocked'),
  major: count((r) => r.severity === 'major'), minor: count((r) => r.severity === 'minor'), design_findings: findings.length, seed, notes }));
