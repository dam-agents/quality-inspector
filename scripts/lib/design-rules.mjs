// design-rules.mjs — the pure rules of the design checks (docs/design-checks.md): the profile's
// `design` key, the finding's Ref and severity, the Design Desk message, retired words, design
// tokens, which screens a pull request changed, and the inconsistency radar's patterns. No browser,
// no file system: design-check.mjs, consistency.mjs and design-outbox.mjs call it, the offline tests too.
//
// A finding (check.json, radar.json): {ref, check, severity, title, screen, path, what, expected,
// steps: [..], build, attachment}. `ref` is the same for the same problem on every build and every
// run — its parts never hold a build, a time or a count — so the Design Desk dedupes by it and the
// outbox sends it once.

import { createHash } from 'node:crypto';

export const MARKER = '🧪 Automated test finding — Quality Inspector';
export const CHECKS = ['missing-state', 'accessibility', 'consistency', 'radar'];
export const SEVERITIES = ['high', 'medium', 'low'];
export const REF_RE = /^qi-[a-z0-9]+(?:-[a-z0-9]+){1,4}$/;
export const sevRank = (s) => { const i = SEVERITIES.indexOf(s); return i < 0 ? SEVERITIES.length : i; };
const clean = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
const cut = (s, n) => { const t = clean(s); return t.length > n ? `${t.slice(0, n - 1)}…` : t; };

// qi-<kind>-<10 hex> of the identity parts; kind a11y | state | token | word | focus.
export function refOf(kind, ...parts) {
  if (!/^[a-z0-9]{2,8}$/.test(kind)) throw new Error(`ref kind '${kind}'`);
  return `qi-${kind}-${createHash('sha256').update(parts.map(clean).join('\u001f')).digest('hex').slice(0, 10)}`;
}

// ------------------------------------------------------------------ the profile's `design` key
// {retired_words: [{word, say}], dark_theme: {color_scheme: "dark"} | {local_storage: {key, value}}
//  | {html_class: <c>} | {html_attribute: {name, value}} | "none", tokens: {prefixes: [..], spacing_step}}
// -> {retired: [{word, say, re}], dark: {mode, …}, tokens: {prefixes, spacing_step}, notes: []}
// An invalid part is left out with a note; absent, the defaults: no retired words, the system dark
// theme (prefers-color-scheme), every :root custom property a token.
const WORD_RE = /^[\p{L}\p{N}][\p{L}\p{N} '’-]{0,39}$/u;
const VAR_RE = /^--[A-Za-z0-9_-]{1,60}$/;
const NAME_RE = /^[A-Za-z][A-Za-z0-9_.:-]{0,60}$/;
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
export function parseDesign(profile) {
  const d = profile?.design && typeof profile.design === 'object' ? profile.design : {};
  const notes = [];
  const retired = [];
  for (const [i, w] of (Array.isArray(d.retired_words) ? d.retired_words : []).entries()) {
    const word = clean(w?.word); const say = cut(w?.say, 80);
    if (!WORD_RE.test(word) || !say) { notes.push(`design.retired_words[${i}] is invalid (word: up to 40 letters, digits, spaces, ' and -; say: what to say instead) — left out`); continue; }
    retired.push({ word, say, re: new RegExp(`(?<![\\p{L}\\p{N}])${esc(word).replace(/ +/g, '\\s+')}(?![\\p{L}\\p{N}])`, 'iu') });
  }
  let dark = { mode: 'color_scheme' };
  const t = d.dark_theme;
  if (t === 'none') dark = { mode: 'none' };
  else if (t && typeof t === 'object') {
    if (t.color_scheme === 'dark') dark = { mode: 'color_scheme' };
    else if (t.local_storage && NAME_RE.test(t.local_storage.key ?? '') && typeof t.local_storage.value === 'string' && t.local_storage.value.length <= 60) dark = { mode: 'local_storage', key: t.local_storage.key, value: t.local_storage.value };
    else if (typeof t.html_class === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,40}$/.test(t.html_class)) dark = { mode: 'html_class', value: t.html_class };
    else if (t.html_attribute && /^(data-[a-z0-9-]{1,40}|class)$/.test(t.html_attribute.name ?? '') && typeof t.html_attribute.value === 'string' && t.html_attribute.value.length <= 60) dark = { mode: 'html_attribute', name: t.html_attribute.name, value: t.html_attribute.value };
    else notes.push('design.dark_theme is invalid — the system dark theme (prefers-color-scheme) is used');
  } else if (t !== undefined) notes.push('design.dark_theme is invalid — the system dark theme (prefers-color-scheme) is used');
  const tk = d.tokens && typeof d.tokens === 'object' ? d.tokens : {};
  const prefixes = (Array.isArray(tk.prefixes) ? tk.prefixes : []).filter((p) => typeof p === 'string' && /^--[A-Za-z0-9_-]{0,40}$/.test(p));
  if (Array.isArray(tk.prefixes) && prefixes.length !== tk.prefixes.length) notes.push('design.tokens.prefixes: an entry that is not --<name> is left out');
  let step = null;
  if (tk.spacing_step !== undefined) { if (VAR_RE.test(tk.spacing_step ?? '')) step = tk.spacing_step; else notes.push('design.tokens.spacing_step is not a --<name> — no spacing step'); }
  return { retired, dark, tokens: { prefixes, spacing_step: step }, notes };
}

// ------------------------------------------------------------------ retired words
// texts: [{text, target, box}] of one page and theme -> one hit per retired word: the first place it
// stands, with how many places say it.
export function findRetired(texts, retired) {
  const hits = new Map();
  for (const t of texts ?? []) {
    for (const w of retired) {
      const m = w.re.exec(String(t.text ?? ''));
      if (!m) continue;
      const h = hits.get(w.word);
      if (h) h.count++; else hits.set(w.word, { word: w.word, say: w.say, seen: m[0], text: cut(t.text, 80), target: t.target, box: t.box ?? null, count: 1 });
    }
  }
  return [...hits.values()];
}

// ------------------------------------------------------------------ design tokens
// tokens: {colors: [[r,g,b]], lengths: [px], step: px|null} (design-probe.mjs → tokens);
// used: [{prop: color|background|border|font-size|radius, value: [r,g,b] | px, count, target, box}]
// -> the uses that match no token, most used first. A colour matches within 2 per channel; a length
// matches a token's px exactly, or a whole multiple of the step; 0 and 1 px always match.
export function offTokens(tokens, used, max = 5) {
  const colors = tokens?.colors ?? []; const lengths = new Set((tokens?.lengths ?? []).map((v) => Math.round(v * 100) / 100));
  const step = tokens?.step > 0 ? tokens.step : null;
  if (!colors.length && !lengths.size && !step) return [];
  const near = (a, b) => a.every((v, i) => Math.abs(v - b[i]) <= 2);
  const onLen = (v) => v <= 1 || lengths.has(Math.round(v * 100) / 100) || (step && Math.abs(v / step - Math.round(v / step)) < 0.01);
  return (used ?? []).filter((u) => (Array.isArray(u.value)
    ? colors.length > 0 && !colors.some((c) => near(c, u.value))
    : (u.prop === 'font-size' || u.prop === 'radius') && (lengths.size > 0 || step) && !onLen(u.value)))
    .sort((a, b) => b.count - a.count || String(a.prop).localeCompare(String(b.prop))).slice(0, max);
}
export const hex = (c) => `#${c.map((v) => Math.round(v).toString(16).padStart(2, '0')).join('')}`;
export const valueText = (u) => (Array.isArray(u.value) ? hex(u.value) : `${Math.round(u.value * 100) / 100}px`);

// ------------------------------------------------------------------ the screens a pull request changed
// Two UI maps (ui-inventory.mjs) -> the PR build's pages that are new or whose controls differ from the
// base build's, most changed first: [{pattern, example, title, reason, score}]. A page the map skips
// (no example, an error, a redirect) is left out. The browser adds the pages that only look different.
const KINDS = ['headings', 'nav', 'buttons', 'tabs', 'inputs', 'links'];
export function changedPages(baseInv, prInv) {
  const base = baseInv?.routes ?? {}; const out = [];
  for (const [pattern, r] of Object.entries(prInv?.routes ?? {})) {
    if (!r?.example || r.error || r.redirected) continue;
    const title = screenName(pattern, r);
    const b = base[pattern];
    if (!b || b.error || b.redirected) { out.push({ pattern, example: r.example, title, reason: 'new screen', score: 1000 }); continue; }
    let n = 0;
    for (const k of KINDS) {
      const x = new Set(b[k] ?? []); const y = new Set(r[k] ?? []);
      n += [...x].filter((v) => !y.has(v)).length + [...y].filter((v) => !x.has(v)).length;
    }
    if (n) out.push({ pattern, example: r.example, title, reason: `${n} control${n === 1 ? '' : 's'} added, removed or renamed`, score: n });
  }
  return out.sort((a, b) => b.score - a.score || a.pattern.localeCompare(b.pattern));
}
// The screen's name a person reads: its first heading, else the document title, else the path.
export function screenName(pattern, r) { return cut((r?.headings ?? [])[0] || r?.title || pattern, 60); }

// ------------------------------------------------------------------ the inconsistency radar
// observations: [{kind: page-header|button|empty-state|spacing, group: '' | filled | outlined | danger,
//   sig, label, pattern, title, example: {target, text, crop}}], one per element kind and page (a button:
//   one per page and signature) -> one finding per kind and group whose signatures differ, its variants
//   most screens first, at most 4. A kind seen on fewer than 2 screens has nothing to compare.
export const RADAR = {
  'page-header': { severity: 'medium', noun: 'page headers', expected: 'Every screen uses the same page header: one size, weight and colour of the title, at the same place.' },
  'empty-state': { severity: 'medium', noun: 'empty states', expected: 'Every empty list or screen uses one empty-state pattern: the same parts (picture, title, text, action) in the same layout.' },
  button: { severity: 'medium', noun: 'buttons', expected: 'Buttons that do the same job look the same on every screen: one shape, font weight, case and colour.' },
  spacing: { severity: 'low', noun: 'page margins', expected: 'Every screen has the same space between the page edge and its content.' },
};
const GROUP = { filled: 'main buttons (filled)', outlined: 'outlined buttons', danger: 'buttons that delete (filled)' };
export function clusterRadar(observations, build) {
  const groups = new Map();
  for (const o of observations ?? []) {
    if (!RADAR[o?.kind] || !o.sig || !o.pattern) continue;
    const k = `${o.kind}|${o.group ?? ''}`;
    if (!groups.has(k)) groups.set(k, new Map());
    const g = groups.get(k);
    if (!g.has(o.sig)) g.set(o.sig, { sig: o.sig, label: cut(o.label, 120), pages: [], titles: [], example: { ...o.example, pattern: o.pattern, title: o.title } });
    const v = g.get(o.sig);
    if (!v.pages.includes(o.pattern)) { v.pages.push(o.pattern); v.titles.push(o.title || o.pattern); }
  }
  const out = [];
  for (const [k, g] of [...groups].sort(([a], [b]) => a.localeCompare(b))) {
    const [kind, group] = k.split('|');
    const variants = [...g.values()].sort((a, b) => b.pages.length - a.pages.length || a.sig.localeCompare(b.sig));
    const screens = new Set(variants.flatMap((v) => v.pages));
    if (variants.length < 2 || screens.size < 2) continue;
    const shown = variants.slice(0, 4);
    const odd = shown[shown.length - 1].example;
    const noun = group ? GROUP[group] ?? `${group} buttons` : RADAR[kind].noun;
    const letter = (i) => String.fromCharCode(65 + i);
    const what = `The screens show ${variants.length} kinds of ${noun}: ${shown.map((v, i) => `${letter(i)} on ${v.pages.length} screen${v.pages.length === 1 ? '' : 's'} (${v.titles.slice(0, 2).join(', ')}${v.titles.length > 2 ? ', …' : ''}) — ${v.label}`).join('; ')}${variants.length > 4 ? `; ${variants.length - 4} more` : ''}.`;
    out.push({
      ref: `qi-radar-${kind}${group ? `-${group}` : ''}`, check: 'radar', severity: RADAR[kind].severity,
      title: cut(`${noun[0].toUpperCase()}${noun.slice(1)} look different on different screens (${variants.length} kinds)`, 120),
      screen: odd.title || odd.pattern, path: odd.pattern, what: cut(what, 600), expected: RADAR[kind].expected,
      steps: shown.slice(0, 3).map((v, i) => `Open ${v.pages[0]} and look at the ${noun.replace(/ \(.*\)$/, '').replace(/s$/, '')} (${letter(i)}).`),
      build, pattern: kind, group: group || null,
      variants: shown.map((v, i) => ({ id: letter(i), sig: v.sig, label: v.label, pages: v.pages, example: v.example })),
    });
  }
  return out;
}

// ------------------------------------------------------------------ the Design Desk message
// The exact text the Design Desk recognises (docs/design-checks.md → To the Design Desk): the marker
// line, then one line per field, product text Slack-escaped so a label cannot mention or link; the
// mention of the Desk's bot is a last line of its own, so the first line stays the marker.
const slack = (s, n) => cut(s, n).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
export function validFinding(f) {
  const bad = [];
  if (!REF_RE.test(f?.ref ?? '') || String(f.ref).length > 60) bad.push('ref');
  if (!CHECKS.includes(f?.check)) bad.push('check');
  if (!SEVERITIES.includes(f?.severity)) bad.push('severity');
  for (const k of ['title', 'screen', 'path', 'what', 'expected', 'build']) if (!clean(f?.[k])) bad.push(k);
  if (!Array.isArray(f?.steps) || !f.steps.some((s) => clean(s))) bad.push('steps');
  return bad;
}
export function formatMessage(f, mention) {
  const bad = validFinding(f);
  if (bad.length) throw new Error(`finding ${f?.ref ?? '?'}: invalid ${bad.join(', ')}`);
  if (mention != null && !/^[UW][A-Z0-9]{6,20}$/.test(mention)) throw new Error(`mention '${mention}' is not a Slack member id`);
  const steps = f.steps.map(clean).filter(Boolean).slice(0, 6);
  return [
    MARKER,
    slack(f.title, 140),
    `Screen: ${slack(f.screen, 80)} (${slack(f.path, 120)})`,
    `What happens: ${slack(f.what, 600)}`,
    `Expected: ${slack(f.expected, 300)}`,
    `Steps: ${steps.map((s, i) => `${i + 1}. ${slack(s, 160)}`).join(' ')}`,
    `Build: ${slack(f.build, 60)}`,
    `Check: ${f.check}`,
    `Severity: ${f.severity}`,
    `Ref: ${f.ref}`,
    ...(mention ? [`<@${mention}>`] : []),
  ].join('\n');
}
