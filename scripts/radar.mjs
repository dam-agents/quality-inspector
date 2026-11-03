#!/usr/bin/env node
// radar.mjs — the Change radar (docs/radar.md): which pull requests of the target are new or changed
// since the radar last read them, which recurring tests their text names, and the ledger of what it
// read, work/PRSCAN.md (lib/prscan.mjs). It reads a pull request's sanitized text alone — what
// `github.sh prs` prints — never its diff, files, commits, reviews or comments, and writes nothing to
// GitHub. The proposals it leads to are maintenance rows of kind `predicted` (docs/maintenance.md).
//
//   node radar.mjs since [--days <n>]       -> {"since": <iso>}   the window's start: <n> (3; 1-30) days ago
//   node radar.mjs scan <prs.json> [--since <iso>] [--record]
//     -> {"due": [...], "plain": [{pr, kind, state, text_hash}], "deferred", "dropped", "truncated", "inventory", "logs": []}
//   node radar.mjs record <pr> --hash <h> --state <open|merged|closed> --updated-at <iso>
//        [--merged-at <iso>] [--proposal M-k]… [--keep]
//     -> {"pr", "state", "proposals", "resolved": []}
//   node radar.mjs list                     -> {"prs": [{pr, text_hash, state, merged_at, updated_at, proposals, scanned_utc}]}
//   node radar.mjs check                    -> {"ok", "problems": []}
//   node radar.mjs issues <changes.json>    -> {"issues": [{issue, title, candidates}]}   the completed issues of
//                                              changes.sh, each with the recurring tests its title and spec name
//                                              (lib/radar-match.mjs; docs/change-awareness.md). Read-only.
//
// since: no watermark — every run lists the whole window, newest first, and the ledger tells what it
//   read; a pull request last updated before the window's start is never read.
// scan: <prs.json> is `github.sh prs` output. Newest update first, a pull request is
//   `new` (no ledger row; open or merged — one closed unmerged before any scan is skipped), `changed`
//   (its text hash differs, or it was reopened), `merged` (merged since the last scan, text the same) or
//   `closed` (closed unmerged since). A `new` or `changed` entry carries its title, body,
//   `injection_suspect` (lib/scan-issues.mjs) and `candidates` (lib/radar-match.mjs). One with nothing
//   to judge and nothing to keep or resolve — no candidate (or `merged` / `closed`) and no proposal — is
//   `plain`: --record writes its ledger row here, as `record` would, and it is never due. The rest are
//   due; at most QI_RADAR_MAX (10) `new` / `changed` a run, the newest — the others are `deferred`, and
//   a later run reads them while they stay inside the window. One updated before --since (the window's
//   start) is `dropped`, one log line for all; one with no update time is skipped, since no row can
//   hold it (one log line). `truncated`: the listing held more items than
//   `github.sh prs` pages, so the oldest part of the window was not listed (one log line).
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
import { now, read } from './lib/util.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const WINDOW_DAYS = 3;
const HASH_RE = /^[0-9a-f]{12}$/;

class Usage extends Error {}
const die = (msg) => { throw new Usage(msg); };
const out = (o) => console.log(JSON.stringify(o));
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
  let listing;
  try { listing = JSON.parse(readFileSync(path, 'utf8')); } catch { die(`${path}: not the JSON of github.sh prs`); }
  const prs = listing?.prs;
  if (typeof listing?.truncated !== 'boolean' || !Array.isArray(prs) || prs.some((p) => !Number.isInteger(p?.number) || !STATES.includes(p?.state))) die(`${path}: not the JSON of github.sh prs`);
  const since = flag('--since');
  if (since != null && !UTC_RE.test(since)) die('--since is the window\'s start, <YYYY-MM-DDTHH:MM:SSZ>');
  const max = Number.parseInt(process.env.QI_RADAR_MAX ?? '10', 10) || 10;
  const ledger = new Map(load().map((r) => [r.pr, r]));
  const ctx = context();
  const due = []; const plain = []; const logs = []; let deferred = 0; let dropped = 0; let reads = 0; let unchanged = 0; let unseen = 0; let untimed = 0;
  for (const pr of prs.slice().sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)) || b.number - a.number)) {
    if (!UTC_RE.test(pr.updated_at ?? '')) { untimed++; continue; }
    if (since && pr.updated_at < since) { dropped++; continue; }
    const row = ledger.get(String(pr.number)); const hash = hashOf(pr);
    let kind = null;
    if (!row) kind = pr.state === 'closed' ? null : 'new';
    else if (pr.state === 'closed') kind = row.state === 'closed' ? null : 'closed';
    else if (row.text_hash !== hash || row.state === 'closed') kind = 'changed';
    else if (pr.state === 'merged' && row.state === 'open') kind = 'merged';
    if (!kind) { if (row) unchanged++; else unseen++; continue; }
    const reading = kind === 'new' || kind === 'changed';
    const e = { pr: pr.number, kind, state: pr.state, draft: pr.draft === true, merged_at: pr.merged_at ?? null, updated_at: pr.updated_at,
      text_hash: hash, labels: pr.labels ?? [], proposals: row?.proposals ?? [] };
    if (reading) Object.assign(e, { title: pr.title, body: pr.body, injection_suspect: injectionLint(`${pr.title}\n${pr.body}`).injection_suspect,
      candidates: matchPr(`${pr.title}\n${pr.body}`, ctx) });
    if (!e.proposals.length && !e.candidates?.length) { plain.push(e); continue; }
    if (reading && reads >= max) { deferred++; continue; }
    if (reading) reads++;
    due.push(e);
    logs.push(`PR #${pr.number}: ${kind}${reading ? ` (${e.candidates.length} candidate test${e.candidates.length === 1 ? '' : 's'})` : ''} — due`);
  }
  if (unchanged) logs.push(`${unchanged} pull request(s) unchanged since their scan — skip`);
  if (unseen) logs.push(`${unseen} pull request(s) closed unmerged before any scan — skip`);
  let note = 'not due';
  if (args.includes('--record') && plain.length) {
    try { note = `ledger rows written (${recordPlain(plain).length})`; } catch (err) { note = `ledger rows not written (${err.message}) — the next run scans them again`; }
  }
  if (plain.length) logs.push(`${plain.length} pull request(s) with no candidate test and no proposal — ${note}`);
  if (deferred) logs.push(`${deferred} new or changed pull request(s) over the cap (${max} a run) — a later run reads them, newest first, while they stay inside the window`);
  if (dropped) logs.push(`${dropped} pull request(s) updated before ${since} — outside the window, dropped`);
  if (untimed) logs.push(`${untimed} pull request(s) with no update time in the listing — skip`);
  const last = UTC_RE.test(listing.last_updated_at ?? '') ? listing.last_updated_at : null;
  if (listing.truncated) logs.push(`listing cut at its page limit${last ? ` (oldest listed update ${last})` : ''} — the pull requests updated before it are not read`);
  out({ due, plain: plain.map(({ pr, kind, state, text_hash }) => ({ pr, kind, state, text_hash })), deferred, dropped, truncated: listing.truncated, inventory: ctx.inventory, logs });
}

// The ledger rows of the plain entries, as `record` writes them without a proposal: under the mutex,
// and only where the row did not gain a proposal since the scan read the ledger. Returns their numbers.
function recordPlain(plain) {
  const ok = plain.filter((e) => UTC_RE.test(e.updated_at ?? '') && (e.state === 'merged' ? UTC_RE.test(e.merged_at ?? '') : true));
  if (!ok.length) return [];
  return withMutex(`${FILE}.lock`, () => {
    const list = load(); const at = now(); const done = [];
    for (const e of ok) {
      const row = list.find((r) => r.pr === String(e.pr));
      if (row?.proposals.length) continue;
      const next = { pr: String(e.pr), text_hash: e.text_hash, state: e.state, merged_at: e.state === 'merged' ? e.merged_at : '-',
        updated_at: e.updated_at, proposals: [], scanned_utc: at };
      if (row) Object.assign(row, next); else list.push(next);
      done.push(e.pr);
    }
    save(list);
    return done;
  });
}

// The completed issues of a build window against the suite: the leads of a night's triage.
function issues() {
  const path = args[0] ?? die('usage: radar.mjs issues <changes.json>');
  let ch;
  try { ch = JSON.parse(readFileSync(path, 'utf8')); } catch { die(`${path}: not the JSON of changes.sh`); }
  if (ch?.error) die(`${path}: changes.sh failed: ${ch.error}`);
  if (!Array.isArray(ch?.issues)) die(`${path}: not the JSON of changes.sh`);
  const ctx = context();
  out({ issues: ch.issues.filter((i) => Number.isInteger(i?.number)).map((i) => ({ issue: i.number, title: i.title ?? '',
    candidates: matchPr(`${i.title ?? ''}\n${i.spec ?? ''}`, ctx) })).filter((i) => i.candidates.length) });
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

// The window's start: --days (1-30, default 3) before now.
function windowStart() {
  const d = flag('--days') ?? String(WINDOW_DAYS);
  if (!/^\d{1,2}$/.test(d) || +d < 1 || +d > 30) die('--days is a whole number of days, 1-30');
  return new Date(Date.now() - +d * 86400000).toISOString().replace(/\.\d+Z$/, 'Z');
}

try {
  switch (cmd) {
    case 'since': out({ since: windowStart() }); break;
    case 'scan': scan(); break;
    case 'issues': issues(); break;
    case 'record': out(record()); break;
    case 'list': out({ prs: load() }); break;
    case 'check': out(check()); break;
    default: die('usage: radar.mjs since|scan|issues|record|list|check — see its header');
  }
} catch (e) {
  console.error(`radar: ${e.message}`);
  process.exit(e instanceof Usage ? 2 : 1);
}
