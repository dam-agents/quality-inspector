#!/usr/bin/env node
// iface-diff.mjs — what changed between two interface snapshots (iface-snapshot.mjs): CLI
// commands and flags, API endpoints and response fields, removed and added. Deterministic;
// the agent judges what a change means (docs/change-awareness.md).
//
//   node iface-diff.mjs <old-iface.json> <new-iface.json> [--md]
//
// JSON on stdout; --md prints the same as a short markdown summary. A missing snapshot (the
// profile names no interfaces, or the previous build had none) -> {"skipped": …}, exit 0.

import { existsSync, readFileSync } from 'node:fs';

const [a, b] = process.argv.slice(2).filter((x) => !x.startsWith('--'));
if (!a || !b) { console.error('usage: iface-diff.mjs <old-iface.json> <new-iface.json> [--md]'); process.exit(2); }
const md = process.argv.includes('--md');
const missing = [a, b].find((f) => !existsSync(f));
if (missing) {
  const skipped = `no interface snapshot at ${missing}`;
  console.log(md ? `Interface diff skipped: ${skipped}.` : JSON.stringify({ skipped }));
  process.exit(0);
}
const [o, n] = [a, b].map((f) => JSON.parse(readFileSync(f, 'utf8')));

const notes = [];
const minus = (x, y) => Object.keys(x).filter((k) => !(k in y));
const d = {
  program: n.cli?.program ?? o.cli?.program ?? null,
  commands_removed: [], commands_added: [], flags_removed: [], flags_added: [],
  endpoints_removed: [], endpoints_added: [], fields_removed: [], fields_added: [],
};

// Only two readable sides compare; an error on either is a note, never "everything removed".
const usable = (side, name, label) => {
  if (!side) return null;
  if (side.error) { notes.push(`${name} ${label}: ${side.error}`); return null; }
  return side;
};
const oc = usable(o.cli, 'cli', o.build ?? 'old');
const nc = usable(n.cli, 'cli', n.build ?? 'new');
if (oc?.commands && nc?.commands) {
  d.commands_removed = minus(oc.commands, nc.commands).map((command) => ({ command }));
  d.commands_added = minus(nc.commands, oc.commands).map((command) => ({ command }));
  for (const c of Object.keys(oc.commands).filter((k) => k in nc.commands)) {
    for (const flag of oc.commands[c]) if (!nc.commands[c].includes(flag)) d.flags_removed.push({ command: c, flag });
    for (const flag of nc.commands[c]) if (!oc.commands[c].includes(flag)) d.flags_added.push({ command: c, flag });
  }
} else if (!!o.cli !== !!n.cli) notes.push('the CLI is in one snapshot only');

const oa = usable(o.api, 'api', o.build ?? 'old');
const na = usable(n.api, 'api', n.build ?? 'new');
if (oa?.endpoints && na?.endpoints) {
  const pathOf = (ep) => ep.slice(ep.indexOf(' ') + 1);
  const newPaths = new Set(Object.keys(na.endpoints).map(pathOf));
  d.endpoints_removed = minus(oa.endpoints, na.endpoints).map((endpoint) => ({ endpoint, path_remains: newPaths.has(pathOf(endpoint)) }));
  d.endpoints_added = minus(na.endpoints, oa.endpoints).map((endpoint) => ({ endpoint }));
  for (const ep of Object.keys(oa.endpoints).filter((k) => k in na.endpoints)) {
    for (const field of oa.endpoints[ep]) if (!na.endpoints[ep].includes(field)) d.fields_removed.push({ endpoint: ep, field });
    for (const field of na.endpoints[ep]) if (!oa.endpoints[ep].includes(field)) d.fields_added.push({ endpoint: ep, field });
  }
} else if (!!o.api !== !!n.api) notes.push('the API description is in one snapshot only');

const lists = ['commands_removed', 'commands_added', 'flags_removed', 'flags_added', 'endpoints_removed', 'endpoints_added', 'fields_removed', 'fields_added'];
d.unchanged = lists.every((k) => !d[k].length);
d.notes = notes;

if (!md) { console.log(JSON.stringify(d, null, 2)); process.exit(0); }
const cmd = (c) => `\`${[d.program, c].filter(Boolean).join(' ')}\``;
const L = [];
if (d.unchanged) L.push('No CLI or API change between the two builds.');
for (const x of d.commands_removed) L.push(`- removed command ${cmd(x.command)}`);
for (const x of d.flags_removed) L.push(`- removed flag \`${x.flag}\` of ${cmd(x.command)}`);
for (const x of d.endpoints_removed) L.push(`- removed endpoint \`${x.endpoint}\``);
for (const x of d.fields_removed) L.push(`- removed response field \`${x.field}\` of \`${x.endpoint}\``);
for (const x of d.commands_added) L.push(`- added command ${cmd(x.command)}`);
for (const x of d.flags_added) L.push(`- added flag \`${x.flag}\` of ${cmd(x.command)}`);
for (const x of d.endpoints_added) L.push(`- added endpoint \`${x.endpoint}\``);
for (const x of d.fields_added) L.push(`- added response field \`${x.field}\` of \`${x.endpoint}\``);
for (const x of notes) L.push(`- note: ${x}`);
console.log(L.join('\n'));
