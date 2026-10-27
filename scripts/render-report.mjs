#!/usr/bin/env node
// render-report.mjs — turn one issue's verdicts and its e2e runs into a self-contained
// evidence page: index.html plus media/ (videos, screenshots, traces), and comment.md. The page
// links media/ relatively; report-media.mjs makes the one file that is published.
// Deterministic and read-only toward everything but <out-dir>. Contract: docs/reporting.md.
//
//   node render-report.mjs <verdicts.json> <out-dir>
//
// verdicts.json is written by the agent (the judgment); every run label in it names a
// directory under work/suite/.e2e/runs/ (the evidence). With "mode": "regression" it is one
// page for a whole regression run: no baseline column, the change context on top, and a
// triage category per criterion (docs/triage.md). With "explorations" (docs/explorations.md)
// it adds a "Beyond the criteria" section from the explorations_run, outside the verdict; with
// "intents" (docs/intent.md) a "What the author wanted" section — candidate and baseline like a
// criterion, the file's "intent_verdict", never the issue verdict; with
// "noticed" (docs/explorations.md → Noticed in passing) a list of what was seen, never tested.
// With "mode": "security" it is the security run's findings, severity-sorted, with the e2e
// evidence of findings that carry a "tag"; it writes no comment.md — security findings never
// go to an issue (docs/security.md). With "mode": "scenario" it is one scenario
// (docs/scenarios.md): tests tagged scenario-<k> (a profile scenario P-<slug>: profile-<slug>),
// the request as received — "request_file", a file under work/scenarios/ read verbatim — next
// to the criteria the agent froze from it, the judge's reading per criterion, and comment.md
// as the channel reply. Nothing else is read, except the previous build's
// screenshots an AC names as "before_shot", the new map's screenshots a context.signals
// item names as "shot", and the screenshot a "noticed" item names as "shot".

import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { VIEWER_CSS, VIEWER_HTML } from './lib/media-viewer.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

const [verdictsPath, outDir] = process.argv.slice(2);
if (!verdictsPath || !outDir) {
  console.error('usage: render-report.mjs <verdicts.json> <out-dir>');
  process.exit(2);
}
const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const runsRoot = process.env.QI_RUNS_ROOT ?? join(work, 'suite', '.e2e', 'runs');
// The issue a criterion came from, as a link (docs/reporting.md): the target repository, read
// through lib/config.sh like every other script. Every target host is a GitHub host (scripts/
// github.sh reaches it with gh --hostname), so one address shape holds for all of them.
const cfgOf = (key) => { try {
  return execFileSync('bash', ['-c', '. "$1"; CONFIG="$2"; cfg "$3"', '_', join(HERE, 'lib', 'config.sh'), join(work, 'CONFIG.md'), key], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
} catch { return ''; } };
const TARGET = cfgOf('target_repo');
const issueHref = (n) => {
  const seg = TARGET.split('/');
  if (!Number.isInteger(n) || n <= 0 || seg.length < 2) return null;
  const host = seg.length === 3 ? seg[0] : 'github.com';
  if (!/^[A-Za-z0-9.-]+$/.test(host) || !seg.slice(-2).every(Boolean)) return null;
  return `https://${host}/${seg.slice(-2).join('/')}/issues/${n}`;
};
const v = JSON.parse(readFileSync(verdictsPath, 'utf8'));
// A scenario is never verified: no change is under test, so no red-green ran (CLAUDE.md →
// Hard invariants). Refused before anything is written, so an earlier report stays.
if (v.mode === 'scenario' && [v.verdict, ...(v.acs ?? []).map((ac) => ac.verdict)].includes('verified')) {
  console.error('render-report: a scenario is never verified — use passed (docs/scenarios.md → The pipeline, step 9)');
  process.exit(2);
}

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const slug = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 60);
const ms = (n) => (n == null ? '' : n < 1000 ? `${n} ms` : `${(n / 1000).toFixed(1)} s`);

// One run label -> { results, root }; artifact paths are relative to an artifacts root
// that moved between e2e versions, so each candidate root is tried.
function loadRun(label) {
  if (!label) return null;
  const dir = join(runsRoot, label);
  const file = join(dir, 'report.json');
  if (!existsSync(file)) return { label, missing: true, results: [] };
  const report = JSON.parse(readFileSync(file, 'utf8'));
  const roots = [join(dir, 'artifacts'), join(dir, 'results'), dir];
  return { label, results: report.run?.results ?? [], roots, version: report.run?.runner?.version };
}
const resolve = (run, rel) => run.roots.map((r) => join(r, rel)).find((p) => existsSync(p));

rmSync(outDir, { recursive: true, force: true });
mkdirSync(join(outDir, 'media'), { recursive: true });

function copyMedia(run, rel, acId) {
  const src = resolve(run, rel);
  if (!src) return null;
  const name = `${slug(String(acId))}-${slug(run.side)}-${slug(dirname(rel).split('/').pop())}-${basename(rel)}`;
  copyFileSync(src, join(outDir, 'media', name));
  return `media/${name}`;
}

// Whose criterion an AC is: an issue (#42, tag issue-42), a scenario (S-7, tag scenario-7) or
// a profile scenario (P-sign-in, tag profile-sign-in).
const scenarioTag = (s) => (/^P-/.test(String(s)) ? `profile-${String(s).slice(2)}` : `scenario-${String(s).replace(/^S-/i, '')}`);
function owner(ac) {
  const s = ac.scenario ?? (ac.issue == null ? v.scenario : null);
  if (s) return { tag: scenarioTag(s), name: String(s) };
  const n = ac.issue ?? v.issue;
  return { tag: `issue-${n}`, name: `#${n}` };
}
// A criterion names its source, linked to its issue where there is one (docs/reporting.md):
// a regression report covers many issues, and an issue report still lets a reader reach it.
const sourceHtml = (ac) => {
  const name = owner(ac).name; const m = /^#(\d+)$/.exec(name);
  const href = m ? issueHref(+m[1]) : null;
  return href ? `<a href="${esc(href)}" title="Opens ${esc(name)} on GitHub.">${esc(name)}</a>` : esc(name);
};
const srcTag = (ac) => (/^#\d+$/.test(owner(ac).name) ? `${sourceHtml(ac)} ` : '');

// The evidence of one AC on one side: the last attempt of the test tagged with its owner
// + ac-<k> (an exploration: issue-<n>-ex + ex-<k>).
function evidence(run, ac, suffix = '') {
  if (!run) return { state: 'not-run' };
  if (run.missing) return { state: 'missing', label: run.label };
  const tags = ac.tag ? [ac.tag] : [`${owner(ac).tag}${suffix}`, ac.id.toLowerCase()];
  const res = run.results.find((r) => tags.every((t) => (r.tags ?? []).includes(t)));
  if (!res) return { state: 'no-test', label: run.label };
  const att = res.attempts?.at(-1) ?? {};
  const arts = att.artifacts ?? [];
  const byId = new Map(arts.map((a) => [a.id, a]));
  const steps = (att.steps ?? []).map((s) => ({
    api: s.api, label: s.label, status: s.status, durationMs: s.durationMs, cache: s.cache?.mode,
    shots: (s.artifacts ?? []).map((id) => byId.get(id)).filter((a) => a?.kind === 'screenshot' && a.path),
  }));
  const shots = [];
  steps.forEach((s, i) => s.shots.forEach((a) => shots.push({ caption: s.api === 'app.screenshot' ? s.label : `after step ${i + 1}: ${s.api} ${s.label ?? ''}`, a })));
  arts.filter((a) => a.kind === 'screenshot' && a.path && a.producer?.kind !== 'step').forEach((a) => shots.push({ caption: 'screen at failure', a }));
  const pick = (kind) => arts.find((a) => a.kind === kind && a.path);
  const video = pick('video');
  const trace = pick('trace');
  const screenLog = arts.find((a) => a.kind === 'log' && a.path && a.path.includes('failure'));
  const tracePage = video || trace ? findTracePage(run, (video ?? trace).path) : null;
  return {
    state: res.status, title: res.titlePath?.join(' › '), durationMs: att.durationMs,
    error: att.error ? { code: att.error.code, message: att.error.message } : null,
    steps,
    video: video ? copyMedia(run, video.path, key(ac)) : null,
    shots: shots.map(({ caption, a }) => ({ caption, src: copyMedia(run, a.path, key(ac)) })).filter((s) => s.src),
    trace: trace ? copyMedia(run, trace.path, key(ac)) : null,
    tracePage,
    screenText: screenLog ? readText(resolve(run, screenLog.path)) : null,
  };
}

// e2e >= 0.19 writes a markdown trace page per test beside its attempts.
function findTracePage(run, rel) {
  const parts = rel.split('/');
  const i = parts.findIndex((p) => /^attempt-\d+$/.test(p));
  if (i < 0) return null;
  for (let j = i; j >= 1; j--) {
    const p = resolve(run, [...parts.slice(0, j), 'trace.md'].join('/'));
    if (p) return readText(p);
  }
  return null;
}
function readText(p) { try { return p ? readFileSync(p, 'utf8').slice(0, 20000) : null; } catch { return null; } }

// A scenario's request as received, verbatim: request.md, or a profile scenario's
// source-<spec_hash>.md — only from under work/scenarios/, never another path.
function requestText() {
  if (!v.request_file) return null;
  const root = join(work, 'scenarios');
  const p = join(root, String(v.request_file).replace(/^scenarios\//, ''));
  if (!p.startsWith(`${root}/`) || p.includes('/../')) return null;
  return readText(p);
}

const key = (ac) => (ac.tag ? `${ac.tag}-${ac.target ?? ''}` : `${owner(ac).name}-${ac.id}`);
const regression = v.mode === 'regression';
const scenario = v.mode === 'scenario';
const runs = { candidate: loadRun(v.candidate_run), baseline: loadRun(v.baseline_run), explore: loadRun(v.explorations_run) };
if (runs.candidate) runs.candidate.side = 'candidate';
if (runs.baseline) runs.baseline.side = 'baseline';
if (runs.explore) runs.explore.side = 'explore';

const VERDICT = {
  verified: ['Verified', 'ok'], failed: ['Failed', 'bad'], partial: ['Partial', 'warn'],
  inconclusive: ['Inconclusive', 'warn'], blocked: ['Blocked', 'muted'], 'not-testable': ['Not testable', 'muted'],
  unchanged: ['Unchanged', 'ok'], relearned: ['UI changed · steps re-learned', 'ok'], healed: ['UI changed · check repaired', 'warn'], reworked: ['UI changed · steps rewritten', 'warn'],
  superseded: ['Superseded by a change', 'muted'], regression: ['Regression', 'bad'], 'needs-review': ['Needs review', 'warn'],
  flaky: ['Flaky', 'warn'], 'observed-ok': ['Observed OK', 'ok'], observation: ['Observation', 'warn'], passed: ['Passed', 'ok'],
  critical: ['Critical', 'bad'], high: ['High', 'bad'], medium: ['Medium', 'warn'], low: ['Low', 'muted'], info: ['Info', 'muted'],
};
const SEVERITY = { info: 'muted', minor: 'warn', major: 'bad' };
const sevBadge = (x) => (x ? `<span class="badge ${SEVERITY[x] ?? 'muted'}">${esc(x)}</span>` : '');
const BLOCKED = {
  absent: 'On the baseline, the test stopped before the check because the function is not there. This is the red of red-green.',
  environment: 'On the baseline, the test stopped before the check because of a problem in the environment. This is not a red. The criterion stays inconclusive.',
  model: 'On the baseline, the test stopped before the check because an agent step failed. This is not a red. The criterion stays inconclusive.',
  setup: 'On the baseline, the test stopped before the check in the test setup. This is not a red. The criterion stays inconclusive.',
};
const badge = (x) => { const [t, c] = VERDICT[x] ?? [x, 'muted']; return `<span class="badge ${c}">${esc(t)}</span>`; };
const stateBadge = (s) => {
  const map = { passed: 'ok', pass: 'ok', flaky: 'warn', failed: 'bad', fail: 'bad', 'timed-out': 'bad', interrupted: 'muted', skipped: 'muted' };
  const text = { 'not-run': 'not run', missing: 'run missing', 'no-test': 'no test' }[s] ?? s;
  return `<span class="state ${map[s] ?? 'muted'}">${esc(text)}</span>`;
};

function sideHtml(name, ev) {
  if (!ev || ['not-run', 'missing', 'no-test'].includes(ev.state)) {
    return `<section class="side"><h4>${esc(name)} ${stateBadge(ev?.state ?? 'not-run')}</h4><p class="dim">No evidence for this side.</p></section>`;
  }
  const poster = ev.shots[0]?.src;
  const video = ev.video
    ? `<video controls preload="metadata" src="${esc(ev.video)}"${poster ? ` poster="${esc(poster)}"` : ''}></video>`
    : `<p class="dim">No video recorded.</p>`;
  const shots = ev.shots.length
    ? `<div class="shots">${ev.shots.map((s) => `<figure><img loading="lazy" src="${esc(s.src)}" alt="${esc(s.caption)}"><figcaption>${esc(s.caption)}</figcaption></figure>`).join('')}</div>`
    : '';
  const err = ev.error ? `<pre class="error">${esc(ev.error.code)}\n${esc(ev.error.message)}</pre>` : '';
  const steps = `<details><summary>Steps (${ev.steps.length}) · ${esc(ms(ev.durationMs))}</summary><ol class="steps">${ev.steps
    .map((s) => `<li class="${esc(s.status)}"><code>${esc(s.api)}</code> ${esc(s.label)} <span class="dim">${esc(ms(s.durationMs))}${s.cache ? ` · cache ${esc(s.cache)}` : ''}</span></li>`)
    .join('')}</ol></details>`;
  const extra = [
    ev.screenText ? `<details><summary>Screen at failure (text)</summary><pre>${esc(ev.screenText)}</pre></details>` : '',
    ev.tracePage ? `<details><summary>Trace page</summary><pre>${esc(ev.tracePage)}</pre></details>` : '',
    ev.trace ? `<p class="dim"><a href="${esc(ev.trace)}">trace.zip</a> — open with <code>npx playwright show-trace</code></p>` : '',
  ].join('');
  return `<section class="side"><h4>${esc(name)} ${stateBadge(ev.state)}</h4>${video}${err}${shots}${steps}${extra}</section>`;
}

const CSS = `:root{--bg:#fff;--fg:#1d1f23;--dim:#6b7078;--card:#f6f7f9;--line:#e3e5e8;--ok:#127a3a;--okbg:#e3f5e9;--bad:#b42318;--badbg:#fdecea;--warn:#8a5a00;--warnbg:#fff4d6;--muted:#555b63;--mutedbg:#eceef1;--link:#1a5fb4}
@media (prefers-color-scheme:dark){:root{--bg:#15171a;--fg:#e8eaed;--dim:#9aa0a6;--card:#1e2125;--line:#2e3238;--ok:#6fd58f;--okbg:#173322;--bad:#ff8a80;--badbg:#3a1d1b;--warn:#f5c26b;--warnbg:#3a2f14;--muted:#b0b5bb;--mutedbg:#2a2e33;--link:#8ab4f8}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}
main{max-width:1180px;margin:0 auto;padding:24px 16px 64px}h1{font-size:24px;margin:0 0 4px}h2{font-size:20px;margin:32px 0 4px}h3{margin:0;font-size:17px}h4{margin:0 0 8px;font-size:14px;display:flex;gap:8px;align-items:center}
a{color:var(--link)}.dim{color:var(--dim)}.meta{color:var(--dim);margin:0 0 20px}
.badge,.state{display:inline-block;border-radius:999px;padding:2px 10px;font-size:12px;font-weight:600;white-space:nowrap}
.ok{color:var(--ok);background:var(--okbg)}.bad{color:var(--bad);background:var(--badbg)}.warn{color:var(--warn);background:var(--warnbg)}.muted{color:var(--muted);background:var(--mutedbg)}
.hero{display:flex;gap:12px;align-items:center;flex-wrap:wrap}.hero .badge{font-size:15px;padding:4px 14px}
table{border-collapse:collapse;width:100%;margin:8px 0 28px}td,th{border-bottom:1px solid var(--line);padding:8px;text-align:left;vertical-align:top}th{font-size:12px;color:var(--dim);text-transform:uppercase;letter-spacing:.04em}
.ac{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px;margin:0 0 20px}
.ac>header{display:flex;justify-content:space-between;gap:12px;align-items:center;margin-bottom:8px}
blockquote{margin:0 0 12px;padding:8px 12px;border-left:3px solid var(--line);color:var(--fg)}
.sides{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,460px),1fr));gap:16px}
.side{min-width:0}video{width:100%;border-radius:8px;background:#000;aspect-ratio:16/9;object-fit:contain}
.shots{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:8px;margin:10px 0}
figure{margin:0}img{width:100%;border-radius:6px;border:1px solid var(--line);display:block}figcaption{font-size:12px;color:var(--dim);margin-top:4px;overflow-wrap:anywhere}
pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:12px;background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:8px;max-height:420px;overflow:auto}
pre.error{color:var(--bad)}details{margin:6px 0}summary{cursor:pointer;color:var(--dim)}
.steps{margin:6px 0;padding-left:22px;font-size:13px}.steps li.failed{color:var(--bad)}.steps code{font-size:12px}
.note{font-style:italic;color:var(--dim)}.quote{margin:0 0 12px;padding:6px 10px;border-left:3px solid var(--line);color:var(--dim)}.signals li{margin:0 0 12px}.sigshot{max-width:320px;margin-top:6px}footer{color:var(--dim);font-size:13px;margin-top:32px}
${VIEWER_CSS}`;

if (v.mode === 'security') { renderSecurity(); process.exit(0); }

const acs = (v.acs ?? []).map((ac) => {
  let before = null;
  if (ac.before_shot && existsSync(ac.before_shot)) {
    before = `media/${slug(key(ac))}-before-${basename(ac.before_shot)}`;
    copyFileSync(ac.before_shot, join(outDir, before));
  }
  return { ...ac, before, cand: ac.testable === false ? null : evidence(runs.candidate, ac), base: ac.testable === false || regression ? null : evidence(runs.baseline, ac) };
});

// Explorations: candidate only, never part of the verdict (docs/explorations.md).
const exps = (v.explorations ?? []).map((ex) => ({ ...ex, cand: evidence(runs.explore, ex, '-ex') }));
const observations = exps.filter((ex) => ex.verdict === 'observation').length;
const exHtml = !exps.length ? '' : `
<section id="beyond-the-criteria">
<h2>Beyond the criteria</h2>
<p class="dim"><b>Not part of the verdict.</b> Checks the agent derived from the criteria (negative paths, persistence, roles…) and ran on the candidate only. An <b>observation</b> is something worth a look; it never changes a criterion's verdict.${v.ex_hash ? ` · checks <code>ex=${esc(v.ex_hash)}</code>` : ''}</p>
<table><thead><tr><th>EX</th><th>From</th><th>Heuristic</th><th>Candidate</th><th>Result</th></tr></thead><tbody>${exps.map((ex) => `<tr><td><a href="#${esc(slug(key(ex)))}">${esc(ex.id)}</a></td><td>${esc(ex.from_ac)}</td><td>${esc(ex.heuristic)}</td><td>${stateBadge(ex.cand?.state ?? 'not-run')}</td><td>${badge(ex.verdict)} ${sevBadge(ex.severity)}</td></tr>`).join('')}</tbody></table>
${exps.map((ex) => `
<article class="ac" id="${esc(slug(key(ex)))}">
  <header><h3>${esc(ex.id)} <span class="dim">from ${esc(ex.from_ac)} · ${esc(ex.heuristic)}${ex.surface ? ` · ${esc(ex.surface)}` : ''}</span></h3><span>${badge(ex.verdict)} ${sevBadge(ex.severity)}</span></header>
  <blockquote>${ex.given ? `<b>Given</b> ${esc(ex.given)}<br>` : ''}${ex.when ? `<b>When</b> ${esc(ex.when)}<br>` : ''}${ex.expected ? `<b>Expected</b> ${esc(ex.expected)}` : ''}</blockquote>
  ${ex.note ? `<p class="note">${esc(ex.note)}</p>` : ''}
  <div class="sides">${sideHtml(`Candidate ${v.candidate ?? ''}`, ex.cand)}</div>
</article>`).join('')}
</section>`;

// Intent tests: the purpose the issue states, red-green like a criterion, never part of the issue
// verdict (docs/intent.md). A regression run carries them in "acs", as criteria of the night.
const INTENT = { met: 'met', 'not-met': 'not met', unclear: 'unclear', none: 'none' };
const intentVerdict = Object.hasOwn(INTENT, v.intent_verdict) ? v.intent_verdict : null;
const intents = regression ? [] : (v.intents ?? []).map((x) => ({ ...x,
  cand: x.testable === false ? null : evidence(runs.candidate, x), base: x.testable === false ? null : evidence(runs.baseline, x) }));
const lettersOnly = v.verdict === 'verified' && intentVerdict === 'not-met';
const inHtml = !intents.length && !intentVerdict ? '' : `
<section id="what-the-author-wanted">
<h2>What the author wanted — intent ${esc(INTENT[intentVerdict] ?? 'not judged')}</h2>
<p class="dim"><b>Not part of the verdict.</b> One user journey from the purpose that the issue states, quoted as its goal. The agent tested it like a criterion, on the candidate and on the baseline.</p>
${lettersOnly ? '<p><b>The criteria are true, but the goal is not met.</b> Examine the evidence below.</p>' : ''}
${intents.length ? `<table><thead><tr><th>IN</th><th>Journey</th><th>Candidate</th><th>Baseline</th><th>Verdict</th></tr></thead><tbody>${intents.map((x) => `<tr><td><a href="#${esc(slug(key(x)))}">${esc(x.id)}</a></td><td>${esc(x.name)}</td><td>${stateBadge(x.cand?.state ?? 'not-run')}</td><td>${stateBadge(x.base?.state ?? 'not-run')}</td><td>${badge(x.verdict)}</td></tr>`).join('')}</tbody></table>` : '<p class="dim">The issue states no purpose beyond its criteria.</p>'}
${intents.map((x) => `
<article class="ac" id="${esc(slug(key(x)))}">
  <header><h3>${esc(x.id)} — ${esc(x.name)}${(x.covers ?? []).length ? ` <span class="dim">covers ${esc([x.covers].flat().join(', '))}</span>` : ''}</h3>${badge(x.verdict)}</header>
  <blockquote>${x.goal ? `<b>Goal</b> ${esc(x.goal)}<br>` : ''}${x.given ? `<b>Given</b> ${esc(x.given)}<br>` : ''}${x.when ? `<b>When</b> ${esc(x.when)}<br>` : ''}${x.then ? `<b>Then</b> ${esc(x.then)}` : ''}</blockquote>
  ${x.note ? `<p class="note">${esc(x.note)}</p>` : ''}
  ${x.baseline_blocked_reason ? `<p class="dim">${BLOCKED[x.baseline_blocked_reason] ?? `On the baseline, the test stopped before the check (${esc(x.baseline_blocked_reason)}).`}</p>` : ''}
  ${x.testable === false ? '' : `<div class="sides">${sideHtml(`Candidate ${v.candidate ?? ''}`, x.cand)}${sideHtml(`Baseline ${v.baseline ?? ''}`, x.base)}</div>`}
</article>`).join('')}
</section>`;

// Noticed in passing: seen while testing, outside the criteria; never tested, never a verdict.
const noticed = v.noticed ?? [];
let notN = 0;
const noticedShot = (p) => {
  if (!p || !existsSync(p)) return '';
  const to = `media/noticed-${++notN}-${basename(p).replace(/[^A-Za-z0-9._-]/g, '_')}`;
  copyFileSync(p, join(outDir, to));
  return `<figure class="sigshot"><img loading="lazy" src="${esc(to)}" alt="what was seen"></figure>`;
};
const noticedHtml = !noticed.length ? '' : `
<section id="noticed">
<h2>Noticed in passing</h2>
<p class="dim"><b>Not tested, not part of the verdict.</b> The agent saw these problems outside the criteria during the test. Examine them if you want. They do not change the verdict.</p>
<ul class="signals">${noticed.map((x) => `<li><code>${esc(x.where)}</code> — ${esc(x.saw)}${noticedShot(x.shot)}</li>`).join('')}</ul>
</section>`;

const ctx = v.context ?? null;
// Signals no test covers (docs/triage.md): each a needs-review item, with the new map's
// screenshot of the page when one is named.
let sigN = 0;
function signalShot(p) {
  if (!p || !existsSync(p)) return '';
  const to = `media/signal-${++sigN}-${basename(p).replace(/[^A-Za-z0-9._-]/g, '_')}`;
  copyFileSync(p, join(outDir, to));
  return `<figure class="sigshot"><img loading="lazy" src="${esc(to)}" alt="the page on this build"></figure>`;
}
const sg = ctx?.signals ?? {};
const why = (x) => (x.explanation ? `<br><span class="dim">${esc(x.explanation)}</span>` : '');
const signalItems = [
  ...(sg.console_errors_new ?? []).map((x) => `<li>${badge(x.verdict ?? 'needs-review')} <code>${esc(x.route)}</code> — new console error${(x.errors ?? []).length > 1 ? 's' : ''}<pre>${esc((x.errors ?? []).join('\n'))}</pre>${why(x)}${signalShot(x.shot)}</li>`),
  ...(sg.failed_requests_new ?? []).map((x) => `<li>${badge(x.verdict ?? 'needs-review')} <code>${esc(x.route)}</code> — new failed request${(x.requests ?? []).length > 1 ? 's' : ''}<pre>${esc((x.requests ?? []).map((q) => `${q.method} ${q.path} → ${q.status}${q.error ? ` (${q.error})` : ''}`).join('\n'))}</pre>${why(x)}${signalShot(x.shot)}</li>`),
  ...(sg.slower_pages ?? []).map((x) => `<li>${badge(x.verdict ?? 'needs-review')} <code>${esc(x.route)}</code> — page load ${esc(ms(x.old_load_ms))} → ${esc(ms(x.new_load_ms))}${why(x)}</li>`),
  ...(sg.slow_tests ?? []).map((x) => `<li>${badge(x.verdict ?? 'needs-review')} ${esc(x.title)} — ${esc(ms(x.median_ms))} → ${esc(ms(x.latest_ms))}${why(x)}</li>`),
];
const contextHtml = !ctx ? '' : `
<section class="ac"><header><h3>What changed since ${esc(ctx.previous ?? 'the last run')}</h3></header>
${(ctx.issues ?? []).length ? `<p><b>Completed issues in the window</b> (${esc(ctx.window ?? '')})</p><ul>${ctx.issues.map((i) => `<li>#${esc(i.number)} — ${esc(i.title)}</li>`).join('')}</ul>` : '<p class="dim">No completed issues in the window.</p>'}
${ctx.ui_diff ? `<p><b>UI map difference</b></p><pre>${esc(ctx.ui_diff)}</pre>` : ''}
${signalItems.length ? `<p><b>Signals no test covers</b> — console errors, failed requests and slowdowns that are new on this build</p><ul class="signals">${signalItems.join('')}</ul>` : ''}
${ctx.iface_diff ? `<p><b>CLI and API difference</b></p><pre>${esc(ctx.iface_diff)}</pre>` : ''}
</section>`;

const acHtml = acs.map((ac) => `
<article class="ac" id="${esc(slug(key(ac)))}">
  <header><h3>${srcTag(ac)}${esc(ac.id)} — ${esc(ac.name)}</h3>${badge(ac.verdict)}</header>
  <blockquote>${ac.given ? `<b>Given</b> ${esc(ac.given)}<br>` : ''}${ac.when ? `<b>When</b> ${esc(ac.when)}<br>` : ''}${ac.then ? `<b>Then</b> ${esc(ac.then)}` : ''}</blockquote>
  ${ac.quote ? `<p class="quote"><b>From the source</b> “${esc(ac.quote)}”</p>` : ''}
  ${ac.note ? `<p class="note">${esc(ac.note)}</p>` : ''}
  ${ac.explanation ? `<p><b>Why:</b> ${esc(ac.explanation)}${ac.because_issue ? ` — see #${esc(ac.because_issue)}` : ''}</p>` : ''}
  ${ac.heal ? `<p class="dim">Check repaired: <code>${esc(ac.heal.from)}</code> → <code>${esc(ac.heal.to)}</code></p>` : ''}
  ${ac.judge ? `<p class="dim"><b>Judge:</b> ${ac.judge.agree ? 'agrees' : 'disagrees'}${ac.judge.call && ac.judge.call !== '-' ? ` (${esc(ac.judge.call)})` : ''} — ${esc(ac.judge.reason)}</p>` : ''}
  ${ac.baseline_blocked_reason ? `<p class="dim">${BLOCKED[ac.baseline_blocked_reason] ?? `On the baseline, the test stopped before the check (${esc(ac.baseline_blocked_reason)}).`}</p>` : ''}
  ${ac.regressed_between ? `<p><b>Regressed between</b> <code>${esc(ac.regressed_between.from)}</code> (passes) and <code>${esc(ac.regressed_between.to)}</code> (fails)${ac.regressed_between.builds_between == null ? '' : ac.regressed_between.builds_between ? ` · ${esc(ac.regressed_between.builds_between)} untested builds in between` : ' · adjacent builds'}</p>` : ''}
  ${ac.testable === false ? '' : `<div class="sides">${sideHtml(`${regression ? 'Build' : 'Candidate'} ${v.candidate ?? ''}`, ac.cand)}${regression
    ? (ac.before ? `<section class="side"><h4>Previous build ${esc(ctx?.previous ?? '')}</h4><figure><img src="${esc(ac.before)}" alt="previous build"><figcaption>the same page on the previous build</figcaption></figure></section>` : '')
    : sideHtml(`Baseline ${v.baseline ?? ''}`, ac.base)}</div>`}
</article>`).join('');

// Open questions: the source contradicts itself, the operator decides, and the AC tested is the
// one the issue states (docs/acceptance-criteria.md → Contradictions).
const questions = (v.open_questions ?? []).filter((q) => q && q.id);
const qHtml = !questions.length ? '' : `
<section id="open-questions">
<h2>Open questions (${questions.length})</h2>
<p class="dim">The issue and its comments do not agree. The agent tested the issue. The operator decides which statement applies, and the next freeze follows that decision.</p>
<ul>${questions.map((q) => `<li><b>${esc(q.id)}</b>${q.ac ? ` · ${esc(q.ac)}` : ''} — ${esc(q.question)}${(q.variants ?? []).map((x) => `<br><span class="dim">${esc(x.source)}:</span> “${esc(x.quote)}”`).join('')}</li>`).join('')}</ul>
</section>`;

// An AC is tested when its verdict was judged; blocked, flaky and not-testable never count.
const coverage = `${acs.filter((ac) => ['verified', 'failed', 'inconclusive'].includes(ac.verdict)).length} of ${acs.length} criteria tested`;
const summaryRows = acs.map((ac) => `<tr><td><a href="#${esc(slug(key(ac)))}">${regression ? `${esc(owner(ac).name)} ` : ''}${esc(ac.id)}</a></td><td>${esc(ac.name)}</td><td>${stateBadge(ac.cand?.state ?? 'not-run')}</td>${regression ? '' : `<td>${stateBadge(ac.base?.state ?? 'not-run')}</td>`}<td>${badge(ac.verdict)}</td></tr>`).join('');

const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${regression ? `Regression ${esc(v.candidate)}` : scenario ? `${esc(v.scenario)} scenario verdict` : `#${esc(v.issue)} QA verdict`}</title>
<style>
${CSS}
</style></head><body><main>
${regression ? `<div class="hero"><h1>Regression run — ${esc(v.candidate)}</h1>${badge(v.verdict)}</div>
<p class="meta">previous build <code>${esc(ctx?.previous ?? '–')}</code> · ${esc(v.generated_utc ?? '')}</p>
<p class="dim">Each promoted criterion ran again on the new build. When a part of the UI moved or got a new name, the test found the controls again (relearned) or the agent repaired the check (healed). A <b>regression</b> is a criterion that is not true now and that no completed issue explains.</p>
<table><thead><tr><th>AC</th><th>Criterion</th><th>Result</th><th>Triage</th></tr></thead><tbody>${summaryRows}</tbody></table>${contextHtml}`
: scenario ? `<div class="hero"><h1>${esc(v.scenario)} — ${esc(v.title)}</h1>${badge(v.verdict)}</div>
<p class="meta">build <code>${esc(v.candidate ?? '–')}</code> · last release <code>${esc(v.baseline ?? '–')}</code> · scenario <code>spec=${esc(v.spec_hash)}</code> (source: ${esc(v.source ?? 'request')}) · ${esc(v.generated_utc ?? '')}</p>
<p class="dim">The agent tested each step of the scenario on the build. When a failure occurred again on a second run, the agent also ran the test on the last release. A failure only on the build is a <b>regression</b>. A failure on both is <b>failed</b>. An independent judge examined the evidence of each criterion. You can examine the videos and screenshots to check the result.</p>
<table><thead><tr><th>AC</th><th>Criterion</th><th>Build</th><th>Last release</th><th>Verdict</th></tr></thead><tbody>${summaryRows}</tbody></table>
${(() => { const t = requestText(); return t == null ? '' : `<details class="request" open><summary><b>The request, verbatim</b> — the agent froze the criteria below from these words</summary><pre>${esc(t)}</pre></details>`; })()}`
: `<div class="hero"><h1>#${esc(v.issue)} — ${esc(v.title)}</h1>${badge(v.verdict)}</div>
<p class="meta">candidate <code>${esc(v.candidate ?? '–')}</code> · baseline <code>${esc(v.baseline ?? '–')}</code> · criteria <code>ac=${esc(v.ac_hash)}</code> (source: ${esc(v.criteria_source ?? 'done-when')}) · ${esc(coverage)} · ${esc(v.generated_utc ?? '')}</p>
<p class="dim">The agent tested each criterion on the candidate build and on the baseline release. <b>Verified</b> means that the test fails on the baseline and passes on the candidate. You can examine the videos and screenshots to check the result.</p>
<table><thead><tr><th>AC</th><th>Criterion</th><th>Candidate</th><th>Baseline</th><th>Verdict</th></tr></thead><tbody>${summaryRows}</tbody></table>`}
${qHtml}
${acHtml}
${inHtml}
${exHtml}
${noticedHtml}
${(v.notes ?? []).length ? `<h3>Notes</h3><ul>${v.notes.map((n) => `<li>${esc(n)}</li>`).join('')}</ul>` : ''}
<footer>${esc(v.display_name ?? 'Quality Inspector')} · black-box test of the build in a nested environment · e2e ${esc(runs.candidate?.version ?? '')}</footer>
</main>${VIEWER_HTML}</body></html>
`;
writeFileSync(join(outDir, 'index.html'), html);

// A scenario's comment.md is the channel reply's body (docs/scenarios.md → The reply).
const comment = scenario ? [
  `*${v.scenario} — ${v.title}*: ${(VERDICT[v.verdict] ?? [v.verdict])[0]} on \`${v.candidate ?? '–'}\``,
  ...acs.map((ac) => `• ${ac.id} ${ac.name} — ${ac.verdict}${ac.judge && !ac.judge.agree ? ' (the judge disagrees)' : ''}${ac.note ? ` — ${ac.note}` : ''}`),
  'Evidence (videos, screenshots, steps): EVIDENCE_LINK',
].join('\n') : [
  `## ${v.display_name ?? 'Quality Inspector'} — #${v.issue} verdict: ${(VERDICT[v.verdict] ?? [v.verdict])[0]}`,
  `candidate \`${v.candidate ?? '–'}\` · baseline \`${v.baseline ?? '–'}\` · criteria ac=${v.ac_hash} · ${coverage}`,
  '',
  '| AC | criterion | candidate | baseline | verdict |',
  '| --- | --- | --- | --- | --- |',
  ...acs.map((ac) => `| ${ac.id} | ${String(ac.name).replace(/\|/g, '\\|')} | ${ac.cand?.state ?? 'not run'} | ${ac.base?.state ?? 'not run'} | ${ac.verdict} |`),
  '',
  ...(intentVerdict ? [`Intent (what the author wanted): ${INTENT[intentVerdict]}${intents.length ? ` — ${intents.map((x) => `${x.id} ${x.verdict}`).join(', ')}` : ''}${lettersOnly ? '. The criteria are true, but the goal is not met.' : ''}`, ''] : []),
  ...(exps.length ? [`${exps.length} explorations beyond the criteria: ${observations} observations (see evidence)`, ''] : []),
  ...(noticed.length ? [`${noticed.length} noticed in passing, not tested (see evidence)`, ''] : []),
  'Evidence (videos, screenshots, step traces): EVIDENCE_LINK',
].join('\n');
writeFileSync(join(outDir, 'comment.md'), `${comment}\n`);
// proof.json: the screenshots that back the verdicts, for a channel answer's one picture
// (scripts/evidence-sheet.mjs, docs/slack.md → The answer in the thread). Per criterion whose
// verdict a screen can show: its AC still — else the screen at failure — on each side that
// decides the verdict; a row needs the candidate's. Failures first, at most PROOF_MAX rows.
const PROOF = scenario
  ? { regression: ['baseline', 'candidate'], failed: ['candidate'], 'needs-review': ['candidate'], passed: ['candidate'] }
  : { failed: ['candidate'], verified: ['baseline', 'candidate'], inconclusive: ['candidate'] };
const PROOF_MAX = 4;
const proofShot = (ac, ev) => (ev?.shots ?? []).find((s) => String(s.caption).startsWith(`${ac.id}:`))
  ?? (ev?.shots ?? []).find((s) => s.caption === 'screen at failure') ?? null;
const proofRows = regression ? [] : acs.filter((ac) => PROOF[ac.verdict]).map((ac) => ({
  id: ac.id, name: ac.name, verdict: ac.verdict,
  shots: PROOF[ac.verdict].map((side) => {
    const ev = side === 'candidate' ? ac.cand : ac.base;
    const s = proofShot(ac, ev);
    return s && { side, build: (side === 'candidate' ? v.candidate : v.baseline) ?? null, state: ev.state, caption: s.caption, src: s.src };
  }).filter(Boolean),
})).filter((r) => r.shots.some((s) => s.side === 'candidate'))
  .sort((a, b) => Number(!['failed', 'regression'].includes(a.verdict)) - Number(!['failed', 'regression'].includes(b.verdict)));
if (!regression) {
  writeFileSync(join(outDir, 'proof.json'), `${JSON.stringify({
    mode: scenario ? 'scenario' : 'issue', subject: scenario ? String(v.scenario) : `#${v.issue}`, title: v.title ?? '', verdict: v.verdict ?? null,
    candidate: v.candidate ?? null, baseline: v.baseline ?? null, rows: proofRows.slice(0, PROOF_MAX), left_out: Math.max(0, proofRows.length - PROOF_MAX),
  }, null, 2)}\n`);
}
console.log(JSON.stringify({ out: outDir, acs: acs.length, ...(regression ? {} : { proof: Math.min(proofRows.length, PROOF_MAX) }), videos: acs.flatMap((a) => [a.cand?.video, a.base?.video]).filter(Boolean).length, screenshots: acs.flatMap((a) => [...(a.cand?.shots ?? []), ...(a.base?.shots ?? [])]).length,
  ...(intents.length || intentVerdict ? { intents: intents.length, intent_verdict: intentVerdict, intent_videos: intents.flatMap((x) => [x.cand?.video, x.base?.video]).filter(Boolean).length } : {}),
  ...(exps.length ? { explorations: exps.length, observations, exploration_videos: exps.filter((e) => e.cand?.video).length } : {}),
  ...(noticed.length ? { noticed: noticed.length } : {}) }));

// The security run's page: one severity-sorted table; e2e findings keep their video.
function renderSecurity() {
  const ORDER = ['critical', 'high', 'medium', 'low', 'info'];
  const rank = (f) => (f.status === 'fail' ? 0 : f.status === 'skipped' ? 10 : 20) + Math.max(0, ORDER.indexOf(f.severity));
  const findings = [...(v.findings ?? [])].sort((a, b) => rank(a) - rank(b) || String(a.id).localeCompare(String(b.id)));
  const counts = v.counts ?? Object.fromEntries(ORDER.map((s) => [s, findings.filter((f) => f.status === 'fail' && f.severity === s).length]));
  const row = (f) => `<tr><td>${badge(f.severity)}</td><td><code>${esc(f.id)}</code></td><td>${esc(f.target)}</td><td>${stateBadge(f.status)}</td><td>${esc(f.explanation ?? f.reason ?? '')}</td></tr>`;
  const detail = (f) => {
    const ev = f.tag && runs.candidate ? evidence(runs.candidate, f) : null;
    return `<article class="ac"><header><h3>${esc(f.id)} — ${esc(f.target)}</h3>${badge(f.severity)}</header>
  <p>${esc(f.explanation ?? f.reason ?? '')}</p>
  <details open><summary>Evidence</summary><pre>${esc(JSON.stringify(f.evidence ?? {}, null, 2))}</pre></details>
  ${ev ? `<div class="sides">${sideHtml(`Build ${v.candidate ?? ''}`, ev)}</div>` : ''}</article>`;
  };
  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Security ${esc(v.candidate)}</title>
<style>
${CSS}
</style></head><body><main>
<div class="hero"><h1>Security checks — ${esc(v.candidate)}</h1></div>
<p class="meta">${ORDER.map((s) => `${esc(s)} <b>${esc(counts[s] ?? 0)}</b>`).join(' · ')} · skipped <b>${esc(counts.skipped ?? findings.filter((f) => f.status === 'skipped').length)}</b> · ${esc(v.generated_utc ?? '')}</p>
<p class="dim">Black-box checks of the nested product, from the frozen catalogue (docs/security.md). This page is private. Do not send it to a public place.</p>
<table><thead><tr><th>Severity</th><th>Check</th><th>Target</th><th>Status</th><th>Explanation</th></tr></thead><tbody>${findings.map(row).join('')}</tbody></table>
${findings.filter((f) => f.status === 'fail').map(detail).join('')}
${(v.notes ?? []).length ? `<h3>Notes</h3><ul>${v.notes.map((n) => `<li>${esc(n)}</li>`).join('')}</ul>` : ''}
<footer>${esc(v.display_name ?? 'Quality Inspector')} · security run · e2e ${esc(runs.candidate?.version ?? '')}</footer>
</main>${VIEWER_HTML}</body></html>
`;
  writeFileSync(join(outDir, 'index.html'), html);
  console.log(JSON.stringify({ out: outDir, findings: findings.length, failed: findings.filter((f) => f.status === 'fail').length }));
}
