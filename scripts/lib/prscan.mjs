// prscan.mjs — the Change radar's ledger, work/PRSCAN.md (docs/radar.md → The ledger): one row per
// pull request it read — the hash of its sanitized text, its state, its merge time, its update time,
// the `predicted` proposals it holds open, the time of the scan. Read by scripts/radar.mjs (its one
// writer, under the mutex of lib/mutex.mjs) and by scripts/maintenance.mjs sweep (which proposal
// belongs to a pull request merged before a build).

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { writeAtomic } from './mutex.mjs';

const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
export const FILE = join(work, 'PRSCAN.md');
export const HEADER = '| pr | text_hash | state | merged_at | updated_at | proposals | scanned_utc |';
const TITLE = '# Change radar — pull requests read for their text alone (docs/radar.md)';
export const COLS = ['pr', 'text_hash', 'state', 'merged_at', 'updated_at', 'proposals', 'scanned_utc'];
export const STATES = ['open', 'merged', 'closed'];
export const UTC_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
export const M_RE = /^M-\d{1,6}$/;

const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
const cells = (text) => (text ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2)
  .map((l) => l.split('|').slice(1, -1).map((c) => c.trim()));

export const text = () => read(FILE);
export const rawRows = (t = text()) => cells(t);
// load() -> [{pr, text_hash, state, merged_at, updated_at, proposals: [M-k…], scanned_utc}]; throws on a changed header.
export function load() {
  const t = text();
  if (t != null && !t.split('\n').includes(HEADER)) throw new Error('work/PRSCAN.md: header changed — fix it to the format of docs/radar.md');
  return cells(t).map((r) => {
    const o = Object.fromEntries(COLS.map((k, j) => [k, r[j] ?? '-']));
    return { ...o, proposals: o.proposals.split(',').map((x) => x.trim()).filter((x) => M_RE.test(x)) };
  });
}
export function save(list) {
  const body = list.slice().sort((a, b) => +a.pr - +b.pr)
    .map((r) => `| ${COLS.map((k) => (k === 'proposals' ? r.proposals.join(', ') : r[k]) || '-').join(' | ')} |`);
  writeAtomic(FILE, `${TITLE}\n\n${HEADER}\n| ${COLS.map(() => '---').join(' | ')} |\n${body.join('\n')}${body.length ? '\n' : ''}`);
}
// The pull requests that hold a proposal: [{pr, state, merged_at}].
export const holders = (list, id) => list.filter((r) => r.proposals.includes(id));
