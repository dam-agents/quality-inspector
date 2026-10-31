// design-ledger.mjs — the two ledgers of the design checks (docs/design-checks.md → The ledgers):
// work/design-checks/PRS.md, each pull request build that had its design check, and
// work/design-checks/SENT.md, each Ref that went to the Design Desk or was held back. Append-only
// rows, each written under the mutex of lib/mutex.mjs; design-check.mjs and design-outbox.mjs are
// their one writers.

import { existsSync, mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { withMutex, writeAtomic } from './mutex.mjs';

const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
export const DIR = join(work, 'design-checks');
export const TABLES = {
  prs: { file: join(DIR, 'PRS.md'), title: '# Design checks — pull request builds checked (docs/design-checks.md)',
    cols: ['pr', 'build', 'findings', 'checked_utc'] },
  sent: { file: join(DIR, 'SENT.md'), title: '# Design checks — findings sent to the Design Desk, or held back (docs/design-checks.md)',
    cols: ['ref', 'status', 'check', 'severity', 'build', 'note', 'utc'] },
};
const header = (t) => `| ${t.cols.join(' | ')} |`;
export const UTC_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
export const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');

// rows(<table>) -> [{col: value}]; [] when the file is missing; throws on a changed header.
export function rows(name) {
  const t = TABLES[name];
  let text;
  try { text = readFileSync(t.file, 'utf8'); } catch { return []; }
  const lines = text.split('\n');
  const h = lines.indexOf(header(t));
  if (h < 0) throw new Error(`${t.file}: header changed — restore "${header(t)}" (docs/design-checks.md → The ledgers)`);
  return lines.slice(h + 2).filter((l) => l.startsWith('|'))
    .map((l) => Object.fromEntries(l.split('|').slice(1, -1).map((c, i) => [t.cols[i] ?? `x${i}`, c.trim()])));
}

// append(<table>, {col: value}): one row; a value loses `|` and line breaks; '-' for empty.
export function append(name, row) {
  const t = TABLES[name];
  mkdirSync(DIR, { recursive: true });
  return withMutex(`${t.file}.lock`, () => {
    const cell = (v) => (String(v ?? '').replace(/[|\r\n]+/g, ' ').trim() || '-');
    const line = `| ${t.cols.map((c) => cell(row[c])).join(' | ')} |\n`;
    const old = existsSync(t.file) ? readFileSync(t.file, 'utf8') : `${t.title}\n\n${header(t)}\n| ${t.cols.map(() => '---').join(' | ')} |\n`;
    if (!old.split('\n').includes(header(t))) throw new Error(`${t.file}: header changed — restore "${header(t)}" (docs/design-checks.md → The ledgers)`);
    writeAtomic(t.file, `${old}${old.endsWith('\n') ? '' : '\n'}${line}`);
    return true;
  });
}
