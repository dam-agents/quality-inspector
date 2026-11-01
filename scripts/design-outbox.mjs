#!/usr/bin/env node
// design-outbox.mjs — which design findings go to the Design Desk, and in which words
// (docs/design-checks.md → To the Design Desk). Local only: it composes the messages and keeps the
// ledger work/design-checks/SENT.md; the agent sends (`send_channel_message`), never this script.
//
//   node design-outbox.mjs plan <check.json|radar.json>…
//     -> {"sending": bool, "reason", "channel", "due": [{ref, check, severity, build, text, attachment}],
//         "ready": n, "held": {sent, unsure, below_floor, over_cap, invalid}, "logs"}
//        The findings of the files, each Ref once: not in SENT.md, and its last ledger line in the event
//        logs not an `intent` (a send that may have gone out) or a `done` (its record did not run) —
//        both count as sent, never twice; only a last `failed` lets it go again — at or above
//        `design_desk_min_severity` (medium), the most severe first, at most `design_desk_max_per_run`
//        (5). `text` is the exact message (lib/design-rules.mjs → formatMessage) ending in the mention
//        of `design_desk_bot`; `attachment` the absolute path of its one screenshot or null. With
//        `design_desk_findings` not `enabled`, or no valid channel or bot, `sending` is false, `due` is
//        empty and `ready` counts what would have gone.
//   node design-outbox.mjs record <ref> --status sent|held --check C --severity S --build B [--note TEXT]
//     -> {"ref", "recorded": bool}   one SENT.md row; a Ref already there is not recorded again.
//        `held`: the agent's look at the screenshot found the finding false — never sent.
//   node design-outbox.mjs list   -> {"rows": [...]}
//   node design-outbox.mjs check  -> {"ok", "problems": []}   SENT.md and PRS.md readable, each row valid
//
// Exit 2: usage or a bad value; exit 1: a ledger that cannot be read or written.

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { WORK, msg, sh } from './lib/design-browser.mjs';
import { TABLES, UTC_RE, append, now, rows } from './lib/design-ledger.mjs';
import { CHECKS, REF_RE, SEVERITIES, formatMessage, sevRank, validFinding } from './lib/design-rules.mjs';

const [cmd, ...argv] = process.argv.slice(2);
const flags = {}; const pos = [];
for (let i = 0; i < argv.length; i++) { const a = argv[i]; if (a.startsWith('--')) flags[a.slice(2)] = argv[++i]; else pos.push(a); }
const die = (m, code = 2) => { console.error(`design-outbox: ${m}`); process.exit(code); };
const out = (o) => console.log(JSON.stringify(o));
const usage = 'usage: design-outbox.mjs plan <check.json|radar.json>… | record <ref> --status sent|held --check C --severity S --build B [--note TEXT] | list | check';
const CHANNEL_RE = /^[CDG][A-Z0-9]{6,20}$/;
const BOT_RE = /^[UW][A-Z0-9]{6,20}$/;

// Refs whose send went out, or may have, by the event logs: Ref -> its last action, `intent` (no
// outcome yet) or `done` (SENT.md missed its row). A last `failed` lets the Ref go again.
function logged() {
  const last = new Map();
  let files = [];
  try { files = readdirSync(join(WORK, 'logs')).filter((f) => /^events-\d{4}-\d\d-\d\d\.jsonl$/.test(f)).sort(); } catch { return new Map(); }
  for (const f of files) {
    for (const l of readFileSync(join(WORK, 'logs', f), 'utf8').split('\n')) {
      if (!l.includes('key=design@')) continue;
      let e; try { e = JSON.parse(l); } catch { continue; }
      const m = /surface=slack action=(intent|done|failed) .*key=design@(\S+)/.exec(e.event === 'external_write' ? e.msg ?? '' : '');
      if (m) last.set(m[2], m[1]);
    }
  }
  return new Map([...last].filter(([, a]) => a !== 'failed'));
}

if (cmd === 'plan') {
  if (!pos.length) die(usage);
  const on = sh('cfg design_desk_findings') === 'enabled';
  const channel = sh('cfg design_desk_channel'); const bot = sh('cfg design_desk_bot');
  const maxN = (() => { const n = Number(sh('cfg design_desk_max_per_run') || 5); return Number.isInteger(n) && n >= 1 && n <= 20 ? n : 5; })();
  const floorRaw = sh('cfg design_desk_min_severity') || 'medium';
  const floor = SEVERITIES.includes(floorRaw) ? floorRaw : 'medium';
  const logs = [];
  if (floorRaw !== floor) logs.push(`design_desk_min_severity '${floorRaw}' is invalid — medium is used`);
  let sent;
  try { sent = new Set(rows('sent').map((r) => r.ref)); } catch (e) { die(msg(e), 1); }
  const gone = logged();
  const held = { sent: 0, unsure: 0, below_floor: 0, over_cap: 0, invalid: 0 };
  const seen = new Set(); const list = [];
  for (const [fi, file] of pos.entries()) {
    let r;
    try { r = JSON.parse(readFileSync(file, 'utf8')); } catch (e) { die(`cannot read ${file}: ${msg(e)}`); }
    for (const [i, f] of (r.findings ?? []).entries()) {
      if (seen.has(f?.ref)) continue;
      seen.add(f?.ref);
      const bad = validFinding(f);
      if (bad.length) { held.invalid++; logs.push(`${file}: finding ${i} is invalid (${bad.join(', ')}) — not sent`); continue; }
      if (sent.has(f.ref)) { held.sent++; continue; }
      if (gone.get(f.ref) === 'done') { held.sent++; logs.push(`${f.ref}: the event log has its send but SENT.md has no row — it counts as sent, never again`); continue; }
      if (gone.get(f.ref) === 'intent') { held.unsure++; logs.push(`${f.ref}: an earlier send has no outcome in the ledger — it counts as sent, never again`); continue; }
      if (sevRank(f.severity) > sevRank(floor)) { held.below_floor++; continue; }
      const att = f.attachment ? resolve(dirname(resolve(file)), f.attachment) : null;
      list.push({ f, order: [sevRank(f.severity), CHECKS.indexOf(f.check), fi, i], attachment: att && existsSync(att) ? att : null });
    }
  }
  // The most severe first; then accessibility, missing states, consistency, radar; then file order.
  list.sort((a, b) => { const k = a.order.findIndex((v, j) => v !== b.order[j]); return k < 0 ? 0 : a.order[k] - b.order[k]; });
  const ready = list.length;
  const why = !on ? 'design_desk_findings is not enabled' : !CHANNEL_RE.test(channel) ? 'design_desk_channel is not a Slack conversation id'
    : !BOT_RE.test(bot) ? 'design_desk_bot is not a Slack member id (U…)' : null;
  if (why) { out({ sending: false, reason: why, channel: channel || null, due: [], ready, held, logs }); process.exit(0); }
  held.over_cap = Math.max(0, list.length - maxN);
  const due = list.slice(0, maxN).map(({ f, attachment }) => ({ ref: f.ref, check: f.check, severity: f.severity, build: f.build,
    text: formatMessage(f, bot), attachment }));
  for (const d of due.filter((x) => !x.attachment)) logs.push(`${d.ref}: no screenshot — it goes without one`);
  out({ sending: true, reason: null, channel, due, ready, held, logs });
  process.exit(0);
}

if (cmd === 'record') {
  const [ref] = pos;
  const { status, check, severity, build, note } = flags;
  if (!REF_RE.test(ref ?? '') || !['sent', 'held'].includes(status) || !CHECKS.includes(check) || !SEVERITIES.includes(severity) || !String(build ?? '').trim()) die(usage);
  try {
    if (rows('sent').some((r) => r.ref === ref)) { out({ ref, recorded: false, reason: 'already recorded' }); process.exit(0); }
    append('sent', { ref, status, check, severity, build, note: String(note ?? '').slice(0, 200), utc: now() });
  } catch (e) { die(msg(e), 1); }
  out({ ref, recorded: true }); process.exit(0);
}

if (cmd === 'list') {
  try { out({ rows: rows('sent') }); } catch (e) { die(msg(e), 1); }
  process.exit(0);
}

if (cmd === 'check') {
  const problems = [];
  for (const name of Object.keys(TABLES)) {
    let rs;
    try { rs = rows(name); } catch (e) { problems.push(msg(e)); continue; }
    const seen = new Set();
    for (const [i, r] of rs.entries()) {
      const at = `${TABLES[name].file.slice(WORK.length + 1)} row ${i + 1}`;
      if (name === 'sent') {
        if (!REF_RE.test(r.ref ?? '') || !['sent', 'held'].includes(r.status) || !CHECKS.includes(r.check) || !SEVERITIES.includes(r.severity)) problems.push(`${at}: not a valid row`);
        if (seen.has(r.ref)) problems.push(`${at}: ${r.ref} is recorded twice`);
        seen.add(r.ref);
        if (!UTC_RE.test(r.utc ?? '')) problems.push(`${at}: utc is not a UTC time`);
      } else {
        if (!/^[1-9][0-9]{0,6}$/.test(r.pr ?? '') || !/^\d+$/.test(r.findings ?? '') || !UTC_RE.test(r.checked_utc ?? '')) problems.push(`${at}: not a valid row`);
      }
    }
  }
  out({ ok: !problems.length, problems }); process.exit(0);
}

die(usage);
