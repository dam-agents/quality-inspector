// jobs.mjs (lib) — the dashboard's jobs J-<n>: work a person gave Quality Inspector with a press of the
// page (docs/dashboard-page.md → Commands). One file, work/dashboard/jobs.jsonl, append only:
//   {"id":"J-<n>","utc","event":"queued","command","label","item","note","role","platform","email"}  the server
//   {"id":"J-<n>","utc","event":"started"|"done"|"failed","text"?}                           jobs.mjs (the agent)
// A job's state is its last event. The server writes a job only for a role that may give its command
// (lib/people.mjs); the agent starts it only when that is still so.
import { appendFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { read } from './util.mjs';

export const JOB_RE = /^J-\d{1,6}$/;
export const STATES = { queued: 'Waiting', started: 'Working', done: 'Done', failed: 'Did not work' };
const rowsOf = (file) => (read(file) ?? '').split('\n').filter(Boolean).map((l) => { try { return JSON.parse(l); } catch { return null; } })
  .filter((r) => r && JOB_RE.test(r.id ?? '') && ['queued', 'started', 'done', 'failed'].includes(r.event));
const append = (file, row) => { mkdirSync(dirname(file), { recursive: true }); appendFileSync(file, `${JSON.stringify(row)}\n`, { mode: 0o600 }); };

// [{id, utc, command, label, item, note, role, platform, email, state, started, finished, text}], oldest first.
export function jobs(file) {
  const m = new Map();
  for (const r of rowsOf(file)) {
    if (r.event === 'queued') { if (!m.has(r.id)) m.set(r.id, { id: r.id, utc: r.utc, command: r.command, label: r.label ?? null, item: r.item ?? null, note: r.note ?? null, role: r.role, platform: r.platform, email: r.email ?? null, state: 'queued', started: null, finished: null, text: null }); continue; }
    const j = m.get(r.id); if (!j) continue;
    j.state = r.event;
    if (r.event === 'started') j.started = r.utc; else { j.finished = r.utc; j.text = typeof r.text === 'string' ? r.text.slice(0, 2000) : null; }
  }
  return [...m.values()];
}
export function queue(file, { command, label, item, note, role, platform, email }, now) {
  const id = `J-${jobs(file).length + 1}`;
  append(file, { id, utc: now, event: 'queued', command, label: label ?? null, item: item ?? null, ...(note ? { note } : {}), role, platform, email: email ?? null });
  return id;
}
// The agent's step of a job: started (from queued), done (from started), failed (from queued or started).
export function step(file, id, event, text, now) {
  const j = jobs(file).find((x) => x.id === id);
  if (!j) throw new Error(`no job ${id}`);
  const from = { started: ['queued'], done: ['started'], failed: ['queued', 'started'] }[event];
  if (!from) throw new Error(`no step ${event}`);
  if (!from.includes(j.state)) throw new Error(`${id} is ${j.state}, not ${from.join(' or ')}`);
  append(file, { id, utc: now, event, ...(text ? { text: String(text).slice(0, 2000) } : {}) });
  return { id, state: event };
}
