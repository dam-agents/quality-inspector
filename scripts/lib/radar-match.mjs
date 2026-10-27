// radar-match.mjs — which recurring tests a pull request's text names (docs/radar.md → Matching):
// its sanitized title and body against the features registry and the newest UI map. Pure, no I/O;
// scripts/radar.mjs scan feeds it. Deterministic: the agent then judges each candidate.
//
// - A feature counts when its id, name or an alias stands in the text as whole words (case, accents
//   and punctuation do not count): its recurring members, score 1 (0.9 by an alias).
// - A page counts when its title (unique to it) stands in the text as whole words: score 0.7 for
//   each recurring test that opens it. A control only one page shows (a heading, button, tab, field
//   or link of at least 4 characters) counts the same way: score 0.6 for each recurring test that
//   names it in a quoted string — per frozen block (`#N AC-k`) where that line sits in one, else the
//   whole test — and 0.5 for one that only opens its page.
// - A test's own step string counts when the text names it as whole words: a quoted string of the
//   test (a field label, a dialog title, an agent instruction's words) of at least 2 words or 8
//   characters, never a URL, a template or a control of the newest map (those count above): score 0.5
//   per frozen block where its line sits, else the whole test. It finds the step a change replaced,
//   which the newest map no longer shows.
// - Only the tiers `regression`, `promotable` and `quarantined`; an ad-hoc test is out of scope.
// - A whole test's hits fold into its blocks' where the text names a block of it. Per test the best
//   score, +0.05 for each further reason, at most 1; at most MAX candidates,
//   best first, each with up to 3 reasons {via: feature|page|control, term, feature|page}.

import { blockAt, controlRe, firstLine, pageRe } from './match.mjs';
import { RECURRING, idOf } from './staleness.mjs';

export const MAX = 8;
const KINDS = ['headings', 'buttons', 'tabs', 'inputs', 'links'];

export const norm = (s) => String(s ?? '').normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const has = (text, term) => { const t = norm(term); return t.length >= 3 && ` ${text} `.includes(` ${t} `); };
const MEMBER_RE = /^(?:#\d{1,7}(?: (?:AC|IN)-\d{1,3})?|S-\d{1,6}(?: AC-\d{1,3})?|P-[a-z0-9][a-z0-9-]{0,40}(?: AC-\d{1,3})?)$/;
const fileOfMember = (m) => { const x = /^(?:#(\d+)|S-(\d+)|P-([a-z0-9-]+))/.exec(m); return x ? `tests/${x[1] ? `issue-${x[1]}` : x[2] ? `scenario-${x[2]}` : `profile-${x[3]}`}.e2e.ts` : null; };

// matchPr(<sanitized title and body>, {features: [{id, name, aliases, members}], tiers: Map file -> tier,
//   routes: <inventory.json routes>, tests: [{file: "tests/<name>", src}]}) -> [{test, tier, score, reasons}]
export function matchPr(text, { features = [], tiers = new Map(), routes = {}, tests = [] } = {}) {
  const t = norm(text);
  const found = new Map();
  const add = (test, file, score, reason) => {
    const tier = tiers.get(file);
    if (!RECURRING.has(tier)) return;
    const c = found.get(test) ?? { test, tier, scores: [], reasons: [] };
    c.scores.push(score); if (c.reasons.length < 3) c.reasons.push(reason);
    found.set(test, c);
  };
  for (const f of features) {
    const names = [[f.name, 1], [f.id?.replace(/-/g, ' '), 1], ...(f.aliases ?? []).map((a) => [a, 0.9])];
    const hit = names.find(([n]) => n && has(t, n));
    if (!hit) continue;
    for (const m of f.members ?? []) if (MEMBER_RE.test(m)) add(m, fileOfMember(m), hit[1], { via: 'feature', feature: f.id, term: hit[0] });
  }
  // A control counts for one page only: shared chrome ("Save" on every form) names no page.
  const label = (k, s) => (k === 'links' ? String(s).split(' → ')[0] : String(s));
  const pagesOf = new Map();
  const terms = Object.entries(routes ?? {}).map(([page, r]) => {
    const own = [...new Set(KINDS.flatMap((k) => (Array.isArray(r?.[k]) ? r[k] : []).map((s) => label(k, s))))].filter((s) => s.length >= 4);
    for (const n of own) pagesOf.set(norm(n), (pagesOf.get(norm(n)) ?? new Set()).add(page));
    return { page, title: typeof r?.title === 'string' ? r.title : null, own };
  });
  const titles = new Map();
  for (const p of terms) if (p.title) titles.set(norm(p.title), (titles.get(norm(p.title)) ?? 0) + 1);
  for (const p of terms) {
    const opens = pageRe(p.page);
    if (p.title && p.title.length >= 4 && titles.get(norm(p.title)) === 1 && has(t, p.title)) {
      for (const x of tests) if (opens.test(x.src)) add(idOf(x.file.split('/').at(-1)), x.file, 0.7, { via: 'page', page: p.page, term: p.title });
    }
    for (const n of p.own) {
      if (pagesOf.get(norm(n))?.size !== 1 || !has(t, n)) continue;
      const re = controlRe(n, { quoted: true });
      for (const x of tests) {
        const at = firstLine(x.src, re);
        const id = idOf(x.file.split('/').at(-1));
        if (!id) continue;
        if (at >= 0) {
          const b = blockAt(x.src, at);
          add(b && (id.startsWith('#') || b.startsWith('AC-')) ? `${id} ${b}` : id, x.file, 0.6, { via: 'control', page: p.page, term: n });
        } else if (opens.test(x.src)) add(id, x.file, 0.5, { via: 'page', page: p.page, term: n });
      }
    }
  }
  // The test's own step strings: what the text says the change replaced.
  const STR_RE = /(['"`])([^'"`\n]{4,80})\1/g;
  for (const x of tests) {
    const id = idOf(x.file.split('/').at(-1));
    if (!id) continue;
    const seenTerm = new Set();
    x.src.split('\n').forEach((line, i) => {
      for (const [, , term] of line.matchAll(STR_RE)) {
        const k = norm(term);
        if (seenTerm.has(k) || /[/$]|^\s|\s$/.test(term) || !/[A-Za-z]/.test(term)) continue;
        if (!(k.includes(' ') || k.length >= 8) || pagesOf.has(k) || !has(t, term)) continue; // a map control: counted above
        seenTerm.add(k);
        const b = blockAt(x.src, i);
        add(b && (id.startsWith('#') || b.startsWith('AC-')) ? `${id} ${b}` : id, x.file, 0.5, { via: 'step', term });
      }
    });
  }
  // A whole test's hits fold into its blocks' when the text also names a block of it.
  for (const c of [...found.values()]) {
    const blocks = [...found.values()].filter((x) => x !== c && x.test.startsWith(`${c.test} `));
    if (c.test.includes(' ') || !blocks.length) continue;
    for (const b of blocks) { b.scores.push(...c.scores); b.reasons.push(...c.reasons.slice(0, 3 - b.reasons.length)); }
    found.delete(c.test);
  }
  return [...found.values()].filter((c) => c.test)
    .map((c) => ({ test: c.test, tier: c.tier, score: Math.min(1, Math.round((Math.max(...c.scores) + 0.05 * (c.scores.length - 1)) * 100) / 100), reasons: c.reasons }))
    .sort((a, b) => b.score - a.score || a.test.localeCompare(b.test))
    .slice(0, MAX);
}
