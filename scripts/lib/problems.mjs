// problems.mjs (lib) — the dashboard's problems F-<k> and the one writer of their dismissals,
// work/PROBLEMS.md `| problem | dismissed_utc | reason |` (docs/dashboard-page.md → Problems).
// scripts/problems.mjs calls it in the operator's direct session; the dashboard server for the
// operator's own press (docs/modules.md → Control).
//
// A problem is one by its words: its title and where it is. The page numbers them F-1, F-2 … by when
// a run found each first (page.html → problems()); this file numbers them the same way, so F-<k> in a
// command names the problem the page showed. The row keeps the problem's words, not its number: a
// dismissal stays with its problem when the numbers move.
import { renameSync, writeFileSync } from 'node:fs';
import { read } from './util.mjs';

export const REASONS = ['false-positive', 'wont-fix', 'duplicate', 'by-design'];
const HEAD = '| problem | dismissed_utc | reason |';

// The runs as the page orders them: R-<n> by when they ran (a number the data gives wins), oldest first.
function ordered(runs) {
  const all = (Array.isArray(runs) ? runs : []).map((r) => ({ ...r }));
  all.slice().sort((a, b) => String(a.utc).localeCompare(String(b.utc)) || `${a.type}${a.ref}`.localeCompare(`${b.type}${b.ref}`))
    .forEach((r, n) => { if (!/^R-\d+$/.test(r.id || '')) r.id = `R-${n + 1}`; });
  return all.sort((a, b) => String(a.utc).localeCompare(String(b.utc)) || +a.id.slice(2) - +b.id.slice(2));
}
// [{id: "F-<k>", key: "<title>|<where>", title}] in the page's numbering.
export function problemIds(runs) {
  const keys = new Map();
  for (const r of ordered(runs)) {
    const found = [...(r.analysis?.problems || []), ...(r.failure ? [{ title: 'The product could not start', where: null }] : [])];
    for (const p of found) { const k = `${p.title}|${p.where || ''}`; if (!keys.has(k)) keys.set(k, p.title); }
  }
  return [...keys].map(([key, title], n) => ({ id: `F-${n + 1}`, key, title }));
}
// A cell cannot hold a pipe or a line break: the key is written with them escaped, read back the same.
const cell = (k) => String(k).replace(/\\/g, '\\\\').replace(/\|/g, '\\p').replace(/\r?\n/g, ' ');
const uncell = (c) => String(c).replace(/\\(p|\\)/g, (_, x) => (x === 'p' ? '|' : '\\'));
const rowsOf = (text) => (text ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2)
  .map((l) => l.slice(1, -1).split(' | ').map((x) => x.trim())).filter(([k]) => k);
// [{key, utc, reason}] — the dismissed problems.
export function dismissedProblems(file) {
  return rowsOf(read(file)).map(([k, utc, reason]) => ({ key: uncell(k), utc: utc || null, reason: REASONS.includes(reason) ? reason : null }));
}
// dismiss|reopen F-<k> [reason]: by the runs of the catalog data. Returns what it did.
export function changeProblem(file, runs, cmd, id, reason, now) {
  if (!['dismiss', 'reopen'].includes(cmd)) throw new Error('dismiss or reopen');
  if (reason != null && !REASONS.includes(reason)) throw new Error(`"${reason}" is not a reason (${REASONS.join(', ')})`);
  const p = problemIds(runs).find((x) => x.id === id);
  if (!p) throw new Error(`${id} is not a problem the page shows`);
  const had = dismissedProblems(file), on = had.some((x) => x.key === p.key);
  if (cmd === 'dismiss' && on) return { id, title: p.title, dismissed: false, reason: 'already dismissed' };
  if (cmd === 'reopen' && !on) return { id, title: p.title, reopened: false, reason: 'not dismissed' };
  const next = cmd === 'dismiss' ? [...had, { key: p.key, utc: now, reason: reason ?? null }] : had.filter((x) => x.key !== p.key);
  const out = `# Dismissed problems\n\n${HEAD}\n| --- | --- | --- |\n${next.map((x) => `| ${cell(x.key)} | ${x.utc ?? '-'} | ${x.reason ?? '-'} |\n`).join('')}`;
  writeFileSync(`${file}.tmp`, out); renameSync(`${file}.tmp`, file);
  return cmd === 'dismiss' ? { id, title: p.title, dismissed: true } : { id, title: p.title, reopened: true };
}
export { ordered as orderedRuns };
