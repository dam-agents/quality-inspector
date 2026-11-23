// property-rules.mjs — the pure rules of the property module (docs/property.md): the frozen
// properties.json and its closed vocabulary, the generated inputs as fast-check arbitraries, the
// templates of a step, the paths into an answer, the assertions, and a design finding's Ref and
// severity. No network, no browser, no file system: property.mjs calls it, the offline tests too.
//
// A property: {id: PROP-<k>, kind, statement, source, input?, steps?, expect?, page?, invariants?, vary?}.
// A step: {as, api: {method, path, body?}} | {as, cli: [argv…]} | {as, ui: {open}}, `repeat` 1..3.
// An answer (what a step's `as` names): {status, body, text} — the API's HTTP status and JSON body,
// the CLI's exit code and its stdout as JSON, the UI page's visible text (status 200).

import { DANGER } from './danger.mjs';
import { refOf } from './design-rules.mjs';

export const KINDS = ['round-trip', 'idempotent', 'invariant', 'cross-surface', 'design'];
export const METHODS = ['GET', 'POST', 'PUT', 'PATCH'];
export const MIX = ['unicode', 'whitespace', 'long', 'boundary', 'html'];
export const OPS = ['>=', '<=', '>', '<', '==', '!='];
// A design invariant -> the check of lib/ui-checks.mjs that breaks it, its register and Desk severity.
export const DESIGN = {
  'no-sideways-scroll': { check: 'overflow-x', severity: 'major', desk: 'high', expected: 'the page does not scroll sideways' },
  'controls-reachable': { check: 'offscreen', severity: 'major', desk: 'high', expected: 'every control stays on the screen and reachable' },
  'no-clipped-text': { check: 'clipped-text', severity: 'minor', desk: 'medium', expected: 'no text is cut off' },
  'no-overlap': { check: 'overlap', severity: 'minor', desk: 'medium', expected: 'no text or control overlaps another' },
  contrast: { check: 'contrast', severity: 'minor', desk: 'medium', expected: 'text contrast stays at 4.5:1 or more (3:1 for large text)' },
};
export const LOCALES = /^[a-z]{2,3}(?:-[A-Z]{2})?$/;
// Hard caps, whatever a properties.json says (docs/property.md → Caps).
export const CAP = { properties: 50, steps: 8, argv: 30, text: 2000, width: [240, 2560], zoom: [1, 4], textLength: 400, uiRuns: 20, runs: 500 };

const str = (s) => typeof s === 'string' && s.trim() !== '';
const isObj = (o) => o && typeof o === 'object' && !Array.isArray(o);
const NAME = /^[a-z][a-z0-9_]{0,30}$/;

// ------------------------------------------------------------------ the frozen file
// -> [] when it is valid, else one reason per problem ("PROP-2: …").
export function validate(doc) {
  const bad = [];
  if (!isObj(doc) || !Array.isArray(doc.properties)) return ['not {build, properties: [...]}'];
  if (!doc.properties.length) bad.push('no properties');
  if (doc.properties.length > CAP.properties) bad.push(`${doc.properties.length} properties, the cap is ${CAP.properties}`);
  const ids = new Set();
  doc.properties.forEach((p, i) => {
    const at = isObj(p) && str(p.id) ? p.id : `property ${i + 1}`;
    const no = (why) => bad.push(`${at}: ${why}`);
    if (!isObj(p)) return no('not an object');
    if (!/^PROP-\d{1,4}$/.test(p.id ?? '')) no('id is not PROP-<k>');
    if (ids.has(p.id)) no('id used twice');
    ids.add(p.id);
    if (!KINDS.includes(p.kind)) return no(`kind '${p.kind}' is not one of ${KINDS.join(', ')}`);
    if (!str(p.statement)) no('no statement');
    if (!str(p.source)) no('no source: quote what the invariant comes from');
    if (p.kind === 'design') return designBad(p).forEach(no);
    const surfaces = stepsBad(p, no);
    if (p.input !== undefined) inputBad(p.input).forEach(no);
    if (!Array.isArray(p.expect) || !p.expect.length) return no('no expect');
    const names = new Set((p.steps ?? []).map((s) => s?.as));
    p.expect.forEach((e, j) => assertionBad(e, names).forEach((w) => no(`expect ${j + 1}: ${w}`)));
    const has = (k) => p.expect.some((e) => isObj(e) && k in e);
    if (p.kind === 'round-trip' && !has('equal') && !has('contains')) no('a round-trip needs an equal or contains');
    if (p.kind === 'idempotent' && (!has('delta') || !(p.steps ?? []).some((s) => Number(s?.repeat) >= 2))) no('an idempotent property needs a step with repeat 2..3 and a delta');
    if (p.kind === 'invariant' && !['compare', 'sum', 'count', 'ok'].some(has)) no('an invariant needs a compare, sum, count or ok');
    if (p.kind === 'cross-surface' && surfaces.size < 2) no('a cross-surface property needs steps on two surfaces');
  });
  return bad;
}

function stepsBad(p, no) {
  const surfaces = new Set();
  if (!Array.isArray(p.steps) || !p.steps.length) { no('no steps'); return surfaces; }
  if (p.steps.length > CAP.steps) no(`${p.steps.length} steps, the cap is ${CAP.steps}`);
  const names = new Set();
  p.steps.forEach((s, j) => {
    const at = `step ${j + 1}`;
    if (!isObj(s) || !NAME.test(s.as ?? '')) return no(`${at}: no 'as' name (a-z, 0-9, _)`);
    if (names.has(s.as) || s.as === 'input' || s.as === 'stamp') no(`${at}: name '${s.as}' is taken`);
    names.add(s.as);
    if (s.repeat !== undefined && !(Number.isInteger(s.repeat) && s.repeat >= 1 && s.repeat <= 3)) no(`${at}: repeat is not 1..3`);
    const kinds = ['api', 'cli', 'ui'].filter((k) => k in s);
    if (kinds.length !== 1) return no(`${at}: exactly one of api, cli, ui`);
    surfaces.add(kinds[0]);
    if (s.api) {
      const { method, path } = s.api;
      if (!METHODS.includes(method)) no(`${at}: method '${method}' is not one of ${METHODS.join(', ')} — never a delete`);
      if (!localPath(path)) no(`${at}: path must start with one '/' and stay on the product`);
      if (DANGER.test(String(path ?? ''))) no(`${at}: path names a destructive action`);
      if ('body' in s.api && !(isObj(s.api.body) || Array.isArray(s.api.body))) no(`${at}: body is not JSON object or list`);
      if (DANGER.test(JSON.stringify(s.api.body ?? '').replace(/\{[a-z_.\[\]0-9]+\}/g, ''))) no(`${at}: body names a destructive action`);
    }
    if (s.cli) {
      if (!Array.isArray(s.cli) || !s.cli.length || s.cli.length > CAP.argv || !s.cli.every((a) => typeof a === 'string')) no(`${at}: cli is not a list of 1..${CAP.argv} strings`);
      else if (s.cli.some((a) => DANGER.test(a.replace(/\{[a-z_.\[\]0-9]+\}/g, '')))) no(`${at}: cli names a destructive action`);
    }
    if (s.ui && !localPath(s.ui.open)) no(`${at}: ui.open must be a path that starts with one '/'`);
  });
  return surfaces;
}
const localPath = (p) => typeof p === 'string' && /^\/(?!\/)/.test(p) && !/[\s\\]/.test(p) && !/^\/[^/]*:/.test(p);

export function inputBad(i) {
  const bad = [];
  if (!isObj(i)) return ['input is not an object'];
  if (i.type === 'text') {
    const min = i.min ?? 0; const max = i.max ?? 200;
    if (!(Number.isInteger(min) && Number.isInteger(max) && min >= 0 && max >= min && max <= CAP.text)) bad.push(`input: min/max not 0 <= min <= max <= ${CAP.text}`);
    if (i.mix !== undefined && !(Array.isArray(i.mix) && i.mix.length && i.mix.every((m) => MIX.includes(m)))) bad.push(`input: mix not a list of ${MIX.join(', ')}`);
  } else if (i.type === 'integer') {
    if (!(Number.isSafeInteger(i.min) && Number.isSafeInteger(i.max) && i.max >= i.min)) bad.push('input: integer needs min <= max');
  } else bad.push(`input: type '${i.type}' is not text or integer`);
  return bad;
}

// A reference to an answer: `<as>.<path>` with `.key`, `[n]` and `[]` (every element), or {input}/{stamp}.
const REF = /^([a-z][a-z0-9_]{0,30})((?:\.[A-Za-z0-9_$-]+|\[\d*\])*)$/;
function refBad(r, names) {
  if (typeof r === 'number' || typeof r === 'boolean' || r === null) return [];
  if (typeof r !== 'string') return [`'${JSON.stringify(r)}' is not a reference or a value`];
  if (r === '{input}' || r === '{stamp}') return [];
  const m = REF.exec(r);
  if (!m) return [`'${r}' is not <as>.<path>`];
  return names.has(m[1]) ? [] : [`'${m[1]}' names no step`];
}
export function assertionBad(e, names) {
  if (!isObj(e)) return ['not an object'];
  const k = Object.keys(e).filter((x) => x !== 'normalize' && x !== 'equals' && x !== 'max');
  if (k.length !== 1) return ['exactly one of ok, equal, contains, compare, sum, count, delta'];
  const v = e[k[0]];
  if (e.normalize !== undefined && !['none', 'trim', 'nfc', 'trim+nfc'].includes(e.normalize)) return [`normalize '${e.normalize}' is not none, trim, nfc or trim+nfc`];
  switch (k[0]) {
    case 'ok': return names.has(v) ? [] : [`ok: '${v}' names no step`];
    case 'equal': case 'contains':
      return Array.isArray(v) && v.length === 2 ? v.flatMap((r) => refBad(r, names)) : [`${k[0]}: not [a, b]`];
    case 'compare':
      if (!Array.isArray(v) || v.length !== 3 || !OPS.includes(v[1])) return [`compare: not [a, op, b] with op one of ${OPS.join(' ')}`];
      return [...refBad(v[0], names), ...refBad(v[2], names)];
    case 'sum': case 'count':
      return [...refBad(v, names), ...(e.equals === undefined ? [`${k[0]}: no equals`] : refBad(e.equals, names))];
    case 'delta':
      if (!Array.isArray(v) || v.length !== 2) return ['delta: not [before, after]'];
      if (!(Number.isInteger(e.max) && e.max >= 0)) return ['delta: max is not a whole number >= 0'];
      return v.flatMap((r) => refBad(r, names));
    default: return [`'${k[0]}' is not an assertion`];
  }
}

function designBad(p) {
  const bad = [];
  if (!localPath(p.page)) bad.push('page must be a path that starts with one \'/\'');
  if (!Array.isArray(p.invariants) || !p.invariants.length || !p.invariants.every((x) => x in DESIGN)) bad.push(`invariants not a list of ${Object.keys(DESIGN).join(', ')}`);
  const v = p.vary ?? {};
  if (!isObj(v)) return [...bad, 'vary is not an object'];
  const range = (k, [lo, hi], num = Number.isInteger) => {
    if (v[k] === undefined) return;
    if (!(Array.isArray(v[k]) && v[k].length === 2 && v[k].every(num) && v[k][0] <= v[k][1] && v[k][0] >= lo && v[k][1] <= hi)) bad.push(`vary.${k} is not [min, max] within ${lo}..${hi}`);
  };
  range('width', CAP.width); range('zoom', CAP.zoom, (n) => Number.isFinite(n)); range('text_length', [0, CAP.textLength]);
  if (v.locales !== undefined && !(Array.isArray(v.locales) && v.locales.length && v.locales.length <= 12 && v.locales.every((l) => LOCALES.test(l)))) bad.push('vary.locales is not a list of 1..12 locales like en-US');
  return bad;
}

// ------------------------------------------------------------------ generated inputs
// A fast-check arbitrary for a property's `input` (fc: the suite's fast-check module). Text mixes
// graphemes of every script and emoji, whitespace around a value, values at and near the bounds,
// long values and HTML-like text; integers the range and its bounds, one past each bound too.
export function arbitrary(fc, input = { type: 'text' }) {
  if (input.type === 'integer') {
    const { min, max } = input;
    const edge = [...new Set([min, max, min - 1, max + 1, 0, -1].filter((n) => Number.isSafeInteger(n)))];
    return fc.oneof({ arbitrary: fc.integer({ min, max }), weight: 3 }, { arbitrary: fc.constantFrom(...edge), weight: 1 });
  }
  const min = input.min ?? 0; const max = input.max ?? 200;
  const mix = input.mix ?? MIX;
  const parts = [];
  const text = (lo, hi) => fc.string({ unit: 'grapheme', minLength: lo, maxLength: hi });
  if (mix.includes('unicode')) parts.push({ arbitrary: text(min, Math.min(max, 40)), weight: 4 });
  if (mix.includes('whitespace')) {
    const ws = fc.constantFrom(' ', '  ', '\t', ' ', '　', '\n');
    parts.push({ arbitrary: fc.tuple(ws, text(Math.max(min, 1), Math.min(max, 20)), ws).map(([a, s, b]) => `${a}${s}${b}`), weight: 2 });
  }
  if (mix.includes('long') && max > 40) parts.push({ arbitrary: text(Math.max(min, max - 20), max), weight: 1 });
  if (mix.includes('boundary')) {
    const at = [...new Set([min, max, max + 1, Math.max(0, min - 1)])].map((n) => 'x'.repeat(n));
    parts.push({ arbitrary: fc.constantFrom(...at), weight: 1 });
  }
  if (mix.includes('html')) parts.push({ arbitrary: fc.constantFrom('<b>x</b>', '"\'><img src=x>', 'a &amp; b', '{{7*7}}', '${x}'), weight: 1 });
  return parts.length === 1 ? parts[0].arbitrary : fc.oneof(...parts);
}

// The design property's sample: viewport width, zoom, text length and locale.
export function designArbitrary(fc, vary = {}) {
  const [w0, w1] = vary.width ?? [320, 1920];
  const [z0, z1] = vary.zoom ?? [1, 2];
  const [t0, t1] = vary.text_length ?? [0, 200];
  const locales = vary.locales ?? ['en-US', 'de-DE', 'fi-FI', 'ar', 'ja-JP'];
  return fc.record({
    width: fc.integer({ min: w0, max: w1 }),
    // in steps of 0.25: 1, 1.25, … — what a browser offers
    zoom: fc.integer({ min: Math.round(z0 * 4), max: Math.round(z1 * 4) }).map((n) => n / 4),
    text_length: fc.integer({ min: t0, max: t1 }),
    locale: fc.constantFrom(...locales),
  });
}

// ------------------------------------------------------------------ templates and paths
export function get(obj, path) {
  // -> one value, or a list when the path has [] (every element)
  const toks = [...path.matchAll(/\.([A-Za-z0-9_$-]+)|\[(\d*)\]/g)];
  let cur = [obj]; let many = false;
  for (const [, key, idx] of toks) {
    const next = [];
    for (const c of cur) {
      if (key !== undefined) { if (c != null && typeof c === 'object' && key in c) next.push(c[key]); }
      else if (idx === '') { if (Array.isArray(c)) { next.push(...c); many = true; } }
      else if (Array.isArray(c) && Number(idx) < c.length) next.push(c[Number(idx)]);
    }
    cur = next;
  }
  return many ? cur : cur[0];
}
// A reference's value in a context {input, stamp, <as>: answer}.
export function resolve(ref, ctx) {
  if (typeof ref !== 'string') return ref;
  if (ref === '{input}') return ctx.input;
  if (ref === '{stamp}') return ctx.stamp;
  const m = REF.exec(ref);
  if (!m || !(m[1] in ctx)) return ref;
  return get(ctx[m[1]], m[2] ?? '');
}
// Fill a step's strings: a string that is exactly one {ref} takes its value (a number stays a
// number); otherwise each {ref} is put in as text.
export function fill(v, ctx) {
  if (typeof v === 'string') {
    const one = /^\{([a-z][a-z0-9_.[\]]*)\}$/.exec(v);
    if (one) return one[1] === 'input' || one[1] === 'stamp' ? ctx[one[1]] : resolve(one[1], ctx);
    return v.replace(/\{([a-z][a-z0-9_.[\]]*)\}/g, (_, r) => {
      const x = r === 'input' || r === 'stamp' ? ctx[r] : resolve(r, ctx);
      return x == null ? '' : typeof x === 'object' ? JSON.stringify(x) : String(x);
    });
  }
  if (Array.isArray(v)) return v.map((x) => fill(x, ctx));
  if (isObj(v)) return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, fill(x, ctx)]));
  return v;
}
// A path segment filled with a value is URL-encoded.
export const fillPath = (path, ctx) => path.replace(/\{([a-z][a-z0-9_.[\]]*)\}/g, (_, r) => {
  const x = r === 'input' || r === 'stamp' ? ctx[r] : resolve(r, ctx);
  return encodeURIComponent(x == null ? '' : typeof x === 'object' ? JSON.stringify(x) : String(x));
});

// ------------------------------------------------------------------ assertions
const norm = (x, how = 'none') => {
  if (typeof x !== 'string') return x;
  let s = x;
  if (how.includes('nfc')) s = s.normalize('NFC');
  if (how.includes('trim')) s = s.trim();
  return s;
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const numOf = (x) => (Array.isArray(x) ? x.length : typeof x === 'number' ? x : typeof x === 'string' && x.trim() !== '' && Number.isFinite(Number(x)) ? Number(x) : NaN);
const show = (x) => { const s = JSON.stringify(x); return s === undefined ? 'nothing' : s.length > 120 ? `${s.slice(0, 119)}…` : s; };
// -> null when it holds, else what broke (one sentence).
export function check(e, ctx) {
  const how = e.normalize ?? 'none';
  if ('ok' in e) {
    const a = ctx[e.ok];
    const ok = a && (a.surface === 'cli' ? a.status === 0 : a.status >= 200 && a.status < 300);
    return ok ? null : `step '${e.ok}' did not succeed (${a?.surface === 'cli' ? 'exit' : 'status'} ${a?.status ?? 'none'})`;
  }
  if ('equal' in e) {
    const [a, b] = e.equal.map((r) => norm(resolve(r, ctx), how));
    return same(a, b) ? null : `${e.equal[0]} is ${show(a)}, expected ${show(b)} (${e.equal[1]})`;
  }
  if ('contains' in e) {
    const [a, b] = e.contains.map((r) => norm(resolve(r, ctx), how));
    const hay = typeof a === 'string' ? a.replace(/\s+/g, ' ') : JSON.stringify(a ?? '');
    const needle = typeof b === 'string' ? b.replace(/\s+/g, ' ').trim() : JSON.stringify(b);
    return hay.includes(needle) ? null : `${e.contains[0]} does not contain ${show(b)}`;
  }
  if ('compare' in e) {
    const [ra, op, rb] = e.compare;
    const as = [].concat(resolve(ra, ctx)); const b = numOf(resolve(rb, ctx));
    if (!as.length) return `${ra} has no value`;
    for (const x of as) {
      const a = numOf(x);
      const ok = Number.isFinite(a) && Number.isFinite(b) && { '>=': a >= b, '<=': a <= b, '>': a > b, '<': a < b, '==': a === b, '!=': a !== b }[op];
      if (!ok) return `${ra} is ${show(x)}, expected ${op} ${show(resolve(rb, ctx))}`;
    }
    return null;
  }
  if ('sum' in e) {
    const xs = [].concat(resolve(e.sum, ctx) ?? []).map(numOf); const want = numOf(resolve(e.equals, ctx));
    const got = xs.reduce((s, x) => s + x, 0);
    return xs.every(Number.isFinite) && Math.abs(got - want) < 1e-9 ? null : `the sum of ${e.sum} is ${show(got)}, ${e.equals} is ${show(resolve(e.equals, ctx))}`;
  }
  if ('count' in e) {
    const xs = resolve(e.count, ctx); const want = numOf(resolve(e.equals, ctx));
    const got = Array.isArray(xs) ? xs.length : NaN;
    return got === want ? null : `${e.count} has ${Array.isArray(xs) ? got : 'no list'} items, ${e.equals} is ${show(resolve(e.equals, ctx))}`;
  }
  if ('delta' in e) {
    const [a, b] = e.delta.map((r) => numOf(resolve(r, ctx)));
    if (!Number.isFinite(a) || !Number.isFinite(b)) return `${e.delta[0]} or ${e.delta[1]} is no count`;
    return b - a <= e.max ? null : `${e.delta[1]} grew by ${b - a} from ${e.delta[0]}, at most ${e.max} expected`;
  }
  return 'unknown assertion';
}

// ------------------------------------------------------------------ findings
// The Ref of a design property finding: the page, the invariant and the element — never the
// counterexample, which another seed shrinks to another value.
export const designRef = (page, invariant, target) => refOf('prop', page, invariant, String(target ?? '').toLowerCase().replace(/\d+/g, '#'));
export const sampleText = (s) => `${s.width} px wide at ${Math.round(s.zoom * 100)} % zoom, locale ${s.locale}, texts of ${s.text_length} characters`;
