#!/usr/bin/env node
// blockers.mjs — the register of what stops the agent's work, work/BLOCKERS.md (docs/autonomy.md → The
// register): one row per cause — the product does not install or start (`env`), the platform refuses a
// report's delivery (`delivery`), recurring tests cannot reach their frozen block for a reason outside the
// product (`tests`) —, whose fix it is, how often it struck and when the agent tries again. The pre-flight
// holds the work a standing blocker stops (scripts/preflight.sh → blockers_load), so a known failure
// costs one try per backoff step instead of one per run, and the operator is told once.
//
//   node blockers.mjs open --scope <scope> [--test <id>]… --owner <owner> --stage <stage> --build <build> --signature-file <path>
//     -> {"id", "opened": bool, "hits", "retry_utc", "notes"}   an open row of the same scope and signature takes the hit instead
//   node blockers.mjs hit <B-k> --build <build> [--owner <owner>] [--test <id>]…   -> {"id", "hits", "retry_utc"}
//   node blockers.mjs resolve <B-k>    -> {"id", "state": "resolved"}   what it stopped works again
//   node blockers.mjs told <B-k>       -> {"id", "told"}                the notice due for it went out
//   node blockers.mjs retry <B-k>      -> {"id", "retry_utc"}           the operator's "retry B-k": released now
//   node blockers.mjs close <B-k>      -> {"id", "state": "closed"}     the operator's "close B-k": no longer held
//   node blockers.mjs list [--open]    -> {"blockers": [{id, scope, tests[], owner, stage, signature, build, hits, state, first_utc, last_utc, retry_utc, told}]}
//   node blockers.mjs status           -> {"open", "held": [], "released": [], "notices": [], "env", "delivery", "tests": {<test>: <B-k>}}
//   node blockers.mjs check            -> {"ok", "problems": []}
//
// <scope>: env | delivery | tests (one --test per recurring test it stops: #N, S-k, P-<slug>). <owner>: whose
// fix it is — agent | operator | profile | product | platform | unknown. <stage>: where it stopped, one short
// word (up, reset, smoke, canary, upload, comment, label, replay, adopt …). The signature — the failure's key
// line, read from <path>, the call's own `mktemp /tmp/quality-inspector-signature.XXXXXX` written with a file
// tool, since it may quote an install log (lib/words.mjs) — is compared with digit runs and long hex folded,
// so a build id or a count does not make a new cause.
// Hold and release: an open row holds its scope while now < retry_utc, its last hit plus 2^(hits−1) hours less
// a quarter of an hour (so the hourly run after it is free), at most a day — a week for owner `profile`, whose
// repair shows as a change of its files. It is released early once the kit's VERSION, work/CONFIG.md, the
// profile's files or work/env/credentials.env (its size and time, never its text) changed since that hit.
// `status` says which (`released[].reason`); `env`, `delivery` and `tests` name the rows that hold.
// Notices (docs/autonomy.md → Telling the operator): `opened` is due for an open row not told yet whose owner
// is not the agent, or that struck twice; `resolved` for a resolved or closed row that was told it opened.
// `retry` and `close` are the operator's, in the direct session only (lib/config.sh → direct_session).
// Every write holds the register's mutex (lib/mutex.mjs). Exit 2: usage or a malformed value, the file left
// as it was; exit 1: locked.

import { createHash } from 'node:crypto';
import { readdirSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { withMutex, writeAtomic } from './lib/mutex.mjs';
import { WORK as work, read, sh, tableRows } from './lib/util.mjs';
import { takeWords } from './lib/words.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const FILE = join(work, 'BLOCKERS.md');
const TITLE = '# Blockers — what stops the agent\'s work, whose fix it is, when it tries again (docs/autonomy.md)';
const COLS = ['id', 'scope', 'tests', 'owner', 'stage', 'signature', 'build', 'hits', 'state', 'first_utc', 'last_utc', 'retry_utc', 'fp', 'told'];
const HEADER = `| ${COLS.join(' | ')} |`;
const SCOPES = ['env', 'delivery', 'tests'];
const OWNERS = ['agent', 'operator', 'profile', 'product', 'platform', 'unknown'];
const STATES = ['open', 'resolved', 'closed'];
const TOLD = ['-', 'opened', 'resolved'];
const TEST_RE = /^(#\d{1,7}|S-\d{1,6}|P-[a-z0-9][a-z0-9-]{0,40})$/;
const ID_RE = /^B-\d{1,6}$/;
const STAGE_RE = /^[a-z][a-z-]{0,19}$/;
const BUILD_RE = /^[A-Za-z0-9._+-]{1,80}$/;
const UTC_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const HOUR = 3600000;

class Usage extends Error {}
const die = (msg) => { throw new Usage(msg); };
const out = (o) => console.log(JSON.stringify(o));
const utc = (ms) => new Date(ms).toISOString().replace(/\.\d+Z$/, 'Z');
const sanitize = (raw) => String(raw ?? '').replace(/[|\r\n\u0000-\u001f`]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 160);
// One cause, whatever build or count it names: lower case, long hex and digit runs folded.
const sameCause = (s) => s.toLowerCase().replace(/\b[0-9a-f]{7,}\b/g, 'h').replace(/\d+/g, 'n').replace(/\s+/g, ' ').trim();

// ------------------------------------------------------------------ the fingerprint of what a fix changes
const short = (s) => createHash('sha256').update(s).digest('hex').slice(0, 8);
function profileHash() {
  const dir = sh('profile_dir');
  if (!dir) return 'none';
  const files = [];
  const walk = (d) => {
    let names; try { names = readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of names) {
      if (files.length > 2000 || e.name === '.git' || e.name === 'node_modules') continue;
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p); else if (e.isFile()) files.push(p);
    }
  };
  walk(dir);
  const h = createHash('sha256');
  for (const p of files.sort()) h.update(`${relative(dir, p)}\0`).update(read(p) ?? '').update('\0');
  return h.digest('hex').slice(0, 8);
}
function credentialsMark() {
  try { const s = statSync(join(work, 'env', 'credentials.env')); return short(`${s.size}:${Math.floor(s.mtimeMs)}`); } catch { return 'none'; }
}
const PARTS = ['kit', 'config', 'profile', 'credentials'];
const fingerprint = () => [sanitize(read(join(HERE, '..', 'VERSION'))?.split('\n')[0] ?? '') || 'none',
  short(read(join(work, 'CONFIG.md')) ?? ''), profileHash(), credentialsMark()].join(':');
const changedParts = (then, now) => { const a = then.split(':'); const b = now.split(':'); return PARTS.filter((_, i) => a[i] !== b[i]); };

// ------------------------------------------------------------------ the register
function load() {
  const text = read(FILE);
  if (text != null && !text.split('\n').includes(HEADER)) die('work/BLOCKERS.md: header changed — fix it to the format of docs/autonomy.md');
  return tableRows(text).map((r) => Object.fromEntries(COLS.map((k, j) => [k, r[j] ?? '-'])));
}
function save(list) {
  const body = list.map((b) => `| ${COLS.map((k) => b[k] || '-').join(' | ')} |`);
  writeAtomic(FILE, `${TITLE}\n\n${HEADER}\n| ${COLS.map(() => '---').join(' | ')} |\n${body.join('\n')}${body.length ? '\n' : ''}`);
}
const testsOf = (b) => (b.tests && b.tests !== '-' ? b.tests.split(/\s+/).filter(Boolean) : []);
const merge = (b, tests) => { const all = [...new Set([...testsOf(b), ...tests])]; b.tests = all.length ? all.join(' ') : '-'; };
const backoff = (hits, owner) => Math.min(owner === 'profile' ? 168 * HOUR : 24 * HOUR, HOUR * 2 ** Math.min(hits - 1, 10)) - HOUR / 4;
function strike(b, build, ms) {
  b.hits = String((+b.hits || 0) + 1); b.build = build; b.last_utc = utc(ms); b.fp = fingerprint();
  b.retry_utc = utc(ms + backoff(+b.hits, b.owner));
}
const nextId = (list) => `B-${Math.max(0, ...list.map((b) => +(/^B-(\d+)$/.exec(b.id)?.[1] ?? 0))) + 1}`;
const notice = (b) => (b.state === 'open' && b.told === '-' && (b.owner !== 'agent' || +b.hits >= 2) ? 'opened'
  : b.state !== 'open' && b.told === 'opened' ? 'resolved' : null);
const view = (b) => ({ id: b.id, scope: b.scope, tests: testsOf(b), owner: b.owner, stage: b.stage, signature: b.signature,
  build: b.build, hits: +b.hits || 0, state: b.state, first_utc: b.first_utc, last_utc: b.last_utc, retry_utc: b.retry_utc, told: b.told });

const [cmd, ...args] = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const flags = (name) => args.flatMap((a, i) => (a === name ? [args[i + 1]] : []));
const testsArg = () => { const t = flags('--test'); for (const x of t) if (!TEST_RE.test(x ?? '')) die(`--test "${x}" is not a test (#N, S-k, P-<slug>)`); return t; };
const idArg = () => { const id = args[0]; if (!ID_RE.test(id ?? '')) die(`usage: blockers.mjs ${cmd} <B-k>`); return id; };
const find = (list, id) => list.find((b) => b.id === id) ?? die(`no ${id} in work/BLOCKERS.md`);
const operatorOnly = () => { if (sh('direct_session && echo yes') !== 'yes') die(`${cmd} is the operator's, in the direct session only`); };
const locked = (fn) => withMutex(`${FILE}.lock`, fn);

function main() {
  switch (cmd) {
    case 'open': {
      const path = flag('--signature-file');
      if (!path) die('--signature-file <path> is required: the failure\'s key line');
      let raw; try { raw = takeWords(path, 'signature'); } catch (e) { die(e.message); }
      const scope = flag('--scope'); const owner = flag('--owner'); const stage = flag('--stage'); const build = flag('--build');
      const tests = testsArg(); const signature = sanitize(raw);
      if (!SCOPES.includes(scope)) die(`--scope is one of ${SCOPES.join(', ')}`);
      if ((scope === 'tests') !== (tests.length > 0)) die('a tests scope names its tests (--test <id>), and only it');
      if (!OWNERS.includes(owner)) die(`--owner is one of ${OWNERS.join(', ')}`);
      if (!STAGE_RE.test(stage ?? '')) die('--stage <stage> is one short word');
      if (!BUILD_RE.test(build ?? '')) die('--build <build> is required');
      if (!signature) die('the signature is empty');
      locked(() => {
        const list = load(); const ms = Date.now();
        const same = list.find((b) => b.state === 'open' && b.scope === scope && sameCause(b.signature) === sameCause(signature));
        if (same) { merge(same, tests); strike(same, build, ms); save(list); out({ id: same.id, opened: false, hits: +same.hits, retry_utc: same.retry_utc, notes: `work/blockers/${same.id}.md` }); return; }
        const b = { id: nextId(list), scope, tests: '-', owner, stage, signature, build, hits: '0', state: 'open', first_utc: utc(ms), told: '-' };
        merge(b, tests); strike(b, build, ms); list.push(b); save(list);
        out({ id: b.id, opened: true, hits: 1, retry_utc: b.retry_utc, notes: `work/blockers/${b.id}.md` });
      });
      break;
    }
    case 'hit': {
      const id = idArg(); const build = flag('--build'); const owner = flag('--owner'); const tests = testsArg();
      if (!BUILD_RE.test(build ?? '')) die('--build <build> is required');
      if (owner != null && !OWNERS.includes(owner)) die(`--owner is one of ${OWNERS.join(', ')}`);
      locked(() => {
        const list = load(); const b = find(list, id);
        if (b.state !== 'open') die(`${id} is ${b.state}: open it again`);
        if (tests.length && b.scope !== 'tests') die(`${id} is not a tests blocker`);
        if (owner) b.owner = owner;
        merge(b, tests); strike(b, build, Date.now()); save(list);
        out({ id, hits: +b.hits, retry_utc: b.retry_utc });
      });
      break;
    }
    case 'resolve': case 'close': {
      const id = idArg();
      if (cmd === 'close') operatorOnly();
      locked(() => {
        const list = load(); const b = find(list, id);
        if (b.state !== 'open') die(`${id} is already ${b.state}`);
        b.state = cmd === 'close' ? 'closed' : 'resolved'; b.last_utc = utc(Date.now());
        save(list); out({ id, state: b.state });
      });
      break;
    }
    case 'retry': {
      const id = idArg(); operatorOnly();
      locked(() => {
        const list = load(); const b = find(list, id);
        if (b.state !== 'open') die(`${id} is ${b.state}`);
        b.retry_utc = utc(Date.now()); save(list); out({ id, retry_utc: b.retry_utc });
      });
      break;
    }
    case 'told': {
      const id = idArg();
      locked(() => {
        const list = load(); const b = find(list, id); const kind = notice(b);
        if (!kind) die(`${id}: no notice is due`);
        b.told = kind; save(list); out({ id, told: kind });
      });
      break;
    }
    case 'list': {
      const open = args.includes('--open');
      out({ blockers: load().filter((b) => !open || b.state === 'open').map(view) });
      break;
    }
    case 'status': {
      const list = load(); const now = Date.now(); const fp = fingerprint();
      const held = []; const released = []; const tests = {};
      let env = null; let delivery = null;
      for (const b of list.filter((x) => x.state === 'open')) {
        const changed = changedParts(b.fp, fp);
        const due = !UTC_RE.test(b.retry_utc) || Date.parse(b.retry_utc) <= now;
        if (!changed.length && !due) {
          held.push(view(b));
          if (b.scope === 'env') env ??= b.id;
          if (b.scope === 'delivery') delivery ??= b.id;
          if (b.scope === 'tests') for (const t of testsOf(b)) tests[t] ??= b.id;
        } else released.push({ ...view(b), reason: changed.length ? `changed: ${changed.join(', ')}` : 'retry time' });
      }
      const notices = list.map((b) => ({ b, kind: notice(b) })).filter((n) => n.kind).map(({ b, kind }) => ({ ...view(b), kind }));
      out({ open: list.filter((b) => b.state === 'open').length, held, released, notices, env, delivery, tests });
      break;
    }
    case 'check': {
      const problems = []; let list = [];
      try { list = load(); } catch (e) { problems.push(e.message); }
      const ids = new Set();
      for (const b of list) {
        const at = b.id;
        if (!ID_RE.test(b.id) || ids.has(b.id)) problems.push(`${at}: not a unique B-<k>`);
        ids.add(b.id);
        if (!SCOPES.includes(b.scope)) problems.push(`${at}: scope "${b.scope}"`);
        if ((b.scope === 'tests') !== (testsOf(b).length > 0) || testsOf(b).some((t) => !TEST_RE.test(t))) problems.push(`${at}: tests "${b.tests}"`);
        if (!OWNERS.includes(b.owner)) problems.push(`${at}: owner "${b.owner}"`);
        if (!STATES.includes(b.state)) problems.push(`${at}: state "${b.state}"`);
        if (!TOLD.includes(b.told)) problems.push(`${at}: told "${b.told}"`);
        if (!/^[1-9]\d{0,5}$/.test(b.hits)) problems.push(`${at}: hits "${b.hits}"`);
        for (const k of ['first_utc', 'last_utc', 'retry_utc']) if (!UTC_RE.test(b[k])) problems.push(`${at}: ${k} "${b[k]}"`);
      }
      out({ ok: !problems.length, problems });
      break;
    }
    default: die('usage: blockers.mjs open|hit|resolve|told|retry|close|list|status|check');
  }
}

try { main(); } catch (e) {
  if (e instanceof Usage) { console.error(`blockers.mjs: ${e.message}`); process.exit(2); }
  if (/stays locked/.test(e.message)) { console.error(`blockers.mjs: ${e.message}`); process.exit(1); }
  throw e;
}
