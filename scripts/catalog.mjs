#!/usr/bin/env node
// catalog.mjs — the test catalog: every criterion, exploration and scenario test of
// work/suite as one self-contained, browsable HTML page (docs/catalog.md). Reads work/ and,
// once, the target's labelled issues (GET, for labels and state); writes work/catalog/ only.
//
//   node catalog.mjs   -> {"html", "bytes", "items", "images", "dropped_images", "thumbnails",
//                          "notes", "hash", "changed"}
//
// `notes` names every source that could not be read (the issues listing, the drift check, the
// coverage of the UI map): the page is still built, without what that source gives. A credential
// value or a token in the data -> exit 1, {"refused", "notes", "hash", "changed": false}, no page.
//
// Test-related content only — the page may be shared: never a scenario's request text, its
// requester or thread, a verdict's notes, a triage explanation, LESSONS.md, the operator
// conversation, a security finding, or anything of work/env/. `hash` covers the data without its
// generation time; `changed` = it differs from work/catalog/published.hash, which the agent
// writes after a publish. Stills and page shots are cached as small JPEGs in
// work/catalog/thumbs/ (rendered by the suite's own playwright-core; none without it).
// `runs` lists every night, issue run and scenario run with its build, verdicts and report
// reference — the page is the way into all of them; `pages[].hotspots` are the controls of the
// newest UI map with the items that name them (the product map). `modules`, `design` and
// `findings` make it the control center (docs/modules.md): the modules' state, the design
// findings with their crops, the newest validation and stress results — of the security run its
// counts and report reference only.

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { controlRe, esc, matchable, pageRe } from './lib/match.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const runsRoot = process.env.QI_RUNS_ROOT ?? join(work, 'suite', '.e2e', 'runs');
const outDir = join(work, 'catalog');
const thumbsDir = join(outDir, 'thumbs');
const IMG_BUDGET = Number(process.env.QI_CATALOG_IMG_BUDGET ?? 6 * 1024 * 1024); // base64 bytes
const PAGE_MAX = 9 * 1024 * 1024; // the platform renders a page up to 10 MiB; images give way first
const notes = [];
const THUMB_W = 360;
const MAP_W = 720; // a page shot of the product map: wide enough to click a control on it
const HISTORY_MAX = 30; // newest history entries per item: the page stays a few MB at a year of nights
const RUNS_MAX = 400; // newest runs of the Runs view
const HOTSPOTS_MAX = 120; // controls per page of the product map
const DESIGN_CROPS_MAX = 80; // design findings' crops embedded, open and major first

const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
const readJson = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } };
const ls = (p) => { try { return readdirSync(p); } catch { return []; } };
const mtime = (p) => { try { return statSync(p).mtimeMs; } catch { return 0; } };
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const rows = (p) => (read(p) ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2)
  .map((l) => l.split('|').slice(1, -1).map((c) => c.trim()));
const cfg = (k) => {
  const m = (read(join(work, 'CONFIG.md')) ?? '').match(new RegExp(`^- ${k.replace('.', '\\.')}:[ \\t]*(.*)$`, 'm'));
  return m ? m[1].replace(/\s+#.*$/, '').trim().replace(/^[`"']|[`"']$/g, '') : '';
};

// ------------------------------------------------------------------ state tables
const suite = new Map(rows(join(work, 'SUITE.md')).map(([test, owner, tier, hash, promoted]) =>
  [test, { owner, tier, hash, promoted: promoted && promoted !== '-' ? promoted : null }]));
const qa = new Map(rows(join(work, 'QA.md')).map(([n, acHash]) => [n, { acHash }]));
const scen = new Map(rows(join(work, 'SCENARIOS.md')).map(([id, source, , , specHash]) => [id, { source, specHash }]));
// A scenario's test key: S-7 -> scenario-7, a profile scenario P-sign-in -> profile-sign-in.
const scenKey = (id) => (String(id).startsWith('P-') ? `profile-${String(id).slice(2)}` : `scenario-${String(id).replace(/^S-/i, '')}`);
const heals = rows(join(work, 'HEALS.md')).map(([utc, test, ac, build, , , basis]) => ({ utc, test, ac, build, basis }));
const flaky = rows(join(work, 'FLAKY.md')).map(([utc, test, ac, build, runs, passes]) => ({ utc, test, ac, build, runs: +runs || null, passes: +passes || 0 }));
const collections = rows(join(work, 'CATALOG.md')).map(([name, members]) =>
  ({ name, members: String(members ?? '').split(',').map((s) => s.trim()).filter(Boolean) })).filter((c) => c.name);
let drift = [];
try {
  drift = JSON.parse(execFileSync('bash', [join(HERE, 'check-asserts.sh'), '--json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] })).drift ?? [];
} catch { notes.push('drift not measured (check-asserts.sh --json failed)'); }
const drifted = (file) => drift.some((d) => String(d.test ?? d.file ?? d).endsWith(file));

// --------------------------------------------------------------------- criteria
// `# #42 — <title>` / `# S-7 — <title>`, then `## AC-1 — <name>` (or `## EX-1 (from AC-1, …)`)
// sections with Given/When/Then (Expected) lines, surface and testable.
function parseCriteria(text) {
  if (!text) return null;
  const title = (text.match(/^# (?:#\d+|S-\d+|P-[a-z0-9][a-z0-9-]*) — (.*?)(?:\s{2,}\S+:.*)?$/m) ?? [])[1] ?? null;
  const acs = [];
  for (const sec of text.split(/^## /m).slice(1)) {
    const head = sec.split('\n')[0];
    const id = (head.match(/^((?:AC|EX)-\d+)/) ?? [])[1];
    if (!id) continue;
    const line = (k) => ((sec.match(new RegExp(`^${k}[: ]\\s*(.*)$`, 'm')) ?? [])[1] ?? null);
    const testable = line('testable');
    acs.push({
      id, name: (head.match(/ — (.*)$/) ?? [])[1] ?? null,
      given: line('Given'), when: line('When'), then: line('Then') ?? line('Expected'),
      surface: line('surface'), testable: testable == null ? true : /^yes/.test(testable),
    });
  }
  return { title, acs };
}

// ------------------------------------------------------------------- test files
const STR = String.raw`(['"\x60])((?:\\.|(?!\1)[\s\S])*?)\1`;
const STEP = new RegExp(String.raw`\b(app\.open|agent\.act|agent\.assert|app\.screenshot)\(\s*(['"\x60])((?:\\.|(?!\2)[\s\S])*?)\2`, 'g');
const STEP_KIND = { 'app.open': 'open', 'agent.act': 'act', 'agent.assert': 'assert', 'app.screenshot': 'shot' };
const unjs = (s) => s.replace(/\$\{\s*(\w+)\s*\}/g, '{$1}').replace(/\\(.)/g, '$1');

function parseTestFile(src) {
  const first = src.search(/^\s*test\(/m);
  const head = first >= 0 ? src.slice(0, first) : src;
  const summary = (head.match(/@qi-summary\s+(.+?)(?=\s*(?:@qi-|\*\/|\n|$))/) ?? [])[1]?.trim() ?? null;
  const area = (head.match(/@qi-area\s+([\w-]+)/) ?? [])[1] ?? null;
  const starts = [...src.matchAll(/^\s*test\(\s*/gm)].map((m) => m.index);
  const tests = starts.map((s, i) => {
    const body = src.slice(s, starts[i + 1] ?? src.length);
    const title = unjs((body.match(new RegExp(String.raw`^\s*test\(\s*` + STR)) ?? [])[2] ?? '');
    const id = (title.match(/\b((?:AC|EX)-\d+)\b/) ?? [])[1] ?? null;
    const session = (body.match(/session:\s*['"]([\w-]+)['"]/) ?? [])[1] ?? 'owner';
    const tags = [...((body.match(/tags:\s*\[([^\]]*)\]/) ?? [])[1] ?? '').matchAll(/['"]([^'"]+)['"]/g)].map((m) => m[1]);
    const steps = [];
    for (const m of body.matchAll(STEP)) steps.push({ kind: STEP_KIND[m[1]], text: unjs(m[3]).slice(0, 240), at: m.index });
    const block = id ? body.match(new RegExp(String.raw`//\s*${id} begin([\s\S]*?)//\s*${id} end`)) : null;
    const inBlock = block?.[1] ?? '';
    for (const m of inBlock.matchAll(/expect\(([\s\S]*?)\)\s*\.\s*(not\.)?(to\w+)\(([^;]*?)\)\s*;/g)) {
      steps.push({ kind: 'expect', text: `${m[1].replace(/\s+/g, ' ').trim()} ${m[2] ?? ''}${m[3]}(${m[4].replace(/\s+/g, ' ').trim()})`.slice(0, 240), at: body.indexOf(m[0]) });
    }
    steps.sort((a, b) => a.at - b.at);
    return {
      title, id, session, tags,
      steps: steps.map(({ kind, text }) => ({ kind, text })),
      checks: { expects: (inBlock.match(/\bexpect\(/g) ?? []).length, agent_asserts: (body.match(/\bagent\.assert\(/g) ?? []).length },
      pages: [...new Set(steps.filter((x) => x.kind === 'open' && x.text.startsWith('/')).map((x) => x.text.replace(/\?.*$/, '')))],
      body,
    };
  });
  return { summary, area, tests };
}

// --------------------------------------------------------------------- verdicts
const history = new Map(); // item key -> [{build, run, value, utc}]
const addHist = (key, h) => { if (!h.value) return; (history.get(key) ?? history.set(key, []).get(key)).push(h); };
const stillRuns = new Map(); // item key -> [{label, utc}] candidate runs, newest last
const evidence = new Map(); // origin key -> artifact reference
const titles = new Map(); // origin key -> title from a verdicts file
const runs = []; // every run: nights, issue runs, scenario runs (the Runs view)
// artifact.id holds the platform's reference; a link when it is one.
const artRef = (dir) => { const a = read(join(dir, 'artifact.id'))?.trim(); return a ? (/^https:\/\/\S+$/.test(a) ? a : `platform://artifacts/${a}`) : null; };

const WORST = ['regression', 'failed', 'needs-review', 'flaky', 'inconclusive', 'partial', 'blocked', 'not-testable', 'passed', 'verified'];
const rank = (v) => (WORST.includes(v) ? WORST.indexOf(v) : WORST.length);
function readVerdicts(dir, okey, run, ref) {
  for (const f of ls(dir).filter((x) => /^verdicts-.*\.json$/.test(x))) {
    const v = readJson(join(dir, f));
    if (!v) continue;
    const utc = v.generated_utc ?? new Date(mtime(join(dir, f))).toISOString().replace(/\.\d+Z$/, 'Z');
    const build = v.candidate ?? v.build ?? null;
    if (v.title) titles.set(okey, v.title);
    // A scenario's file has no top verdict: its worst criterion stands for the run.
    const worst = (v.acs ?? []).map((e) => e?.verdict).filter(Boolean).sort((a, b) => rank(a) - rank(b))[0] ?? null;
    runs.push({ type: run, ref, build, baseline: v.baseline ?? null, utc, verdict: v.verdict ?? worst, report: artRef(dir),
      entries: [...(v.acs ?? []), ...(v.explorations ?? [])].filter((e) => e?.id && e.verdict).map((e) => ({ key: `${okey}/${e.id}`, value: e.verdict })) });
    for (const ac of v.acs ?? []) {
      const key = `${okey}/${ac.id}`;
      addHist(key, { build, run, value: ac.verdict, utc });
      if (v.candidate_run) (stillRuns.get(key) ?? stillRuns.set(key, []).get(key)).push({ label: v.candidate_run, utc });
    }
    for (const ex of v.explorations ?? []) {
      const key = `${okey}/${ex.id}`;
      addHist(key, { build, run: 'exploration', value: ex.verdict, utc });
      if (v.explorations_run) (stillRuns.get(key) ?? stillRuns.set(key, []).get(key)).push({ label: v.explorations_run, utc });
    }
  }
  if (artRef(dir)) evidence.set(okey, artRef(dir));
}
for (const n of ls(join(work, 'issues')).filter((x) => /^\d+$/.test(x))) readVerdicts(join(work, 'issues', n), `issue-${n}`, 'issue', `#${n}`);
for (const s of ls(join(work, 'scenarios')).filter((x) => /^(S-\d+|P-[a-z0-9][a-z0-9-]*)$/.test(x))) readVerdicts(join(work, 'scenarios', s), scenKey(s), 'scenario', s);

// Nightly runs: REGRESSION.log `ran candidate=` lines, and per run the criteria that were not
// unchanged (work/regression/<candidate>/verdicts.json); every other regression-tier item of
// that night counts as unchanged. A night whose environment failed is a run without results.
const nights = [];
const nightOutcomes = new Map(); // build -> Map(item key -> value)
const nightFile = new Map(); // build -> its verdicts.json
for (const c of ls(join(work, 'regression'))) {
  const v = readJson(join(work, 'regression', c, 'verdicts.json'));
  if (!v) continue;
  nightFile.set(c, v);
  const per = new Map();
  for (const e of v.acs ?? v.entries ?? []) {
    const okey = e.scenario ? scenKey(e.scenario) : `issue-${e.issue}`;
    per.set(`${okey}/${e.id}`, e.verdict);
  }
  nightOutcomes.set(c, per);
}
const TOP = ['regression', 'needs-review', 'healed', 'relearned'];
for (const line of (read(join(work, 'REGRESSION.log')) ?? '').split('\n')) {
  const env = line.match(/^(\S+) ERROR: environment candidate=(\S+)/);
  if (env) { runs.push({ type: 'regression', ref: null, build: env[2], utc: env[1], verdict: 'environment', report: null, entries: [] }); continue; }
  const m = line.match(/^(\S+) ran candidate=(\S+)(.*)$/);
  if (!m) continue;
  const counts = {};
  for (const [, k, v] of m[3].matchAll(/(\w[\w-]*)=(\d+)/g)) counts[k.replace(/_/g, '-')] = +v;
  nights.push({ build: m[2], utc: m[1], counts });
  // What the night's report says beside its entries: the change context's issues, the UI diff's
  // text and the signals' counts — never an entry's explanation.
  const v = nightFile.get(m[2]);
  const ctx = v?.context ?? {};
  const signals = Object.fromEntries(Object.entries(ctx.signals ?? {}).map(([k, x]) => [k, Array.isArray(x) ? x.length : +x || 0]));
  runs.push({ type: 'regression', ref: null, build: m[2], utc: m[1], counts,
    verdict: v?.verdict ?? TOP.find((k) => counts[k] > 0) ?? 'unchanged',
    previous: ctx.previous ?? nights.at(-2)?.build ?? null, window: ctx.window ?? null,
    issues: (ctx.issues ?? []).filter((x) => x?.number != null).slice(0, 60).map((x) => ({ number: x.number, title: x.title ?? null })),
    ui_diff: typeof ctx.ui_diff === 'string' ? ctx.ui_diff.slice(0, 4000) : null, signals,
    report: artRef(join(work, 'regression', m[2])),
    entries: [...(nightOutcomes.get(m[2]) ?? new Map())].map(([key, value]) => ({ key, value })) });
}
runs.sort((a, b) => String(b.utc).localeCompare(String(a.utc)));
runs.splice(RUNS_MAX);

// ------------------------------------------------------------------------ issues
// One paginated GET of the labelled issues for labels, state and title (best effort).
const issueMeta = new Map();
const target = process.env.QI_TARGET_REPO ?? cfg('target_repo');
if (target && process.env.QI_CATALOG_OFFLINE !== '1') {
  const host = target.split('/').length === 3 ? target.split('/')[0] : null;
  const repo = host ? target.split('/').slice(1).join('/') : target;
  try {
    const out = execFileSync('gh', ['api', ...(host ? ['--hostname', host] : []), '--paginate', '-X', 'GET', `repos/${repo}/issues`,
      '-f', `labels=${cfg('qa_label') || 'qa:ready'}`, '-f', 'state=all', '-f', 'per_page=100',
      '--jq', '.[] | {number, title, state, labels: [.labels[]? | .name? // .]} | tojson'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 60000 });
    for (const line of out.split('\n').filter(Boolean)) {
      let x; try { x = JSON.parse(line); } catch { continue; }
      for (const i of [x].flat()) {
        if (i?.number != null) issueMeta.set(String(i.number), { title: i.title ?? null, labels: (i.labels ?? []).map((l) => l?.name ?? l), state: i.state ?? null });
      }
    }
  } catch { notes.push('issue labels and state unavailable (the issues listing failed)'); }
}

// ------------------------------------------------------------------------- items
const perf = readJson(join(work, 'perf', 'trend.json'))?.tests ?? {};
const items = [];
const testFiles = ls(join(work, 'suite', 'tests')).filter((f) => /^((issue|scenario)-\d+|profile-[a-z0-9][a-z0-9-]*)\.e2e\.ts$/.test(f)).sort((a, b) =>
  a.localeCompare(b, 'en', { numeric: true }));
const origins = new Set([...testFiles.map((f) => f.replace(/\.e2e\.ts$/, '')),
  ...[...qa.keys()].map((n) => `issue-${n}`), ...[...scen.keys()].map(scenKey)]);

for (const okey of [...origins].sort((a, b) => a.localeCompare(b, 'en', { numeric: true }))) {
  const kind = okey.slice(0, okey.indexOf('-')), num = okey.slice(okey.indexOf('-') + 1);
  const isIssue = kind === 'issue';
  const file = `tests/${okey}.e2e.ts`;
  const row = suite.get(file);
  const ref = isIssue ? `#${num}` : kind === 'profile' ? `P-${num}` : `S-${num}`;
  const crit = isIssue
    ? parseCriteria(read(join(work, 'issues', num, `criteria-${qa.get(num)?.acHash}.md`)))
    : parseCriteria(read(join(work, 'scenarios', ref, `criteria-${scen.get(ref)?.specHash}.md`)));
  const exps = isIssue ? parseCriteria(read(join(work, 'issues', num, `explorations-${qa.get(num)?.acHash}.md`))) : null;
  const src = read(join(work, 'suite', file));
  const parsed = src ? parseTestFile(src) : { summary: null, area: null, tests: [] };
  const meta = isIssue ? issueMeta.get(num) : null;
  const origin = isIssue
    ? { kind: 'issue', ref, number: +num, title: meta?.title ?? titles.get(okey) ?? crit?.title ?? null, labels: meta?.labels ?? null, state: meta?.state ?? null }
    : { kind: 'scenario', ref, title: crit?.title ?? titles.get(okey) ?? null, source: scen.get(ref)?.source ?? null };
  const ids = [...new Set([...(crit?.acs ?? []).map((a) => a.id), ...(exps?.acs ?? []).map((a) => a.id),
    ...parsed.tests.map((t) => t.id).filter(Boolean)])];
  for (const id of ids) {
    const c = [...(crit?.acs ?? []), ...(exps?.acs ?? [])].find((a) => a.id === id) ?? {};
    const t = parsed.tests.find((x) => x.id === id);
    const key = `${okey}/${id}`;
    const ex = id.startsWith('EX');
    const hist = (history.get(key) ?? []).slice();
    if (row?.tier === 'regression' && !ex && t) {
      // A drifted file is not run (regression.md step 4), and only a heal or a new promotion
      // ends the drift: while it is drifted, the trailing nights that skipped a drift show `drift`.
      const since = nights.filter((n) => !row.promoted || n.utc >= row.promoted);
      let skipped = since.length;
      if (drifted(file)) while (skipped > 0 && since[skipped - 1].counts.drift > 0) skipped--;
      since.forEach((n, j) => hist.push({ build: n.build, run: 'regression',
        value: nightOutcomes.get(n.build)?.get(key) ?? (j >= skipped ? 'drift' : 'unchanged'), utc: n.utc }));
    }
    hist.sort((a, b) => String(a.utc).localeCompare(String(b.utc)));
    hist.splice(0, Math.max(0, hist.length - HISTORY_MAX));
    const perfKey = t ? Object.keys(perf).find((k) => k === t.title || k.endsWith(` › ${t.title}`)) : null;
    items.push({
      key, file: t ? file : null, origin, id,
      kind: ex ? 'exploration' : 'criterion',
      name: c.name ?? t?.title?.replace(/^.*?(?:AC|EX)-\d+:\s*/, '') ?? null,
      given: c.given ?? null, when: c.when ?? null, then: c.then ?? null,
      surface: c.surface ?? null, testable: c.testable ?? true,
      tier: !t ? 'untracked' : ex ? 'exploratory' : (row?.tier ?? 'untracked'), // explorations are never promoted
      promoted_utc: t && !ex ? row?.promoted ?? null : null, drift: t && !ex ? drifted(file) : false,
      area: parsed.area ?? (t?.pages[0]?.split('/')[1] || null),
      summary: parsed.summary, session: t?.session ?? null, pages: t?.pages ?? [],
      steps: t?.steps ?? [], checks: t?.checks ?? null,
      verdict: hist.at(-1) ?? null, history: hist,
      heals: heals.filter((h) => h.test === file && h.ac === id).map(({ utc, build, basis }) => ({ utc, build, basis })),
      flaky: flaky.filter((f) => f.test === file && f.ac === id).map(({ utc, build, runs, passes }) => ({ utc, build, runs, passes })),
      duration_ms: perfKey ? (perf[perfKey].samples ?? []).map((s) => s.ms).filter(Number.isFinite) : [],
      still: null, evidence: evidence.get(okey) ?? null, _body: t?.body ?? null,
    });
  }
}

// --------------------------------------------------------------------- coverage
const maps = ls(join(work, 'inventory')).filter((b) => existsSync(join(work, 'inventory', b, 'inventory.json')))
  .sort((a, b) => mtime(join(work, 'inventory', a, 'inventory.json')) - mtime(join(work, 'inventory', b, 'inventory.json')));
const newestMap = maps.at(-1) ? join(work, 'inventory', maps.at(-1)) : null;
let pages = [];
let uncoveredNav = [];
if (newestMap) {
  try {
    const cov = JSON.parse(execFileSync(process.execPath, [join(HERE, 'coverage.mjs'), join(newestMap, 'inventory.json'), join(work, 'SUITE.md'),
      ...testFiles.map((f) => join(work, 'suite', 'tests', f))], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }));
    const inv = readJson(join(newestMap, 'inventory.json'));
    const rootNav = Object.entries(inv?.routes?.['/']?.navigates ?? {});
    const noGolden = new Set((cov.nav_without_golden_path ?? []).map((n) => n.target));
    uncoveredNav = (cov.nav_without_golden_path ?? []).map((n) => n.item);
    // A control's label shown on one page only names that page; shared chrome needs the page opened.
    const onPages = new Map();
    for (const [pat, r] of Object.entries(inv?.routes ?? {})) for (const b of r?.boxes ?? []) {
      const k = String(b[1]).toLowerCase(); onPages.set(k, (onPages.get(k) ?? new Set()).add(pat));
    }
    // A navigation item stands for the page it leads to: the items that reach that page.
    const routes = Object.entries(inv?.routes ?? {});
    const routeOf = (path) => path && routes.map(([pat]) => pat)
      .find((pat) => new RegExp(`^${pat.split('/').map((x) => (x === ':id' ? '[^/]+' : esc(x))).join('/')}/?$`).test(path));
    const navTarget = (name) => routes.map(([, r]) => r?.navigates?.[name]).find(Boolean)
      ?? routeOf(routes.flatMap(([, r]) => r?.links ?? []).map((l) => String(l).split(' → ')).find(([n]) => n === name)?.[1]);
    const reach = (files) => items.filter((i) => i.file && files.some((f) => f === i.file || f.endsWith(`/${i.file}`))).map((i) => i.key);
    const reachOf = new Map((cov.pages ?? []).map((p) => [p.pattern, reach((p.tests ?? []).map((x) => x.test))]));
    const hotspots = (pat) => {
      const r = inv?.routes?.[pat]; const [vw, vh] = Array.isArray(r?.viewport) ? r.viewport : [0, 0];
      if (!(vw > 0 && vh > 0)) return [];
      const opens = pageRe(pat);
      const f = (n) => Math.round(n * 10000) / 10000;
      return (r.boxes ?? []).filter((b) => Array.isArray(b) && matchable(String(b[1]))).slice(0, HOTSPOTS_MAX).map(([kind, name, x, y, w, h]) => {
        const box = [f(x / vw), f(y / vh), f(w / vw), f(h / vh)];
        const to = kind === 'nav' ? navTarget(name) : null;
        if (to) return { kind, name, box, to, items: reachOf.get(to) ?? [] };
        const re = controlRe(String(name), { quoted: true });
        const only = onPages.get(String(name).toLowerCase())?.size === 1;
        return { kind, name, box, items: items.filter((i) => i._body && re.test(i._body) && (only || opens.test(i._body))).map((i) => i.key) };
      });
    };
    pages = (cov.pages ?? []).map((p) => {
      const files = (p.tests ?? []).map((x) => x.test);
      const seg = p.pattern.split('/')[1] ?? '';
      const nav = rootNav.find(([, to]) => to === p.pattern || (seg && to.split('/')[1] === seg))?.[0] ?? (seg || 'home');
      return {
        pattern: p.pattern, title: p.title ?? null, nav,
        covered: p.covered ? 'regression' : files.length ? 'exploratory' : 'none',
        items: reachOf.get(p.pattern) ?? [],
        shot: null, golden_path: !noGolden.has(p.pattern), _shot: inv?.routes?.[p.pattern]?.shot ?? null,
        viewport: inv?.routes?.[p.pattern]?.viewport ?? null, hotspots: hotspots(p.pattern),
      };
    });
  } catch { notes.push(`coverage unavailable (coverage.mjs failed on ${maps.at(-1)})`); }
}

// ------------------------------------------------------------- control center
// The testing modules (docs/modules.md): their state from modules.sh status, the design findings
// register (docs/ui-sweep.md), the newest validation and stress results, and of the security run
// only its counts and its private report's reference — never a finding (docs/security.md).
let modules = null;
try {
  modules = JSON.parse(execFileSync('bash', [join(HERE, 'modules.sh'), 'status'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }));
  delete modules.generated_utc; // the hash covers state, not the time it was read
} catch { notes.push('module state unavailable (modules.sh status failed)'); }
const newestOf = (dir, file) => ls(join(work, dir)).map((b) => join(work, dir, b, file)).filter(existsSync)
  .sort((a, b) => mtime(a) - mtime(b)).at(-1) ?? null;
const DESIGN_KEYS = ['id', 'source', 'check', 'severity', 'suspect', 'pattern', 'viewport', 'target', 'saw', 'first_seen', 'last_seen', 'status', 'resolved_build'];
const design = (readJson(join(work, 'design', 'findings.json'))?.findings ?? []).filter((f) => f && /^D-\d+$/.test(String(f.id)))
  .map((f) => ({ ...Object.fromEntries(DESIGN_KEYS.map((k) => [k, f[k] ?? null])), crop: null, _crop: join(work, 'design', 'crops', `${f.id}.jpg`) }));
const valFile = newestOf('validation', 'results.json');
const val = valFile ? readJson(valFile) : null;
const stressFile = newestOf('stress', 'stress.json');
const stress = stressFile ? readJson(stressFile) : null;
const secFile = newestOf('security', 'verdicts.json');
const sec = secFile ? readJson(secFile) : null;
// The feature focus runs (docs/modules.md → Feature focus): the newest five, each check's verdict —
// never its note.
const focus = ls(join(work, 'focus')).map((d) => ({ d, f: join(work, 'focus', d, 'results.json') })).filter((x) => existsSync(x.f))
  .sort((a, b) => mtime(b.f) - mtime(a.f)).slice(0, 5).map(({ d, f }) => {
    const r = readJson(f) ?? {};
    return { run: d, area: r.area ?? null, build: r.build ?? r.candidate ?? null, utc: r.generated_utc ?? null,
      checks: (Array.isArray(r) ? r : r.checks ?? r.explorations ?? []).filter((c) => c && c.id).map((c) => ({ id: c.id, heuristic: c.heuristic ?? null,
        given: c.given ?? null, when: c.when ?? null, expected: c.expected ?? null, verdict: c.verdict ?? null, severity: c.severity ?? null })) };
  });
// Scenario requests still on their way (docs/scenarios.md): id, source, state and the frozen
// title once there is one — never the request text, its requester or thread.
const requests = rows(join(work, 'SCENARIOS.md')).filter(([id, , , , , , , status]) => /^S-\d+$/.test(id) && ['queued', 'in_progress', 'report_pending', 'rejected'].includes(status))
  .map(([id, source, , , specHash, build, verdict, status, utc]) => ({ id, source, status, build: build && build !== '-' ? build : null,
    verdict: verdict && verdict !== '-' ? verdict : null, utc: utc || null,
    title: parseCriteria(read(join(work, 'scenarios', id, `criteria-${specHash}.md`)) ?? '')?.title ?? null }))
  .sort((a, b) => String(b.utc).localeCompare(String(a.utc))).slice(0, 50);
const sweepFile = newestOf('design', 'sweep.json');
const findings = {
  requests,
  focus,
  design_build: sweepFile ? readJson(sweepFile)?.build ?? null : null,
  validation: val ? { build: val.build ?? null, run: val.run ?? null, utc: val.generated_utc ?? null,
    cases: (val.cases ?? []).map((c) => ({ id: c.id, page: c.page, form: c.form, field: c.field ?? null, kind: c.kind, oracle: c.oracle,
      result: c.result, severity: c.severity ?? null, message: c.message ?? null })) } : null,
  stress: stress ? { build: stress.build ?? null, utc: stress.generated_utc ?? null, config: stress.config ?? null, counts: stress.counts ?? null,
    checks: (stress.checks ?? []).map((c) => ({ id: c.id, target: c.target, status: c.status, severity: c.severity, evidence: c.evidence ?? null, reason: c.reason ?? null })) } : null,
  security: sec ? { candidate: sec.candidate ?? null, utc: sec.generated_utc ?? null, counts: sec.counts ?? null, report: artRef(dirname(secFile)) } : null,
};
const areas = [...new Set([...items.map((i) => i.area).filter(Boolean), ...pages.map((p) => p.nav).filter(Boolean)].map(String))]
  .filter((a) => /^[A-Za-z0-9][A-Za-z0-9 _./-]{0,39}$/.test(a)).sort();

// ---------------------------------------------------------------------- stills
// The AC still: the `app.screenshot('<id>: …')` of the item's newest candidate run.
function stillSource(item) {
  const [okey] = item.key.split('/');
  const tag = item.kind === 'exploration' ? `${okey}-ex` : okey;
  for (const { label } of (stillRuns.get(item.key) ?? []).slice().reverse()) {
    const report = readJson(join(runsRoot, label, 'report.json'));
    const res = (report?.run?.results ?? []).find((r) => (r.tags ?? []).includes(tag) && (r.tags ?? []).includes(item.id.toLowerCase()));
    const att = res?.attempts?.at(-1);
    if (!att) continue;
    const step = (att.steps ?? []).find((s) => s.api === 'app.screenshot' && String(s.label ?? '').startsWith(`${item.id}:`));
    const art = (att.artifacts ?? []).find((a) => step?.artifacts?.includes(a.id) && a.kind === 'screenshot' && a.path);
    if (!art) continue;
    const src = [join(runsRoot, label, 'artifacts'), join(runsRoot, label, 'results'), join(runsRoot, label)].map((r) => join(r, art.path)).find(existsSync);
    if (src) return src;
  }
  return null;
}

const jobs = [];
const thumbOf = (name) => join(thumbsDir, `${slug(name)}.jpg`);
for (const item of items) {
  const dst = thumbOf(item.key);
  const src = stillSource(item);
  if (src && mtime(src) > mtime(dst)) jobs.push({ src, dst, w: THUMB_W });
  item._thumb = dst;
}
for (const p of pages) {
  const dst = thumbOf(`map-${p.pattern}`);
  const src = p._shot ? join(newestMap, p._shot) : null;
  if (src && existsSync(src) && mtime(src) > mtime(dst)) jobs.push({ src, dst, w: MAP_W });
  p._thumb = dst;
}

// A browser draws each image onto a canvas `w` wide (tall shots cropped) and returns a JPEG.
async function renderThumbs(list) {
  if (!list.length) return 'none due';
  let pw;
  try {
    const req = createRequire(join(work, 'suite', 'package.json'));
    pw = await import(pathToFileURL(req.resolve('playwright-core')).href);
  } catch { return 'unavailable: playwright-core is not installed in work/suite'; }
  let browser;
  try {
    browser = await (pw.chromium ?? pw.default.chromium).launch();
    const page = await browser.newPage();
    await page.route('**', (r) => r.abort());
    mkdirSync(thumbsDir, { recursive: true });
    let n = 0;
    for (const { src, dst, w } of list) {
      const mime = src.endsWith('.png') ? 'image/png' : 'image/jpeg';
      const data = `data:${mime};base64,${readFileSync(src).toString('base64')}`;
      const out = await page.evaluate(async ({ data, w }) => {
        const img = new Image(); img.src = data; await img.decode();
        const s = Math.min(1, w / img.naturalWidth);
        const c = document.createElement('canvas');
        c.width = Math.round(img.naturalWidth * s); c.height = Math.round(Math.min(img.naturalHeight * s, w * 1.25));
        const g = c.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, c.width, c.height);
        g.drawImage(img, 0, 0, img.naturalWidth * s, img.naturalHeight * s);
        return c.toDataURL('image/jpeg', 0.62);
      }, { data, w }).catch(() => null);
      if (!out) continue;
      writeFileSync(`${dst}.tmp`, Buffer.from(out.split(',')[1], 'base64')); renameSync(`${dst}.tmp`, dst); n++;
    }
    return `${n} rendered`;
  } catch (e) { return `unavailable: ${String(e.message).split('\n')[0].slice(0, 120)}`; }
  finally { await browser?.close().catch(() => {}); }
}
const thumbnails = await renderThumbs(jobs);

// Thumbnails of items and pages that no longer exist are a stale cache: removed one by one.
const wanted = new Set([...items, ...pages].map((x) => x._thumb));
for (const f of ls(thumbsDir).filter((x) => x.endsWith('.jpg'))) if (!wanted.has(join(thumbsDir, f))) { try { rmSync(join(thumbsDir, f)); } catch { /* next run */ } }

// Embed within the budget — what the data leaves of PAGE_MAX, at most IMG_BUDGET: regression
// items' stills first, then the product map's page shots (pages tests reach first), then the
// other stills by tier, newest verdict first. A page without its shot still shows its controls.
const images = {};
let used = 0; let dropped = 0; let seq = 0;
const base = Buffer.byteLength(JSON.stringify({ items, pages, nights, runs, modules, design, findings }, (k, v) => (k.startsWith('_') ? undefined : v)))
  + Buffer.byteLength(read(join(HERE, 'catalog', 'viewer.html')) ?? '');
const budget = Math.max(0, Math.min(IMG_BUDGET, PAGE_MAX - base));
if (budget < IMG_BUDGET) notes.push(`image budget cut to ${Math.round(budget / 1024)} KiB by the size of the data`);
const embed = (path) => {
  if (!existsSync(path)) return null;
  const uri = `data:image/jpeg;base64,${readFileSync(path).toString('base64')}`;
  if (used + uri.length > budget) { dropped++; return null; }
  used += uri.length; const id = `i${seq++}`; images[id] = uri; return id;
};
const RANK = { regression: 0, promotable: 1, exploratory: 2 };
const byRank = items.slice().sort((a, b) => (RANK[a.tier] ?? 3) - (RANK[b.tier] ?? 3)
  || String(b.verdict?.utc ?? '').localeCompare(String(a.verdict?.utc ?? '')));
for (const item of byRank.filter((i) => i.tier === 'regression')) item.still = embed(item._thumb);
const DSEV = { major: 0, minor: 1 };
for (const f of design.slice().sort((a, b) => (a.status === 'open' ? 0 : 1) - (b.status === 'open' ? 0 : 1) || (DSEV[a.severity] ?? 2) - (DSEV[b.severity] ?? 2)
  || String(b.last_seen ?? '').localeCompare(String(a.last_seen ?? ''))).slice(0, DESIGN_CROPS_MAX)) f.crop = embed(f._crop);
const COV = { regression: 0, exploratory: 1 };
for (const p of pages.slice().sort((a, b) => (COV[a.covered] ?? 2) - (COV[b.covered] ?? 2))) p.shot = embed(p._thumb);
for (const item of byRank.filter((i) => i.tier !== 'regression')) item.still = embed(item._thumb);
for (const x of [...items, ...pages, ...design]) { delete x._thumb; delete x._shot; delete x._body; delete x._crop; }

// ------------------------------------------------------------------------ output
const builds = [...new Map([...items.flatMap((i) => i.history), ...nights].filter((h) => h.build)
  .sort((a, b) => String(a.utc).localeCompare(String(b.utc))).map((h) => [h.build, { id: h.build, utc: h.utc }])).values()];
const product = (() => { try {
  const dir = execFileSync('bash', ['-c', '. "$1"; CONFIG="$2"; . "$3"; profile_dir', '_',
    join(HERE, 'lib', 'config.sh'), join(work, 'CONFIG.md'), join(HERE, 'lib', 'profile.sh')],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  return readJson(join(dir, 'profile.json'))?.product ?? null;
} catch { return null; } })();
const host = target.split('/').length === 3 ? target.split('/')[0] : 'github.com';
const data = {
  schema: 'qi-catalog/v1',
  agent: { display_name: cfg('display_name') || 'Quality Inspector', version: (read(join(HERE, '..', 'VERSION')) ?? '').trim() || null },
  product, target: target || null,
  issue_url: target ? `https://${host}/${target.split('/').slice(-2).join('/')}/issues/{n}` : null,
  builds, collections, items, pages, uncovered_nav: uncoveredNav, nights, runs,
  modules, design, findings, areas, interactive: modules?.global?.dashboard_interactive?.value === 'enabled', images,
};
const hash = createHash('sha256').update(JSON.stringify(data)).digest('hex').slice(0, 12);
data.generated_utc = new Date().toISOString().replace(/\.\d+Z$/, 'Z');

const template = read(join(HERE, 'catalog', 'viewer.html'));
if (!template || !template.includes('__QI_CATALOG_DATA__')) { console.error('catalog: scripts/catalog/viewer.html missing or without its data token'); process.exit(1); }
// The page may be shared: a credential value of work/env/credentials.env or a token in its data
// (the images aside — base64 would match short values by chance) refuses the page, as the backup
// refuses the snapshot. A scan that cannot run refuses too; the last page stays as it was.
const scanDir = mkdtempSync(join(tmpdir(), 'quality-inspector-catalog-'));
let leak = true;
try {
  writeFileSync(join(scanDir, 'data.json'), JSON.stringify({ ...data, images: {} }));
  const r = JSON.parse(execFileSync(process.execPath, [join(HERE, 'lib', 'secrets.mjs'), 'scan-all', join(work, 'env', 'credentials.env'), scanDir],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }));
  leak = !Array.isArray(r.files) || r.files.length > 0;
} catch { /* the scan did not run: refused */ } finally { rmSync(scanDir, { recursive: true, force: true }); }
if (leak) {
  console.log(JSON.stringify({ refused: 'a credential value or a token in the page data, or the scan did not run', notes, hash, changed: false }));
  process.exit(1);
}
mkdirSync(outDir, { recursive: true });
const html = template.replace('__QI_CATALOG_DATA__', () => JSON.stringify(data).replace(/</g, '\\u003c'));
writeFileSync(join(outDir, 'index.html.tmp'), html); renameSync(join(outDir, 'index.html.tmp'), join(outDir, 'index.html'));
const published = (read(join(outDir, 'published.hash')) ?? '').trim();
console.log(JSON.stringify({ html: join(outDir, 'index.html'), bytes: Buffer.byteLength(html), items: items.length,
  images: Object.keys(images).length, dropped_images: dropped, thumbnails, notes, hash, changed: hash !== published }));
