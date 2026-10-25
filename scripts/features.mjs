#!/usr/bin/env node
// features.mjs — the features registry, work/FEATURES.md (docs/features.md): the recurring test cases
// grouped by what the product does ("model switching", "reply in Slack"), so a person can ask for a
// feature by its name and get its tests run again. Only a recurring test runs: its work/SUITE.md tier
// is `regression` or `promotable`; any other member is listed as skipped, with the reason.
//
//   node features.mjs list                              -> {"features": [{id, name, aliases, members, updated_utc, runnable, skipped}]}
//   node features.mjs resolve <words…>                  -> {"query", "match": "exact"|"ranked"|"none", "features": [{…, score, tags}]}
//   node features.mjs add <feature> <member> [--name <text>]   -> {"feature", "added": bool}  (creates the feature)
//   node features.mjs remove <feature> <member>         -> {"feature", "removed": bool}
//   node features.mjs alias <feature> <text>            -> {"feature", "aliases"}
//   node features.mjs rename <feature> <text>           -> {"feature", "name"}
//   node features.mjs merge <from> <into>               -> {"feature": <into>, "members"}  (<from> is gone)
//   node features.mjs drop <feature>                    -> {"feature", "dropped": true}
//   node features.mjs check                             -> {"ok", "problems": [], "warnings": []}
//   node features.mjs record <label> <feature> --build <candidate>
//     -> {"file", "feature", "build", "results": {"issue-42/AC-1": {"status", "error"}}}
//
// <feature> is an id: [a-z0-9][a-z0-9-]{0,39}. A member is `#N`, `#N AC-k`, `S-k`, `S-k AC-j`,
// `P-<slug>` or `P-<slug> AC-j`. `tags` are the suite.sh arguments of the runnable members' files
// (`--tag issue-42 --tag scenario-7 …`): a member that names one criterion runs its whole file, and
// `record` keeps the member criteria only. `record` reads work/suite/.e2e/runs/<label>/report.json and
// writes work/reruns/feature-<id>/<label>.json — a run by hand: never a verdict, no tier change.
// Exit 2: usage, an unknown feature, or a malformed member; the file is then left as it was.

import { mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const runsRoot = process.env.QI_RUNS_ROOT ?? join(work, 'suite', '.e2e', 'runs');
const FILE = join(work, 'FEATURES.md');
const HEADER = '| feature | name | aliases | members | updated_utc |';
const TITLE = '# Features — recurring test cases grouped by what the product does (docs/features.md)';
const RECURRING = new Set(['regression', 'promotable']);
const ID_RE = /^[a-z0-9][a-z0-9-]{0,39}$/;
const MEMBER_RE = /^(#(\d{1,7})|S-(\d{1,6})|P-([a-z0-9][a-z0-9-]{0,40}))(?: (AC-\d{1,3}))?$/;
const TEXT_RE = /^[^|\n\r\u0000-\u001f]{1,80}$/;

const die = (msg) => { console.error(`features: ${msg}`); process.exit(2); };
const out = (o) => console.log(JSON.stringify(o));
const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');
const rows = (text) => (text ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2)
  .map((l) => l.split('|').slice(1, -1).map((c) => c.trim()));
const list = (s, sep) => String(s ?? '').split(sep).map((x) => x.trim()).filter((x) => x && x !== '-');
const clean = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();

function load() {
  const text = read(FILE);
  if (text != null && !text.split('\n').includes(HEADER)) die('work/FEATURES.md: header changed — fix it to the format of docs/features.md');
  return rows(text).map(([id, name, aliases, members, utc]) =>
    ({ id, name: name || id, aliases: list(aliases, ';'), members: list(members, ','), updated_utc: utc && utc !== '-' ? utc : null }));
}
function save(features) {
  const body = features.slice().sort((a, b) => a.id.localeCompare(b.id)).map((f) =>
    `| ${f.id} | ${f.name} | ${f.aliases.join('; ') || '-'} | ${f.members.join(', ') || '-'} | ${f.updated_utc ?? '-'} |`);
  writeFileSync(`${FILE}.tmp`, `${TITLE}\n\n${HEADER}\n| --- | --- | --- | --- | --- |\n${body.join('\n')}${body.length ? '\n' : ''}`);
  renameSync(`${FILE}.tmp`, FILE);
}

// A member's test file and tier: `#42 AC-1` -> tests/issue-42.e2e.ts, the stem issue-42.
const suite = new Map(rows(read(join(work, 'SUITE.md'))).map(([test, , tier]) => [test, tier]));
function memberOf(ref) {
  const m = MEMBER_RE.exec(ref);
  if (!m) return null;
  const stem = m[2] ? `issue-${m[2]}` : m[3] ? `scenario-${m[3]}` : `profile-${m[4]}`;
  const file = `tests/${stem}.e2e.ts`;
  return { ref, stem, file, ac: m[5] ?? null, tier: suite.get(file) ?? null };
}
function resolved(f) {
  const runnable = []; const skipped = [];
  for (const ref of f.members) {
    const m = memberOf(ref);
    if (!m) skipped.push({ ref, reason: 'not a member reference' });
    else if (!m.tier) skipped.push({ ref, reason: 'no test in work/SUITE.md' });
    else if (!RECURRING.has(m.tier)) skipped.push({ ref, reason: `tier ${m.tier}` });
    else runnable.push(ref);
  }
  const stems = [...new Set(runnable.map((r) => memberOf(r).stem))];
  return { ...f, runnable, skipped, tags: stems.flatMap((s) => ['--tag', s]) };
}

// Matching: case, accents and punctuation do not count ("Změna modelu" = "zmena modelu").
const norm = (s) => String(s).normalize('NFD').replace(/\p{M}/gu, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
const words = (s) => norm(s).split(' ').filter(Boolean);
function score(f, q) {
  const names = [f.id.replace(/-/g, ' '), f.name, ...f.aliases].map(norm);
  if (names.includes(norm(q))) return 1;
  const have = new Set(names.flatMap((n) => n.split(' ')));
  const want = words(q);
  if (!want.length) return 0;
  const hit = want.filter((w) => have.has(w) || (w.length >= 4 && [...have].some((h) => h.length >= 4 && (h.startsWith(w) || w.startsWith(h)))));
  return Math.round((hit.length / want.length) * 90) / 100; // below 1: only a whole name is exact
}

const [cmd, ...args] = process.argv.slice(2);
const need = (n) => { if (args.length < n) die(`usage: features.mjs ${cmd} — see the header of scripts/features.mjs`); };
const idArg = (s) => { if (!ID_RE.test(s ?? '')) die(`"${s ?? ''}" is not a feature id ([a-z0-9][a-z0-9-]{0,39})`); return s; };
// A member may come as one argument ("#42 AC-1") or two (#42 AC-1).
const memberAt = (k) => memberArg(/^AC-\d{1,3}$/.test(args[k + 1] ?? '') ? `${args[k]} ${args[k + 1]}` : args[k]);
const memberArg = (s) => { const m = clean(s); if (!MEMBER_RE.test(m)) die(`"${m}" is not a member (#N, #N AC-k, S-k, S-k AC-j, P-<slug>, P-<slug> AC-j)`); return m; };
const textArg = (s) => { const t = clean(s); if (!TEXT_RE.test(t)) die('a name or an alias is 1–80 printable characters without "|"'); return t; };
const find = (features, id) => features.find((f) => f.id === id) ?? die(`no feature "${id}" in work/FEATURES.md`);

switch (cmd) {
  case 'list': out({ features: load().map(resolved) }); break;
  case 'resolve': {
    need(1);
    const q = clean(args.join(' '));
    const scored = load().map((f) => ({ ...resolved(f), score: score(f, q) })).filter((f) => f.score >= 0.45).sort((a, b) => b.score - a.score || a.id.localeCompare(b.id));
    const exact = scored.filter((f) => f.score === 1);
    out({ query: q, match: exact.length === 1 ? 'exact' : scored.length ? 'ranked' : 'none', features: exact.length === 1 ? exact : scored.slice(0, 5) });
    break;
  }
  case 'add': {
    need(2);
    const id = idArg(args[0]); const ref = memberAt(1);
    const ni = args.indexOf('--name');
    const name = ni >= 0 ? textArg(args.slice(ni + 1).join(' ')) : null;
    const features = load();
    let f = features.find((x) => x.id === id);
    if (!f) features.push(f = { id, name: name ?? id, aliases: [], members: [], updated_utc: null });
    const added = !f.members.includes(ref);
    if (added) f.members.push(ref);
    if (added || !f.updated_utc) { f.updated_utc = now(); save(features); }
    out({ feature: id, added });
    break;
  }
  case 'remove': {
    need(2);
    const features = load(); const f = find(features, idArg(args[0])); const ref = memberAt(1);
    const removed = f.members.includes(ref);
    if (removed) { f.members = f.members.filter((m) => m !== ref); f.updated_utc = now(); save(features); }
    out({ feature: f.id, removed });
    break;
  }
  case 'alias': {
    need(2);
    const features = load(); const f = find(features, idArg(args[0])); const a = textArg(args.slice(1).join(' '));
    if (!f.aliases.some((x) => norm(x) === norm(a))) { f.aliases.push(a); f.updated_utc = now(); save(features); }
    out({ feature: f.id, aliases: f.aliases });
    break;
  }
  case 'rename': {
    need(2);
    const features = load(); const f = find(features, idArg(args[0]));
    f.name = textArg(args.slice(1).join(' ')); f.updated_utc = now(); save(features);
    out({ feature: f.id, name: f.name });
    break;
  }
  case 'merge': {
    need(2);
    const features = load(); const from = find(features, idArg(args[0])); const into = find(features, idArg(args[1]));
    if (from === into) die('merge needs two different features');
    into.members = [...new Set([...into.members, ...from.members])];
    for (const a of [from.name, ...from.aliases]) if (![into.name, ...into.aliases].some((x) => norm(x) === norm(a))) into.aliases.push(a);
    into.updated_utc = now();
    save(features.filter((f) => f !== from));
    out({ feature: into.id, members: into.members });
    break;
  }
  case 'drop': {
    need(1);
    const features = load(); const f = find(features, idArg(args[0]));
    save(features.filter((x) => x !== f));
    out({ feature: f.id, dropped: true });
    break;
  }
  case 'check': {
    const text = read(FILE);
    const problems = []; const warnings = [];
    if (text == null) { out({ ok: true, problems, warnings: ['work/FEATURES.md not created yet'] }); break; }
    if (!text.split('\n').includes(HEADER)) problems.push('header changed');
    const seen = new Set();
    for (const r of rows(text)) {
      const [id, name, aliases, members, utc] = r;
      if (r.length !== 5) { problems.push(`row "${r.join(' | ')}": ${r.length} cells, not 5`); continue; }
      if (!ID_RE.test(id)) problems.push(`"${id}": not a feature id`);
      if (seen.has(id)) problems.push(`"${id}": twice`); seen.add(id);
      if (!TEXT_RE.test(name)) problems.push(`${id}: the name is empty or too long`);
      for (const a of list(aliases, ';')) if (!TEXT_RE.test(a)) problems.push(`${id}: alias "${a.slice(0, 40)}" too long`);
      for (const m of list(members, ',')) {
        const x = memberOf(m);
        if (!x) problems.push(`${id}: "${m}" is not a member`);
        else if (!x.tier) warnings.push(`${id}: ${m} has no test in work/SUITE.md`);
        else if (!RECURRING.has(x.tier)) warnings.push(`${id}: ${m} is ${x.tier} — not run with the feature`);
      }
      if (utc && utc !== '-' && !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(utc)) problems.push(`${id}: updated_utc "${utc}" is not an ISO UTC time`);
    }
    out({ ok: problems.length === 0, problems, warnings });
    break;
  }
  case 'record': {
    need(2);
    const label = args[0];
    const bi = args.indexOf('--build'); const build = bi >= 0 ? args[bi + 1] : null;
    if (!/^[A-Za-z0-9._-]{1,120}$/.test(label ?? '') || !build || !/^[A-Za-z0-9._+-]{1,80}$/.test(build)) die('usage: features.mjs record <label> <feature> --build <candidate>');
    const f = resolved(find(load(), idArg(args[1])));
    let report;
    try { report = JSON.parse(readFileSync(join(runsRoot, label, 'report.json'), 'utf8')); } catch { die(`no report.json for run ${label}`); }
    const wanted = f.runnable.map(memberOf);
    const results = {};
    for (const r of report.run?.results ?? []) {
      const tags = r.tags ?? [];
      const id = tags.map((t) => /^ac-(\d+)$/.exec(t)).find(Boolean);
      if (!id) continue; // explorations are not recurring tests
      const ac = `AC-${id[1]}`;
      const m = wanted.find((w) => tags.includes(w.stem) && (!w.ac || w.ac === ac));
      if (!m) continue;
      const att = r.attempts?.at(-1) ?? {};
      results[`${m.stem}/${ac}`] = { status: r.status === 'passed' ? 'passed' : r.status === 'failed' ? 'failed' : 'blocked',
        error: att.error?.message ? String(att.error.message).replace(/\s+/g, ' ').slice(0, 400) : null };
    }
    const dir = join(work, 'reruns', `feature-${f.id}`);
    mkdirSync(dir, { recursive: true });
    const file = join(dir, `${label}.json`);
    writeFileSync(`${file}.tmp`, `${JSON.stringify({ label, feature: f.id, name: f.name, build, utc: now(), results, skipped: f.skipped }, null, 2)}\n`);
    renameSync(`${file}.tmp`, file);
    out({ file, feature: f.id, build, results, skipped: f.skipped });
    break;
  }
  default: die('usage: features.mjs list|resolve|add|remove|alias|rename|merge|drop|check|record — see its header');
}
