#!/usr/bin/env node
// validation-results.mjs — the validation module's results from its e2e runs (docs/validation.md):
// each plan case's outcome, its severity keyed on the oracle prefix the test's failure message
// opens with, and flakiness from the confirmation runs. Deterministic; reads the plan and the
// runs' report.json, writes work/validation/<build>/results.json only.
//
//   node validation-results.mjs <plan.json> --run <label> [--confirm <label>]…
//     -> {"results", "cases", "ok", "major", "minor", "blocked", "flaky"}
//
// A case without a result in the run is `blocked` ("not run"). A finding whose confirmation
// run passed at least once is `flaky`, not a finding. A run that cannot have reached the
// tests — its report.json missing or unreadable, or no val-* result while the plan has
// cases — is no result: exit 1, {"error"}, nothing written.

import { readFileSync, renameSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const argv = process.argv.slice(2);
const planPath = argv[0];
const many = (k) => argv.flatMap((a, i) => (a === `--${k}` && argv[i + 1] ? [argv[i + 1]] : []));
const label = many('run')[0];
if (!planPath || planPath.startsWith('--') || !label) {
  console.error('usage: validation-results.mjs <plan.json> --run <label> [--confirm <label>]…'); process.exit(2);
}
const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const runsRoot = process.env.QI_RUNS_ROOT ?? join(work, 'suite', '.e2e', 'runs');
const readJson = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } };
const plan = readJson(planPath);
if (!plan || !Array.isArray(plan.cases)) { console.error(`validation-results: ${planPath} is not a plan`); process.exit(2); }

// Results of one run by case tag (val-<k>): every attempt's status and the last error message.
const report = (lbl) => readJson(join(runsRoot, lbl, 'report.json'));
const byTag = (rep) => {
  const m = new Map();
  for (const r of Array.isArray(rep?.run?.results) ? rep.run.results : []) {
    const tag = (r.tags ?? []).find((t) => /^val-\d+$/.test(t));
    if (!tag) continue;
    const e = m.get(tag) ?? { statuses: [], message: null };
    e.statuses.push(r.status);
    const err = r.attempts?.at(-1)?.error?.message;
    if (err) e.message = String(err).split('\n')[0].slice(0, 300);
    m.set(tag, e);
  }
  return m;
};
const fail = (error) => { console.log(JSON.stringify({ error })); process.exit(1); };
const mainReport = report(label);
if (!Array.isArray(mainReport?.run?.results)) fail(`run ${label}: no readable report.json under ${join(runsRoot, label)} — the run did not finish`);
const main = byTag(mainReport);
if (plan.cases.length && !main.size) fail(`run ${label}: no val-* result for the plan's ${plan.cases.length} cases — the run did not reach the tests`);
const confirms = many('confirm').map((l) => byTag(report(l)));

const SEVERITY = { 'no-server-error': 'major', 'no-uncaught-error': 'major', 'no-error-page': 'major',
  'value-intact': 'major', 'single-effect': 'major', 'refused-visibly': 'minor' };
const cases = plan.cases.map((c) => {
  const tag = String(c.id).toLowerCase();
  const r = main.get(tag);
  const base = { id: c.id, page: c.page, form: c.form, field: c.field ?? null, kind: c.kind, oracle: c.oracle };
  if (!r) return { ...base, result: 'blocked', severity: null, message: 'not run' };
  if (r.statuses.every((s) => s === 'passed')) return { ...base, result: 'ok', severity: null, message: null };
  if (r.statuses.every((s) => s === 'skipped')) return { ...base, result: 'blocked', severity: null, message: r.message ?? 'skipped' };
  const prefix = /^\[([a-z-]+)\]/.exec(r.message ?? '')?.[1];
  if (!prefix || !SEVERITY[prefix]) return { ...base, result: 'blocked', severity: null, message: r.message ?? 'failed before a check' };
  const flaky = confirms.some((m) => (m.get(tag)?.statuses ?? []).includes('passed'));
  return { ...base, result: flaky ? 'flaky' : 'finding', severity: flaky ? null : SEVERITY[prefix], message: r.message };
});

const count = (f) => cases.filter(f).length;
const out = join(dirname(planPath), 'results.json');
const doc = { build: plan.build, generated_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), run: label,
  confirm: many('confirm'), cases };
writeFileSync(`${out}.tmp`, JSON.stringify(doc, null, 2)); renameSync(`${out}.tmp`, out);
console.log(JSON.stringify({ results: out, cases: cases.length, ok: count((c) => c.result === 'ok'),
  major: count((c) => c.severity === 'major'), minor: count((c) => c.severity === 'minor'),
  blocked: count((c) => c.result === 'blocked'), flaky: count((c) => c.result === 'flaky') }));
