#!/usr/bin/env node
// coverage.mjs — which pages of the UI map (ui-inventory.mjs) the suite reaches, and which
// it does not. A page is covered when a `regression`-tier test opens it by URL or names one
// of its own controls in a quoted string. Deterministic and read-only; matching shared
// with impact.mjs (lib/match.mjs). docs/change-awareness.md → Coverage.
//
//   node coverage.mjs <inventory.json> <SUITE.md> <test-file>... [--md]
//     -> {"pages":[{pattern, title, tests:[{test, tier}], covered}], "uncovered":[…],
//         "nav_without_golden_path":[{item, target}]}
//   --md prints work/COVERAGE.md instead (its header is COVERAGE_HEADER in lib/state.sh).

import { existsSync, readFileSync } from 'node:fs';
import { controlRe, esc, matchable, pageRe } from './lib/match.mjs';

const args = process.argv.slice(2);
const md = args.includes('--md');
const [invPath, suitePath, ...files] = args.filter((a) => a !== '--md');
if (!invPath || !suitePath) { console.error('usage: coverage.mjs <inventory.json> <SUITE.md> <test-file>... [--md]'); process.exit(2); }
const inv = JSON.parse(readFileSync(invPath, 'utf8'));
const routes = inv.routes ?? {};

// Tier per SUITE.md row; a file without a row is `untracked`.
const tiers = new Map();
let suite = '';
try { suite = readFileSync(suitePath, 'utf8'); } catch { /* no suite table yet */ }
for (const row of suite.split('\n').filter((l) => l.startsWith('|')).slice(2)) {
  const c = row.split('|').map((x) => x.trim());
  if (c[1]) tiers.set(c[1], c[3]);
}
// An unexpanded glob (no test files yet) is not a file.
const tests = files.filter((f) => existsSync(f)).map((f) => {
  const key = [...tiers.keys()].find((t) => f === t || f.endsWith(`/${t}`));
  return { test: key ?? f, tier: key ? tiers.get(key) : 'untracked', src: readFileSync(f, 'utf8') };
});

// A control counts for a page only when no other page shows the same label: shared chrome
// (navigation, a "Save" on every form) would otherwise cover every page at once.
const KINDS = ['headings', 'buttons', 'tabs', 'inputs', 'links'];
const label = (k, s) => (k === 'links' ? s.split(' → ')[0] : s);
const own = (r) => [...new Set(KINDS.flatMap((k) => (r[k] ?? []).map((s) => label(k, s))))].filter(matchable);
const pagesOf = new Map();
for (const [p, r] of Object.entries(routes)) for (const n of own(r)) {
  const k = n.toLowerCase();
  pagesOf.set(k, (pagesOf.get(k) ?? new Set()).add(p));
}

const pages = Object.entries(routes).map(([pattern, r]) => {
  const opens = pageRe(pattern);
  const names = own(r).filter((n) => pagesOf.get(n.toLowerCase()).size === 1).map((n) => controlRe(n, { quoted: true }));
  const hit = tests.filter((t) => opens.test(t.src) || names.some((re) => re.test(t.src)));
  return { pattern, title: r.title ?? null, tests: hit.map(({ test, tier }) => ({ test, tier })), covered: hit.some((t) => t.tier === 'regression') };
});
const covered = new Map(pages.map((p) => [p.pattern, p.covered]));

// Top-level navigation: the root page's nav items and the page each one leads to.
const routeFor = (path) => (path in routes ? path
  : Object.keys(routes).find((p) => new RegExp(`^${p.split('/').map((s) => (s === ':id' ? '[^/]+' : esc(s))).join('/')}/?$`).test(path)) ?? null);
const root = routes['/'] ?? Object.values(routes)[0] ?? {};
const viaLink = (r, item) => (r.links ?? []).map((s) => s.split(' → ')).find(([n]) => n === item)?.[1];
const target = (item) => root.navigates?.[item]
  ?? Object.values(routes).map((r) => r.navigates?.[item]).find(Boolean)
  ?? routeFor(viaLink(root, item) ?? Object.values(routes).map((r) => viaLink(r, item)).find(Boolean) ?? '');
const nav = (root.nav ?? []).map((item) => ({ item, target: target(item) ?? null }))
  .filter((n) => !n.target || !covered.get(n.target));

const out = { pages, uncovered: pages.filter((p) => !p.covered).map((p) => p.pattern), nav_without_golden_path: nav };
if (!md) { console.log(JSON.stringify(out, null, 2)); process.exit(0); }

const cellEsc = (s) => String(s ?? '-').replace(/\|/g, '\\|');
const L = ['# Coverage — pages of the newest UI map and the tests that reach them (docs/change-awareness.md → Coverage)', '',
  `Map: ${inv.build ?? '?'} (${inv.generated_utc ?? '?'}) · pages ${pages.length} · covered ${pages.length - out.uncovered.length} · uncovered ${out.uncovered.length}`, '',
  '| page | title | tests | covered |', '| --- | --- | --- | --- |',
  ...pages.map((p) => `| ${cellEsc(p.pattern)} | ${cellEsc(p.title || '-')} | ${cellEsc(p.tests.map((t) => `${t.test} (${t.tier})`).join(', ') || '-')} | ${p.covered ? 'yes' : 'no'} |`),
  '', `Nav items without a golden path: ${nav.map((n) => `${n.item} → ${n.target ?? '?'}`).join(', ') || 'none'}`];
console.log(L.join('\n'));
