#!/usr/bin/env node
// secrets.mjs — nested credential values (work/env/credentials.env) out of run artefacts.
// A secret is the value of every key matching (^|_)(PASSWORD|TOKEN|SECRET), case-insensitive
// (E2E_USER_<NAME>_PASSWORD, QI_SECRET_<NAME>, …). Replacement is literal, never a regex:
// the raw value, its JSON-escaped and its URL-encoded form all become ***.
//
//   secrets.mjs mask <credentials.env> <dir>     rewrite the dir's text files in place
//   secrets.mjs filter <credentials.env>         stdin -> stdout, masked
//   secrets.mjs scan <credentials.env> <dir>…    -> {"files":[paths still holding a value],"unmaskable":n}
//
// Text files: .log .txt .md .json .jsonl .html (recursive; binaries such as videos and
// trace.zip are untouched). A value shorter than MIN is never replaced (it would corrupt
// the file) and is counted as `unmaskable`. A missing credentials file means no secrets.

import { existsSync, lstatSync, readdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { extname, join } from 'node:path';

const MIN = 4;
const KEY = /(^|_)(PASSWORD|TOKEN|SECRET)/i;
const TEXT = new Set(['.log', '.txt', '.md', '.json', '.jsonl', '.html']);
const MASK = '***';

function values(envFile) {
  const out = []; let short = 0;
  if (!envFile || !existsSync(envFile)) return { forms: [], short };
  for (const line of readFileSync(envFile, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!m || !KEY.test(m[1])) continue;
    let v = m[2].trim();
    const q = v[0];
    if (v.length >= 2 && (q === '"' || q === "'") && v.at(-1) === q) v = v.slice(1, -1);
    if (!v) continue;
    if (v.length < MIN) { short += 1; continue; }
    out.push(v, JSON.stringify(v).slice(1, -1), encodeURIComponent(v));
  }
  // longest first, so a value containing another one is replaced whole
  return { forms: [...new Set(out)].sort((a, b) => b.length - a.length), short };
}

const mask = (s, forms) => forms.reduce((acc, f) => acc.split(f).join(MASK), s);

function* textFiles(dir) {
  if (!existsSync(dir)) return;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isSymbolicLink()) continue;
    if (e.isDirectory()) yield* textFiles(p);
    else if (e.isFile() && TEXT.has(extname(e.name).toLowerCase())) yield p;
  }
}

const [cmd, envFile, ...dirs] = process.argv.slice(2);
const { forms, short } = values(envFile);

if (cmd === 'mask' && dirs.length === 1) {
  if (!lstatSync(dirs[0], { throwIfNoEntry: false })?.isDirectory()) { console.error(`secrets: no directory ${dirs[0]}`); process.exit(1); }
  if (!forms.length) process.exit(0);
  for (const p of textFiles(dirs[0])) {
    const s = readFileSync(p, 'utf8'), m = mask(s, forms);
    if (m !== s) { writeFileSync(`${p}.qi-mask`, m); renameSync(`${p}.qi-mask`, p); }
  }
} else if (cmd === 'filter') {
  process.stdout.write(mask(readFileSync(0, 'utf8'), forms));
} else if (cmd === 'scan' && dirs.length) {
  const files = [];
  for (const d of dirs) for (const p of textFiles(d)) {
    const s = readFileSync(p, 'utf8');
    if (forms.some(f => s.includes(f))) files.push(p);
  }
  process.stdout.write(`${JSON.stringify({ files, unmaskable: short })}\n`);
} else {
  console.error('usage: secrets.mjs mask <credentials.env> <dir> | filter <credentials.env> | scan <credentials.env> <dir>…');
  process.exit(2);
}
