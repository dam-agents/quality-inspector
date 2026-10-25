#!/usr/bin/env node
// gherkin.mjs — Gherkin in and out of the criteria format (docs/acceptance-criteria.md → Gherkin).
// Deterministic and local: it reads a file, prints text, and never runs a step. Gherkin is a
// source of criteria here, never a runner: the e2e tests stay as docs/test-authoring.md says.
//
//   gherkin.mjs check <file>      {"ok","language","title","requires","acs":n,"blocks":n,"errors":[],"warnings":[]}
//                                 exit 0 = no error, 1 = at least one
//   gherkin.mjs criteria <file>   the AC blocks of the profile-scenario format (docs/profile-contract.md
//                                 → scenarios/): `# <title>`, `requires:`, `language:`, then
//                                 `## AC-<k> — <name>` with Given/When/Then; exit 1 (errors on stderr)
//                                 when the text has an error
//   gherkin.mjs export <criteria.md> [--ref <#N|S-k|P-slug>]
//                                 a frozen criteria file as a .feature: one Scenario per AC
//
// A <file> named *.feature is Gherkin as a whole; any other file is Markdown whose ```gherkin
// (```feature, ```cucumber) fenced blocks are read, in order, numbered as one list of ACs.
//
// The mapping — one place; docs restate none of it:
//   Feature            → `# <title>`; its free description is not a criterion and is dropped
//   Background         → its Given steps lead every scenario's Given (a Rule's after the Feature's)
//   Scenario / Example → one AC per Then step: a Then followed by And/But gives one AC each,
//                        sharing the Given and the When (one observable outcome per AC)
//   Scenario Outline   → one AC per Examples row (and per Then); <name> placeholders filled in
//   Given… And…        → one Given line, joined with " and "
//   When… And…         → one When line, joined with ", then " — a warning: one user action per AC
//   doc string / table → appended to its step as quoted words, never a command
//   @requires-<role>   → `requires: <role>` (member, viewer, outsider; one role per file)
//   @wip @manual @skip @ignore @not-testable → `testable: no — tagged @<tag>`
//   # language: cs     → the Czech keywords; the criteria name the language, the freeze translates
// Errors: a When or Given after a Then, a scenario without a When or a Then, a placeholder with no
// column, an Examples block over MAX_ROWS rows, over MAX_ACS ACs in one file, a line that is no step.

import { readFileSync } from 'node:fs';

export const MAX_ROWS = 10;
export const MAX_ACS = 50;
export const ROLES = ['member', 'viewer', 'outsider'];
export const NOT_TESTABLE_TAGS = ['wip', 'manual', 'skip', 'ignore', 'not-testable'];

// Keywords per language, from the Gherkin dialects. `step` keys: given, when, then, and (And/But/*).
export const DIALECTS = {
  en: {
    feature: ['Feature', 'Business Need', 'Ability'], rule: ['Rule'], background: ['Background'],
    scenario: ['Scenario', 'Example'], outline: ['Scenario Outline', 'Scenario Template'], examples: ['Examples', 'Scenarios'],
    given: ['Given'], when: ['When'], then: ['Then'], and: ['And', 'But', '*'],
  },
  cs: {
    feature: ['Požadavek'], rule: ['Pravidlo'], background: ['Pozadí', 'Kontext'],
    scenario: ['Scénář', 'Příklad'], outline: ['Náčrt Scénáře', 'Osnova scénáře'], examples: ['Příklady'],
    given: ['Pokud', 'Za předpokladu'], when: ['Když'], then: ['Pak'], and: ['A také', 'A', 'Ale', '*'],
  },
};

const FENCE_OPEN = /^[ \t]*(`{3,}|~{3,})[ \t]*(gherkin|feature|cucumber)\b.*$/i;

// The ```gherkin blocks of a Markdown text, in order: [{text, line}] (line = 1-based, the fence).
export function gherkinBlocks(markdown) {
  const lines = String(markdown ?? '').replace(/\r/g, '').split('\n');
  const out = [];
  for (let i = 0; i < lines.length; i++) {
    const m = FENCE_OPEN.exec(lines[i]);
    if (!m) continue;
    const fence = m[1];
    const close = new RegExp(`^[ \\t]*${fence[0] === '`' ? '`' : '~'}{${fence.length},}[ \\t]*$`);
    const body = [];
    let j = i + 1;
    for (; j < lines.length && !close.test(lines[j]); j++) body.push(lines[j]);
    out.push({ text: body.join('\n'), line: i + 1 });
    i = j;
  }
  return out;
}

const sectionRe = (words) => new RegExp(`^(${words.map(esc).join('|')})[ \\t]*:[ \\t]*(.*)$`, 'u');
const stepRe = (words) => new RegExp(`^(${words.map(esc).join('|')})(?:[ \\t]+|$)(.*)$`, 'u');
function esc(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
const cells = (row) => row.trim().replace(/^\||\|$/g, '').split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, '|'));
const quote = (s) => `"${s.replace(/\s+/g, ' ').trim()}"`;

// Parse one Gherkin text. `offset` shifts reported line numbers (a block inside Markdown).
export function parseFeature(text, offset = 0) {
  const lines = String(text ?? '').replace(/\r/g, '').split('\n');
  const errors = [];
  const warnings = [];
  const err = (n, msg) => errors.push(`line ${n + 1 + offset}: ${msg}`);
  let language = 'en';
  for (const l of lines) {
    const t = l.trim();
    if (!t) continue;
    const m = /^#\s*language\s*:\s*([A-Za-z-]+)\s*$/.exec(t);
    if (m) language = m[1].toLowerCase();
    break;
  }
  if (!DIALECTS[language]) { errors.push(`language '${language}' is not supported (${Object.keys(DIALECTS).join(', ')})`); language = 'en'; }
  const D = DIALECTS[language];
  const RE = {
    feature: sectionRe(D.feature), rule: sectionRe(D.rule), background: sectionRe(D.background),
    outline: sectionRe(D.outline), scenario: sectionRe(D.scenario), examples: sectionRe(D.examples),
    given: stepRe(D.given), when: stepRe(D.when), then: stepRe(D.then), and: stepRe(D.and),
  };

  let title = null;
  let featureTags = [];
  let pendingTags = [];
  const backgrounds = { feature: [], rule: [] };
  const scenarios = []; // {name, tags, outline, steps:[{kind,text,line}], examples:[{tags, header, rows, line}], bg, line}
  let cur = null; // the block steps go to: {type:'background'|'scenario', steps, …}
  let examples = null;
  let doc = null; // an open doc string: {delim, lines, step}
  let inRule = false;

  for (let i = 0; i < lines.length; i++) {
    const raw = lines[i];
    const t = raw.trim();
    if (doc) {
      if (t === doc.delim) { doc.step.text += ` ${quote(doc.lines.join(' '))}`; doc = null; }
      else doc.lines.push(t);
      continue;
    }
    if (!t || t.startsWith('#')) continue;
    if (t.startsWith('@')) { pendingTags.push(...t.split(/\s+/).filter((x) => x.startsWith('@')).map((x) => x.slice(1).toLowerCase())); continue; }
    let m;
    if ((m = RE.feature.exec(t))) {
      if (title !== null) err(i, 'a second Feature');
      title = m[2].trim(); featureTags = pendingTags; pendingTags = []; cur = null; examples = null; continue;
    }
    if ((m = RE.rule.exec(t))) { inRule = true; backgrounds.rule = []; pendingTags = []; cur = null; examples = null; continue; }
    if ((m = RE.background.exec(t))) {
      cur = { type: 'background', steps: inRule ? backgrounds.rule : backgrounds.feature }; examples = null; pendingTags = []; continue;
    }
    if ((m = RE.outline.exec(t)) || (m = RE.scenario.exec(t))) {
      const outline = RE.outline.test(t);
      cur = { type: 'scenario', name: m[2].trim(), tags: [...featureTags, ...pendingTags], outline, steps: [], examples: [],
        bg: [...backgrounds.feature, ...(inRule ? backgrounds.rule : [])], line: i };
      pendingTags = []; examples = null; scenarios.push(cur); continue;
    }
    if ((m = RE.examples.exec(t))) {
      if (!cur || cur.type !== 'scenario') { err(i, 'Examples outside a scenario'); continue; }
      examples = { tags: pendingTags, header: null, rows: [], line: i }; pendingTags = []; cur.examples.push(examples); continue;
    }
    if (t.startsWith('|')) {
      if (examples) { if (!examples.header) examples.header = cells(t); else examples.rows.push(cells(t)); continue; }
      const last = cur?.steps.at(-1);
      if (!last) { err(i, 'a table that belongs to no step'); continue; }
      last.table = [...(last.table ?? []), cells(t)];
      continue;
    }
    if (t === '"""' || t === '```' || t === '~~~') {
      const last = cur?.steps.at(-1);
      if (!last) { err(i, 'a doc string that belongs to no step'); continue; }
      doc = { delim: t, lines: [], step: last }; continue;
    }
    let kind = null; let words = ''; let kw = '';
    for (const k of ['given', 'when', 'then', 'and']) if ((m = RE[k].exec(t))) { kind = k; kw = m[1]; words = m[2].trim(); break; }
    if (kind) {
      if (!cur) { err(i, 'a step outside a scenario or background'); continue; }
      if (examples) { err(i, 'a step after Examples'); continue; }
      if (kind === 'and') {
        // A leading And continues the Background's Given.
        const prev = cur.steps.at(-1)?.kind ?? (cur.type === 'background' || cur.bg.length ? 'given' : null);
        if (!prev) { err(i, `"${kw}" opens no step — start with ${D.given[0]}`); continue; }
        kind = prev;
      }
      if (!words) { err(i, 'a step without words'); continue; }
      if (cur.type === 'background' && kind !== 'given') { err(i, 'a Background holds Given steps only'); continue; }
      cur.steps.push({ kind, text: words, line: i });
      continue;
    }
    // Free text: a description right under a Feature, Rule, Scenario or Examples line, before any step.
    if (cur && cur.steps.length && !examples) err(i, `not a step: "${t.slice(0, 80)}"`);
  }
  if (doc) err(lines.length - 1, 'a doc string that is never closed');
  if (title === null && scenarios.length) warnings.push('no Feature line — the criteria have no title');

  // Scenarios to ACs.
  const acs = [];
  const roles = new Set();
  const tableWords = (rows) => ` with ${rows.map((r) => r.join(', ')).join('; ')}`;
  const stepText = (s) => s.text + (s.table ? tableWords(s.table) : '');
  for (const sc of scenarios) {
    const at = `line ${sc.line + 1 + offset}`;
    const name = sc.name.replace(/^AC-\d+\s+—\s+/, '') || '(no name)';
    for (const tag of sc.tags) {
      const r = /^requires[-:](.+)$/.exec(tag);
      if (r) { if (ROLES.includes(r[1])) roles.add(r[1]); else warnings.push(`${at}: @${tag} is not a role of the convention (${ROLES.join(', ')})`); }
    }
    const steps = sc.steps;
    const order = { given: 0, when: 1, then: 2 };
    let bad = false;
    for (let k = 1; k < steps.length; k++) {
      if (order[steps[k].kind] < order[steps[k - 1].kind]) {
        err(steps[k].line, `a ${steps[k].kind === 'given' ? 'Given' : 'When'} after a ${steps[k - 1].kind === 'then' ? 'Then' : 'When'} — split it into two scenarios`);
        bad = true; break;
      }
    }
    const given = [...sc.bg, ...steps.filter((s) => s.kind === 'given')];
    const when = steps.filter((s) => s.kind === 'when');
    const then = steps.filter((s) => s.kind === 'then');
    if (!when.length) { errors.push(`${at}: "${name}" has no ${D.when[0]} step — name the one user action`); bad = true; }
    if (!then.length) { errors.push(`${at}: "${name}" has no ${D.then[0]} step — name the outcome a user sees`); bad = true; }
    if (bad) continue;
    if (when.length > 1) warnings.push(`${at}: "${name}" has ${when.length} When steps — one user action per AC; they are joined`);
    const skip = sc.tags.find((x) => NOT_TESTABLE_TAGS.includes(x));
    const rows = [];
    if (sc.outline) {
      if (!sc.examples.length) { errors.push(`${at}: "${name}" is an outline without Examples`); continue; }
      for (const ex of sc.examples) {
        if (!ex.header) { err(ex.line, 'Examples without a header row'); continue; }
        if (ex.rows.length > MAX_ROWS) { err(ex.line, `${ex.rows.length} Examples rows, over ${MAX_ROWS} — split the outline`); continue; }
        const exSkip = ex.tags.find((x) => NOT_TESTABLE_TAGS.includes(x));
        for (const r of ex.rows) {
          if (r.length !== ex.header.length) { err(ex.line, `a row of ${r.length} cells under a header of ${ex.header.length}`); continue; }
          rows.push({ vals: Object.fromEntries(ex.header.map((h, k) => [h, r[k]])), skip: exSkip });
        }
      }
    } else rows.push({ vals: null, skip: null });
    for (const row of rows) {
      const fill = (s) => (row.vals ? s.replace(/<([^<>]+)>/g, (all, k) => {
        if (k in row.vals) return row.vals[k];
        errors.push(`${at}: <${k}> has no Examples column`); return all;
      }) : s);
      const rowName = row.vals ? (/<[^<>]+>/.test(name) ? fill(name) : `${name} [${Object.values(row.vals).join(', ')}]`) : name;
      const g = given.map((s) => fill(stepText(s))).join(' and ');
      const w = when.map((s) => fill(stepText(s))).join(', then ');
      then.forEach((s, k) => acs.push({
        name: then.length > 1 ? `${rowName} (${k + 1}/${then.length})` : rowName,
        given: g || null, when: w, then: fill(stepText(s)),
        testable: (skip || row.skip) ? `no — tagged @${skip || row.skip}` : null,
      }));
    }
  }
  if (roles.size > 1) errors.push(`more than one second role (${[...roles].join(', ')}) — one per file`);
  return { language, title, requires: roles.size === 1 ? [...roles][0] : null, acs, errors, warnings, scenarios: scenarios.length };
}

// Several texts (blocks of one Markdown file, or one .feature) as one list of ACs.
export function parseAll(texts) {
  const parts = texts.map((b) => parseFeature(b.text, b.offset ?? 0));
  const acs = parts.flatMap((p) => p.acs).map((a, k) => ({ id: `AC-${k + 1}`, ...a }));
  const errors = parts.flatMap((p) => p.errors);
  if (acs.length > MAX_ACS) errors.push(`${acs.length} acceptance criteria, over ${MAX_ACS} — split the file`);
  const req = [...new Set(parts.map((p) => p.requires).filter(Boolean))];
  if (req.length > 1) errors.push(`more than one second role (${req.join(', ')}) — one per file`);
  const langs = [...new Set(parts.map((p) => p.language))];
  return {
    language: langs.length === 1 ? langs[0] : langs.join(','), title: parts.map((p) => p.title).find(Boolean) ?? null,
    requires: req[0] ?? null, acs, errors, warnings: parts.flatMap((p) => p.warnings), blocks: texts.length,
  };
}

// A file's Gherkin: a .feature as a whole, else its fenced blocks.
export function parseFile(name, text) {
  if (/\.feature$/i.test(name)) return parseAll([{ text, offset: 0 }]);
  return parseAll(gherkinBlocks(text).map((b) => ({ text: b.text, offset: b.line })));
}

// The profile-scenario format (docs/profile-contract.md → scenarios/), which a freeze reads.
export function toCriteria(p) {
  const out = [`# ${p.title ?? '(no title)'}`];
  if (p.requires) out.push(`requires: ${p.requires}`);
  if (p.language !== 'en') out.push(`language: ${p.language} — the freeze translates it (docs/acceptance-criteria.md → Language)`);
  for (const a of p.acs) {
    out.push('', `## ${a.id} — ${a.name}`);
    if (a.given) out.push(`Given ${a.given}`);
    out.push(`When ${a.when}`, `Then ${a.then}`);
    if (a.testable) out.push(`testable: ${a.testable}`);
  }
  return `${out.join('\n')}\n`;
}

// A frozen criteria file (or a profile scenario's AC blocks) as a .feature. Explorations (EX-)
// are no criteria and stay out; a `testable: no` AC carries its tag back (@wip…), else @not-testable
// and its reason as a comment.
export function toFeature(criteria, ref = null) {
  const text = String(criteria ?? '').replace(/\r/g, '');
  const head = /^# (.*)$/m.exec(text)?.[1] ?? '';
  const m = /^(?:(#\d+|S-\d+|P-[a-z0-9][a-z0-9-]*) — )?(.*?)(?:\s{2,}\S+:.*)?$/.exec(head) ?? [];
  const id = ref ?? m[1] ?? null;
  const title = (m[2] ?? '').trim() || '(no title)';
  const frozen = /frozen_utc:\s*(\S+)/.exec(text)?.[1];
  const hash = /(?:ac_hash|spec_hash):\s*(\S+)/.exec(text)?.[1];
  const requires = /^requires:\s*(\S+)/m.exec(text)?.[1];
  const out = [`# Exported by quality-inspector${id ? ` from ${id}` : ''}${frozen ? `, frozen ${frozen}` : ''}${hash ? `, hash ${hash}` : ''}.`,
    '# The frozen acceptance criteria, in words. No step definitions run them.'];
  if (requires) out.push(`@requires-${requires.toLowerCase()}`);
  out.push(`Feature: ${title}`);
  for (const sec of text.split(/^## /m).slice(1)) {
    const hd = sec.split('\n')[0];
    const ac = /^(AC-\d+)(?: — (.*))?$/.exec(hd.trim());
    if (!ac) continue;
    const line = (k) => (new RegExp(`^${k}[: ]\\s*(.*)$`, 'm').exec(sec) ?? [])[1]?.trim() ?? null;
    const testable = line('testable');
    out.push('');
    if (testable && !/^yes/i.test(testable)) {
      const tag = /^no — tagged @(\S+)$/.exec(testable)?.[1];
      out.push(...(NOT_TESTABLE_TAGS.includes(tag) ? [`  @${tag}`] : [`  # testable: ${testable}`, '  @not-testable']));
    }
    out.push(`  Scenario: ${ac[1]}${ac[2] ? ` — ${ac[2].trim()}` : ''}`);
    for (const k of ['Given', 'When', 'Then']) { const v = line(k); if (v) out.push(`    ${k} ${v}`); }
  }
  return `${out.join('\n')}\n`;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const [cmd, file, ...rest] = process.argv.slice(2);
  const usage = () => { console.error('usage: gherkin.mjs check|criteria <file> | export <criteria.md> [--ref <id>]'); process.exit(2); };
  if (!file) usage();
  let text;
  try { text = readFileSync(file, 'utf8'); } catch { console.error(`gherkin: cannot read ${file}`); process.exit(2); }
  if (cmd === 'check') {
    const p = parseFile(file, text);
    console.log(JSON.stringify({ ok: !p.errors.length, language: p.language, title: p.title, requires: p.requires,
      acs: p.acs.length, blocks: p.blocks, errors: p.errors, warnings: p.warnings }));
    process.exit(p.errors.length ? 1 : 0);
  } else if (cmd === 'criteria') {
    const p = parseFile(file, text);
    if (!p.blocks || !p.acs.length) p.errors.push('no Gherkin scenario');
    if (p.errors.length) { for (const e of p.errors) console.error(`gherkin: ${e}`); process.exit(1); }
    for (const w of p.warnings) console.error(`gherkin: warning: ${w}`);
    process.stdout.write(toCriteria(p));
  } else if (cmd === 'export') {
    const i = rest.indexOf('--ref');
    const ref = i >= 0 ? rest[i + 1] : null;
    if (i >= 0 && !/^(#\d+|S-\d+|P-[a-z0-9][a-z0-9-]{0,47})$/.test(ref ?? '')) usage();
    process.stdout.write(toFeature(text, ref));
  } else usage();
}
