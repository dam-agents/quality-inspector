// collections.mjs (lib) — the one writer of work/CATALOG.md's collections table, `| collection | members |`
// (docs/catalog.md → Describing and categorizing). scripts/collections.mjs calls it in the operator's direct
// session; the dashboard server for the operator's own press (docs/modules.md → Control).
import { renameSync, writeFileSync } from 'node:fs';
import { read } from './util.mjs';

export const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}$/;
export const REF_RE = /^(#\d{1,7}( (AC|IN)-\d{1,3})?|S-\d{1,6}( AC-\d{1,3})?)$/;

// add|remove <refs> in <name>: a new name makes the collection, an emptied one goes. Returns its members.
export function changeCollection(file, cmd, name, refs) {
  if (!['add', 'remove'].includes(cmd)) throw new Error('add or remove');
  if (!NAME_RE.test(name ?? '')) throw new Error(`"${name}" is not a collection's name`);
  for (const r of refs) if (!REF_RE.test(r)) throw new Error(`"${r}" is not a test (#N, #N AC-k, S-k, S-k AC-j)`);
  const text = read(file) ?? '';
  const lines = text.split('\n');
  const head = lines.findIndex((l) => /^\|\s*collection\s*\|\s*members\s*\|/.test(l));
  const rows = new Map();
  if (head >= 0) for (const l of lines.slice(head + 2)) {
    if (!l.startsWith('|')) break;
    const [n, m] = l.split('|').slice(1, -1).map((c) => c.trim());
    if (n) rows.set(n, (m ?? '').split(',').map((x) => x.trim()).filter(Boolean));
  }
  const members = rows.get(name) ?? [];
  const next = cmd === 'add' ? [...members, ...refs.filter((r) => !members.includes(r))] : members.filter((m) => !refs.includes(m));
  if (next.length) rows.set(name, next); else rows.delete(name);
  const table = ['| collection | members |', '| --- | --- |', ...[...rows].map(([n, m]) => `| ${n} | ${m.join(', ')} |`)];
  let out;
  if (head >= 0) {
    let end = head + 2; while (end < lines.length && lines[end].startsWith('|')) end++;
    out = [...lines.slice(0, head), ...table, ...lines.slice(end)].join('\n');
  } else out = `${text.trim() ? `${text.trimEnd()}\n\n` : '# Catalog collections\n\n'}${table.join('\n')}\n`;
  writeFileSync(`${file}.tmp`, out); renameSync(`${file}.tmp`, file);
  return next;
}
