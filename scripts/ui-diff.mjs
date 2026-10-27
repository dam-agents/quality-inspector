#!/usr/bin/env node
// ui-diff.mjs — what changed between two UI maps (ui-inventory.mjs): pages added or
// removed, and per control (heading, nav item, button, tab, field, link) whether it was
// added, removed, renamed on the same page, or moved to another page; and the page signals
// that are new: console errors, failed requests, and pages whose load grew more than
// --perf-factor (default 2.0) and by at least 1000 ms. A failed request the installed profile
// declares expected (profile.json → expected_requests, lib/expected-requests.mjs) is never new.
// Deterministic; the agent judges what a change means (docs/change-awareness.md).
//
//   node ui-diff.mjs <old-inventory.json> <new-inventory.json> [--md] [--perf-factor 2.0]
//
// JSON on stdout; --md prints the same as a short markdown summary. A map recorded before
// signals existed has none to compare: the signal lists stay empty.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { isExpected, profileExpected } from './lib/expected-requests.mjs';

const argv = process.argv.slice(2);
const fi = argv.indexOf('--perf-factor');
const [a, b] = argv.filter((x, i) => !x.startsWith('--') && !(fi >= 0 && i === fi + 1));
if (!a || !b) { console.error('usage: ui-diff.mjs <old.json> <new.json> [--md] [--perf-factor 2.0]'); process.exit(2); }
const md = argv.includes('--md');
const FACTOR = fi >= 0 ? Number(argv[fi + 1]) : 2.0;
const FLOOR_MS = 1000; // absolute growth below this is noise, whatever the factor
if (!(FACTOR > 1)) { console.error('--perf-factor must be a number above 1'); process.exit(2); }
const load = (f) => JSON.parse(readFileSync(f, 'utf8')).routes ?? {};
const oldR = load(a);
const newR = load(b);
const KINDS = ['headings', 'nav', 'buttons', 'tabs', 'inputs', 'links'];
const linkName = (s) => s.split(' → ')[0];

// kind|name -> set of routes it appears on
function index(routes) {
  const m = new Map();
  for (const [route, r] of Object.entries(routes)) {
    for (const k of KINDS) for (const raw of r[k] ?? []) {
      const name = k === 'links' ? linkName(raw) : raw;
      const key = `${k}|${name}`;
      if (!m.has(key)) m.set(key, new Set());
      m.get(key).add(route);
    }
  }
  return m;
}
const oi = index(oldR);
const ni = index(newR);

// Similarity of two labels: token Jaccard blended with normalized edit distance.
function lev(x, y) {
  const d = Array.from({ length: x.length + 1 }, (_, i) => [i]);
  for (let j = 1; j <= y.length; j++) d[0][j] = j;
  for (let i = 1; i <= x.length; i++) for (let j = 1; j <= y.length; j++)
    d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (x[i - 1] === y[j - 1] ? 0 : 1));
  return d[x.length][y.length];
}
function sim(x, y) {
  const p = x.toLowerCase(); const q = y.toLowerCase();
  const tp = new Set(p.split(/\W+/).filter(Boolean)); const tq = new Set(q.split(/\W+/).filter(Boolean));
  const inter = [...tp].filter((t) => tq.has(t)).length;
  const jac = inter / (new Set([...tp, ...tq]).size || 1);
  const ed = 1 - lev(p, q) / Math.max(p.length, q.length, 1);
  return Math.max(jac, ed);
}

const pagesAdded = Object.keys(newR).filter((r) => !(r in oldR));
const pagesRemoved = Object.keys(oldR).filter((r) => !(r in newR));
const moved = [];
let added = [];
let removed = [];
for (const [key, routes] of oi) {
  const [kind, name] = key.split('|');
  const now = ni.get(key);
  if (!now) { removed.push({ kind, name, routes: [...routes] }); continue; }
  const from = [...routes].filter((r) => !now.has(r));
  const to = [...now].filter((r) => !routes.has(r));
  if (from.length && to.length) moved.push({ kind, name, from, to });
}
for (const [key, routes] of ni) if (!oi.has(key)) { const [kind, name] = key.split('|'); added.push({ kind, name, routes: [...routes] }); }

// A removal and an addition of the same kind on a shared page, with similar labels, is a rename.
const renamed = [];
for (const r of [...removed]) {
  let best = null;
  for (const n of added) {
    if (n.kind !== r.kind || !n.routes.some((x) => r.routes.includes(x))) continue;
    const s = sim(r.name, n.name);
    if (s >= 0.5 && (!best || s > best.s)) best = { n, s };
  }
  if (best) {
    renamed.push({ kind: r.kind, from: r.name, to: best.n.name, routes: best.n.routes.filter((x) => r.routes.includes(x)), similarity: Number(best.s.toFixed(2)) });
    removed = removed.filter((x) => x !== r);
    added = added.filter((x) => x !== best.n);
  }
}
// A removal and an addition of the same label on different pages is a move.
for (const r of [...removed]) {
  const n = added.find((x) => x.kind === r.kind && x.name === r.name);
  if (n) { moved.push({ kind: r.kind, name: r.name, from: r.routes, to: n.routes }); removed = removed.filter((x) => x !== r); added = added.filter((x) => x !== n); }
}

// Controls that lived only on a removed page, or live only on an added one, are covered
// by the page entry. A label swap with no textual likeness (a renamed tab) is offered as
// a likely rename when one control left and one arrived in exactly the same places.
const onlyOn = (x, pages) => x.routes.every((r) => pages.includes(r));
removed = removed.filter((x) => !onlyOn(x, pagesRemoved));
added = added.filter((x) => !onlyOn(x, pagesAdded));
// With several candidates on the same pages, the one at the same position in its list wins.
const places = (x, gone) => x.routes.filter((r) => !gone.includes(r)).sort().join(',');
const pos = (routes, route, kind, name) => (routes[route]?.[kind] ?? []).map((s) => (kind === 'links' ? linkName(s) : s)).indexOf(name);
for (const r of [...removed]) {
  const key = places(r, pagesRemoved);
  if (!key) continue;
  const route = key.split(',')[0];
  let peers = added.filter((n) => n.kind === r.kind && places(n, pagesAdded) === key);
  const twins = removed.filter((x) => x.kind === r.kind && places(x, pagesRemoved) === key);
  if (peers.length > 1 || twins.length > 1) {
    const at = pos(oldR, route, r.kind, r.name);
    peers = peers.filter((n) => pos(newR, route, n.kind, n.name) === at);
  }
  if (peers.length === 1) {
    renamed.push({ kind: r.kind, from: r.name, to: peers[0].name, routes: key.split(','), similarity: Number(sim(r.name, peers[0].name).toFixed(2)), basis: 'same-place' });
    removed = removed.filter((x) => x !== r);
    added = added.filter((x) => x !== peers[0]);
  }
}

// Signals: only when both maps recorded them (a page missing from the old map counts as
// clean there). Timing values are the inventory's medians when it took several samples.
const hasSignals = (routes) => Object.values(routes).some((r) => Array.isArray(r.console_errors));
const signals = hasSignals(oldR) && hasSignals(newR);
const reqKey = (q) => `${q.method} ${q.path} ${q.status}`;
const expected = signals ? profileExpected().list : [];
const shot = (r) => (newR[r]?.shot ? join(dirname(b), newR[r].shot) : null);
const consoleNew = [];
const requestsNew = [];
const slower = [];
for (const [route, r] of signals ? Object.entries(newR) : []) {
  const o = oldR[route] ?? {};
  const errors = (r.console_errors ?? []).filter((e) => !(o.console_errors ?? []).includes(e));
  if (errors.length) consoleNew.push({ route, errors, shot: shot(route) });
  const was = new Set((o.failed_requests ?? []).map(reqKey));
  const requests = (r.failed_requests ?? []).filter((q) => !was.has(reqKey(q)) && !isExpected(expected, q.method, q.path, q.status));
  if (requests.length) requestsNew.push({ route, requests, shot: shot(route) });
  const t0 = o.timing?.load_ms; const t1 = r.timing?.load_ms;
  if (typeof t0 === 'number' && typeof t1 === 'number' && t0 > 0 && t1 > t0 * FACTOR && t1 - t0 >= FLOOR_MS) {
    slower.push({ route, old_load_ms: t0, new_load_ms: t1, factor: Number((t1 / t0).toFixed(1)) });
  }
}

const diff = { pages_added: pagesAdded, pages_removed: pagesRemoved, renamed, moved, added, removed,
  unchanged: Object.keys(newR).length - pagesAdded.length === Object.keys(oldR).length - pagesRemoved.length && !renamed.length && !moved.length && !added.length && !removed.length,
  console_errors_new: consoleNew, failed_requests_new: requestsNew, slower_pages: slower, perf_factor: FACTOR };

if (!md) { console.log(JSON.stringify(diff, null, 2)); process.exit(0); }
const L = [];
const sing = { headings: 'heading', nav: 'nav item', buttons: 'button', tabs: 'tab', inputs: 'field', links: 'link' };
if (diff.unchanged) L.push('No UI change between the two builds.');
if (pagesAdded.length) L.push(`**Pages added:** ${pagesAdded.map((p) => `\`${p}\``).join(', ')}`);
if (pagesRemoved.length) L.push(`**Pages removed:** ${pagesRemoved.map((p) => `\`${p}\``).join(', ')}`);
const where = (rs) => (rs.length > 3 ? `${rs.length} pages` : rs.map((x) => `\`${x}\``).join(', '));
for (const r of renamed) L.push(`- ${r.basis ? 'likely renamed (same place, unlike text)' : 'renamed'} ${sing[r.kind]} "${r.from}" → "${r.to}" on ${where(r.routes)}`);
for (const m of moved) L.push(`- moved ${sing[m.kind]} "${m.name}" from ${where(m.from)} to ${where(m.to)}`);
for (const x of removed) L.push(`- removed ${sing[x.kind]} "${x.name}" from ${where(x.routes)}`);
for (const x of added) L.push(`- added ${sing[x.kind]} "${x.name}" on ${where(x.routes)}`);
if (consoleNew.length) L.push('**New console errors:**', ...consoleNew.flatMap((c) => c.errors.map((e) => `- \`${c.route}\`: ${e}`)));
if (requestsNew.length) L.push('**New failed requests:**', ...requestsNew.flatMap((c) => c.requests.map((q) => `- \`${c.route}\`: ${q.method} ${q.path} → ${q.status}`)));
if (slower.length) L.push(`**Slower pages** (load > ${FACTOR}× and +${FLOOR_MS} ms):`, ...slower.map((s) => `- \`${s.route}\`: ${s.old_load_ms} ms → ${s.new_load_ms} ms (${s.factor}×)`));
console.log(L.join('\n'));
