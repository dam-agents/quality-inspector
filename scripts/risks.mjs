#!/usr/bin/env node
// risks.mjs — the register of product risks, work/RISKS.md (docs/risks.md): one rule per thing that went
// wrong before (an escaped defect, a lesson, the operator's word), each with a trigger read from the text an
// issue run already has — the issue's words and labels, never its code — and one check a user can see. The
// issues run asks `match` for the rules an issue's text meets and runs each as an exploration of heuristic
// `risk` (docs/explorations.md), outside every verdict. A new rule starts in `observe`: it runs and counts,
// but the report does not show it; the operator moves it to `enforce` (shown under "Beyond the criteria")
// or `retired` once its counts say whether it finds anything.
//
//   node risks.mjs add --trigger-file <path> --check-file <path> --source <E-k|L-<yyyy-mm-dd>|operator> [--mode enforce]
//     -> {"id", "mode", "triggers": []}        --mode enforce is the operator's, in the direct session only
//   node risks.mjs match --text-file <path> [--label <name>]…
//     -> {"risks": [{id, mode, check, matched}], "cap", "left_out": []}   the active rules the text or a label meets
//   node risks.mjs hit <R-k> --result ok|observation|blocked --ref <#N EX-k>   -> {"id", "runs", "observations"}
//   node risks.mjs set <R-k> observe|enforce|retired   -> {"id", "mode"}   the operator's, in the direct session only
//   node risks.mjs list [--active]     -> {"risks": [{id, mode, triggers[], check, source, added_utc, runs, observations, last_utc, last_ref}]}
//   node risks.mjs check               -> {"ok", "problems": [], "ready": [], "stale": [], "lessons_old": <n>}
//
// The two files are the one call's own `mktemp /tmp/quality-inspector-words.XXXXXX` (lib/words.mjs), written
// with a file tool, since an issue's words may hold a quote. A trigger file has one trigger a line:
// `word: <a word or phrase>` (the issue's title, body or frozen criteria hold it as whole words, any case) or
// `label: <label name>` (the issue carries it); at most 8. The check file is one sentence: what a user does and
// what every correct product shows ("Given … When … Expected …"). Cells are kept to 200 characters, without
// `|`, back quotes or line breaks.
// `match` orders `enforce` before `observe`, then the rules that found more, then the older; it returns at most
// `max_risk_checks_per_issue` (3; 0 = none), the rest in `left_out`.
// `check` (the weekly audit): the format; `ready` — an `observe` rule with at least 5 runs, for the operator to
// enforce (it found something) or retire (it never did); `stale` — an active rule no issue met in 90 days;
// `lessons_old` — the dated lines of work/LESSONS.md older than 180 days, to prune.
// Every write holds the register's mutex (lib/mutex.mjs). Exit 2: usage or a malformed value, the file left as
// it was; exit 1: locked.

import { join } from 'node:path';
import { withMutex, writeAtomic } from './lib/mutex.mjs';
import { WORK as work, now, read, sh, tableRows } from './lib/util.mjs';
import { takeWords } from './lib/words.mjs';

const FILE = join(work, 'RISKS.md');
const TITLE = '# Risks — what went wrong before, and the check that looks for it again (docs/risks.md)';
const COLS = ['id', 'mode', 'triggers', 'check', 'source', 'added_utc', 'runs', 'observations', 'last_utc', 'last_ref'];
const HEADER = `| ${COLS.join(' | ')} |`;
const MODES = ['observe', 'enforce', 'retired'];
const RESULTS = ['ok', 'observation', 'blocked'];
const ID_RE = /^R-\d{1,6}$/;
const SOURCE_RE = /^(E-\d{1,6}|L-\d{4}-\d\d-\d\d|operator)$/;
const REF_RE = /^#\d{1,7} EX-\d{1,3}$/;
const UTC_RE = /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/;
const DAY = 86400000;

class Usage extends Error {}
const die = (msg) => { throw new Usage(msg); };
const out = (o) => console.log(JSON.stringify(o));
const cell = (raw) => String(raw ?? '').replace(/[|\r\n\u0000-\u001f`]+/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 200);

// ------------------------------------------------------------------ triggers
// One trigger: {kind: word|label, value}. Stored as `word:upload; label:area/files`.
function parseTriggers(text) {
  const list = [];
  for (const line of String(text ?? '').split('\n').map((l) => l.trim()).filter(Boolean)) {
    const m = /^(word|label)\s*:\s*(.+)$/i.exec(line);
    if (!m) die(`trigger "${cell(line).slice(0, 60)}" is not "word: <phrase>" or "label: <name>"`);
    const value = cell(m[2]).replace(/;/g, ' ').trim().toLowerCase();
    if (value.length < 3 || value.length > 60) die(`trigger "${value}" is not 3 to 60 characters`);
    list.push({ kind: m[1].toLowerCase(), value });
  }
  if (!list.length) die('the trigger file names no trigger');
  if (list.length > 8) die('at most 8 triggers a rule');
  return list;
}
const showTriggers = (list) => list.map((t) => `${t.kind}:${t.value}`).join('; ');
const readTriggers = (s) => String(s ?? '').split(';').map((x) => x.trim()).filter(Boolean).map((x) => {
  const i = x.indexOf(':'); return { kind: x.slice(0, i), value: x.slice(i + 1) };
});
const escRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
// A whole-word match in any case: no letter or digit right before or after the phrase; spaces match any run of white space.
const wordIn = (phrase, text) => new RegExp(`(?<![\\p{L}\\p{N}])${escRe(phrase).replace(/ +/g, '\\s+')}(?![\\p{L}\\p{N}])`, 'iu').test(text);

// ------------------------------------------------------------------ the register
function load() {
  const text = read(FILE);
  if (text != null && !text.split('\n').includes(HEADER)) die('work/RISKS.md: header changed — fix it to the format of docs/risks.md');
  return tableRows(text).map((r) => Object.fromEntries(COLS.map((k, j) => [k, r[j] ?? '-'])));
}
function save(list) {
  const body = list.map((r) => `| ${COLS.map((k) => r[k] || '-').join(' | ')} |`);
  writeAtomic(FILE, `${TITLE}\n\n${HEADER}\n| ${COLS.map(() => '---').join(' | ')} |\n${body.join('\n')}${body.length ? '\n' : ''}`);
}
const nextId = (list) => `R-${Math.max(0, ...list.map((r) => +(/^R-(\d+)$/.exec(r.id)?.[1] ?? 0))) + 1}`;
const view = (r) => ({ id: r.id, mode: r.mode, triggers: readTriggers(r.triggers).map((t) => `${t.kind}:${t.value}`), check: r.check,
  source: r.source, added_utc: r.added_utc, runs: +r.runs || 0, observations: +r.observations || 0,
  last_utc: r.last_utc === '-' ? null : r.last_utc, last_ref: r.last_ref === '-' ? null : r.last_ref });
const cap = () => { const raw = sh('cfg max_risk_checks_per_issue'); const n = Number(raw || 3); return Number.isInteger(n) && n >= 0 && n <= 10 ? n : 3; };

const [cmd, ...args] = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const flags = (name) => args.flatMap((a, i) => (a === name ? [args[i + 1]] : []));
const idArg = () => { const id = args[0]; if (!ID_RE.test(id ?? '')) die(`usage: risks.mjs ${cmd} <R-k>`); return id; };
const find = (list, id) => list.find((r) => r.id === id) ?? die(`no ${id} in work/RISKS.md`);
const operatorOnly = (what) => { if (sh('direct_session && echo yes') !== 'yes') die(`${what} is the operator's, in the direct session only`); };
const locked = (fn) => withMutex(`${FILE}.lock`, fn);
const take = (name) => { const p = flag(name); if (!p) die(`${name} <path> is required`); try { return takeWords(p, 'words'); } catch (e) { return die(e.message); } };

function main() {
  switch (cmd) {
    case 'add': {
      const source = flag('--source'); const mode = flag('--mode') ?? 'observe';
      if (!SOURCE_RE.test(source ?? '')) die('--source is E-<k>, L-<yyyy-mm-dd> (a line of work/LESSONS.md) or operator');
      if (!['observe', 'enforce'].includes(mode)) die('--mode is observe or enforce');
      if (mode === 'enforce') operatorOnly('a rule that starts enforced');
      const triggers = parseTriggers(take('--trigger-file'));
      const check = cell(take('--check-file'));
      if (check.length < 20) die('the check is one sentence: what a user does and what a correct product shows');
      locked(() => {
        const list = load();
        const same = list.find((r) => r.mode !== 'retired' && r.check.toLowerCase() === check.toLowerCase());
        if (same) die(`${same.id} already holds this check`);
        const id = nextId(list);
        list.push({ id, mode, triggers: showTriggers(triggers), check, source, added_utc: now(), runs: '0', observations: '0', last_utc: '-', last_ref: '-' });
        save(list);
        out({ id, mode, triggers: triggers.map((t) => `${t.kind}:${t.value}`) });
      });
      break;
    }
    case 'match': {
      const text = take('--text-file');
      const labels = flags('--label').map((l) => cell(l).toLowerCase());
      const hits = [];
      for (const r of load().filter((x) => x.mode === 'observe' || x.mode === 'enforce')) {
        const t = readTriggers(r.triggers).find((x) => (x.kind === 'label' ? labels.includes(x.value) : x.kind === 'word' && wordIn(x.value, text)));
        if (t) hits.push({ id: r.id, mode: r.mode, check: r.check, matched: `${t.kind}:${t.value}`, _o: +r.observations || 0 });
      }
      hits.sort((a, b) => (a.mode === b.mode ? 0 : a.mode === 'enforce' ? -1 : 1) || b._o - a._o || +a.id.slice(2) - +b.id.slice(2));
      const n = cap();
      const strip = ({ _o, ...h }) => h;
      out({ risks: hits.slice(0, n).map(strip), cap: n, left_out: hits.slice(n).map((h) => h.id) });
      break;
    }
    case 'hit': {
      const id = idArg(); const result = flag('--result'); const ref = flag('--ref');
      if (!RESULTS.includes(result)) die(`--result is one of ${RESULTS.join(', ')}`);
      if (!REF_RE.test(ref ?? '')) die('--ref is the exploration that ran it: "#<n> EX-<k>"');
      locked(() => {
        const list = load(); const r = find(list, id);
        if (r.mode === 'retired') die(`${id} is retired`);
        r.runs = String((+r.runs || 0) + 1);
        if (result === 'observation') r.observations = String((+r.observations || 0) + 1);
        r.last_utc = now(); r.last_ref = ref;
        save(list);
        out({ id, runs: +r.runs, observations: +r.observations });
      });
      break;
    }
    case 'set': {
      const id = idArg(); const mode = args[1];
      if (!MODES.includes(mode)) die(`usage: risks.mjs set <R-k> ${MODES.join('|')}`);
      operatorOnly('set');
      locked(() => { const list = load(); find(list, id).mode = mode; save(list); out({ id, mode }); });
      break;
    }
    case 'list': {
      const all = load();
      out({ risks: (args.includes('--active') ? all.filter((r) => r.mode !== 'retired') : all).map(view) });
      break;
    }
    case 'check': {
      const problems = []; const ready = []; const stale = []; let list = [];
      try { list = load(); } catch (e) { problems.push(e.message); }
      const ms = Date.now(); const seen = new Set();
      for (const r of list) {
        const at = r.id;
        if (!ID_RE.test(r.id) || seen.has(r.id)) problems.push(`${at}: id "${r.id}" malformed or twice`);
        seen.add(r.id);
        if (!MODES.includes(r.mode)) problems.push(`${at}: mode "${r.mode}"`);
        if (!SOURCE_RE.test(r.source)) problems.push(`${at}: source "${r.source}"`);
        if (!UTC_RE.test(r.added_utc)) problems.push(`${at}: added_utc "${r.added_utc}"`);
        if (r.last_utc !== '-' && !UTC_RE.test(r.last_utc)) problems.push(`${at}: last_utc "${r.last_utc}"`);
        if (!/^\d{1,6}$/.test(r.runs) || !/^\d{1,6}$/.test(r.observations) || +r.observations > +r.runs) problems.push(`${at}: runs "${r.runs}", observations "${r.observations}"`);
        try { parseTriggers(readTriggers(r.triggers).map((t) => `${t.kind}: ${t.value}`).join('\n')); } catch (e) { problems.push(`${at}: ${e.message}`); }
        if (r.mode === 'observe' && +r.runs >= 5) ready.push({ id: r.id, runs: +r.runs, observations: +r.observations, suggest: +r.observations > 0 ? 'enforce' : 'retire' });
        const since = Date.parse(r.last_utc !== '-' ? r.last_utc : r.added_utc);
        if (r.mode !== 'retired' && Number.isFinite(since) && ms - since > 90 * DAY) stale.push({ id: r.id, since: r.last_utc !== '-' ? r.last_utc : r.added_utc });
      }
      const lessonsOld = (read(join(work, 'LESSONS.md')) ?? '').split('\n')
        .map((l) => /^\s*(?:[-*]\s*)?(\d{4}-\d\d-\d\d)/.exec(l)?.[1]).filter(Boolean)
        .filter((d) => ms - Date.parse(`${d}T00:00:00Z`) > 180 * DAY).length;
      out({ ok: !problems.length, problems, ready, stale, lessons_old: lessonsOld });
      break;
    }
    default: die('usage: risks.mjs add|match|hit|set|list|check');
  }
}

try { main(); } catch (e) {
  if (e instanceof Usage) { console.error(`risks.mjs: ${e.message}`); process.exit(2); }
  if (/stays locked/.test(e.message)) { console.error(`risks.mjs: ${e.message}`); process.exit(1); }
  throw e;
}
