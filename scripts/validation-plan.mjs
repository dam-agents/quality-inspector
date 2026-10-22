#!/usr/bin/env node
// validation-plan.mjs — the form-validation plan for one build, derived from the UI map's
// `forms` (ui-inventory.mjs): per field, the inputs its type and DOM constraints make
// interesting, each with the oracle it is judged by; tests/validation.e2e.ts runs them.
// Pure: no network, no browser. Rationale and the severity of each oracle: docs/validation.md.
//
//   node validation-plan.mjs <inventory.json> --build <c> [--out <dir>] [--max-cases 60] [--base URL] [--dry-run]
//
// Writes <out>/plan.json ({build, generated_utc, base, forms, cases, skipped, notes}) and prints
// a summary; --dry-run prints the whole plan and writes nothing. Default <out>:
// work/validation/<build>. A form is never planned when it has no submit button, when its
// submit or name is destructive (lib/danger.mjs), when it holds a password field, or when the
// profile's profile.json → validation.exclude names its page pattern, form or submit exactly.

import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DANGER } from './lib/danger.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const flags = {}; const pos = [];
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--dry-run') flags.dry = true;
  else if (a.startsWith('--')) flags[a.slice(2)] = process.argv[++i];
  else pos.push(a);
}
const usage = 'usage: validation-plan.mjs <inventory.json> --build <c> [--out DIR] [--max-cases N] [--base URL] [--dry-run]';
if (!pos[0]) { console.error(usage); process.exit(2); }

const WORK = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
// The config and the profile come through the one reader (scripts/lib/config.sh, profile.sh).
const sh = (expr) => {
  try {
    return execFileSync('bash', ['-c', `CONFIG="$WORK/CONFIG.md"; . "$LIB/config.sh"; . "$LIB/profile.sh"; ${expr}`],
      { env: { ...process.env, WORK, LIB: join(here, 'lib') }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return ''; }
};
let inv;
try { inv = JSON.parse(readFileSync(pos[0], 'utf8')); } catch (e) { console.error(`cannot read ${pos[0]}: ${e.message}`); process.exit(2); }
const base = (() => { try { return new URL(flags.base ?? inv.base ?? 'http://localhost'); } catch { return null; } })();
if (!base || !['localhost', '127.0.0.1'].includes(base.hostname)) { console.error(`refusing ${base?.origin ?? flags.base}: only the nested product on localhost`); process.exit(2); }
const build = flags.build ?? inv.build;
if (!build) { console.error(usage); process.exit(2); }
const profileDir = sh('profile_dir');
const profile = (() => { try { return JSON.parse(readFileSync(join(profileDir, 'profile.json'), 'utf8')); } catch { return {}; } })();
const exclude = Array.isArray(profile.validation?.exclude) ? profile.validation.exclude.filter((x) => typeof x === 'string') : [];
const maxCases = Math.max(1, Math.floor(Number(flags['max-cases'] ?? (sh('cfg validation_max_cases') || 60))) || 60);

// ------------------------------------------------------------------ the plan (pure) ----
const TEXT = new Set(['text', 'search', 'textarea', 'email', 'url', 'tel']); // whitespace, length
const FREE = new Set(['text', 'search', 'textarea']); // unicode, rtl, emoji, html
const WRONG = { email: 'not-an-email', number: 'abc', url: 'not a url', date: '2026-13-45' };
const VALUES = { unicode: 'Žluťoučký kůň — ünïcödé ✓', rtl: '‮abc‬ שלום', emoji: '🙂👍🏽🧪', html: '<b>qa</b><img src=x>' };
const ORACLE = {
  'required-empty': 'refused-visibly', 'max-len+1': 'refused-visibly', 'wrong-type': 'refused-visibly', 'num-below': 'refused-visibly',
  'num-above': 'refused-visibly', 'pattern-miss': 'refused-visibly', 'max-len': 'refused-or-intact', long: 'refused-or-intact',
  unicode: 'refused-or-intact', rtl: 'refused-or-intact', emoji: 'refused-or-intact', html: 'refused-or-intact', 'duplicate-submit': 'single-effect',
};
const isNum = (x) => typeof x === 'number' && Number.isFinite(x);
// A valid value for a field the case does not test; k makes the created object recognizable.
function filler(f, k) {
  switch (f.type) {
    case 'email': return `qa-val-${k}@example.invalid`;
    case 'url': return 'https://example.invalid/qa';
    case 'tel': return '+420000000000';
    case 'date': return '2026-01-15';
    case 'datetime-local': return '2026-01-15T12:00';
    case 'time': return '12:00';
    case 'month': return '2026-01';
    case 'week': return '2026-W03';
    case 'color': return '#336699';
    case 'number': case 'range': {
      const v = isNum(f.min) ? f.min : 1;
      return String(isNum(f.max) && v > f.max ? f.max : v);
    }
    case 'checkbox': return { check: true };
    case 'select': return { select: 'first' };
    case 'radio': return null;
    default: return `qa-val-${k}`.padEnd(f.minlength ?? 0, 'x').slice(0, f.maxlength || undefined);
  }
}
const patternMatches = (p, v) => { try { return new RegExp(`^(?:${p})$`, 'u').test(v); } catch { return false; } };

function kindsFor(f) {
  const out = [];
  const add = (kind, value, extra = {}) => out.push({ kind, value, ...extra });
  if (f.required && !['select', 'radio', 'range', 'color'].includes(f.type)) add('required-empty', '');
  if (TEXT.has(f.type)) {
    add('whitespace', '   ', { oracle: f.required ? 'refused-visibly' : 'refused-or-intact' });
    if (isNum(f.maxlength) && f.maxlength > 0) {
      add('max-len', 'a'.repeat(f.maxlength), { maxlength: f.maxlength });
      add('max-len+1', 'a'.repeat(f.maxlength + 1), { maxlength: f.maxlength });
    } else add('long', 'a'.repeat(5000));
  }
  if (FREE.has(f.type)) for (const k of ['unicode', 'rtl', 'emoji', 'html']) add(k, VALUES[k]);
  if (WRONG[f.type]) add('wrong-type', WRONG[f.type]);
  if (f.type === 'number' && isNum(f.min)) add('num-below', String(f.min - 1));
  if (f.type === 'number' && isNum(f.max)) add('num-above', String(f.max + 1));
  if (f.pattern && TEXT.has(f.type) && !patternMatches(f.pattern, '!!!')) add('pattern-miss', '!!!');
  return out;
}

function buildPlan() {
  const skipped = []; const notes = []; const planned = [];
  const routes = Object.entries(inv.routes ?? {}).filter(([, r]) => r && r.example && !r.error && !r.redirected)
    .sort(([a], [b]) => a.localeCompare(b));
  let anyForms = false;
  for (const [page, r] of routes) {
    const forms = (Array.isArray(r.forms) ? r.forms : []).map((f, i) => ({ ...f, name: f.name || `form-${i + 1}` }))
      .sort((a, b) => a.name.localeCompare(b.name));
    for (const f of forms) {
      anyForms = true;
      const skip = (reason) => skipped.push({ page, form: f.name, reason });
      const fields = (Array.isArray(f.fields) ? f.fields : []).filter((x) => x && x.label);
      if (!f.submit) { skip('no submit button'); continue; }
      if (DANGER.test(f.submit) || DANGER.test(f.name)) { skip(`destructive: "${DANGER.test(f.submit) ? f.submit : f.name}"`); continue; }
      const ex = exclude.find((x) => x === page || x === f.name || x === f.submit);
      if (ex) { skip(`excluded by the profile (validation.exclude: "${ex}")`); continue; }
      if (fields.some((x) => x.type === 'password')) { skip('has a password field (a submit could change credentials)'); continue; }
      if (!fields.length) { skip('no labelled field'); continue; }
      if (fields.some((x) => x.type === 'radio')) notes.push(`${page} · ${f.name}: radio buttons are left at their default`);
      planned.push({ page, example: r.example, form: f.name, submit: f.submit, fields: fields.slice().sort((a, b) => a.label.localeCompare(b.label)) });
    }
  }
  if (!anyForms) notes.push('the UI map has no forms (built before the validation module, or the product shows none) — rebuild it');

  // Every case in id order: page, form, field, kind (in kindsFor's order); duplicate-submit
  // last in its form. Ids are numbered before the cap, so a case keeps its id whatever the cap.
  const all = [];
  for (const p of planned) {
    for (const f of p.fields) for (const c of kindsFor(f)) all.push({ p, f, ...c });
    all.push({ p, f: null, kind: 'duplicate-submit', value: null });
  }
  all.forEach((c, i) => { c.k = i + 1; });
  const cases = all.map((c) => {
    const fill = {};
    for (const o of c.p.fields) {
      if (o === c.f || !(o.required || c.kind === 'duplicate-submit')) continue;
      const v = filler(o, c.k);
      if (v !== null) fill[o.label] = v;
    }
    return {
      id: `VAL-${c.k}`, page: c.p.page, example: c.p.example, form: c.p.form, submit: c.p.submit,
      field: c.f?.label ?? null, type: c.f?.type ?? null, kind: c.kind, value: c.value, fill,
      oracle: c.oracle ?? ORACLE[c.kind], ...(c.maxlength != null ? { maxlength: c.maxlength } : {}),
    };
  });

  // The cap: round-robin over forms so every form is covered; within a form, round-robin
  // over its fields, its duplicate-submit after them.
  let chosen = cases;
  if (cases.length > maxCases) {
    const queues = planned.map((p) => {
      const mine = cases.filter((c) => c.page === p.page && c.form === p.form && c.submit === p.submit);
      const byField = p.fields.map((f) => mine.filter((c) => c.field === f.label));
      const q = [];
      for (let i = 0; byField.some((l) => i < l.length); i++) for (const l of byField) if (l[i]) q.push(l[i]);
      return q.concat(mine.filter((c) => c.kind === 'duplicate-submit'));
    });
    const keep = new Set();
    for (let i = 0; keep.size < maxCases && queues.some((q) => i < q.length); i++) {
      for (const q of queues) { if (keep.size >= maxCases) break; if (q[i]) keep.add(q[i].id); }
    }
    chosen = cases.filter((c) => keep.has(c.id));
    notes.push(`capped at ${maxCases} of ${cases.length} cases (max-cases), round-robin over ${planned.length} forms`);
  }
  return { forms: planned.length, cases: chosen, skipped, notes };
}

const { forms, cases, skipped, notes } = buildPlan();
const plan = { build, generated_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), base: base.origin, forms, cases, skipped, notes };
if (flags.dry) { console.log(JSON.stringify(plan, null, 2)); process.exit(0); }
const out = flags.out ?? join(WORK, 'validation', String(build));
mkdirSync(out, { recursive: true });
writeFileSync(join(out, 'plan.json'), `${JSON.stringify(plan, null, 2)}\n`);
console.log(JSON.stringify({ plan: join(out, 'plan.json'), forms, cases: cases.length, skipped: skipped.length, notes }));
