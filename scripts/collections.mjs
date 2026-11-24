#!/usr/bin/env node
// collections.mjs — the operator's collections of tests, work/CATALOG.md (docs/catalog.md → Describing and
// categorizing): `| collection | members |`, the members comma-separated (#42, #42 AC-1, S-7, S-7 AC-1).
// The operator's word only: in the direct session, or pressed on the dashboard (the dashboard server's own
// child, lib/util.mjs → dashboardWriter). Local only.
//
//   node collections.mjs add <name> <ref>…      -> {"collection", "members"}   a new name makes the collection
//   node collections.mjs remove <name> <ref>…   -> {"collection", "members"}   an emptied collection goes
//
// <name>: letters, digits, spaces and _ . - (at most 40, the first a letter or digit). <ref>: #N[ AC-k|IN-k] or
// S-k[ AC-j], one argument each. Exit 2: usage, a bad name or ref, or not the operator's word.
import { renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { WORK, dashboardWriter, read, sh } from './lib/util.mjs';

const FILE = join(WORK, 'CATALOG.md');
const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9 _.-]{0,39}$/;
const REF_RE = /^(#\d{1,7}( (AC|IN)-\d{1,3})?|S-\d{1,6}( AC-\d{1,3})?)$/;
const die = (m) => { process.stderr.write(`collections.mjs: ${m}\n`); process.exit(2); };

const [cmd, name, ...refs] = process.argv.slice(2);
if (!['add', 'remove'].includes(cmd) || !name || !refs.length) die('usage: collections.mjs add|remove <name> <ref>…');
if (!NAME_RE.test(name)) die(`"${name}" is not a collection's name`);
for (const r of refs) if (!REF_RE.test(r)) die(`"${r}" is not a test (#N, #N AC-k, S-k, S-k AC-j)`);
if (sh('direct_session && echo yes') !== 'yes' && !dashboardWriter()) die(`${cmd} is the operator's, in the direct session or on the dashboard only`);

const text = read(FILE) ?? '';
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
writeFileSync(`${FILE}.tmp`, out); renameSync(`${FILE}.tmp`, FILE);
process.stdout.write(`${JSON.stringify({ collection: name, members: next })}\n`);
