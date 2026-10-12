#!/usr/bin/env node
// impact.mjs — which tests a UI change touches, before they run: every regression test
// whose source names a page or a control that the UI diff (ui-diff.mjs) reports as
// removed, renamed or moved. Deterministic and read-only. docs/change-awareness.md.
//
//   node impact.mjs <diff.json> <test-file>...   -> {"impacted":[{test, hits:[…]}], "clear":[…]}

import { readFileSync } from 'node:fs';

const [diffPath, ...files] = process.argv.slice(2);
if (!diffPath || !files.length) { console.error('usage: impact.mjs <diff.json> <test-file>...'); process.exit(2); }
const d = JSON.parse(readFileSync(diffPath, 'utf8'));

// What a test may depend on that no longer is where it was.
const changes = [
  ...(d.pages_removed ?? []).map((p) => ({ needle: p, what: `page ${p} removed`, page: true })),
  ...(d.renamed ?? []).map((r) => ({ needle: r.from, what: `${r.kind} "${r.from}" renamed to "${r.to}"${r.basis ? ' (likely)' : ''}` })),
  ...(d.moved ?? []).map((m) => ({ needle: m.name, what: `${m.kind} "${m.name}" moved from ${m.from.join(', ')} to ${m.to.join(', ')}` })),
  ...(d.removed ?? []).map((r) => ({ needle: r.name, what: `${r.kind} "${r.name}" removed from ${r.routes.join(', ')}` })),
];

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const impacted = [];
const clear = [];
for (const f of files) {
  const src = readFileSync(f, 'utf8');
  const hits = [];
  for (const c of changes) {
    if (!c.needle || c.needle.length < 3) continue;
    // A page counts when the test opens it; a control when its label appears as a quoted
    // locator name or inside an agent instruction.
    const re = c.page
      ? new RegExp(`['"\`]${esc(c.needle)}(?:[/?#'"\`])`)
      : new RegExp(`(?:^|[^A-Za-z0-9])${esc(c.needle)}(?:$|[^A-Za-z0-9])`, 'i');
    const line = src.split('\n').findIndex((l) => re.test(l));
    if (line >= 0) hits.push({ change: c.what, line: line + 1, inAcBlock: insideAc(src, line) });
  }
  (hits.length ? impacted : clear).push(hits.length ? { test: f, hits } : f);
}

function insideAc(src, idx) {
  const lines = src.split('\n');
  for (let i = idx; i >= 0; i--) {
    if (/\/\/\s*AC-\d+\s+end/.test(lines[i]) && i !== idx) return false;
    if (/\/\/\s*AC-\d+\s+begin/.test(lines[i])) return true;
  }
  return false;
}

console.log(JSON.stringify({ impacted, clear }, null, 2));
