#!/usr/bin/env node
// design-findings.mjs — the design findings register, work/design/findings.json: what the UI
// sweep found (ui-sweep.mjs), what the agent saw reviewing its screenshots, and what tests
// noticed in passing — one stable id per finding (D-<k>, never reused), open until a sweep of
// the same page and viewport no longer finds it. Rationale: docs/ui-sweep.md.
//
//   node design-findings.mjs review-plan <sweep.json> [--max N]
//       -> [{pattern, viewport, shot, reason}]   the shots to review: changed, then new, then most findings
//   node design-findings.mjs merge <sweep.json> [--review <review.json>] [--no-render]
//   node design-findings.mjs merge --noticed-only [--no-render]
//   node design-findings.mjs merge --signals <scored.json> [--field <field.json>] [--no-render]
//       -> {findings, open, resolved, dismissed, new, crops, notes}
//   node design-findings.mjs recheck-plan D-<k>
//       -> {id, status, source, check, severity, pattern, viewport, last_seen, sweep: {pattern, viewports} | null, review, note}
//
// recheck-plan reads the register only: what the operator's "recheck D-<k>" sweeps (docs/ui-sweep.md
// → Recheck). `sweep` is ui-sweep.mjs's --pattern and --viewports for its page and viewport (null for
// a noticed item, which no sweep resolves); `review` — a review finding: its one shot is reviewed
// again before the merge. Exit 2: usage, or no such id.
// --max defaults to config `ui_sweep_review_pages` (10; 0 = none). A review file is
// [{pattern, viewport, check: review:<alignment|spacing|typography|layout|truncation|legibility|other>,
// severity: major|minor, saw, box: {x,y,w,h}|null, confidence: 0..1}] about this sweep's pages;
// an entry that breaks it is rejected with a note, confidence < 0.6 is `suspect`. A sweep resolves
// a sweep finding it did not find again only where its check ran: on a page+viewport it swept
// without an error, `a11y:*` only where axe-core ran on that page (pages[].axe), `layout-shift`
// only where CLS was measured. A review resolves the review findings of the pages it covered
// (the review plan's and the ones it names). One seen again reopens. `dismissed` comes only from
// work/design/DISMISSED.md (| id | dismissed_utc | reason |, the operator's), re-applied on every merge.
// Noticed items (work/issues/*/verdicts-<ac_hash>-<candidate>.json and
// work/scenarios/*/verdicts-<spec_hash>-<build>.json → noticed[]) join as source `noticed` — only
// where, saw and shot are read — and are never resolved by a sweep. `first_seen`, `last_seen` and
// `resolved_build` are build ids: the sweep's `build`, a noticed item's from its file name. A merge
// that changes nothing leaves findings.json untouched (not rewritten, `updated_utc` kept). Crops
// of open findings render to work/design/crops/<id>.jpg by the suite's playwright-core (none
// without it; --no-render skips).
// Field findings (docs/ux-signals.md): --field is the agent's replay of the candidates of
// --signals (ux-signals.mjs score) — [{signal, route, element, build, class, ui, saw, expected,
// steps, shot, video, box, judge: {agree, reason}}]; one id per signal, route and element. The
// numbers come from scored.json only; bug, ux-friction or slow without the judge's agreement is
// kept as not-reproduced. --signals alone refreshes their numbers and resolves an open one once a
// newer build ran a whole period without it passing the thresholds (lib/ux-field.mjs → quietBuild).

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { CLASSES, REPORTED, fingerprint as fieldFp, quietBuild } from './lib/ux-field.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const WORK = resolve(process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work'));
const DESIGN = join(WORK, 'design');
const REGISTER = join(DESIGN, 'findings.json');
const CROPS = join(DESIGN, 'crops');
const flags = {}; const pos = [];
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--no-render' || a === '--noticed-only') flags[a.slice(2)] = true;
  else if (a.startsWith('--')) flags[a.slice(2)] = process.argv[++i];
  else pos.push(a);
}
const usage = 'usage: design-findings.mjs review-plan <sweep.json> [--max N] | merge <sweep.json> [--review FILE] [--no-render] | merge --noticed-only [--no-render] | merge --signals <scored.json> [--field FILE] [--no-render] | recheck-plan D-<k>';
const die = (m) => { console.error(m ? `design-findings: ${m}` : usage); process.exit(2); };
const regValue = (k) => { // a registry key through lib/config.sh → reg: out of range reads as its default
  try {
    return execFileSync('bash', ['-c', `CONFIG="$WORK/CONFIG.md"; . "$LIB/config.sh"; reg "$1"`, '_', k],
      { env: { ...process.env, WORK, LIB: join(here, 'lib') }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return ''; }
};
const readJson = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } };
const ls = (p) => { try { return readdirSync(p).sort(); } catch { return []; } };
const mtime = (p) => { try { return statSync(p).mtimeMs; } catch { return 0; } };
const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const atomic = (p, s) => { mkdirSync(dirname(p), { recursive: true }); writeFileSync(`${p}.tmp`, s); renameSync(`${p}.tmp`, p); };
// Paths in the register are relative to work/ when they lie in it: the backup restores them anywhere.
const rel = (p) => { if (!p) return null; const r = relative(WORK, resolve(p)); return r.startsWith('..') || isAbsolute(r) ? resolve(p) : r; };
const abs = (p) => (!p ? null : isAbsolute(p) ? p : join(WORK, p));
// A build id (as ui-sweep.mjs accepts one); an ISO timestamp is never one (':' is not allowed).
const BUILD = /^(?!\.)[A-Za-z0-9._+-]+$/;
const str = (s, n) => String(s ?? '').replace(/\s+/g, ' ').trim().slice(0, n);

const [cmd, sweepPath] = pos;
if (!['review-plan', 'merge', 'recheck-plan'].includes(cmd)) die();

// ------------------------------------------------------------------ recheck-plan ----
if (cmd === 'recheck-plan') {
  const id = pos[1];
  if (!/^D-\d{1,6}$/.test(String(id ?? ''))) die();
  const f = (readJson(REGISTER)?.findings ?? []).find((x) => x?.id === id);
  if (!f) die(`no finding ${id} in ${REGISTER}`);
  const vp = /^\d{3,4}x\d{3,4}$/.test(String(f.viewport ?? '')) ? f.viewport : null;
  const sweepable = f.source !== 'noticed' && vp && typeof f.pattern === 'string' && f.pattern.startsWith('/');
  console.log(JSON.stringify({
    id, status: f.status, source: f.source, check: f.check, severity: f.severity, pattern: f.pattern, viewport: f.viewport, last_seen: f.last_seen,
    sweep: sweepable ? { pattern: f.pattern, viewports: vp } : null, review: f.source === 'review',
    note: f.source === 'noticed' ? 'noticed in passing: no sweep resolves it — look at the page and say what you see'
      : !sweepable ? `page '${str(f.pattern, 80)}' @ '${str(f.viewport, 20)}' is not one a sweep can repeat`
      : f.status === 'dismissed' ? 'dismissed: the merge keeps it dismissed until "reopen"' : null,
  }, null, 2));
  process.exit(0);
}
if (!sweepPath && !(cmd === 'merge' && (flags['noticed-only'] || flags.signals))) die();
const sweep = sweepPath ? readJson(sweepPath) : null;
if (sweepPath && (!sweep || !Array.isArray(sweep.pages) || !BUILD.test(String(sweep.build ?? '')))) die(`${sweepPath} is not a sweep.json`);
const sweepDir = sweepPath ? dirname(resolve(sweepPath)) : null;
const swept = (sweep?.pages ?? []).filter((p) => p.shot && !p.error);

// ------------------------------------------------------------------ review-plan ----
function reviewPlan(max) {
  const rank = (p) => (p.changed === true ? 0 : p.changed == null ? 1 : 2);
  return swept.map((p, i) => ({ p, i })).sort((a, b) => rank(a.p) - rank(b.p) || b.p.findings.length - a.p.findings.length || a.i - b.i)
    .slice(0, max).map(({ p }) => ({ pattern: p.pattern, viewport: p.viewport, shot: join(sweepDir, p.shot),
      reason: p.changed === true ? `changed since the previous sweep (${Math.round((p.diff ?? 0) * 1000) / 10}% of pixels)`
        : p.changed == null ? 'new: no shot of it in the previous sweep' : `${p.findings.length} finding${p.findings.length === 1 ? '' : 's'}` }));
}
const planMax = (v) => { const n = Number(v); return Number.isInteger(n) && n >= 0 ? n : null; };
const cfgMax = planMax(regValue('ui_sweep_review_pages') || 10) ?? 10;
if (cmd === 'review-plan') {
  const max = flags.max !== undefined ? planMax(flags.max) : cfgMax;
  if (max === null) die(`--max '${flags.max}' is not a whole number`);
  console.log(JSON.stringify(reviewPlan(max), null, 2));
  process.exit(0);
}

// ------------------------------------------------------------------ merge ----
const notes = [];
const before = (() => { try { return readFileSync(REGISTER, 'utf8'); } catch { return null; } })();
const reg = readJson(REGISTER) ?? { schema: 'qi-design/v1', updated_utc: null, next_id: 1, findings: [] };
if (reg.schema !== 'qi-design/v1' || !Array.isArray(reg.findings)) die(`${REGISTER} is not a qi-design/v1 register`);
const idNum = (id) => Number(String(id).replace(/^D-/, '')) || 0;
reg.next_id = Math.max(Number(reg.next_id) || 1, ...reg.findings.map((f) => idNum(f.id) + 1));
const byFp = new Map(reg.findings.map((f) => [f.fingerprint, f]));
const fp = (...parts) => createHash('sha1').update(parts.join('|')).digest('hex').slice(0, 12);
const norm = (s) => String(s ?? '').toLowerCase().replace(/\d+/g, '#').replace(/\s+/g, ' ').trim();
const build = sweep?.build ?? null;
const seenFp = new Set();
let added = 0;

// One sentence a person reads, from a sweep finding.
const cap1 = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const SAW = {
  'overflow-x': (f) => (f.target === 'the page' ? `The page scrolls sideways: ${f.detail}` : `${cap1(f.target)} ${f.detail} and widens the page`),
  offscreen: (f) => `${cap1(f.target)} is ${f.detail}`,
  'clipped-text': (f) => `Text of ${f.target} is clipped (${f.detail})`,
  overlap: (f) => `${cap1(f.target)} overlap: ${f.detail}`,
  'broken-image': (f) => `${cap1(f.target)} does not load`,
  'placeholder-text': (f) => `${cap1(f.target)} ${f.detail}`,
  'tap-target': (f) => `${cap1(f.target)} is too small to tap (${f.detail})`,
  contrast: (f) => `Text of ${f.target} has too little contrast: ${f.detail}`,
  'no-name': (f) => `${cap1(f.target)} has no accessible name`,
  'layout-shift': (f) => `The layout shifts while the page loads (${f.detail})`,
  'console-error': (f) => `The browser console shows an error: ${f.text || f.detail}`,
  'failed-request': (f) => `A request of the page fails: ${f.target}`,
};
const sawOf = (f) => str((SAW[f.check] ?? ((x) => `${cap1(x.target)}: ${x.detail}`))(f), 300);
const okBox = (b) => b && ['x', 'y', 'w', 'h'].every((k) => Number.isFinite(b[k])) && b.w > 0 && b.h > 0
  ? { x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.w), h: Math.round(b.h) } : null;

// seen: the build it was seen in; first: the earliest build of this merge that saw it.
function upsert(source, x, seen, first = seen) {
  if (seenFp.has(x.fingerprint)) return;
  seenFp.add(x.fingerprint);
  let f = byFp.get(x.fingerprint);
  if (!f) {
    f = { id: `D-${reg.next_id++}`, fingerprint: x.fingerprint, source, check: x.check, severity: x.severity, suspect: false,
      pattern: x.pattern, viewport: x.viewport, target: null, saw: '', box: null, shot: null, crop: null,
      first_seen: first, last_seen: seen, status: 'open', resolved_build: null };
    reg.findings.push(f); byFp.set(f.fingerprint, f); added++;
  } else if (!BUILD.test(String(f.first_seen ?? ''))) f.first_seen = first; // a register of wall-clock times: the build now
  const newer = f.shot !== x.shot;
  Object.assign(f, { severity: x.severity, suspect: !!x.suspect, target: x.target ?? null, saw: x.saw, box: x.box ?? null, shot: x.shot ?? null, last_seen: seen });
  if (newer && f.crop) f.crop = null; // a newer shot: its crop is rendered again
  f.resolved_build = null; // seen again: open (a dismissal stays the operator's)
  if (f.status !== 'dismissed') f.status = 'open';
}

// Sweep findings: one per page, viewport, check and normalised target.
for (const p of swept) {
  for (const x of p.findings ?? []) {
    if (!x?.check || !x.target) continue;
    upsert('sweep', { fingerprint: fp(p.pattern, p.viewport, x.check, norm(x.target)), check: x.check, severity: x.severity === 'major' ? 'major' : 'minor',
      pattern: p.pattern, viewport: p.viewport, target: str(x.target, 200), saw: sawOf(x), box: okBox(x.box), shot: rel(join(sweepDir, p.shot)) }, build);
  }
}

// Review findings: what the agent saw on a shot; located by a coarse bucket of the box's centre.
const RUBRIC = new Set(['alignment', 'spacing', 'typography', 'layout', 'truncation', 'legibility', 'other'].map((k) => `review:${k}`));
const reviewed = new Set();
if (flags.review) {
  const rv = readJson(flags.review);
  if (!sweep) notes.push('--review needs a sweep: ignored');
  else if (!Array.isArray(rv)) notes.push(`${flags.review} is not a JSON list: no review merged`);
  else {
    for (const r of reviewPlan(cfgMax)) reviewed.add(`${r.pattern}|${r.viewport}`);
    const pageOf = new Map(swept.map((p) => [`${p.pattern}|${p.viewport}`, p]));
    rv.forEach((r, i) => {
      const bad = (why) => notes.push(`review entry ${i + 1} rejected: ${why}`);
      if (!r || typeof r !== 'object') return bad('not an object');
      const key = `${r.pattern}|${r.viewport}`;
      if (!pageOf.has(key)) return bad(`${r.pattern} @${r.viewport} is not a page of this sweep`);
      if (!RUBRIC.has(r.check)) return bad(`check '${str(r.check, 40)}' is not one of ${[...RUBRIC].join(', ')}`);
      if (!['major', 'minor'].includes(r.severity)) return bad(`severity '${str(r.severity, 20)}' is not major or minor`);
      if (!str(r.saw, 300)) return bad('no saw');
      const box = r.box == null ? null : okBox(r.box);
      if (r.box != null && !box) return bad('box is not {x, y, w, h}');
      const c = Number(r.confidence);
      if (r.confidence == null || !Number.isFinite(c) || c < 0 || c > 1) return bad('confidence is not 0..1');
      reviewed.add(key);
      const bucket = box ? `${Math.floor((box.x + box.w / 2) / 160)},${Math.floor((box.y + box.h / 2) / 160)}` : 'page';
      upsert('review', { fingerprint: fp(r.pattern, r.viewport, r.check, bucket), check: r.check, severity: r.severity, suspect: c < 0.6,
        pattern: r.pattern, viewport: r.viewport, target: null, saw: str(r.saw, 300), box, shot: rel(join(sweepDir, pageOf.get(key).shot)) }, build);
    });
  }
}

// Noticed in passing: only where, saw and shot of each item — nothing else of a verdicts file.
// Its build is the file name's (verdicts-<hash>-<build>.json); files oldest first, so an item in
// several files is first seen in the oldest and last seen in the newest.
const vfiles = [];
for (const kind of ['issues', 'scenarios']) {
  for (const d of ls(join(WORK, kind))) {
    for (const f of ls(join(WORK, kind, d)).filter((x) => /^verdicts-.*\.json$/.test(x))) {
      const m = /^verdicts-[^-]+-(.+)\.json$/.exec(f);
      if (!m || !BUILD.test(m[1])) { notes.push(`${kind}/${d}/${f}: not verdicts-<hash>-<build>.json — its noticed items skipped`); continue; }
      vfiles.push({ kind, d, f, b: m[1], t: mtime(join(WORK, kind, d, f)) });
    }
  }
}
const noticed = new Map();
for (const { kind, d, f, b } of vfiles.sort((x, y) => x.t - y.t || `${x.kind}/${x.d}/${x.f}`.localeCompare(`${y.kind}/${y.d}/${y.f}`))) {
  const v = readJson(join(WORK, kind, d, f));
  for (const n of Array.isArray(v?.noticed) ? v.noticed : []) {
    const where = str(n?.where, 200); const saw = str(n?.saw, 300);
    if (!where || !saw) continue;
    const shot = typeof n.shot === 'string' && n.shot ? (isAbsolute(n.shot) ? n.shot : join(WORK, kind, d, n.shot)) : null;
    const x = { fingerprint: fp(where, '-', 'noticed', norm(saw)), check: 'noticed', severity: 'minor', pattern: where, viewport: '-',
      target: null, saw, box: null, shot: shot && existsSync(shot) ? rel(shot) : null };
    noticed.set(x.fingerprint, { x, first: noticed.get(x.fingerprint)?.first ?? b, last: b });
  }
}
for (const { x, first, last } of noticed.values()) upsert('noticed', x, last, first);

// Field findings: the agent's replay of a real-user signal; the numbers are scored.json's.
const scored = flags.signals ? readJson(flags.signals) : null;
if (flags.signals && scored?.schema !== 'qi-ux-scored/v1') die(`${flags.signals} is not a qi-ux-scored/v1 file`);
if (flags.field && !scored) die('--field needs --signals <scored.json>');
const candidate = new Map((scored?.candidates ?? []).map((c) => [`${c.fingerprint}|${c.build}`, c]));
const metrics = (c) => ({ signal: c.signal, users: c.users, events: c.events ?? null, views: c.views ?? null, rate: c.rate, prev_rate: c.prev_rate ?? null,
  trend: c.trend ?? null, regression: !!c.regression, build: c.build, period: scored.period });
const evidence = (p) => (typeof p === 'string' && p && existsSync(abs(p)) ? rel(abs(p)) : null);
if (flags.field) {
  const rv = readJson(flags.field);
  if (!Array.isArray(rv)) notes.push(`${flags.field} is not a JSON list: no field finding merged`);
  else rv.forEach((r, i) => {
    const bad = (why) => notes.push(`field entry ${i + 1} rejected: ${why}`);
    if (!r || typeof r !== 'object') return bad('not an object');
    const key = fieldFp(r.signal, r.route, r.element ?? null);
    const c = candidate.get(`${key}|${r.build}`);
    if (!c) return bad(`${str(r.signal, 20)} on ${str(r.route, 80)} @ ${str(r.build, 40)} is no candidate of ${flags.signals}`);
    if (!CLASSES.includes(r.class)) return bad(`class '${str(r.class, 20)}' is not one of ${CLASSES.join(', ')}`);
    if (!str(r.saw, 300)) return bad('no saw');
    const judge = r.judge && typeof r.judge === 'object' ? { agree: r.judge.agree === true, reason: str(r.judge.reason, 300) || null } : null;
    let cls = r.class;
    if (REPORTED.has(cls) && !judge?.agree) { notes.push(`field entry ${i + 1}: the judge did not confirm it — kept as not-reproduced`); cls = 'not-reproduced'; }
    upsert('field', { fingerprint: key, check: `field:${c.signal}`, severity: cls === 'bug' || (REPORTED.has(cls) && c.regression) ? 'major' : 'minor',
      pattern: c.route, viewport: '-', target: c.element, saw: str(r.saw, 300), box: r.box == null ? null : okBox(r.box), shot: evidence(r.shot) }, c.build);
    byFp.get(key).field = { ...metrics(c), class: cls, ui: r.ui !== false, expected: str(r.expected, 300) || null,
      steps: (Array.isArray(r.steps) ? r.steps : []).map((x) => str(x, 200)).filter(Boolean).slice(0, 15), video: evidence(r.video), judge };
  });
}

// Resolution: not seen again on a page+viewport this merge covered, by a check that ran there.
const sweptPage = new Map(swept.map((p) => [`${p.pattern}|${p.viewport}`, p]));
const ran = (p, check) => (String(check).startsWith('a11y:') ? p.axe === true : check === 'layout-shift' ? p.cls != null : true);
for (const f of reg.findings) {
  if (seenFp.has(f.fingerprint) || f.source === 'noticed') continue;
  const k = `${f.pattern}|${f.viewport}`;
  const covered = f.source === 'sweep' ? sweptPage.has(k) && ran(sweptPage.get(k), f.check) : f.source === 'review' ? reviewed.has(k) : false;
  if (!covered || f.resolved_build || f.status === 'resolved') continue;
  f.resolved_build = build;
  if (f.status !== 'dismissed') f.status = 'resolved';
}
if (scored) {
  for (const f of reg.findings) {
    if (f.source !== 'field' || seenFp.has(f.fingerprint)) continue;
    const c = candidate.get(`${f.fingerprint}|${f.last_seen}`);
    if (c && f.field) f.field = { ...f.field, ...metrics(c) };
    if (f.status === 'resolved' || f.resolved_build) continue;
    const b = quietBuild(f, scored);
    if (b) { f.resolved_build = b; if (f.status !== 'dismissed') f.status = 'resolved'; }
  }
}
// Dismissed: exactly the ids of DISMISSED.md; one taken off it returns to what the sweeps say.
const dismissed = new Set((() => { try { return readFileSync(join(DESIGN, 'DISMISSED.md'), 'utf8'); } catch { return ''; } })()
  .split('\n').filter((l) => l.trim().startsWith('|')).slice(2).map((l) => l.split('|')[1]?.trim()).filter((x) => /^D-\d+$/.test(x)));
for (const f of reg.findings) {
  if (dismissed.has(f.id)) f.status = 'dismissed';
  else if (f.status === 'dismissed') f.status = f.resolved_build ? 'resolved' : 'open';
}
reg.findings.sort((a, b) => idNum(a.id) - idNum(b.id));

// ------------------------------------------------------------------ crops ----
async function renderCrops(jobs) {
  if (!jobs.length) return 0;
  let pw;
  try {
    const req = createRequire(process.env.QI_PLAYWRIGHT_FROM ?? join(WORK, 'suite', 'package.json'));
    let p; try { p = req.resolve('playwright-core'); } catch { p = createRequire(req.resolve('@e2e-dev/web')).resolve('playwright-core'); }
    pw = await import(pathToFileURL(p).href);
  } catch { notes.push('crops: playwright-core is not installed in work/suite — none rendered'); return 0; }
  let browser; let n = 0;
  try {
    browser = await (pw.chromium ?? pw.default.chromium).launch();
    const page = await browser.newPage();
    await page.route('**', (r) => r.abort());
    mkdirSync(CROPS, { recursive: true });
    for (const { f, src, dst } of jobs) {
      const mime = src.endsWith('.png') ? 'image/png' : 'image/jpeg';
      const data = `data:${mime};base64,${readFileSync(src).toString('base64')}`;
      const out = await page.evaluate(async ({ data, box, W }) => {
        const img = new Image(); img.src = data; await img.decode();
        const iw = img.naturalWidth; const ih = img.naturalHeight;
        let sx = 0; let sy = 0; let sw = iw; let sh = Math.min(ih, Math.round(iw * 1.25));
        if (box) {
          sx = Math.max(0, box.x - 40); sy = Math.max(0, box.y - 40);
          sw = Math.min(iw, box.x + box.w + 40) - sx; sh = Math.min(ih, box.y + box.h + 40) - sy;
          if (sw <= 0 || sh <= 0) { sx = 0; sy = 0; sw = iw; sh = Math.min(ih, Math.round(iw * 1.25)); box = null; }
        }
        const s = W / sw;
        sh = Math.min(sh, Math.round((W * 2) / s)); // at most twice as tall as wide
        const c = document.createElement('canvas'); c.width = W; c.height = Math.max(1, Math.round(sh * s));
        const g = c.getContext('2d'); g.fillStyle = '#fff'; g.fillRect(0, 0, c.width, c.height);
        g.drawImage(img, sx, sy, sw, sh, 0, 0, c.width, c.height);
        if (box) { g.strokeStyle = '#e00'; g.lineWidth = 3; g.strokeRect((box.x - sx) * s, (box.y - sy) * s, box.w * s, box.h * s); }
        return c.toDataURL('image/jpeg', 0.7);
      }, { data, box: f.box, W: 360 }).catch(() => null);
      if (!out) { notes.push(`crop ${f.id}: the shot could not be drawn`); continue; }
      writeFileSync(`${dst}.tmp`, Buffer.from(out.split(',')[1], 'base64')); renameSync(`${dst}.tmp`, dst);
      f.crop = rel(dst); n++;
    }
  } catch (e) { notes.push(`crops: ${String(e.message).split('\n')[0].slice(0, 120)}`); } finally { await browser?.close().catch(() => {}); }
  return n;
}
const jobs = [];
for (const f of reg.findings) {
  const src = abs(f.shot); const dst = join(CROPS, `${f.id}.jpg`);
  if (f.crop && !existsSync(abs(f.crop))) f.crop = null;
  if (f.status !== 'open' || !src || !existsSync(src)) continue;
  if (!f.crop || mtime(src) > mtime(dst)) jobs.push({ f, src, dst });
}
const crops = flags['no-render'] ? 0 : await renderCrops(jobs);
const ids = new Set(reg.findings.map((f) => f.id));
for (const x of ls(CROPS)) if (!ids.has(x.replace(/\.jpg(\.tmp)?$/, ''))) { try { rmSync(join(CROPS, x)); } catch { /* next merge */ } }

// Written only when something changed: the catalog's hash of it stays put across idle merges.
const text = (u) => `${JSON.stringify({ ...reg, updated_utc: u }, null, 2)}\n`;
if (text(reg.updated_utc ?? null) !== before) atomic(REGISTER, text(now()));
const count = (s) => reg.findings.filter((f) => f.status === s).length;
console.log(JSON.stringify({ findings: reg.findings.length, open: count('open'), resolved: count('resolved'), dismissed: count('dismissed'), new: added, crops, notes }));
