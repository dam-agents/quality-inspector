// people.mjs (lib) — who may do what on the dashboard (docs/dashboard-page.md → Roles). The roster is
// work/dashboard/PEOPLE.md `| email | role | changed_utc |`, written only by the dashboard server for an
// admin's press in Settings → People; read by the server and by scripts/dashboard/jobs.mjs.
//
// Four roles. The platform's owner of the dashboard is always an admin, and is never a row.
//   admin      everything, the settings and the people included
//   developer  the work of the page: run, repair, keep, upkeep, bug issues, dismissals, collections —
//   tester     not the settings, the schedules, the focus area or a blocker's retry (the two the same for now)
//   viewer     reads; asks a question in the chat; presses nothing that changes anything
// A person not in the roster is a viewer.
import { mkdirSync, renameSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { read } from './util.mjs';

export const ROLES = ['admin', 'developer', 'tester', 'viewer'];
const HEAD = '| email | role | changed_utc |';
// The commands only an admin gives: the settings and schedules, the focus area, a blocker's retry, a live walk.
const ADMIN_ONLY = [/^module /, /^focus /, /^retry B-/, /^walk these steps live: /];
export const EMAIL_RE = /^[a-z0-9._%+-]{1,64}@[a-z0-9.-]{1,190}\.[a-z]{2,24}$/;

const rowsOf = (text) => (text ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2)
  .map((l) => l.split('|').slice(1, -1).map((x) => x.trim())).filter(([e, r]) => EMAIL_RE.test(e ?? '') && ROLES.includes(r));
// [{email, role, utc}] — the roster as written, one row an email (the last row wins).
export function people(file) {
  const m = new Map();
  for (const [email, role, utc] of rowsOf(read(file))) m.set(email, { email, role, utc: utc || null });
  return [...m.values()];
}
// The role of a caller: the platform's owner is an admin; anyone else as the roster says, else viewer.
export function roleOf(file, platformRole, email) {
  if (platformRole === 'owner') return 'admin';
  const e = String(email ?? '').trim().toLowerCase();
  return (e && people(file).find((p) => p.email === e)?.role) || 'viewer';
}
// May this role give this command of the page? (The command's shape is checked elsewhere.)
export function may(role, command) {
  if (role === 'admin') return true;
  if (role !== 'developer' && role !== 'tester') return false;
  return !ADMIN_ONLY.some((re) => re.test(String(command ?? '')));
}
// The admin's change: a role for an email, or null to take the row out. → {email, old, role}
export function setRole(file, email, role, now) {
  const e = String(email ?? '').trim().toLowerCase();
  if (!EMAIL_RE.test(e)) throw new Error('Write an email address, like pat@example.com.');
  if (role !== null && !ROLES.includes(role)) throw new Error(`A role is one of ${ROLES.join(', ')}.`);
  const list = people(file), old = list.find((p) => p.email === e)?.role ?? null;
  const kept = list.filter((p) => p.email !== e);
  if (role !== null) kept.push({ email: e, role, utc: now });
  if (kept.length > 200) throw new Error('The roster holds at most 200 people.');
  const text = `${HEAD}\n| --- | --- | --- |\n${kept.map((p) => `| ${p.email} | ${p.role} | ${p.utc ?? '-'} |`).join('\n')}${kept.length ? '\n' : ''}`;
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(`${file}.tmp`, text, { mode: 0o600 }); renameSync(`${file}.tmp`, file);
  return { email: e, old, role };
}
