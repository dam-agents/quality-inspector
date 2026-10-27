#!/usr/bin/env node
// issue-draft.mjs — the draft of a found issue (skills/create-issue): one or more problems the
// agent saw — a failed test of a criterion, an intent test or an exploration, a design finding, a validation case,
// a stress check — written up for the people who fix them: what is wrong, how it should work and
// where that comes from (the original issue's criterion), how to reproduce it step by step, the
// evidence (the screenshots, the video, the crop), and a "Done when" section an issue run can test
// once it is fixed. Reads work/ only; writes work/found/<slug>/ only. Never posts anything.
//
//   node issue-draft.mjs <ref>[, <ref>…] [--fix]
//     <ref>: `#42 AC-2`, `#42 EX-1`, `S-7 AC-1`, `P-sign-in AC-1`, `D-12`, `VAL-3`, `STRESS-API-2`
//     -> {"dir", "refs", "build", "title", "labels", "images", "video", "missing", "already", "notes"}
//
// The draft: title.txt (one line), body.md (Markdown with the hidden marker
// `<!-- <marker_prefix>-found refs="<ref>; <ref>" build=<b> -->` and the literal EVIDENCE_LINK where the
// evidence page's link goes), draft.json ({refs, build, labels, problems}), and evidence/ — an
// index.html with media/ beside it; report-media.mjs makes the one file that is published. Several refs are one
// issue: one section per problem, one "Done when" for all. A ref the work/ state does not know is
// named in `missing` and left out (exit 2 when none is left); one already in work/FOUND.md is named
// in `already`. What it copies is data the agent judged — an issue's criteria, a test's steps, the
// product's screens — never a verdict's notes, a triage explanation, LESSONS.md or work/env/.

import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { basename, extname, join } from 'node:path';
import { VIEWER_CSS, VIEWER_HTML } from './lib/media-viewer.mjs';

const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const runsRoot = process.env.QI_RUNS_ROOT ?? join(work, 'suite', '.e2e', 'runs');
const MAX_REFS = 20;
const MAX_SHOTS = 6; // per problem: the criterion's still, the failure, the last steps
const VIDEO_MAX = 40 * 1024 * 1024;

const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
const readJson = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } };
const ls = (p) => { try { return readdirSync(p).sort(); } catch { return []; } };
const mtime = (p) => { try { return statSync(p).mtimeMs; } catch { return 0; } };
const size = (p) => { try { return statSync(p).size; } catch { return 0; } };
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60);
const iso = (ms) => new Date(ms).toISOString().replace(/\.\d+Z$/, 'Z');
const one = (s, n = 300) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, n);
const rows = (p) => (read(p) ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2)
  .map((l) => l.split('|').slice(1, -1).map((c) => c.trim()));
const cfg = (k) => {
  const m = (read(join(work, 'CONFIG.md')) ?? '').match(new RegExp(`^- ${k}:[ \\t]*(.*)$`, 'm'));
  return m ? m[1].replace(/\s+#.*$/, '').trim().replace(/^[`"']|[`"']$/g, '') : '';
};
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const mdq = (s) => String(s ?? '').replace(/([\\`*_[\]<>|])/g, '\\$1'); // product text in Markdown: shown, never markup

// ------------------------------------------------------------------ arguments
const args = process.argv.slice(2);
const fix = args.includes('--fix');
const REF_RE = /^(#\d{1,7} (?:AC|IN|EX)-\d{1,3}|S-\d{1,6} AC-\d{1,3}|P-[a-z0-9][a-z0-9-]{0,40} AC-\d{1,3}|D-\d{1,6}|VAL-\d{1,6}|STRESS-[A-Z]{1,20}-\d{1,3})$/;
const refs = [...new Set(args.filter((a) => a !== '--fix').join(' ').split(',').map((s) => s.trim().replace(/\s+/g, ' ')).filter(Boolean))];
if (!refs.length || refs.length > MAX_REFS || refs.some((r) => !REF_RE.test(r))) {
  console.error(`usage: issue-draft.mjs <ref>[, <ref>…] [--fix] — 1 to ${MAX_REFS} refs: #42 AC-2, #42 EX-1, S-7 AC-1, P-<slug> AC-1, D-12, VAL-3, STRESS-API-2`);
  process.exit(2);
}
const notes = [];

// ------------------------------------------------------------------ shared readers
const VERDICT = {
  failed: 'the check failed', regression: 'a regression: the test passed before and fails now', 'needs-review': 'the nightly test failed, and a person must examine it',
  flaky: 'the test passes and fails on the same build', observation: 'the exploration found a possible problem', blocked: 'the test did not get to its check',
  inconclusive: 'inconclusive', partial: 'partial', verified: 'verified', passed: 'passed', unchanged: 'unchanged', healed: 'repaired after a UI change',
};
const BAD = new Set(['failed', 'regression', 'needs-review', 'flaky', 'observation', 'blocked']);
const OK = new Set(['verified', 'passed', 'unchanged', 'relearned', 'healed', 'observed-ok']);

function parseCriteria(text, id) {
  if (!text) return null;
  const title = (text.match(/^# (?:#\d+|S-\d+|P-[a-z0-9][a-z0-9-]*) — (.*?)(?:\s{2,}\S+:.*)?$/m) ?? [])[1] ?? null;
  for (const sec of text.split(/^## /m).slice(1)) {
    const head = sec.split('\n')[0];
    if ((head.match(/^((?:AC|IN|EX)-\d+)/) ?? [])[1] !== id) continue;
    const line = (k) => ((sec.match(new RegExp(`^${k}[: ]\\s*(.*)$`, 'm')) ?? [])[1] ?? null);
    return { title, name: (head.match(/ — (.*)$/) ?? [])[1] ?? null, given: line('Given'), when: line('When'),
      then: line('Then') ?? line('Expected'), surface: line('surface'), from: (head.match(/\(from (AC-\d+)/) ?? [])[1] ?? null };
  }
  return { title };
}

// One test's steps and session from its file, the way catalog.mjs reads them.
const STEP = /\b(app\.open|agent\.act|agent\.assert|app\.screenshot)\(\s*(['"`])((?:\\.|(?!\2)[\s\S])*?)\2/g;
const unjs = (s) => s.replace(/\$\{\s*(\w+)\s*\}/g, '{$1}').replace(/\\(.)/g, '$1');
function testSteps(src, id) {
  if (!src) return null;
  const starts = [...src.matchAll(/^\s*test\(\s*/gm)].map((m) => m.index);
  for (let i = 0; i < starts.length; i++) {
    const body = src.slice(starts[i], starts[i + 1] ?? src.length);
    const title = (body.match(/^\s*test\(\s*(['"`])((?:\\.|(?!\1)[\s\S])*?)\1/) ?? [])[2] ?? '';
    if (!new RegExp(`\\b${id}\\b`).test(title)) continue;
    const steps = [];
    for (const m of body.matchAll(STEP)) steps.push({ kind: m[1], text: one(unjs(m[3]), 240), at: m.index });
    const block = body.match(new RegExp(String.raw`//\s*${id} begin([\s\S]*?)//\s*${id} end`))?.[1] ?? '';
    for (const m of block.matchAll(/expect\(([\s\S]*?)\)\s*\.\s*(not\.)?(to\w+)\(([^;]*?)\)\s*;/g)) {
      steps.push({ kind: 'expect', text: one(`${m[1]} ${m[2] ?? ''}${m[3]}(${m[4]})`, 240), at: body.indexOf(m[0]) });
    }
    steps.sort((a, b) => a.at - b.at);
    return { session: (body.match(/session:\s*['"]([\w-]+)['"]/) ?? [])[1] ?? 'owner', steps };
  }
  return null;
}

// The evidence of one test in one run: the error, the screenshots by their step, the video.
function runEvidence(label, tags) {
  const dir = join(runsRoot, label);
  const report = readJson(join(dir, 'report.json'));
  if (!report) return null;
  const roots = [join(dir, 'artifacts'), join(dir, 'results'), dir];
  const at = (rel) => roots.map((r) => join(r, rel)).find(existsSync) ?? null;
  const res = (report.run?.results ?? []).find((r) => tags.every((t) => (r.tags ?? []).includes(t)));
  const att = res?.attempts?.at(-1);
  if (!att) return null;
  const arts = att.artifacts ?? [];
  const byId = new Map(arts.map((a) => [a.id, a]));
  const shots = [];
  (att.steps ?? []).forEach((s, i) => (s.artifacts ?? []).map((x) => byId.get(x)).filter((a) => a?.kind === 'screenshot' && a.path)
    .forEach((a) => shots.push({ caption: s.api === 'app.screenshot' ? one(s.label, 120) : `after step ${i + 1}: ${s.api} ${one(s.label, 100)}`, path: at(a.path), still: s.api === 'app.screenshot', failed: s.status === 'failed' })));
  arts.filter((a) => a.kind === 'screenshot' && a.path && a.producer?.kind !== 'step').forEach((a) => shots.push({ caption: 'the screen at the failure', path: at(a.path), failed: true }));
  const video = arts.find((a) => a.kind === 'video' && a.path);
  // The criterion's still, the failing moments, then the last steps — at most MAX_SHOTS.
  const ok = shots.filter((s) => s.path);
  const pick = [...ok.filter((s) => s.still), ...ok.filter((s) => s.failed), ...ok.slice(-3)];
  return {
    status: res.status, error: att.error ? one(`${att.error.message ?? ''}`, 600) : null,
    failedStep: (att.steps ?? []).find((s) => s.status === 'failed') ?? null,
    shots: [...new Set(pick)].slice(0, MAX_SHOTS), video: video ? at(video.path) : null,
  };
}

// ------------------------------------------------------------------ problems
const qa = new Map(rows(join(work, 'QA.md')).map(([n, h]) => [n, h]));
const scenRows = new Map(rows(join(work, 'SCENARIOS.md')).map(([id, , , , h]) => [id, h]));
const found = rows(join(work, 'FOUND.md')).map(([ref, issue, url]) => ({ ref, issue, url }));

function testProblem(ref) {
  const [, owner, id] = ref.match(/^(\S+) ((?:AC|IN|EX)-\d+)$/);
  const isIssue = owner.startsWith('#');
  const num = owner.slice(1);
  const okey = isIssue ? `issue-${num}` : owner.startsWith('P-') ? `profile-${owner.slice(2)}` : `scenario-${owner.slice(2)}`;
  const dir = isIssue ? join(work, 'issues', num) : join(work, 'scenarios', owner);
  const ex = id.startsWith('EX');
  const hash = isIssue ? qa.get(num) : scenRows.get(owner);
  const critFile = (pre) => (hash && existsSync(join(dir, `${pre}-${hash}.md`)) ? join(dir, `${pre}-${hash}.md`)
    : ls(dir).filter((f) => f.startsWith(`${pre}-`) && f.endsWith('.md')).map((f) => join(dir, f)).sort((a, b) => mtime(a) - mtime(b)).at(-1));
  // An intent test's frozen lines live in intent-<ac_hash>.md (docs/intent.md).
  const crit = parseCriteria(read(critFile(ex ? 'explorations' : id.startsWith('IN') ? 'intent' : 'criteria')), id) ?? {};
  const originTitle = parseCriteria(read(critFile('criteria')), 'AC-1')?.title ?? crit.title ?? null;

  // Every result of this test: issue and scenario runs, nights, runs by hand — the newest bad one.
  const results = [];
  for (const f of ls(dir).filter((x) => /^verdicts-.*\.json$/.test(x))) {
    const v = readJson(join(dir, f)); if (!v) continue;
    const e = [...(v.acs ?? []), ...(v.intents ?? []), ...(v.explorations ?? [])].find((x) => x?.id === id);
    if (e?.verdict) results.push({ value: e.verdict, build: v.candidate ?? v.build ?? null, baseline: v.baseline ?? null,
      utc: v.generated_utc ?? iso(mtime(join(dir, f))), label: ex ? v.explorations_run : v.candidate_run, run: isIssue ? 'issue run' : 'scenario run', title: v.title });
  }
  for (const c of ls(join(work, 'regression'))) {
    const v = readJson(join(work, 'regression', c, 'verdicts.json')); if (!v) continue;
    const e = (v.acs ?? v.entries ?? []).find((x) => x?.id === id && (isIssue ? String(x.issue) === num : x.scenario === owner));
    if (e?.verdict) results.push({ value: e.verdict, build: c, utc: v.generated_utc ?? iso(mtime(join(work, 'regression', c, 'verdicts.json'))), label: `regression-${c}`, run: 'nightly regression' });
  }
  for (const f of ls(join(work, 'reruns', okey)).filter((x) => x.endsWith('.json'))) {
    const v = readJson(join(work, 'reruns', okey, f)); const e = v?.results?.[id];
    if (e?.status) results.push({ value: e.status, build: v.build ?? null, utc: v.utc ?? iso(mtime(join(work, 'reruns', okey, f))), label: v.label, run: 'manual run' });
  }
  results.sort((a, b) => String(a.utc).localeCompare(String(b.utc)));
  if (!results.length && !crit.then) return null;
  const bad = results.filter((r) => BAD.has(r.value)).at(-1) ?? results.at(-1) ?? null;
  const lastOk = bad ? results.filter((r) => OK.has(r.value) && String(r.utc) < String(bad.utc)).at(-1) ?? null : null;
  const ev = bad?.label ? runEvidence(bad.label, [ex ? `${okey}-ex` : okey, id.toLowerCase()]) : null;
  if (bad?.label && !ev) notes.push(`${ref}: no evidence in run ${bad.label} (its report.json or the test's result is gone)`);
  const file = `tests/${okey}.e2e.ts`;
  const t = testSteps(read(join(work, 'suite', file)), id);

  const repro = [];
  if (t) {
    repro.push(`Sign in to the product as a user with the \`${t.session}\` role.`);
    for (const s of t.steps) {
      if (s.kind === 'app.open') repro.push(`Open \`${s.text}\`.`);
      else if (s.kind === 'agent.act') repro.push(mdq(s.text.charAt(0).toUpperCase() + s.text.slice(1)));
      else if (s.kind === 'agent.assert') repro.push(`Check: ${mdq(s.text)}`);
      else if (s.kind === 'expect') repro.push(`The test expects: \`${s.text.replace(/`/g, "'")}\``);
    }
  } else if (crit.given || crit.when) {
    if (crit.given) repro.push(`Set up: ${mdq(crit.given)}`);
    if (crit.when) repro.push(mdq(crit.when));
  }
  const failedAt = ev?.failedStep ? `The step that failed: \`${one(`${ev.failedStep.api} ${ev.failedStep.label ?? ''}`, 160).replace(/`/g, "'")}\`.` : null;
  return {
    ref, kind: ex ? 'exploration' : 'criterion', build: bad?.build ?? null, utc: bad?.utc ?? null,
    title: one(crit.name ?? crit.then ?? `${ref} fails`, 120),
    what: [`On build \`${bad?.build ?? '?'}\` (${bad?.run ?? 'no run yet'}), ${ref}${crit.name ? ` — ${mdq(crit.name)}` : ''}: ${VERDICT[bad?.value] ?? bad?.value ?? 'no result yet'}.`,
      ev?.error ? `The message of the check: \`${ev.error.replace(/`/g, "'")}\`` : null, failedAt].filter(Boolean),
    expected: { source: isIssue ? `#${num}${originTitle ? ` (${mdq(originTitle)})` : ''}, ${ex ? `exploration ${id}${crit.from ? ` of ${crit.from}` : ''}` : id.startsWith('IN') ? `intent test ${id} (the purpose the issue states)` : `acceptance criterion ${id}`}`
      : `the scenario ${owner}${originTitle ? ` (${mdq(originTitle)})` : ''}, criterion ${id}`,
      given: crit.given, when: crit.when, then: crit.then },
    done: crit.then ? { given: crit.given, when: crit.when, then: crit.then } : null,
    repro, lastOk: lastOk ? `The test passed last on build \`${lastOk.build}\` (${lastOk.run}, ${String(lastOk.utc).slice(0, 10)}).` : null,
    meta: [`test \`${file}\``, bad?.label ? `run \`${bad.label}\`` : null, existsSync(join(dir, 'artifact.id')) ? 'the full report is the agent\'s private artifact of this issue run' : null].filter(Boolean),
    shots: (ev?.shots ?? []).map((s) => ({ path: s.path, caption: s.caption })), video: ev?.video ?? null,
  };
}

// What a design check expects of a screen (docs/ui-sweep.md → the checks and the review rubric).
const DESIGN_EXPECT = {
  'overflow-x': 'the page is not wider than the screen, and no element is wider than the screen',
  offscreen: 'every control is fully on the screen', 'broken-image': 'every image loads',
  'placeholder-text': 'no raw placeholder (`undefined`, `NaN`, `[object Object]`, `{{…}}`, an untranslated key) is shown',
  'no-name': 'every button, link and field has an accessible name', 'clipped-text': 'no text is cut off by its box without an ellipsis',
  overlap: 'controls do not cover each other', contrast: 'text meets the WCAG AA contrast ratio against its background',
  'tap-target': 'every control is at least 24 px in both directions on a phone screen', 'layout-shift': 'the layout does not move while the page loads (CLS ≤ 0.1)',
  'console-error': 'the page logs no error in the browser console', 'failed-request': 'no request of the page is answered with an error (≥ 400)',
  'review:alignment': 'elements meant to line up do line up', 'review:spacing': 'spacing between like elements is consistent',
  'review:typography': 'like texts use the same size, weight and font', 'review:layout': 'every region is laid out in full: nothing collapsed, stacked wrongly, cut off or empty',
  'review:truncation': 'a user can read the full text of each text that the user needs', 'review:legibility': 'text is readable on its background',
};
function designProblem(ref) {
  const f = (readJson(join(work, 'design', 'findings.json'))?.findings ?? []).find((x) => x?.id === ref);
  if (!f) return null;
  const category = rows(join(work, 'design', 'CATEGORIES.md')).find(([id]) => id === ref)?.[1] ?? null;
  const check = String(f.check ?? '');
  const expect = DESIGN_EXPECT[check] ?? (check.startsWith('a11y:') ? `the page passes the WCAG 2 A/AA rule \`${check.slice(5)}\`` : 'the screen shows no visible defect');
  const vp = f.viewport && f.viewport !== '-' ? String(f.viewport) : null;
  const abs = (p) => (!p ? null : p.startsWith('/') ? p : join(work, p));
  const shots = [{ path: abs(f.crop) ?? join(work, 'design', 'crops', `${ref}.jpg`), caption: `${ref}: the finding with a mark` }, { path: abs(f.shot), caption: `the full page${vp ? ` at ${vp}` : ''}` }]
    .filter((s) => s.path && existsSync(s.path));
  return {
    ref, kind: 'design', build: f.last_seen ?? null, utc: null,
    title: one(f.saw || `${check} on ${f.pattern}`, 120),
    what: [`On build \`${f.last_seen ?? '?'}\`, the page \`${f.pattern}\`${vp ? ` at ${vp}` : ''}: ${mdq(one(f.saw, 400)) || check}.`,
      `Check: \`${check}\`. Severity: ${f.severity ?? '?'}.${category ? ` Category: \`${category}\`.` : ''} First seen on build \`${f.first_seen ?? '?'}\`.${f.suspect ? ' The model was not sure. Examine the screenshot first.' : ''}`,
      f.target ? `The element: \`${one(f.target, 200).replace(/`/g, "'")}\`` : null].filter(Boolean),
    expected: { source: { sweep: 'the UI sweep\'s layout and accessibility checks', review: 'the design review rubric', noticed: 'noticed while testing' }[f.source] ?? 'the UI sweep', then: expect },
    done: { given: `the page \`${f.pattern}\`${vp ? ` in a ${vp} window` : ''}`, when: 'it is open', then: expect },
    repro: [`Open a page with the address pattern \`${f.pattern}\`${vp ? ` in a browser window of ${vp}` : ''}.`, f.target ? `Examine \`${one(f.target, 200).replace(/`/g, "'")}\`.` : 'Examine the area with the mark on the screenshot.'],
    lastOk: null, meta: [`design finding ${ref}`], shots, video: null,
  };
}

const VAL_EXPECT = {
  'refused-visibly': 'the form refuses the input visibly (with an error message or a mark on the field) and does not save it',
  'refused-or-intact': 'the form refuses the input visibly, or saves it exactly as the user typed it',
  'single-effect': 'when the user submits the form two times, it has an effect one time only', 'no-server-error': 'the server answers without a 5xx',
  'no-uncaught-error': 'the page throws no uncaught error', 'no-error-page': 'no error page is shown', 'value-intact': 'the form keeps an accepted value exactly as the user typed it',
};
function validationProblem(ref) {
  const dirs = ls(join(work, 'validation')).map((b) => join(work, 'validation', b)).filter((d) => existsSync(join(d, 'results.json')))
    .sort((a, b) => mtime(join(b, 'results.json')) - mtime(join(a, 'results.json')));
  for (const d of dirs) {
    const r = readJson(join(d, 'results.json')); const c = (r?.cases ?? []).find((x) => x?.id === ref);
    if (!c) continue;
    const p = (readJson(join(d, 'plan.json'))?.cases ?? []).find((x) => x?.id === ref) ?? {};
    const oracle = String(/^\[([a-z-]+)\]/.exec(c.message ?? '')?.[1] ?? c.oracle ?? '');
    const fill = Object.entries(p.fill ?? {}).map(([k, v]) => `\`${k}\` = \`${String(v).replace(/`/g, "'")}\``);
    return {
      ref, kind: 'validation', build: r.build ?? null, utc: r.generated_utc ?? null,
      title: one(`${c.form ?? 'form'}${c.field ? ` · ${c.field}` : ''}: ${c.kind} input ${c.result === 'finding' ? 'mishandled' : c.result}`, 120),
      what: [`On build \`${r.build ?? '?'}\`, the form \`${mdq(c.form)}\` on \`${c.page}\`${c.field ? `, field \`${mdq(c.field)}\`` : ''}, the input of type \`${c.kind}\` gives the result "${c.result}"${c.severity ? ` (${c.severity})` : ''}.`,
        c.message ? `The message of the check: \`${one(c.message, 400).replace(/`/g, "'")}\`` : null].filter(Boolean),
      expected: { source: `the validation oracle \`${oracle || c.oracle}\``, then: VAL_EXPECT[oracle] ?? VAL_EXPECT[c.oracle] ?? String(c.oracle ?? '') },
      done: { given: `the form \`${mdq(c.form)}\` on \`${c.page}\``, when: `a \`${c.kind}\` value is entered${c.field ? ` in \`${mdq(c.field)}\`` : ''} and submitted`, then: VAL_EXPECT[oracle] ?? VAL_EXPECT[c.oracle] ?? String(c.oracle ?? '') },
      repro: [`Open \`${p.example ?? c.page}\`.`, fill.length ? `Put values into the other required fields: ${fill.join(', ')}.` : null,
        c.field ? `Put \`${String(p.value ?? '').replace(/`/g, "'").slice(0, 200)}\` into \`${mdq(c.field)}\`.` : null,
        `Submit the form with \`${mdq(p.submit ?? 'its submit button')}\`${c.kind === 'duplicate-submit' ? ' two times quickly' : ''}.`].filter(Boolean),
      lastOk: null, meta: [`validation case ${ref}`, r.run ? `run \`${r.run}\`` : null].filter(Boolean),
      shots: [], video: null,
    };
  }
  return null;
}
// A stress check is one id across its targets (scripts/stress.mjs): every target it failed on in the newest run.
function stressProblem(ref) {
  const files = ls(join(work, 'stress')).map((b) => join(work, 'stress', b, 'stress.json')).filter(existsSync).sort((a, b) => mtime(b) - mtime(a));
  for (const f of files) {
    const s = readJson(f); const all = (s?.checks ?? []).filter((x) => x?.id === ref);
    if (!all.length) continue;
    const bad = all.filter((c) => c.status === 'fail');
    const cs = bad.length ? bad : all;
    const load = s.config ? `${s.config.concurrency ?? '?'} parallel users for ${s.config.duration_s ?? '?'} s` : 'the configured load';
    const targets = cs.map((c) => `\`${one(c.target, 160).replace(/`/g, "'")}\``);
    return {
      ref, kind: 'stress', build: s.build ?? null, utc: s.generated_utc ?? null,
      title: one(`${ref} under load: ${cs[0].reason || cs[0].status}`, 120),
      what: [`On build \`${s.build ?? '?'}\`, under ${load}, the stress check \`${ref}\` (${cs[0].severity ?? '?'}) ${bad.length ? 'failed' : cs[0].status} on ${targets.join(', ')}.`,
        ...cs.map((c) => `- \`${one(c.target, 160).replace(/`/g, "'")}\`: ${mdq(one(c.reason || c.status, 300))}${c.evidence && typeof c.evidence === 'object' && Object.keys(c.evidence).length ? ` — measured \`${one(JSON.stringify(c.evidence), 300).replace(/`/g, "'")}\`` : typeof c.evidence === 'string' && c.evidence ? ` — ${mdq(one(c.evidence, 300))}` : ''}`)],
      expected: { source: 'the stress module\'s thresholds (docs/stress.md)', then: `every target holds under ${load}: no error answers (at most 1 % errors, no 5xx), pages load` },
      done: { given: load, when: `${targets.join(', ')} ${cs.length > 1 ? 'are' : 'is'} requested`, then: 'no error answers and no 5xx, within the thresholds' },
      repro: [`Send a load of ${load} to ${targets.join(', ')}.`, 'Examine the status codes, the errors and the response times of the answers.'],
      lastOk: null, meta: [`stress check ${ref}`], shots: [], video: null,
    };
  }
  return null;
}

const problems = []; const missing = [];
for (const ref of refs) {
  const p = ref.startsWith('D-') ? designProblem(ref) : ref.startsWith('VAL-') ? validationProblem(ref) : ref.startsWith('STRESS-') ? stressProblem(ref) : testProblem(ref);
  if (p) problems.push(p); else missing.push(ref);
}
if (!problems.length) { console.log(JSON.stringify({ error: 'none of the refs is known to work/', missing })); process.exit(2); }
const already = problems.filter((p) => found.some((f) => f.ref === p.ref)).map((p) => ({ ref: p.ref, ...found.filter((f) => f.ref === p.ref).at(-1) }));

// ------------------------------------------------------------------ the draft
const build = problems.map((p) => p.build).filter((b) => /^[A-Za-z0-9._+-]{1,80}$/.test(String(b ?? ''))).at(0) ?? '-';
const prefix = cfg('marker_prefix') || 'quality-inspector';
const labels = [cfg('found_label') || 'qa:found', ...(fix && cfg('fix_label') ? [cfg('fix_label')] : [])];
if (fix && !cfg('fix_label')) notes.push('--fix: fix_label is not set in work/CONFIG.md — no label for the architect');
const name = problems.length === 1 ? `${problems[0].ref}-${problems[0].build ?? 'x'}` : `${problems.length}-problems-${build}-${slug(refs.join(' ')).slice(0, 24)}`;
const dir = join(work, 'found', slug(name));
rmSync(dir, { recursive: true, force: true });
mkdirSync(join(dir, 'evidence', 'media'), { recursive: true });

// Media copied beside the evidence page; a missing or oversized file is a note, not a failure.
let images = 0; let video = 0;
for (const p of problems) {
  p.media = [];
  for (const [k, s] of p.shots.entries()) {
    const ext = extname(s.path) || '.png';
    const dst = `media/${slug(p.ref)}-${k + 1}${ext}`;
    try { copyFileSync(s.path, join(dir, 'evidence', dst)); p.media.push({ src: dst, caption: s.caption, kind: 'image' }); images++; } catch { notes.push(`${p.ref}: could not copy ${basename(s.path)}`); }
  }
  if (p.video) {
    if (size(p.video) > VIDEO_MAX) notes.push(`${p.ref}: the video exceeds ${VIDEO_MAX >> 20} MiB — left out`);
    else { const dst = `media/${slug(p.ref)}-video${extname(p.video) || '.webm'}`; try { copyFileSync(p.video, join(dir, 'evidence', dst)); p.media.push({ src: dst, caption: 'the video of the full test', kind: 'video' }); video++; } catch { notes.push(`${p.ref}: could not copy the video`); } }
  }
}

const many = problems.length > 1;
const title = many ? `${problems.length} problems on build ${build}: ${problems.map((p) => p.title).join('; ')}`.slice(0, 200)
  : `${problems[0].title}${problems[0].build ? ` (build ${problems[0].build})` : ''}`.slice(0, 200);
const gwt = (x, lead = '') => [x.given ? `${lead}**Given** ${x.given}` : null, x.when ? `${lead}**When** ${x.when}` : null, x.then ? `${lead}**Then** ${x.then}` : null].filter(Boolean);
const section = (p, h) => [
  `${h} ${many ? `${p.ref} — ${mdq(p.title)}` : 'The problem'}`, '',
  ...(many ? ['**The problem**', ''] : []), ...p.what, '',
  `${many ? '**The correct function**' : `${h} The correct function`}`, '',
  `Source: ${p.expected.source}.`, '', ...gwt(p.expected, '- '), '',
  `${many ? '**Steps to reproduce**' : `${h} Steps to reproduce`}`, '',
  ...p.repro.map((s, k) => `${k + 1}. ${s}`), ...(p.lastOk ? ['', p.lastOk] : []), '',
  `${many ? '**Evidence**' : `${h} Evidence`}`, '',
  p.media.length ? `The evidence page shows: ${p.media.map((m) => m.caption).join(' · ')}. Link: EVIDENCE_LINK` : 'There is no screenshot for this problem. The measured values are above.',
  ...(p.meta.length ? ['', `<sub>${p.meta.join(' · ')}</sub>`] : []), '',
];
const doneLines = problems.filter((p) => p.done).map((p) => `- ${[p.done.given ? `Given ${p.done.given}` : null, p.done.when ? `when ${p.done.when}` : null, `then ${p.done.then}`].filter(Boolean).join(', ')}${many ? ` (${p.ref})` : ''}`);
const body = [
  `<!-- ${prefix}-found refs="${problems.map((p) => p.ref).join('; ')}" build=${build} -->`,
  many ? `Quality Inspector found ${problems.length} problems on build \`${build}\`. Each problem has a section with the problem, the correct function, the steps to reproduce it and the evidence.\n` : '',
  ...(many ? problems.flatMap((p) => section(p, '##')) : section(problems[0], '##')),
  '## Done when', '', ...(doneLines.length ? doneLines : ['- the problems above no longer occur']), '',
  '---',
  `<sub>${cfg('display_name') || 'Quality Inspector'} found ${many ? 'these problems' : 'this problem'}. It tests the running product through its UI and does not read the source code. The evidence page has the screenshots${video ? ' and the video' : ''}.</sub>`, '',
].join('\n');
writeFileSync(join(dir, 'title.txt'), `${title}\n`);
writeFileSync(join(dir, 'body.md'), body);
writeFileSync(join(dir, 'draft.json'), `${JSON.stringify({ refs: problems.map((p) => p.ref), build, labels, title,
  problems: problems.map(({ shots: _s, video: _v, media, ...p }) => ({ ...p, media })) }, null, 2)}\n`);

// The evidence page: self-contained, one section per problem, the media beside it.
const page = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(many ? `${problems.length} problems — evidence` : `${problems[0].ref} — evidence`)}</title>
<style>:root{--bg:#fff;--fg:#1b1f24;--dim:#57606a;--line:#d0d7de;--card:#f6f8fa}@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--dim:#8d96a0;--line:#30363d;--card:#161b22}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,sans-serif}main{max-width:1000px;margin:0 auto;padding:16px}
section{border:1px solid var(--line);border-radius:8px;padding:12px 16px;margin:16px 0;background:var(--card)}figure{margin:12px 0}img,video{max-width:100%;border:1px solid var(--line);border-radius:6px;background:#fff}
figcaption,.dim{color:var(--dim);font-size:13px}code{font-size:13px;overflow-wrap:anywhere}
${VIEWER_CSS}</style></head><body><main>
<h1>${esc(title)}</h1><p class="dim">Build ${esc(build)}. A black-box test of the running product found ${many ? 'these problems' : 'this problem'}.</p>
${problems.map((p) => `<section><h2>${esc(p.ref)} — ${esc(p.title)}</h2>
<p>${p.what.map((x) => esc(x.replace(/\\(.)/g, '$1'))).join('<br>')}</p>
<p><b>The correct function</b> — source: ${esc(String(p.expected.source).replace(/\\(.)/g, '$1'))}.<br>${gwt(p.expected).map((x) => esc(x.replace(/\*\*/g, ''))).join('<br>')}</p>
<p><b>Steps to reproduce</b></p><ol>${p.repro.map((s) => `<li>${esc(s.replace(/\\(.)/g, '$1'))}</li>`).join('')}</ol>${p.lastOk ? `<p class="dim">${esc(p.lastOk)}</p>` : ''}
${p.media.map((m) => (m.kind === 'video' ? `<figure><video controls preload="metadata" src="${esc(m.src)}"></video><figcaption>${esc(m.caption)}</figcaption></figure>`
    : `<figure><img src="${esc(m.src)}" alt="${esc(m.caption)}" loading="lazy"><figcaption>${esc(m.caption)}</figcaption></figure>`)).join('\n')}
</section>`).join('\n')}
</main>${VIEWER_HTML}</body></html>
`;
writeFileSync(join(dir, 'evidence', 'index.html'), page);

console.log(JSON.stringify({ dir, refs: problems.map((p) => p.ref), build, title, labels, images, video, missing, already, notes }));
