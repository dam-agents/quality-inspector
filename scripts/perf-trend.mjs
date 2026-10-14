#!/usr/bin/env node
// perf-trend.mjs — which promoted tests got slower. Reads the e2e reports of the runs
// labelled regression-* (work/suite/.e2e/runs/<label>/report.json, oldest first by the
// report's mtime), keeps per test title its last --k + 1 durations in work/perf/trend.json
// (local bookkeeping; a run already recorded never counts twice, and the history outlives
// the media retention of the runs), and prints the tests whose duration in the judged run
// exceeds the median of their up to --k earlier runs by more than --perf-factor and by at
// least 1000 ms. Only passed tests count; fewer than 3 earlier runs is no trend yet.
// Deterministic and read-only toward everything but work/perf/ (docs/regression.md).
//
//   node perf-trend.mjs [<label>] [--k 10] [--perf-factor 2.0]
//     -> {"latest": <label>|null, "tests": N, "slow_tests": [{title, latest_ms, median_ms, runs, explanation}]}
//
// <label> is the run to judge; default the newest regression-* run.

import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const flag = (k, d) => { const i = argv.indexOf(`--${k}`); return i >= 0 ? Number(argv[i + 1]) : d; };
const label = argv.find((x, i) => !x.startsWith('--') && !argv[i - 1]?.startsWith('--'));
const FACTOR = flag('perf-factor', 2.0);
const K = flag('k', 10);
const FLOOR_MS = 1000; // absolute growth below this is noise, whatever the factor
const MIN_HISTORY = 3;
if (!(FACTOR > 1) || !(K >= MIN_HISTORY)) { console.error(`usage: perf-trend.mjs [<label>] [--k N>=${MIN_HISTORY}] [--perf-factor F>1]`); process.exit(2); }

const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const runsRoot = process.env.QI_RUNS_ROOT ?? join(work, 'suite', '.e2e', 'runs');
const dir = join(work, 'perf');
const file = join(dir, 'trend.json');
const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');

const median = (xs) => {
  const s = [...xs].sort((p, q) => p - q);
  if (!s.length) return null;
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : Math.round((s[m - 1] + s[m]) / 2);
};

// State: {schema, updated_utc, runs: [labels recorded], tests: {title: {samples: [{run, ms}], median_ms}}}.
// An unreadable file is backed up to work/backup/ and the history starts over.
let state = { schema: 'qi-perf-trend/v1', runs: [], tests: {} };
if (existsSync(file)) {
  try {
    const s = JSON.parse(readFileSync(file, 'utf8'));
    if (!Array.isArray(s.runs) || typeof s.tests !== 'object' || !s.tests) throw new Error('unexpected shape');
    state = { ...state, ...s };
  } catch (e) {
    mkdirSync(join(work, 'backup'), { recursive: true });
    const to = join(work, 'backup', `perf-trend.json.${now()}`);
    copyFileSync(file, to);
    console.error(`perf-trend: ${file} unreadable (${e.message}); backed up to ${to}, history restarts`);
  }
}

// One run -> Map(title -> duration ms) of its passed tests.
function durations(lbl) {
  const report = JSON.parse(readFileSync(join(runsRoot, lbl, 'report.json'), 'utf8'));
  const per = new Map();
  for (const r of report.run?.results ?? []) {
    if (r.selected === false || r.status !== 'passed') continue;
    const ms = typeof r.durationMs === 'number' ? r.durationMs : (r.attempts ?? []).reduce((t, a) => t + (a.durationMs ?? 0), 0);
    if (!(ms > 0)) continue;
    const title = (r.titlePath ?? []).join(' › ');
    per.set(title, [...(per.get(title) ?? []), ms]);
  }
  return new Map([...per].map(([t, xs]) => [t, median(xs)]));
}

const runs = (existsSync(runsRoot) ? readdirSync(runsRoot) : [])
  .filter((l) => /^regression-/.test(l) && existsSync(join(runsRoot, l, 'report.json')))
  .map((l) => ({ l, t: statSync(join(runsRoot, l, 'report.json')).mtimeMs }))
  .sort((x, y) => x.t - y.t || (x.l < y.l ? -1 : 1))
  .map((x) => x.l);

let changed = false;
for (const l of runs) {
  if (state.runs.includes(l)) continue;
  let d;
  try { d = durations(l); } catch (e) { console.error(`perf-trend: skipping ${l}: ${e.message}`); continue; }
  for (const [title, ms] of d) {
    const t = (state.tests[title] ??= { samples: [] });
    t.samples = [...t.samples, { run: l, ms }].slice(-(K + 1));
  }
  state.runs = [...state.runs, l].slice(-500);
  changed = true;
}

const latest = label ?? runs.at(-1) ?? null;
const slow = [];
let judged = 0;
for (const [title, t] of Object.entries(state.tests)) {
  const i = t.samples.findIndex((x) => x.run === latest);
  const before = t.samples.slice(0, i < 0 ? t.samples.length : i).slice(-K).map((x) => x.ms);
  t.median_ms = median(before.length ? before : t.samples.map((x) => x.ms));
  if (i < 0) continue;
  judged++;
  if (before.length < MIN_HISTORY) continue;
  const m = median(before);
  const ms = t.samples[i].ms;
  if (ms > m * FACTOR && ms - m >= FLOOR_MS) {
    slow.push({ title, latest_ms: ms, median_ms: m, runs: before.length,
      explanation: `took ${ms} ms on ${latest}, ${(ms / m).toFixed(1)}× its median of ${m} ms over the ${before.length} runs before` });
  }
}
slow.sort((x, y) => (x.title < y.title ? -1 : 1));

if (changed || !existsSync(file)) {
  mkdirSync(dir, { recursive: true });
  state.updated_utc = now();
  writeFileSync(`${file}.tmp`, `${JSON.stringify(state, null, 2)}\n`);
  renameSync(`${file}.tmp`, file);
}
console.log(JSON.stringify({ latest, tests: judged, perf_factor: FACTOR, slow_tests: slow }, null, 2));
