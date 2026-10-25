#!/usr/bin/env node
// impact.mjs — which tests a change touches, before they run: every regression test whose
// source names a page or a control that the UI diff (ui-diff.mjs) reports as removed,
// renamed or moved, or a CLI command or flag, an API endpoint or a response field that the
// interface diff (iface-diff.mjs) reports as removed. Deterministic and read-only.
// docs/change-awareness.md.
//
//   node impact.mjs <diff.json|none> [--iface <iface-diff.json>] <test-file>...
//       -> {"impacted":[{test, blocks:["AC-1",…], hits:[{change, type, line, inAcBlock, block}]}], "clear":[…]}
// `none` stands for a UI diff that was skipped (no map of the previous build). `type`: page-removed |
// renamed | renamed-likely | moved | removed | command-removed | flag-removed | endpoint-removed |
// field-removed. A hit's line is the first one inside a frozen block (`block`, AC-<k> or IN-<k>), else
// the first one; maintenance.mjs predict reads it (docs/maintenance.md).

import { existsSync, readFileSync } from 'node:fs';
import { blockAt, blocksOf, controlRe, esc, matchable, pageRe } from './lib/match.mjs';

const args = process.argv.slice(2);
const at = args.indexOf('--iface');
const ifacePath = at >= 0 ? args[at + 1] : null;
const [diffPath, ...files] = at >= 0 ? args.filter((_, i) => i !== at && i !== at + 1) : args;
if (!diffPath || !files.length || (at >= 0 && !ifacePath)) {
  console.error('usage: impact.mjs <diff.json|none> [--iface <iface-diff.json>] <test-file>...');
  process.exit(2);
}
const d = diffPath === 'none' ? {} : JSON.parse(readFileSync(diffPath, 'utf8'));
const f = ifacePath ? JSON.parse(readFileSync(ifacePath, 'utf8')) : {};

const B = '(?:^|[^A-Za-z0-9_-])'; // a word start for CLI words and flags
// A page counts when the test opens it (or a page below it); a control when its label
// appears anywhere — a quoted locator name or inside an agent instruction (lib/match.mjs).
const ui = (needle, what, type, page) => (matchable(needle)
  ? [{ what, type, re: page ? pageRe(needle, { subpaths: true }) : controlRe(needle) }] : []);
// An API path with its {params} as wildcards, ending where the path ends.
const pathRe = (p) => `${p.split(/\{[^}]*\}/).map(esc).join('[^/?#\'"`\\s]+')}(?=[?#'"\`\\s)]|$)`;

const RESPONSE_PROPS = new Set(['status', 'statusText', 'headers', 'body', 'url', 'type', 'redirected', 'json', 'text']);

// What a test may depend on that no longer is where it was.
const prog = f.program ? [f.program] : [];
const changes = [
  ...(d.pages_removed ?? []).flatMap((p) => ui(p, `page ${p} removed`, 'page-removed', true)),
  ...(d.renamed ?? []).flatMap((r) => ui(r.from, `${r.kind} "${r.from}" renamed to "${r.to}"${r.basis ? ' (likely)' : ''}`, r.basis ? 'renamed-likely' : 'renamed')),
  ...(d.moved ?? []).flatMap((m) => ui(m.name, `${m.kind} "${m.name}" moved from ${m.from.join(', ')} to ${m.to.join(', ')}`, 'moved')),
  ...(d.removed ?? []).flatMap((r) => ui(r.name, `${r.kind} "${r.name}" removed from ${r.routes.join(', ')}`, 'removed')),
  // CLI: the command's words in a string or an argument array (`'agents', 'rm'`).
  ...(f.commands_removed ?? []).map((c) => ({ what: `command "${[...prog, c.command].join(' ')}" removed`, type: 'command-removed',
    re: new RegExp(`${B}${[...prog, ...c.command.split(' ')].map(esc).join('[\'"`,\\s\\[]+')}(?![A-Za-z0-9_-])`) })),
  ...(f.flags_removed ?? []).map((x) => ({ what: `flag ${x.flag} of "${[...prog, x.command].join(' ').trim()}" removed`, type: 'flag-removed',
    re: new RegExp(`${B}${esc(x.flag)}(?![A-Za-z0-9_-])`) })),
  // API: the path; when another method still serves it, the file must name this method too.
  ...(f.endpoints_removed ?? []).map((e) => {
    const [method, path] = [e.endpoint.slice(0, e.endpoint.indexOf(' ')), e.endpoint.slice(e.endpoint.indexOf(' ') + 1)];
    return { what: `endpoint ${e.endpoint} removed`, type: 'endpoint-removed', re: new RegExp(pathRe(path)),
      requires: e.path_remains ? new RegExp(`\\b${method}\\b`, 'i') : null };
  }),
  // A response field counts only in a test that also calls its endpoint; a name that is also a
  // fetch Response property (`res.status`) counts only quoted.
  ...(f.fields_removed ?? []).flatMap((x) => {
    const leaf = x.field.split('.').at(-1).replace(/\[\]/g, '');
    if (leaf.length < 3) return [];
    const dotted = RESPONSE_PROPS.has(leaf) ? '' : `\\.${esc(leaf)}(?![A-Za-z0-9_$])|`;
    return [{ what: `field ${x.field} of ${x.endpoint} removed`, type: 'field-removed',
      re: new RegExp(`(?:${dotted}['"\`]${esc(leaf)}['"\`])`),
      requires: new RegExp(pathRe(x.endpoint.slice(x.endpoint.indexOf(' ') + 1))) }];
  }),
];

const impacted = [];
const clear = [];
// An unexpanded glob (no scenario tests yet) is not a file.
for (const file of files.filter((f) => existsSync(f))) {
  const src = readFileSync(file, 'utf8');
  const lines = src.split('\n');
  const hits = [];
  for (const c of changes) {
    if (c.requires && !c.requires.test(src)) continue;
    const at = lines.flatMap((l, i) => (c.re.test(l) ? [i] : []));
    const line = at.find((i) => blockAt(src, i)) ?? at[0];
    if (line === undefined) continue;
    const block = blockAt(src, line);
    hits.push({ change: c.what, type: c.type, line: line + 1, inAcBlock: block !== null, block });
  }
  (hits.length ? impacted : clear).push(hits.length ? { test: file, blocks: blocksOf(src), hits } : file);
}

console.log(JSON.stringify({ impacted, clear }, null, 2));
