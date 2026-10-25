#!/usr/bin/env node
// rerun.mjs — the record of a test the operator ran by hand ("run #42", "run S-7 AC-1",
// docs/on-demand.md): each criterion's raw result in that run, for the catalog's history and Runs
// view (docs/catalog.md) and as the evidence a found issue can cite (skills/create-issue). A run by
// hand is never a verdict: no criteria file, no verdicts file, no comment, no tier changes.
//
//   node rerun.mjs <label> <ref> --build <candidate>
//     <ref>: #42, #42 AC-2, #42 IN-1, #42 EX-1, S-7, S-7 AC-1, P-<slug>, P-<slug> AC-1
//     -> {"file", "ref", "build", "results": {"AC-1": {"status", "error"}}}
//
// Reads work/suite/.e2e/runs/<label>/report.json; writes work/reruns/<test>/<label>.json, where
// <test> is the file's stem (issue-42, scenario-7, profile-<slug>). status: passed | failed (the
// test ran and failed) | blocked (skipped, timed out, interrupted). Exit 2: usage or no such run.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const runsRoot = process.env.QI_RUNS_ROOT ?? join(work, 'suite', '.e2e', 'runs');
const [label, ...rest] = process.argv.slice(2);
const bi = rest.indexOf('--build');
const build = bi >= 0 ? rest[bi + 1] : null;
const ref = rest.filter((_, k) => k !== bi && k !== bi + 1).join(' ').trim().replace(/\s+/g, ' ');
// An intent test (IN-k, docs/intent.md) belongs to an issue only.
const m = /^(?:#(?<n>\d{1,7})(?: (?<i>(?:AC|IN|EX)-\d{1,3}))?|S-(?<s>\d{1,6})(?: (?<si>(?:AC|EX)-\d{1,3}))?|P-(?<p>[a-z0-9][a-z0-9-]{0,40})(?: (?<pi>(?:AC|EX)-\d{1,3}))?)$/.exec(ref);
const die = (msg) => { console.error(`rerun: ${msg}`); process.exit(2); };
if (!label || !/^[A-Za-z0-9._-]{1,120}$/.test(label) || !m || !build || !/^[A-Za-z0-9._+-]{1,80}$/.test(build)) {
  die('usage: rerun.mjs <label> <#N[ AC-k|IN-k|EX-k]|S-k[ AC-k|EX-k]|P-slug[ AC-k|EX-k]> --build <candidate>');
}
const g = m?.groups ?? {};
const stem = g.n ? `issue-${g.n}` : g.s ? `scenario-${g.s}` : `profile-${g.p}`;
const only = g.i ?? g.si ?? g.pi ?? null;
let report;
try { report = JSON.parse(readFileSync(join(runsRoot, label, 'report.json'), 'utf8')); } catch { die(`no report.json for run ${label}`); }

const results = {};
for (const r of report.run?.results ?? []) {
  const tags = r.tags ?? [];
  const ex = tags.includes(`${stem}-ex`);
  if (!tags.includes(stem) && !ex) continue;
  const id = tags.map((t) => /^(ac|in|ex)-(\d+)$/.exec(t)).find(Boolean);
  if (!id) continue;
  const key = `${id[1].toUpperCase()}-${id[2]}`;
  if (only && key !== only) continue;
  const att = r.attempts?.at(-1) ?? {};
  const status = r.status === 'passed' ? 'passed' : r.status === 'failed' ? 'failed' : 'blocked';
  results[key] = { status, error: att.error?.message ? String(att.error.message).replace(/\s+/g, ' ').slice(0, 400) : null };
}
const utc = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const dir = join(work, 'reruns', stem);
mkdirSync(dir, { recursive: true });
const file = join(dir, `${label}.json`);
writeFileSync(`${file}.tmp`, `${JSON.stringify({ label, ref, build, utc, results }, null, 2)}\n`);
renameSync(`${file}.tmp`, file);
console.log(JSON.stringify({ file, ref, build, results }));
