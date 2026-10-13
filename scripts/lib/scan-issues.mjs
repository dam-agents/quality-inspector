#!/usr/bin/env node
// scan-issues.mjs — the issues pre-flight's per-issue decisions in one process: spec text,
// ac_hash, spec lint, the QA.md row, lock age and liveness, the retest gate, the cap.
// A shell loop forked a dozen tools per issue; this keeps the Precheck far inside its two
// minutes. Byte-for-byte the same spec text and hash as lib/state.sh (test_scan_parity.sh).
//
//   scan-issues.mjs <listing.json> <QA.md> <events-dir>   -> {"due":[…],"reports":[…],"logs":[…],"deferred":n}
// Env: QI_RETEST_LABEL, QI_MAX_ISSUES, QI_LOCK_TTL_MIN, QI_NOW_EPOCH.

import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

export const VAGUE = /\b(better|faster|improve[sd]?|properly|correctly|nicer|cleaner|robust|seamless|intuitive|as expected|should work|works? well|user-friendly|etc\.?)\b/gi;
const DONE = /^#{1,6}[ \t]+[Dd]one[ \t]+[Ww]hen[ \t]*$/;

// Same as state.sh issue_spec_text: the "Done when" section (to the next heading of the
// same or a higher level), else the whole body; the title first.
export function specText(title, body) {
  const lines = String(body ?? '').replace(/\r/g, '').split('\n');
  let on = false, lvl = 0; const sec = [];
  for (const l of lines) {
    if (!on && DONE.test(l)) { on = true; lvl = l.indexOf(' '); continue; }
    if (on && /^#{1,6}[ \t]/.test(l)) { const n = l.search(/[ \t]/); if (n <= lvl) break; }
    if (on) sec.push(l);
  }
  const s = sec.join('\n');
  return s.replace(/\s/g, '') ? `${title}\n${s}\n` : `${title}\n${String(body ?? '').replace(/\r/g, '')}\n`;
}
export const hasDoneWhen = (body) => String(body ?? '').split('\n').some((l) => /^#{1,6}[ \t]+done[ \t]+when[ \t]*$/i.test(l.replace(/\r$/, '')));
// Same as state.sh text_hash: whitespace runs to one space, trimmed, sha256, 12 hex.
export const textHash = (t) => createHash('sha256').update(t.replace(/\s+/g, ' ').replace(/^ /, '').replace(/ $/, '')).digest('hex').slice(0, 12);
export function specLint(title, body) {
  const spec = specText(title, body).split('\n').slice(1).join('\n');
  const items = spec.split('\n').filter((l) => /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/.test(l)).length;
  const vague = [...new Set((spec.match(VAGUE) ?? []).map((w) => w.toLowerCase()))].sort();
  const words = spec.split(/\s+/).filter(Boolean).length;
  const d = hasDoneWhen(body);
  return { has_done_when: d, items, vague, words, weak: items === 0 && (!d || words < 8) };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [listingPath, qaPath, eventsDir] = process.argv.slice(2);
  const retest = process.env.QI_RETEST_LABEL ?? 'qa:retest';
  const max = Number(process.env.QI_MAX_ISSUES ?? 1);
  const ttl = Number(process.env.QI_LOCK_TTL_MIN ?? 180);
  const now = Number(process.env.QI_NOW_EPOCH ?? Math.floor(Date.now() / 1000));
  const listing = JSON.parse(readFileSync(listingPath, 'utf8'));

  const rows = new Map();
  if (existsSync(qaPath)) {
    for (const l of readFileSync(qaPath, 'utf8').split('\n').filter((x) => x.startsWith('|')).slice(2)) {
      const c = l.split('|').slice(1, -1).map((x) => x.trim());
      if (c[0]) rows.set(c[0], { hash: c[1], status: c[5], updated: c[6] });
    }
  }
  // Newest event time per issue, from the last two daily files.
  const lastEvent = new Map();
  if (existsSync(eventsDir)) {
    for (const f of readdirSync(eventsDir).filter((x) => /^events-.*\.jsonl$/.test(x)).sort().slice(-2)) {
      for (const line of readFileSync(join(eventsDir, f), 'utf8').split('\n')) {
        if (!line) continue;
        let e; try { e = JSON.parse(line); } catch { continue; }
        const m = /(?:^|\s)issue=(\d+)(?:\s|$)/.exec(e.msg ?? '');
        if (m) { const t = Date.parse(e.ts) / 1000; if (!(lastEvent.get(m[1]) > t)) lastEvent.set(m[1], t); }
      }
    }
  }
  const mins = (iso) => Math.floor((now - (Date.parse(iso) / 1000 || 0)) / 60);

  const due = []; const reports = []; const logs = []; let deferred = 0;
  for (const it of listing.filter((x) => !x.pull_request).sort((a, b) => a.number - b.number)) {
    const n = it.number; const title = it.title ?? ''; const body = it.body ?? '';
    const hash = textHash(specText(title, body));
    const isRetest = (it.labels ?? []).some((l) => l.name === retest);
    const row = rows.get(String(n));
    let kind = ''; let takeover = false;
    if (!row) kind = 'first';
    else if (row.status === 'in_progress') {
      const age = mins(row.updated); const silent = Math.floor((now - (lastEvent.get(String(n)) ?? 0)) / 60);
      if (age >= ttl && silent >= 30) { kind = 'takeover'; takeover = true; logs.push(`issue #${n}: stale lock (${age}m old, ${silent}m silent) — takeover`); }
      else { logs.push(`issue #${n}: in progress (${age}m) — skip`); continue; }
    } else if (isRetest) kind = 'retest';
    else if (row.hash !== hash) kind = 'ac_changed';
    else if (row.status === 'report_pending') { reports.push({ issue: n }); logs.push(`issue #${n}: report pending delivery — due`); continue; }
    else { logs.push(`issue #${n}: done at ac=${hash} — skip`); continue; }
    if (due.length >= max) { deferred++; logs.push(`issue #${n}: ${kind} — deferred (max_issues_per_run)`); continue; }
    due.push({ issue: n, ac_hash: hash, kind, takeover, has_done_when: hasDoneWhen(body), retest_label_present: isRetest, spec: specLint(title, body) });
    logs.push(`issue #${n}: ${kind} (ac=${hash}) — due`);
  }
  console.log(JSON.stringify({ due, reports, logs, deferred }));
}
