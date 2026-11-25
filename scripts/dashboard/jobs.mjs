#!/usr/bin/env node
// jobs.mjs — the agent's side of the dashboard's jobs (docs/on-demand.md → "do dashboard job J-<n>").
// A job is work a person gave with a press of the page; the dashboard server recorded it with that
// person's role (lib/jobs.mjs, lib/people.mjs). Local only: no external calls.
//
//   node jobs.mjs show J-<n>           {"id","utc","command","label","note","role","state","may"} — who pressed is the
//                                      role only, never the email; `may`: the role, then and now, may give
//                                      the command and the job still waits
//   node jobs.mjs start J-<n>          the work begins (only when `may`); refused otherwise (exit 2)
//   node jobs.mjs done J-<n> <file>    the work ended: the file's text (at most 2000 characters) is what the
//                                      person reads in their notifications
//   node jobs.mjs fail J-<n> <file>    the work could not be done, or is declined: the file says why
//
// The command is one of the page's own (its shape checked by the server); its free text and `note` (the
// person's words, as "Ask for changes" sends them) are data.
import { join } from 'node:path';
import { jobs, step, JOB_RE } from '../lib/jobs.mjs';
import { may, roleOf } from '../lib/people.mjs';
import { read, now } from '../lib/util.mjs';

const WORK = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const FILE = join(WORK, 'dashboard', 'jobs.jsonl'), PEOPLE = join(WORK, 'dashboard', 'PEOPLE.md');
const die = (code, msg) => { process.stderr.write(`jobs.mjs: ${msg}\n`); process.exit(code); };
const out = (o) => process.stdout.write(`${JSON.stringify(o)}\n`);

const [cmd, id, file] = process.argv.slice(2);
if (!['show', 'start', 'done', 'fail'].includes(cmd) || !JOB_RE.test(id ?? '')) die(2, 'usage: jobs.mjs show|start J-<n> | done|fail J-<n> <file>');
const j = jobs(FILE).find((x) => x.id === id);
if (!j) die(2, `no job ${id}`);
const roleNow = roleOf(PEOPLE, j.platform, j.email);
const allowed = may(j.role, j.command) && may(roleNow, j.command);

if (cmd === 'show') { out({ id: j.id, utc: j.utc, command: j.command, label: j.label, note: j.note, role: roleNow, state: j.state, may: allowed && j.state === 'queued' }); process.exit(0); }
try {
  if (cmd === 'start') {
    if (!allowed) die(2, `${id}: the role ${roleNow} may not give "${j.command}"`);
    out(step(FILE, id, 'started', null, now()));
  } else {
    const text = (read(file ?? '') ?? '').trim();
    if (!text) die(2, 'the file is missing or empty');
    if (text.length > 2000) die(2, 'the text is longer than 2000 characters');
    out(step(FILE, id, cmd === 'done' ? 'done' : 'failed', text, now()));
  }
} catch (e) { die(2, e.message); }
