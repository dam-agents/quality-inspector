#!/usr/bin/env node
// ux-signals.mjs — the ux-signals module (docs/ux-signals.md): how real users fare in the
// product's UI, read as aggregates from the endpoint the profile names, scored, planned for a
// replay, reported, and handed to Design Desk. Everything it reads from the endpoint is data.
//
//   node ux-signals.mjs fetch [--now ISO] [--days N] [--fixture FILE] [--refresh]
//       -> {period, dir, file, fetched, rows:{builds,features,friction,funnels,trails}, dropped, notes}
//          work/ux/<from>_<to>/signals.json; a period already fetched is kept (fetched: false)
//          unless --refresh. --fixture reads the response from a file instead of the network.
//          A 404, an empty answer or one with no row: {period, nodata} — nothing written, no error.
//          `{profile.<key>}` in the endpoint (and its egress rule) is the instance's value.
//   node ux-signals.mjs score <signals.json> [--inventory FILE]
//       -> <dir>/scored.json: candidates (rows that pass the thresholds), ranked; unused pages and
//          elements of the UI map; the profile's flows
//   node ux-signals.mjs check [--now ISO]      the pre-flight's: fetch when due by `ux_signals`
//       (daily | weekly), score, then {due, period, scored, new, resolve, reason}
//   node ux-signals.mjs plan <scored.json> [--max N] [--inventory FILE]
//       -> [{fingerprint, signal, route, element, build, install, install_note, users, rate, …,
//          evidence, trails}] the candidates not evaluated on their build yet, at most N
//          (`ux_max_candidates`). `install`: the build env.sh up installs for the reported one
//          (env.sh resolve); null when none is published — `install_note` says why
//   node ux-signals.mjs report <scored.json>   -> <dir>/report/index.html + media/ (the usage report)
//   node ux-signals.mjs handoff D-<k> [--sent] -> {id, channel, text, attachment, ref} for Design Desk's
//          Slack intake; --sent records it in work/ux/HANDOFF.md. Exit 2: not eligible, or sent.
//   node ux-signals.mjs handoff-plan           -> [D-<k>] what `ux_handoff: auto` sends now
//
// Exit 2 = usage or refused input (no ux_signals in the profile, an endpoint the profile's egress
// does not allow), 1 = the fetch failed. Never prints the API key.

import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { basename, dirname, extname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { REPORTED, SIGNALS, fingerprint, quietBuild, routeKey } from './lib/ux-field.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const WORK = resolve(process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work'));
const UX = join(WORK, 'ux');
const REGISTER = join(WORK, 'design', 'findings.json');
const HANDOFF = join(UX, 'HANDOFF.md');
const HANDOFF_HEADER = '| id | build | channel | sent_utc |\n| --- | --- | --- | --- |\n';
const flags = {}; const pos = [];
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--refresh' || a === '--sent') flags[a.slice(2)] = true;
  else if (a.startsWith('--')) flags[a.slice(2)] = process.argv[++i];
  else pos.push(a);
}
const out = (o) => console.log(JSON.stringify(o, null, 2));
const die = (m, code = 2) => { out({ error: m }); process.exit(code); };
const sh = (expr) => {
  try {
    return execFileSync('bash', ['-c', `CONFIG="$WORK/CONFIG.md"; . "$LIB/config.sh"; . "$LIB/profile.sh"; ${expr}`],
      { env: { ...process.env, WORK, LIB: join(here, 'lib') }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return ''; }
};
const readJson = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } };
const atomic = (p, s) => { mkdirSync(dirname(p), { recursive: true }); writeFileSync(`${p}.tmp`, s); renameSync(`${p}.tmp`, p); };
const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const str = (s, n) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, n);
const int = (v) => (Number.isInteger(v) && v >= 0 ? v : null);
const num = (v) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : null);
const BUILD = /^(?!\.)[A-Za-z0-9._+-]{1,80}$/;
const TESTID = /^[A-Za-z0-9._:-]{1,100}$/;
const ISO = (s) => (typeof s === 'string' && Number.isFinite(Date.parse(s)) ? new Date(Date.parse(s)).toISOString().replace(/\.\d+Z$/, 'Z') : null);
const regInt = (k, d) => { const n = Number(sh(`reg ${k}`)); return Number.isInteger(n) ? n : d; };

// ------------------------------------------------------------------ the profile's entry ----
function settings() {
  const profile = readJson(join(sh('profile_dir'), 'profile.json')) ?? {};
  const u = profile.ux_signals;
  if (!u || typeof u !== 'object') return { off: 'the profile has no ux_signals entry' };
  // The install that collects the data is the instance's (a DEV install, say): `{profile.<key>}` in the
  // endpoint and in egress is that key's value, a plain name as egress-rules.sh takes it.
  const pcfg = (() => { try { return JSON.parse(sh('profile_config') || '{}'); } catch { return {}; } })();
  const unset = [];
  const fill = (t) => String(t ?? '').replace(/\{profile\.([a-z0-9_]+)\}/g, (_, k) => {
    const v = String(pcfg[k] ?? '');
    if (/^[A-Za-z0-9.-]+(\/[A-Za-z0-9.-]+)*$/.test(v) && !/\/\.\.?\//.test(`/${v}/`)) return v;
    unset.push(`profile.${k}`); return '';
  });
  const endpoint = fill(u.endpoint);
  if (unset.length) return { off: `ux_signals.endpoint needs ${unset.join(', ')} set in work/CONFIG.md` };
  let url;
  try { url = new URL(endpoint); } catch { return { off: 'ux_signals.endpoint is not a URL' }; }
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash) return { off: 'ux_signals.endpoint must be https, with no credentials, query or fragment' };
  // Least privilege: the endpoint is read only where the profile's egress lists exactly it, GET.
  const allowed = (profile.egress ?? []).some((e) => e && fill(e.host) === url.hostname && String(e.method ?? '').toUpperCase() === 'GET' && fill(e.path) === url.pathname);
  if (!allowed) return { off: `the profile's egress has no GET rule for ${url.hostname}${url.pathname}` };
  const key = String(u.api_key_env ?? '');
  if (!/^E2E_[A-Z][A-Z0-9_]{0,31}$/.test(key) || !/(^|_)(TOKEN|SECRET|KEY)(_|$)/.test(key.slice(4))) return { off: 'ux_signals.api_key_env must be E2E_<NAME> of an operator_credentials entry' };
  const minUsers = Math.max(3, Number.isInteger(u.min_users) ? u.min_users : 3);
  const minRate = typeof u.min_rate === 'number' && u.min_rate >= 0 && u.min_rate <= 1 ? u.min_rate : 0.05;
  const flows = (Array.isArray(u.flows) ? u.flows : []).map((f) => str(f, 60)).filter(Boolean).slice(0, 20);
  return { url, key, minUsers, minRate, flows };
}

function apiKey(name) {
  if (process.env[name]) return process.env[name];
  try {
    for (const l of readFileSync(join(WORK, 'env', 'credentials.env'), 'utf8').split('\n')) {
      const m = /^\s*(?:export\s+)?([A-Z0-9_]+)=(.*)$/.exec(l);
      if (m && m[1] === name) return m[2].trim().replace(/^(['"])(.*)\1$/, '$2');
    }
  } catch { /* no file */ }
  return '';
}

// ------------------------------------------------------------------ fetch ----
const periodOf = (to, days) => {
  const end = new Date(Date.UTC(to.getUTCFullYear(), to.getUTCMonth(), to.getUTCDate()));
  const start = new Date(end.getTime() - days * 86400000);
  const iso = (d) => d.toISOString().replace(/\.\d+Z$/, 'Z');
  return { from: iso(start), to: iso(end), id: `${iso(start).slice(0, 10)}_${iso(end).slice(0, 10)}` };
};

// The response, kept to the contract's fields and sizes; rows below the floor are dropped.
function clean(raw, minUsers, notes) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('the response is not a JSON object');
  const list = (k, n) => (Array.isArray(raw[k]) ? raw[k].slice(0, n) : (notes.push(`${k}: missing or not a list`), []));
  const el = (e) => (e == null ? null : TESTID.test(String(e)) ? String(e) : undefined);
  const route = (r) => (typeof r === 'string' && r.startsWith('/') && r.length <= 200 && !/\s/.test(r) ? r : null);
  let dropped = 0;
  const keep = (rows, name, f) => rows.map((r, i) => {
    const x = r && typeof r === 'object' ? f(r) : null;
    if (!x) { notes.push(`${name}[${i}] does not fit the contract — left out`); return null; }
    if (x.users !== undefined && x.users < minUsers) { dropped++; return null; }
    return x;
  }).filter(Boolean);
  const builds = keep(list('builds', 200), 'builds', (b) => (BUILD.test(String(b.version)) && ISO(b.firstSeen) ? { version: String(b.version), firstSeen: ISO(b.firstSeen) } : null));
  const features = keep(list('features', 5000), 'features', (f) => {
    const x = { route: route(f.route), element: el(f.element), users: int(f.users), uses: int(f.uses) };
    return x.route && x.element !== undefined && x.users !== null ? x : null;
  });
  const friction = keep(list('friction', 2000), 'friction', (f) => {
    const x = { signal: f.signal, route: route(f.route), element: el(f.element), build: String(f.build ?? ''), users: int(f.users),
      events: int(f.events), views: int(f.views), rate: num(f.rate), prevRate: f.prevRate == null ? null : num(f.prevRate) };
    return SIGNALS.includes(x.signal) && x.route && x.element !== undefined && BUILD.test(x.build) && x.users !== null && x.rate !== null
      && (f.prevRate == null || x.prevRate !== null) ? x : null;
  });
  const funnels = keep(list('funnels', 50), 'funnels', (f) => {
    const steps = Array.isArray(f.steps) ? f.steps.slice(0, 30).map((s) => ({ step: str(s?.step, 80), users: int(s?.users), medianMsFromStart: int(s?.medianMsFromStart) })) : null;
    return str(f.flow, 60) && steps?.length && steps.every((s) => s.step && s.users !== null) ? { flow: str(f.flow, 60), steps } : null;
  });
  const trails = keep(list('trails', 500), 'trails', (t) => {
    const steps = Array.isArray(t.steps) ? t.steps.slice(0, 60).map((s) => ({ kind: /^[a-z_]{1,20}$/.test(String(s?.kind)) ? s.kind : null,
      route: route(s?.route), element: el(s?.element), dtMs: int(s?.dtMs) })) : null;
    const x = { id: str(t.id, 64), signal: t.signal, route: route(t.route), element: el(t.element), build: String(t.build ?? ''), users: int(t.users), steps };
    return /^[A-Za-z0-9._:-]{1,64}$/.test(x.id) && SIGNALS.includes(x.signal) && x.route && x.element !== undefined && BUILD.test(x.build)
      && x.users !== null && steps?.length && steps.every((s) => s.kind && s.route && s.element !== undefined && s.dtMs !== null) ? x : null;
  });
  return { builds, features, friction, funnels, trails, dropped };
}

async function fetchPeriod(s, at) {
  const days = Number(flags.days ?? regInt('ux_period_days', 7));
  if (!Number.isInteger(days) || days < 1 || days > 90) die(`--days '${flags.days}' is not 1..90`);
  const p = periodOf(at, days);
  const dir = join(UX, p.id); const file = join(dir, 'signals.json');
  if (existsSync(file) && !flags.refresh) return { period: p, dir, file, fetched: false, ...summary(readJson(file)) };
  let raw;
  if (flags.fixture) raw = readJson(flags.fixture);
  else {
    const key = apiKey(s.key);
    if (!key) die(`${s.key} is empty: the operator fills it in work/env/credentials.env`);
    const u = new URL(s.url); u.searchParams.set('from', p.from); u.searchParams.set('to', p.to);
    try {
      const r = await fetch(u, { headers: { Authorization: `Bearer ${key}`, Accept: 'application/json' }, redirect: 'error', signal: AbortSignal.timeout(30000) });
      if (r.status === 404) return { period: p, nodata: `GET ${s.url.hostname}${s.url.pathname} answered 404: the install collects no UI usage` };
      if (!r.ok) die(`GET ${s.url.hostname}${s.url.pathname} answered ${r.status}`, 1);
      const body = await r.text();
      if (body.length > 5 * 1024 * 1024) die('the response is larger than 5 MiB', 1);
      raw = body.trim() ? JSON.parse(body) : null;
    } catch (e) { die(`GET ${s.url.hostname}${s.url.pathname} failed: ${str(e.message, 160)}`, 1); }
  }
  // The feature switched off on the install: an empty answer, or one with no row at all.
  const LISTS = ['builds', 'features', 'friction', 'funnels', 'trails'];
  if (raw == null || (typeof raw === 'object' && !Array.isArray(raw) && LISTS.every((k) => !raw[k]?.length))) {
    return { period: p, nodata: `GET ${s.url.hostname}${s.url.pathname} answered no data: the install collects no UI usage` };
  }
  const notes = [];
  let rows;
  try { rows = clean(raw, s.minUsers, notes); } catch (e) { die(e.message, 1); }
  atomic(file, `${JSON.stringify({ schema: 'qi-ux-signals/v1', fetched_utc: now(), source: `${s.url.hostname}${s.url.pathname}`, period: { from: p.from, to: p.to }, ...rows, notes: notes.slice(0, 50) }, null, 2)}\n`);
  return { period: p, dir, file, fetched: true, ...summary(readJson(file)) };
}
const summary = (x) => ({ rows: Object.fromEntries(['builds', 'features', 'friction', 'funnels', 'trails'].map((k) => [k, (x?.[k] ?? []).length])), dropped: x?.dropped ?? 0, notes: x?.notes ?? [] });

// ------------------------------------------------------------------ score ----
const EVIDENCE = { rage_click: 'video', dead_click: 'video', nav_bounce: 'video', abandoned_dialog: 'video', error_shown: 'screenshot', js_error: 'screenshot', slow_request: 'screenshot' };
const HINT = { slow_request: 'slow', js_error: 'functional' };
const newestMap = (build) => {
  const own = join(WORK, 'inventory', String(build ?? ''), 'inventory.json');
  if (build && existsSync(own)) return own;
  const all = (() => { try { return readdirSync(join(WORK, 'inventory')); } catch { return []; } })()
    .map((b) => join(WORK, 'inventory', b, 'inventory.json')).filter(existsSync);
  return all.sort((a, b) => statSync(a).mtimeMs - statSync(b).mtimeMs).at(-1) ?? null;
};

function score(file, s) {
  const sig = readJson(file);
  if (sig?.schema !== 'qi-ux-signals/v1') die(`${file} is not a qi-ux-signals/v1 file`);
  const from = Date.parse(sig.period.from);
  const firstSeen = new Map(sig.builds.map((b) => [b.version, Date.parse(b.firstSeen)]));
  const newest = sig.builds.slice().sort((a, b) => Date.parse(b.firstSeen) - Date.parse(a.firstSeen))[0]?.version ?? null;
  const passing = sig.friction.filter((r) => r.users >= s.minUsers && r.rate >= s.minRate);
  const candidates = passing.map((r) => {
    const trend = r.prevRate == null ? null : r.prevRate === 0 ? null : Math.round((r.rate / r.prevRate) * 100) / 100;
    const fresh = (firstSeen.get(r.build) ?? -Infinity) >= from;
    // A jump right after a new build: the build came out in this period, and the rate is new or 1.5× the last period's.
    const regression = fresh && (r.prevRate == null || r.rate >= 1.5 * r.prevRate);
    const factor = r.prevRate == null || r.prevRate === 0 ? (fresh ? 2 : 1) : Math.min(4, Math.max(0.5, r.rate / r.prevRate));
    return { fingerprint: fingerprint(r.signal, r.route, r.element), signal: r.signal, route: r.route, element: r.element, build: r.build,
      users: r.users, events: r.events, views: r.views, rate: r.rate, prev_rate: r.prevRate, trend, regression,
      score: Math.round(r.users * r.rate * factor * (regression ? 2 : 1) * 1000) / 1000,
      hint: HINT[r.signal] ?? 'ui', evidence: EVIDENCE[r.signal],
      trails: sig.trails.filter((t) => t.signal === r.signal && routeKey(t.route) === routeKey(r.route) && t.element === r.element && t.build === r.build)
        .sort((a, b) => b.users - a.users).map((t) => t.id).slice(0, 5) };
  }).sort((a, b) => b.score - a.score || a.fingerprint.localeCompare(b.fingerprint));
  // Unused: pages of the UI map no feature row names, and elements (data-testid) a mapped page shows that no row of its page names.
  const mapFile = flags.inventory ?? newestMap(newest);
  const inv = mapFile ? readJson(mapFile) : null;
  const usedPages = new Set(sig.features.map((f) => routeKey(f.route)));
  const usedEls = new Set(sig.features.filter((f) => f.element).map((f) => `${routeKey(f.route)}|${f.element}`));
  const routes = Object.entries(inv?.routes ?? {}).filter(([, r]) => r && !r.error && !r.redirected);
  const unused = inv ? {
    map: mapFile, build: inv.build ?? null,
    pages: routes.filter(([p]) => !usedPages.has(routeKey(p))).map(([p, r]) => ({ pattern: p, title: str(r.title, 120) || null })),
    elements: routes.filter(([p]) => usedPages.has(routeKey(p))).flatMap(([p, r]) => (Array.isArray(r.testids) ? r.testids : [])
      .filter((t) => TESTID.test(String(t)) && !usedEls.has(`${routeKey(p)}|${t}`)).map((t) => ({ pattern: p, element: t }))),
    note: routes.some(([, r]) => Array.isArray(r.testids)) ? null : 'the UI map records no data-testid: elements not judged (map the build again)',
  } : { map: null, build: null, pages: [], elements: [], note: 'no UI map: unused pages and elements not judged' };
  const funnels = sig.funnels.map((f) => {
    const steps = f.steps.map((x, i) => ({ ...x, drop: i && f.steps[i - 1].users ? Math.round((1 - x.users / f.steps[i - 1].users) * 1000) / 1000 : 0 }));
    const worst = steps.slice(1).sort((a, b) => b.drop - a.drop)[0] ?? null;
    return { flow: f.flow, watched: s.flows.includes(f.flow), steps, worst: worst ? { step: worst.step, drop: worst.drop } : null };
  });
  const scored = { schema: 'qi-ux-scored/v1', generated_utc: now(), signals: file, period: sig.period, thresholds: { min_users: s.minUsers, min_rate: s.minRate },
    builds: sig.builds, newest_build: newest, candidates, below: sig.friction.length - passing.length, unused, funnels,
    flows_missing: s.flows.filter((f) => !sig.funnels.some((x) => x.flow === f)) };
  const dst = join(dirname(file), 'scored.json');
  atomic(dst, `${JSON.stringify(scored, null, 2)}\n`);
  return { scored: dst, candidates: candidates.length, regressions: candidates.filter((c) => c.regression).length, below: scored.below,
    unused_pages: unused.pages.length, unused_elements: unused.elements.length, flows_missing: scored.flows_missing };
}

// ------------------------------------------------------------------ due / plan ----
const register = () => readJson(REGISTER)?.findings ?? [];
const fieldOf = () => new Map(register().filter((f) => f.source === 'field').map((f) => [f.fingerprint, f]));
// Not evaluated on its build yet: no field finding, or one last seen on another build — but a dismissed one stays the operator's.
const fresh = (scored) => { const by = fieldOf(); return scored.candidates.filter((c) => { const f = by.get(c.fingerprint); return !f || (f.status !== 'dismissed' && f.last_seen !== c.build); }); };
const toResolve = (scored) => [...fieldOf().values()].filter((f) => f.status === 'open').map((f) => ({ id: f.id, build: quietBuild(f, scored) })).filter((x) => x.build);
const newestScored = () => {
  const all = (() => { try { return readdirSync(UX); } catch { return []; } })().map((d) => join(UX, d, 'scored.json')).filter(existsSync);
  return all.sort((a, b) => (readJson(a)?.period?.to ?? '').localeCompare(readJson(b)?.period?.to ?? '') || statSync(a).mtimeMs - statSync(b).mtimeMs).at(-1) ?? null;
};

function plan(file) {
  const scored = readJson(file);
  if (scored?.schema !== 'qi-ux-scored/v1') die(`${file} is not a qi-ux-scored/v1 file`);
  const max = flags.max !== undefined ? Number(flags.max) : regInt('ux_max_candidates', 3);
  if (!Number.isInteger(max) || max < 0) die(`--max '${flags.max}' is not a whole number`);
  const sig = readJson(scored.signals) ?? { trails: [] };
  const trails = new Map(sig.trails.map((t) => [t.id, t]));
  const maps = new Map();
  const pageOf = (build, route) => {
    if (!maps.has(build)) { const f = flags.inventory ?? newestMap(build); maps.set(build, f ? readJson(f) : null); }
    const hit = Object.entries(maps.get(build)?.routes ?? {}).find(([p]) => routeKey(p) === routeKey(route));
    return hit ? { pattern: hit[0], example: hit[1].example ?? null } : null;
  };
  // The reported build as the profile installs it (env.sh resolve → bin/versions --resolve).
  const installs = new Map();
  const installOf = (b) => {
    if (!installs.has(b)) {
      const r = spawnSync('bash', [join(here, 'env.sh'), 'resolve', b], { env: { ...process.env, WORK_DIR: WORK }, encoding: 'utf8', timeout: 120000 });
      let x = null; try { x = JSON.parse(r.stdout); } catch { /* below */ }
      installs.set(b, r.status === 0 && BUILD.test(String(x?.build ?? '')) ? { install: x.build, install_note: x.how === 'mapped' ? `build ${b} is chart ${x.build}` : null }
        : { install: null, install_note: `build ${b} not installable: ${str(r.stderr, 200) || `env.sh resolve exited ${r.status}`}` });
    }
    return installs.get(b);
  };
  return fresh(scored).slice(0, max).map((c) => ({ ...c, ...installOf(c.build), page: pageOf(c.build, c.route),
    evidence_dir: join(dirname(file), 'evidence', c.fingerprint),
    trails: c.trails.map((id) => trails.get(id)).filter(Boolean).map((t) => ({ id: t.id, users: t.users,
      steps: t.steps.map((s) => ({ ...s, page: pageOf(c.build, s.route) })) })) }));
}

// ------------------------------------------------------------------ report ----
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pct = (r) => (r == null ? '–' : `${Math.round(r * 1000) / 10} %`);
const abs = (p) => (!p ? null : isAbsolute(p) ? p : join(WORK, p));
function report(file) {
  const scored = readJson(file);
  if (scored?.schema !== 'qi-ux-scored/v1') die(`${file} is not a qi-ux-scored/v1 file`);
  const dir = join(dirname(file), 'report'); const media = join(dir, 'media');
  mkdirSync(media, { recursive: true });
  const copy = (p, name) => { const src = abs(p); if (!src || !existsSync(src)) return null; const n = `${name}${extname(src)}`; copyFileSync(src, join(media, n)); return `media/${n}`; };
  const field = register().filter((f) => f.source === 'field' && f.field?.period?.to === scored.period.to);
  const rows = field.map((f) => {
    const shot = copy(f.shot, `${f.id}-shot`); const video = copy(f.field?.video, `${f.id}-video`);
    return `<section><h3>${esc(f.id)} · ${esc(f.field.class)} · ${esc(f.field.signal)} on <code>${esc(f.pattern)}</code>${f.target ? ` — <code>${esc(f.target)}</code>` : ''}</h3>
<p>${esc(f.saw)}</p><p>${esc(f.field.users)} users, ${pct(f.field.rate)} of visits (last period ${pct(f.field.prev_rate)}) on build ${esc(f.field.build)}${f.field.regression ? ' — <b>a jump right after a new build</b>' : ''}.</p>
${shot ? `<img src="${shot}" alt="${esc(f.id)}" style="max-width:100%">` : ''}${video ? `<video src="${video}" controls style="max-width:100%"></video>` : ''}</section>`;
  }).join('\n');
  const list = (xs, f) => (xs.length ? `<ul>${xs.map((x) => `<li>${f(x)}</li>`).join('')}</ul>` : '<p>None.</p>');
  const html = `<title>UX signals ${esc(scored.period.from.slice(0, 10))} to ${esc(scored.period.to.slice(0, 10))}</title>
<style>body{font:15px/1.5 system-ui,sans-serif;max-width:60rem;margin:auto;padding:1rem}code{background:#f3f3f3;padding:0 .2em}section{border-top:1px solid #ddd;margin-top:1rem}</style>
<h1>How users use the UI: ${esc(scored.period.from.slice(0, 10))} to ${esc(scored.period.to.slice(0, 10))}</h1>
<p>Real-user data, as counts (at least ${esc(scored.thresholds.min_users)} users per row). ${esc(scored.candidates.length)} signals pass the thresholds; ${esc(scored.below)} do not.</p>
<h2>Findings from this period</h2>${rows || '<p>None.</p>'}
<h2>Pages that no user opened</h2>${list(scored.unused.pages, (p) => `<code>${esc(p.pattern)}</code>${p.title ? ` — ${esc(p.title)}` : ''}`)}
<h2>Controls that no user used</h2>${scored.unused.note ? `<p>${esc(scored.unused.note)}</p>` : ''}${list(scored.unused.elements, (e) => `<code>${esc(e.element)}</code> on <code>${esc(e.pattern)}</code>`)}
<h2>Flows</h2>${list(scored.funnels, (f) => `${esc(f.flow)}: ${f.steps.map((s) => `${esc(s.step)} ${esc(s.users)}`).join(' → ')}${f.worst ? ` — most users leave at ${esc(f.worst.step)} (${pct(f.worst.drop)})` : ''}`)}
${scored.flows_missing.length ? `<p>No data for the flows ${scored.flows_missing.map(esc).join(', ')}.</p>` : ''}`;
  atomic(join(dir, 'index.html'), html);
  return { dir, page: join(dir, 'index.html'), findings: field.length, unused_pages: scored.unused.pages.length, unused_elements: scored.unused.elements.length };
}

// ------------------------------------------------------------------ handoff ----
const handoffRows = () => { try { return readFileSync(HANDOFF, 'utf8').split('\n').slice(2).filter((l) => l.startsWith('|')).map((l) => l.split('|').slice(1, -1).map((c) => c.trim())); } catch { return []; } };
const sent = (id, build) => handoffRows().some(([i, b]) => i === id && b === build);
const desk = () => { const c = sh('cfg design_desk_channel'); return /^[CDG][A-Z0-9]{6,20}$/.test(c) ? c : null; };
// Why a finding cannot go to Design Desk, or null.
function refusal(f) {
  if (!f) return 'no such finding';
  if (f.status !== 'open') return `it is ${f.status}`;
  if (f.source === 'field') {
    if (!REPORTED.has(f.field?.class)) return `its class is ${f.field?.class ?? 'unknown'}: only bug, ux-friction and slow go to design`;
    if (f.field?.ui === false) return 'it is no UI defect: "create issue for" is its path';
    if (f.field?.judge?.agree !== true) return 'the judge did not confirm its evidence';
  }
  return null;
}
function message(f) {
  const sev = f.severity === 'major' ? (f.field?.regression || f.field?.class === 'bug' ? 'high' : 'medium') : 'low';
  const m = f.field;
  const what = m ? `${f.saw} — ${m.users} users in the period, ${pct(m.rate)} of visits${m.prev_rate != null ? ` (last period ${pct(m.prev_rate)})` : ''}${m.regression ? ', a jump right after a new build' : ''}` : f.saw;
  const steps = m?.steps?.length ? m.steps.map((s, i) => `${i + 1}. ${str(s, 200)}`).join(' ') : `1. Open ${f.pattern}${f.viewport && f.viewport !== '-' ? ` at ${f.viewport}` : ''}.`;
  const lines = ['🧪 Automated test finding — Quality Inspector',
    `Screen: ${f.pattern}${f.viewport && f.viewport !== '-' ? ` @ ${f.viewport}` : ''}${f.target ? ` — ${f.target}` : ''}`,
    `What happens: ${str(what, 600)}`, `Expected: ${str(m?.expected, 300) || '-'}`, `Steps: ${steps}`,
    `Build: ${f.last_seen}`, `Check: ${f.check}`, `Severity: ${sev}`, `Ref: ${str(sh('cfg marker_prefix') || 'quality-inspector', 40)}/${f.id}`];
  return lines.join('\n');
}

// ------------------------------------------------------------------ main ----
const cmd = pos[0];
const at = flags.now ? new Date(flags.now) : new Date();
if (!Number.isFinite(at.getTime())) die(`--now '${flags.now}' is not a time`);
if (cmd === 'fetch' || cmd === 'check') {
  const s = settings();
  if (s.off) { out({ due: false, off: s.off }); process.exit(cmd === 'check' ? 0 : 2); }
  if (cmd === 'fetch') { out(await fetchPeriod(s, at)); process.exit(0); }
  // No data is no error: the module is skipped with the reason (docs/ux-signals.md → The data).
  // check: fetch at most once a day (daily) or a week (weekly), then score the newest period.
  const cadence = sh('reg ux_signals');
  if (!['daily', 'weekly'].includes(cadence)) { out({ due: false, off: 'ux_signals is disabled' }); process.exit(0); }
  const last = newestScored();
  const age = last ? at.getTime() - Date.parse(readJson(last)?.period?.to ?? 0) : Infinity;
  let file = last;
  if (age >= (cadence === 'daily' ? 1 : 7) * 86400000) {
    const f = await fetchPeriod(s, at);
    if (f.nodata) { out({ due: false, nodata: f.nodata, period: f.period }); process.exit(0); }
    score(f.file, s); file = join(f.dir, 'scored.json');
  }
  const scored = readJson(file);
  const n = fresh(scored).length; const r = toResolve(scored).length;
  out({ due: n + r > 0, period: scored.period, scored: file, new: n, resolve: r,
    reason: n + r ? `${n} signal(s) not evaluated on their build, ${r} finding(s) quiet since a newer build` : 'nothing new above the thresholds' });
} else if (cmd === 'score') {
  if (!pos[1]) die('usage: ux-signals.mjs score <signals.json> [--inventory FILE]');
  const s = settings();
  if (s.off) die(s.off);
  out(score(resolve(pos[1]), s));
} else if (cmd === 'plan') {
  if (!pos[1]) die('usage: ux-signals.mjs plan <scored.json> [--max N] [--inventory FILE]');
  out(plan(resolve(pos[1])));
} else if (cmd === 'report') {
  if (!pos[1]) die('usage: ux-signals.mjs report <scored.json>');
  out(report(resolve(pos[1])));
} else if (cmd === 'handoff') {
  const id = pos[1];
  if (!/^D-\d{1,6}$/.test(String(id ?? ''))) die('usage: ux-signals.mjs handoff D-<k> [--sent]');
  const f = register().find((x) => x.id === id);
  const why = refusal(f);
  if (why) die(`${id} does not go to design: ${why}`);
  const channel = desk();
  if (!channel) die('design_desk_channel is not set to a Slack conversation id');
  if (sent(id, f.last_seen)) die(`${id} was already sent to design for build ${f.last_seen}`);
  if (flags.sent) {
    if (!existsSync(HANDOFF)) atomic(HANDOFF, HANDOFF_HEADER);
    writeFileSync(HANDOFF, `${readFileSync(HANDOFF, 'utf8')}| ${id} | ${f.last_seen} | ${channel} | ${now()} |\n`);
    out({ id, build: f.last_seen, recorded: true });
  } else {
    const shot = abs(f.shot) && existsSync(abs(f.shot)) ? abs(f.shot) : abs(f.crop) && existsSync(abs(f.crop)) ? abs(f.crop) : null;
    out({ id, channel, text: message(f), attachment: shot, ref: `${sh('cfg marker_prefix') || 'quality-inspector'}/${id}`, key: `desk@${id}@${f.last_seen}` });
  }
} else if (cmd === 'handoff-plan') {
  if (sh('reg ux_handoff') !== 'auto' || !desk()) out([]);
  else out(register().filter((f) => f.source === 'field' && !refusal(f) && !sent(f.id, f.last_seen)).map((f) => f.id));
} else die(`usage: ux-signals.mjs fetch | check | score <signals.json> | plan <scored.json> | report <scored.json> | handoff D-<k> [--sent] | handoff-plan (${basename(process.argv[1])})`);
