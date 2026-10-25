#!/usr/bin/env node
// radar.mjs — the Change radar (docs/radar.md): which pull requests of the target are new or changed
// since the radar last read them, which recurring tests their text names, and the ledger of what it
// read, work/PRSCAN.md (lib/prscan.mjs). It reads a pull request's sanitized text alone — what
// `github.sh prs` prints — never its diff, files, commits, reviews or comments, and writes nothing to
// GitHub. The proposals it leads to are maintenance rows of kind `predicted` (docs/maintenance.md).
//
//   node radar.mjs since                    -> {"since": <iso>}   the newest updated_at of the ledger, else 14 days ago
//   node radar.mjs scan <prs.json>          -> {"due": [...], "deferred", "inventory", "logs": []}
//   node radar.mjs record <pr> --hash <h> --state <open|merged|closed> --updated-at <iso>
//        [--merged-at <iso>] [--proposal M-k]… [--keep]
//     -> {"pr", "state", "proposals", "resolved": []}
//   node radar.mjs list                     -> {"prs": [{pr, text_hash, state, merged_at, updated_at, proposals, scanned_utc}]}
//   node radar.mjs check                    -> {"ok", "problems": []}
//
// scan: <prs.json> is `github.sh prs` output. Oldest update first, a pull request is due as
//   `new` (no ledger row; open or merged — one closed unmerged before any scan is skipped), `changed`
//   (its text hash differs, or it was reopened), `merged` (merged since the last scan, text the same) or
//   `closed` (closed unmerged since). A `new` or `changed` entry carries its title, body,
//   `injection_suspect` (lib/scan-issues.mjs) and `candidates` (lib/radar-match.mjs); at most
//   QI_RADAR_MAX (10) of them a run — the first over the cap and every pull request after it wait for
//   the next run (`deferred`), so the ledger's newest updated_at never passes one not read.
// record: one ledger row per pull request, written under its mutex. The proposals are those the run
//   opened or updated for it (open `predicted` rows only); --keep adds the row's earlier ones (a
//   `merged` entry). A proposal the pull request no longer holds — every one when it is `closed` — is
//   closed `resolved` (scripts/maintenance.mjs close) unless another pull request not closed holds it.
// Exit 2: usage or a malformed value, the ledger left as it was. Exit 1: locked, a failed read, or a
// failed close (nothing recorded: the next run retries).

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { withMutex } from './lib/mutex.mjs';
import { COLS, FILE, HEADER, M_RE, STATES, UTC_RE, holders, load, rawRows, save, text } from './lib/prscan.mjs';
import { matchPr } from './lib/radar-match.mjs';
import { injectionLint, textHash } from './lib/scan-issues.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const FIRST_DAYS = 14;
const HASH_RE = /^[0-9a-f]{12}$/;

class Usage extends Error {}
const die = (msg) => { throw new Usage(msg); };
const out = (o) => console.log(JSON.stringify(o));
const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const node = (script, args) => JSON.parse(execFileSync(process.execPath, [join(HERE, script), ...args], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }));
// The text the hash covers: title, body and labels — what the radar matches and the agent judges.
export const hashOf = (pr) => textHash(`${pr.title ?? ''}\n${pr.body ?? ''}\n${[...(pr.labels ?? [])].sort().join(',')}`);

// What the matching reads: the features, the tiers, the newest UI map, the recurring tests' sources.
function context() {
  const tiers = new Map((read(join(work, 'SUITE.md')) ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2)
    .map((l) => l.split('|').slice(1, -1).map((c) => c.trim())).map(([test, , tier]) => [test, tier]));
  let features = [];
  try { features = node('features.mjs', ['list']).features ?? []; } catch { /* no registry yet */ }
  const inv = join(work, 'inventory');
  const maps = existsSync(inv) ? readdirSync(inv).map((b) => join(inv, b, 'inventory.json')).filter((f) => existsSync(f))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs) : [];
  let routes = {}; let build = null;
  if (maps[0]) { try { const m = JSON.parse(readFileSync(maps[0], 'utf8')); routes = m.routes ?? {}; build = m.build ?? maps[0].split('/').at(-2); } catch { /* unreadable map */ } }
  const dir = join(work, 'suite', 'tests');
  const tests = existsSync(dir) ? readdirSync(dir).filter((f) => /^(?:issue|scenario|profile)-[a-z0-9-]+\.e2e\.ts$/.test(f))
    .map((f) => ({ file: `tests/${f}`, src: read(join(dir, f)) ?? '' })) : [];
  return { tiers, features, routes, tests, inventory: build };
}

const [cmd, ...args] = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const flags = (name) => args.flatMap((a, i) => (a === name ? [args[i + 1]] : []));

function scan() {
  const path = args[0] ?? die('usage: radar.mjs scan <prs.json>');
  let prs;
  try { prs = JSON.parse(readFileSync(path, 'utf8')); } catch { die(`${path}: not the JSON of github.sh prs`); }
  if (!Array.isArray(prs) || prs.some((p) => !Number.isInteger(p?.number) || !STATES.includes(p?.state))) die(`${path}: not the JSON of github.sh prs`);
  const max = Number.parseInt(process.env.QI_RADAR_MAX ?? '10', 10) || 10;
  const ledger = new Map(load().map((r) => [r.pr, r]));
  const ctx = context();
  const due = []; const logs = []; let deferred = 0; let reads = 0;
  for (const pr of prs.slice().sort((a, b) => String(a.updated_at).localeCompare(String(b.updated_at)) || a.number - b.number)) {
    if (deferred) { deferred++; continue; }
    const row = ledger.get(String(pr.number)); const hash = hashOf(pr);
    let kind = null;
    if (!row) kind = pr.state === 'closed' ? null : 'new';
    else if (pr.state === 'closed') kind = row.state === 'closed' ? null : 'closed';
    else if (row.text_hash !== hash || row.state === 'closed') kind = 'changed';
    else if (pr.state === 'merged' && row.state === 'open') kind = 'merged';
    if (!kind) { logs.push(`PR #${pr.number}: ${!row ? 'closed unmerged before any scan' : 'unchanged'} — skip`); continue; }
    const reading = kind === 'new' || kind === 'changed';
    if (reading && reads >= max) { deferred = 1; logs.push(`PR #${pr.number}: ${kind} — deferred with every later one (${max} a run)`); continue; }
    if (reading) reads++;
    const e = { pr: pr.number, kind, state: pr.state, draft: pr.draft === true, merged_at: pr.merged_at ?? null, updated_at: pr.updated_at,
      text_hash: hash, labels: pr.labels ?? [], proposals: row?.proposals ?? [] };
    if (reading) Object.assign(e, { title: pr.title, body: pr.body, injection_suspect: injectionLint(`${pr.title}\n${pr.body}`).injection_suspect,
      candidates: matchPr(`${pr.title}\n${pr.body}`, ctx) });
    due.push(e);
    logs.push(`PR #${pr.number}: ${kind}${reading ? ` (${e.candidates.length} candidate test${e.candidates.length === 1 ? '' : 's'})` : ''} — due`);
  }
  out({ due, deferred, inventory: ctx.inventory, logs });
}

function record() {
  const pr = args[0];
  if (!/^[1-9]\d{0,6}$/.test(pr ?? '')) die('usage: radar.mjs record <pr> --hash <h> --state <s> --updated-at <iso> [--merged-at <iso>] [--proposal M-k]… [--keep]');
  const hash = flag('--hash'); const state = flag('--state'); const updated = flag('--updated-at'); const merged = flag('--merged-at');
  const given = flags('--proposal'); const keep = args.includes('--keep');
  if (!HASH_RE.test(hash ?? '')) die('--hash is the 12-hex text_hash of the scan entry');
  if (!STATES.includes(state)) die(`--state is one of ${STATES.join(', ')}`);
  if (!UTC_RE.test(updated ?? '')) die('--updated-at <iso> is required');
  if (state === 'merged' ? !UTC_RE.test(merged ?? '') : merged != null) die('--merged-at <iso> goes with --state merged, and only with it');
  if (given.some((id) => !M_RE.test(id ?? ''))) die('--proposal takes M-<k>');
  if (state === 'closed' && (given.length || keep)) die('a closed pull request holds no proposal');
  let open = [];
  try { open = node('maintenance.mjs', ['list', '--open']).proposals ?? []; } catch { throw new Error('maintenance.mjs list failed: nothing recorded'); }
  const predicted = new Set(open.filter((p) => p.kind === 'predicted').map((p) => p.id));
  for (const id of given) if (!predicted.has(id)) die(`${id} is no open predicted proposal (docs/maintenance.md)`);
  return withMutex(`${FILE}.lock`, () => {
    const list = load();
    const row = list.find((r) => r.pr === pr);
    const before = row?.proposals ?? [];
    const proposals = [...new Set([...(keep ? before : []), ...given])].filter((id) => keep ? predicted.has(id) || given.includes(id) : true);
    const others = list.filter((r) => r.pr !== pr && r.state !== 'closed');
    // Close first: a failed close saves nothing, so the next run finds the pull request due again and
    // retries; a row closed meanwhile is no longer open there, and is not tried again.
    const resolved = [];
    for (const id of before.filter((x) => !proposals.includes(x) && predicted.has(x) && !holders(others, x).length)) {
      try { node('maintenance.mjs', ['close', id, 'resolved']); } catch { throw new Error(`maintenance.mjs close ${id} failed: nothing recorded (${resolved.length} closed before)`); }
      resolved.push(id);
    }
    const next = { pr, text_hash: hash, state, merged_at: merged ?? '-', updated_at: updated, proposals, scanned_utc: now() };
    if (row) Object.assign(row, next); else list.push(next);
    save(list);
    return { pr: +pr, state, proposals, resolved };
  });
}

function check() {
  const t = text();
  const problems = [];
  if (t == null) return { ok: true, problems, notes: ['work/PRSCAN.md not created yet'] };
  if (!t.split('\n').includes(HEADER)) problems.push('header changed');
  const seen = new Set();
  for (const r of rawRows(t)) {
    if (r.length !== COLS.length) { problems.push(`row "${r.join(' | ').slice(0, 80)}": ${r.length} cells, not ${COLS.length}`); continue; }
    const [pr, hash, state, merged, updated, props, scanned] = r;
    if (!/^[1-9]\d{0,6}$/.test(pr) || seen.has(pr)) problems.push(`"${pr}": not a pull request number, or twice`); seen.add(pr);
    if (!HASH_RE.test(hash)) problems.push(`#${pr}: text_hash "${hash}"`);
    if (!STATES.includes(state)) problems.push(`#${pr}: state "${state}"`);
    if (state === 'merged' ? !UTC_RE.test(merged) : merged !== '-') problems.push(`#${pr}: merged_at "${merged}" does not match state ${state}`);
    if (!UTC_RE.test(updated)) problems.push(`#${pr}: updated_at "${updated}"`);
    const ids = props === '-' ? [] : props.split(',').map((x) => x.trim());
    if (ids.some((x) => !M_RE.test(x))) problems.push(`#${pr}: proposals "${props}"`);
    if (state === 'closed' && ids.length) problems.push(`#${pr}: closed, yet holds ${ids.join(', ')}`);
    if (!UTC_RE.test(scanned)) problems.push(`#${pr}: scanned_utc "${scanned}"`);
  }
  return { ok: problems.length === 0, problems };
}

try {
  switch (cmd) {
    case 'since': {
      const list = load().map((r) => r.updated_at).filter((u) => UTC_RE.test(u)).sort();
      out({ since: list.at(-1) ?? new Date(Date.now() - FIRST_DAYS * 86400000).toISOString().replace(/\.\d+Z$/, 'Z') });
      break;
    }
    case 'scan': scan(); break;
    case 'record': out(record()); break;
    case 'list': out({ prs: load() }); break;
    case 'check': out(check()); break;
    default: die('usage: radar.mjs since|scan|record|list|check — see its header');
  }
} catch (e) {
  console.error(`radar: ${e.message}`);
  process.exit(e instanceof Usage ? 2 : 1);
}
