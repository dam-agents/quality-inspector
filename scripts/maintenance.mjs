#!/usr/bin/env node
// maintenance.mjs — the test maintenance queue, work/MAINTENANCE.md (docs/maintenance.md): one
// proposal per recurring test that the product moved away from — what changed, the evidence, and what
// to do with the test. The operator decides each one in the direct session ("accept M-3",
// "rewrite M-3", "retire M-3", "keep M-3"); the agent opens them, and closes those whose cause is gone.
//
//   node maintenance.mjs open <test> --kind <kind> --build <build> --proposal <proposal> --basis-file <path>
//     -> {"id", "opened": bool}   one open row per (test, kind): a second open updates its build and basis
//   node maintenance.mjs close <M-k> <state>   -> {"id", "state"}
//   node maintenance.mjs list [--open]         -> {"proposals": [{id, test, kind, build, basis, proposal, state, opened_utc, closed_utc}]}
//   node maintenance.mjs sweep [--unchanged <test>]…   -> {"resolved": ["M-2", …], "notes": []}
//   node maintenance.mjs check                 -> {"ok", "problems": []}
//
// <test>: `#N`, `#N AC-k`, `S-k[ AC-j]`, `P-<slug>[ AC-j]` (one argument or two). <kind>: needs-review |
// superseded | drift | quarantined | fighting. <proposal>: heal | rewrite | retire | re-promote | review.
// <state>: accepted | rewritten | retired | kept | resolved. The basis — read from <path>, the call's own
// `mktemp -t quality-inspector-basis.XXXXXX` written with a file tool, never by the shell, since it
// may quote an issue; removed once read (lib/words.mjs) — is a short evidence pointer (a
// UI-map change, an issue number and its quoted sentence, a build): never a triage explanation, a
// request's words or a credential; the catalog shows it.
// `sweep` resolves the open rows whose cause is gone: a drift whose file no longer drifts
// (check-asserts.sh --json), a quarantine or a superseded test whose tier changed, a test with no
// work/SUITE.md row, and each --unchanged test (the night replayed it plain unchanged). An unreadable
// work/SUITE.md stops it with no change (exit 1): an unhydrated work/ would else resolve every row.
// Every write holds the queue's mutex (lib/mutex.mjs) from load to save.
// Exit 2: usage or a malformed value; the file is then left as it was. Exit 1: locked, or no SUITE.md.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { withMutex, writeAtomic } from './lib/mutex.mjs';
import { takeWords } from './lib/words.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const FILE = join(work, 'MAINTENANCE.md');
const HEADER = '| id | test | kind | build | basis | proposal | state | opened_utc | closed_utc |';
const TITLE = '# Test maintenance — proposals for recurring tests the product moved away from (docs/maintenance.md)';
const KINDS = ['needs-review', 'superseded', 'drift', 'quarantined', 'fighting'];
const PROPOSALS = ['heal', 'rewrite', 'retire', 're-promote', 'review'];
const CLOSED = ['accepted', 'rewritten', 'retired', 'kept', 'resolved'];
const TEST_RE = /^(#(\d{1,7})|S-(\d{1,6})|P-([a-z0-9][a-z0-9-]{0,40}))(?: (AC-\d{1,3}))?$/;
const BUILD_RE = /^[A-Za-z0-9._+-]{1,80}$/;
const UTC_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;

class Usage extends Error {}
const die = (msg) => { throw new Usage(msg); };
const out = (o) => console.log(JSON.stringify(o));
const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const rows = (text) => (text ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2)
  .map((l) => l.split('|').slice(1, -1).map((c) => c.trim()));
const COLS = ['id', 'test', 'kind', 'build', 'basis', 'proposal', 'state', 'opened_utc', 'closed_utc'];

function load() {
  const text = read(FILE);
  if (text != null && !text.split('\n').includes(HEADER)) die('work/MAINTENANCE.md: header changed — fix it to the format of docs/maintenance.md');
  return rows(text).map((r) => Object.fromEntries(COLS.map((k, j) => [k, r[j] ?? '-'])));
}
function save(list) {
  const body = list.map((p) => `| ${COLS.map((k) => p[k] || '-').join(' | ')} |`);
  writeAtomic(FILE, `${TITLE}\n\n${HEADER}\n| ${COLS.map(() => '---').join(' | ')} |\n${body.join('\n')}${body.length ? '\n' : ''}`);
}
const fileOf = (test) => { const m = TEST_RE.exec(test); return m ? `tests/${m[2] ? `issue-${m[2]}` : m[3] ? `scenario-${m[3]}` : `profile-${m[4]}`}.e2e.ts` : null; };
const suite = () => { const t = read(join(work, 'SUITE.md')); return t == null ? null : new Map(rows(t).map(([test, , tier]) => [test, tier])); };

const [cmd, ...args] = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
// A test may come as one argument ("#42 AC-1") or two (#42 AC-1).
const testAt = (k) => {
  const t = (/^AC-\d{1,3}$/.test(args[k + 1] ?? '') ? `${args[k]} ${args[k + 1]}` : String(args[k] ?? '')).replace(/\s+/g, ' ').trim();
  if (!TEST_RE.test(t)) die(`"${t}" is not a test (#N, #N AC-k, S-k[ AC-j], P-<slug>[ AC-j])`);
  return t;
};

function main() {
switch (cmd) {
  case 'open': {
    // The basis file first: any later refusal must not leave the call's own file behind.
    const path = flag('--basis-file');
    let raw = null;
    if (path) try { raw = takeWords(path, 'basis'); } catch (e) { die(e.message); }
    const test = testAt(0);
    const kind = flag('--kind'); const build = flag('--build'); const proposal = flag('--proposal');
    const basis = String(raw ?? '').replace(/[|\r\n\u0000-\u001f]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 160);
    if (!KINDS.includes(kind)) die(`--kind is one of ${KINDS.join(', ')}`);
    if (!PROPOSALS.includes(proposal)) die(`--proposal is one of ${PROPOSALS.join(', ')}`);
    if (!BUILD_RE.test(build ?? '')) die('--build <build> is required');
    if (!basis) die('--basis-file <path> is required: the evidence of the change');
    const list = load();
    const same = list.find((p) => p.state === 'open' && p.test === test && p.kind === kind);
    if (same) { Object.assign(same, { build, basis, proposal }); save(list); out({ id: same.id, opened: false }); break; }
    const next = Math.max(0, ...list.map((p) => +(/^M-(\d+)$/.exec(p.id)?.[1] ?? 0))) + 1;
    list.push({ id: `M-${next}`, test, kind, build, basis, proposal, state: 'open', opened_utc: now(), closed_utc: '-' });
    save(list);
    out({ id: `M-${next}`, opened: true });
    break;
  }
  case 'close': {
    const [id, state] = args;
    if (!/^M-\d{1,6}$/.test(id ?? '') || !CLOSED.includes(state)) die(`usage: maintenance.mjs close <M-k> <${CLOSED.join('|')}>`);
    const list = load();
    const p = list.find((x) => x.id === id) ?? die(`no ${id} in work/MAINTENANCE.md`);
    if (p.state !== 'open') die(`${id} is already ${p.state}`);
    Object.assign(p, { state, closed_utc: now() });
    save(list);
    out({ id, state });
    break;
  }
  case 'list': {
    const open = args.includes('--open');
    out({ proposals: load().filter((p) => !open || p.state === 'open') });
    break;
  }
  case 'sweep': {
    const unchanged = new Set();
    for (let k = 0; k < args.length; k++) if (args[k] === '--unchanged') { unchanged.add(testAt(k + 1)); }
    const notes = [];
    let drift = null;
    try {
      drift = new Set((JSON.parse(execFileSync('bash', [join(HERE, 'check-asserts.sh'), '--json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })).drift ?? [])
        .map((d) => String(d.test ?? d)));
    } catch { notes.push('drift not measured (check-asserts.sh --json failed): open drift rows stay open'); }
    const tiers = suite();
    if (!tiers) throw new Error('work/SUITE.md cannot be read: nothing swept (restore work/ first)');
    const list = load();
    const resolved = [];
    for (const p of list.filter((x) => x.state === 'open')) {
      const file = fileOf(p.test); const tier = tiers.get(file) ?? null;
      const gone = (p.kind === 'drift' && drift && !drift.has(file))
        || (p.kind === 'quarantined' && tier !== 'quarantined')
        || (p.kind === 'superseded' && tier !== 'retired')
        || (!tier)
        || (['needs-review', 'fighting'].includes(p.kind) && (unchanged.has(p.test) || [...unchanged].some((u) => !/ AC-/.test(u) && p.test.startsWith(`${u} `))));
      if (gone) { Object.assign(p, { state: 'resolved', closed_utc: now() }); resolved.push(p.id); }
    }
    if (resolved.length) save(list);
    out({ resolved, notes });
    break;
  }
  case 'check': {
    const text = read(FILE);
    const problems = [];
    if (text == null) { out({ ok: true, problems, notes: ['work/MAINTENANCE.md not created yet'] }); break; }
    if (!text.split('\n').includes(HEADER)) problems.push('header changed');
    const seen = new Set(); const openKeys = new Set();
    for (const r of rows(text)) {
      const p = Object.fromEntries(COLS.map((k, j) => [k, r[j]]));
      if (r.length !== COLS.length) { problems.push(`row "${r.join(' | ').slice(0, 80)}": ${r.length} cells, not ${COLS.length}`); continue; }
      if (!/^M-\d{1,6}$/.test(p.id) || seen.has(p.id)) problems.push(`"${p.id}": not an id, or twice`); seen.add(p.id);
      if (!TEST_RE.test(p.test)) problems.push(`${p.id}: "${p.test}" is not a test`);
      if (!KINDS.includes(p.kind)) problems.push(`${p.id}: kind "${p.kind}"`);
      if (!PROPOSALS.includes(p.proposal)) problems.push(`${p.id}: proposal "${p.proposal}"`);
      if (![...CLOSED, 'open'].includes(p.state)) problems.push(`${p.id}: state "${p.state}"`);
      if (!BUILD_RE.test(p.build)) problems.push(`${p.id}: build "${p.build}"`);
      if (!UTC_RE.test(p.opened_utc)) problems.push(`${p.id}: opened_utc "${p.opened_utc}"`);
      if (p.state === 'open' ? p.closed_utc !== '-' : !UTC_RE.test(p.closed_utc)) problems.push(`${p.id}: closed_utc "${p.closed_utc}" does not match state ${p.state}`);
      if (p.state === 'open') { const k = `${p.test}~${p.kind}`; if (openKeys.has(k)) problems.push(`${p.id}: a second open ${p.kind} row of ${p.test}`); openKeys.add(k); }
    }
    out({ ok: problems.length === 0, problems });
    break;
  }
  default: die('usage: maintenance.mjs open|close|list|sweep|check — see its header');
}
}

// A command that writes the queue runs inside its mutex; a usage error releases it before exit 2.
try {
  if (['open', 'close', 'sweep'].includes(cmd)) withMutex(`${FILE}.lock`, main); else main();
} catch (e) {
  console.error(`maintenance: ${e.message}`);
  process.exit(e instanceof Usage ? 2 : 1);
}
