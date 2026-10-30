#!/usr/bin/env node
// scan-issues.mjs — the issues pre-flight's per-issue decisions in one process: spec text,
// ac_hash, spec lint (with injection suspects), the QA.md row, lock age and liveness, the retest gate, the cap.
// A shell loop forked a dozen tools per issue; this keeps the Precheck far inside its two
// minutes. Byte-for-byte the same spec text and hash as lib/state.sh (test_scan_parity.sh).
//
//   scan-issues.mjs <listing.json> <QA.md> <events-dir>   -> {"due":[…],"reports":[…],"waiting":[…],"logs":[…],"deferred":n}
//   scan-issues.mjs --missing <listing.json>               -> the issues the listing's pull requests close but
//                                                             the listing lacks, as one JSON array of numbers
// Env: QI_OPERATOR_FILE (work/OPERATOR.md), QI_RETEST_LABEL, QI_MAX_ISSUES, QI_LOCK_TTL_MIN, QI_NOW_EPOCH, QI_ENV_LOCK (lib/lock.sh state),
// QI_DEPLOY_GATE (enabled | disabled), QI_CANDIDATE, QI_CANDIDATE_BUILT (the candidate's publish time, bin/build-time; empty = unknown).

import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { gherkinBlocks, isPureGherkin, parseAll } from './gherkin.mjs';
import { prOf } from './pr-text.mjs';

export const VAGUE = /\b(better|faster|improve[sd]?|properly|correctly|nicer|cleaner|robust|seamless|intuitive|as expected|should work|works? well|user-friendly|etc\.?)\b/gi;
const DONE = /^#{1,6}[ \t]+[Dd]one[ \t]+[Ww]hen[ \t]*$/;

// Same as state.sh issue_spec_text: the "Done when" section (to the next heading of the
// same or a higher level), else the whole body; the title first.
export function specText(title, body) {
  const lines = String(body ?? '').replace(/\r/g, '').split('\n');
  let on = false, lvl = 0; const sec = [];
  for (const l of lines) {
    if (!on && DONE.test(l)) { on = true; lvl = l.indexOf(' '); continue; }
    if (on && /^#{1,6}[ \t]/.test(l)) { const n = l.search(/[ \t]/); if (n <= lvl) break; }
    if (on) sec.push(l);
  }
  const s = sec.join('\n');
  return s.replace(/\s/g, '') ? `${title}\n${s}\n` : `${title}\n${String(body ?? '').replace(/\r/g, '')}\n`;
}
// The operator's answers to an issue's open questions (work/OPERATOR.md, "<date> — #<n> Q-<k>: …")
// join the hashed text, so an answer is a new ac_hash and a new freeze. Same as state.sh operator_answers.
export function operatorAnswers(text, n) {
  const re = new RegExp(`#${n} Q-[0-9]+:`);
  return String(text ?? '').replace(/\r/g, '').split('\n').filter((l) => re.test(l)).join('\n');
}
export const hasDoneWhen = (body) => String(body ?? '').split('\n').some((l) => /^#{1,6}[ \t]+done[ \t]+when[ \t]*$/i.test(l.replace(/\r$/, '')));
// Same as state.sh text_hash: whitespace runs to one space, trimmed, sha256, 12 hex.
export const textHash = (t) => createHash('sha256').update(t.replace(/\s+/g, ' ').replace(/^ /, '').replace(/ $/, '')).digest('hex').slice(0, 12);
// Prompt-injection suspects: sentences of the spec that address the agent instead of
// describing the product. Each pattern runs on one sentence with its bullet marker
// stripped. A product verb (run, delete, fetch, open, post, mark/report) is product
// behavior too, so it counts only aimed at the agent — an imperative at the sentence's
// start, after up to two leading words (LEAD: "Then", "Next,", "Then just") or after
// "please" or "kindly", or anywhere in a sentence that addresses a QA agent ("QA agent:
// … and post a comment") — or aimed at the tracker or the issue itself ("open this link").
// "the user can delete an item" and "asks the agent to open a pull request" stay criteria.
// A matched sentence is frozen as an instruction (docs/acceptance-criteria.md).
// One list, here; nothing else may restate it.
const ADDRESS = String.raw`\b(?:qa|test|testing)[ -]?(?:agent|bot|assistant|tester)\s*[:,]`;
const LEAD = String.raw`(?:then|next|now|first|finally|lastly|afterwards?|also|just|simply),? `;
const verb = (id, phrase, tracker) => ({ id, re: new RegExp(
  String.raw`(?:^(?:${LEAD}){0,2}|\b(?:kindly |please ))${phrase}|^(?=.*${ADDRESS}).*\b${phrase}|\b${tracker}`, 'i') });
export const INJECTION = [
  { id: 'ignore', re: /\bignore (?:the|all|any|previous|prior|above|your)\b/i },
  { id: 'agent-role', re: /\bas (?:the|an?) (?:qa|test|testing|ai)[ -]?(?:agent|bot|assistant|model)\b/i },
  { id: 'agent-address', re: /^(?:dear )?(?:qa|test|ai) (?:agent|bot|assistant)\s*[:,]/i },
  { id: 'you-must', re: /\byou (?:must|should|are)\b(?! (?:able|now|then|shown|redirected|taken|asked|prompted|signed|logged|notified|presented|see|get|receive)\b)/i },
  verb('run', '(?:run|execute) ', String.raw`(?:run|execute) (?:this|these|the following)\b`),
  { id: 'curl', re: /\b(?:curl|wget) /i },
  verb('post-comment', String.raw`post (?:a|the|this) comment\b`,
    String.raw`post (?:this comment|(?:a|the) comment (?:on|to|in|under) (?:this|the) (?:issue|pr|pull request))\b`),
  verb('delete', 'delete ', String.raw`delete (?:this (?:issue|repo|repository|branch|comment|label|file)s?|the (?:issue|repo|repository))\b`),
  verb('fetch', 'fetch ', String.raw`fetch this (?:url|link|page|file)\b`),
  verb('open-link', String.raw`open (?:this|the|a) (?:pr|pull request|link|url)\b`, String.raw`open this (?:pr|pull request|link|url)\b`),
  verb('mark-passed', String.raw`(?:mark|report)\b.{0,60}?\b(?:as )?(?:passed|verified)\b`,
    String.raw`(?:mark|report)\b.{0,60}?\b(?:acs?|criteri(?:on|a)|everything|(?:this|the) issue)\b.{0,60}?\b(?:passed|verified)\b`),
];
const sentences = (t) => t.replace(/<!--|-->/g, '\n').split(/\n|(?<=[.!?])\s+/)
  .map((x) => x.replace(/^[ \t]*(?:[-*+]|[0-9]+[.)]|>)[ \t]+/, '').trim()).filter(Boolean);
export function injectionLint(spec) {
  const urls = (spec.match(/\bhttps?:\/\/\S+|\bwww\.\S+/gi) ?? []).length;
  // A pure-Gherkin block (lib/gherkin.mjs → isPureGherkin) is criteria, not code: its fence pair
  // is not counted. A block with a doc string, free text, an error or no closing fence counts as
  // code like any other. Every sentence is scanned below either way.
  const fenceLines = spec.split('\n').filter((l) => /^[ \t]*(```|~~~)/.test(l)).length;
  const pure = gherkinBlocks(spec).filter(isPureGherkin).length;
  const code_fences = Math.max(0, Math.ceil(fenceLines / 2) - pure);
  const html_comments = (spec.match(/<!--/g) ?? []).length;
  const imperatives = [];
  for (const s of sentences(spec)) {
    const hit = INJECTION.filter((p) => p.re.test(s)).map((p) => p.id);
    if (hit.length) imperatives.push({ patterns: hit, sentence: s.slice(0, 240) });
  }
  return { injection: { urls, code_fences, html_comments, imperatives },
    injection_suspect: urls + code_fences + html_comments + imperatives.length > 0 };
}
export function specLint(title, body) {
  const spec = specText(title, body).split('\n').slice(1).join('\n');
  const items = spec.split('\n').filter((l) => /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/.test(l)).length;
  const vague = [...new Set((spec.match(VAGUE) ?? []).map((w) => w.toLowerCase()))].sort();
  const words = spec.split(/\s+/).filter(Boolean).length;
  const d = hasDoneWhen(body);
  // gherkin: the spec's ```gherkin blocks as criteria — {blocks, acs, errors}, or null without one.
  const blocks = gherkinBlocks(spec);
  const g = blocks.length ? parseAll(blocks.map((b) => ({ text: b.text, offset: b.line }))) : null;
  const gherkin = g ? { blocks: g.blocks, acs: g.acs.length, errors: g.errors.slice(0, 5) } : null;
  return { has_done_when: d, items, vague, words, weak: items === 0 && !(gherkin?.acs) && (!d || words < 8), gherkin,
    ...injectionLint(`${title}\n${spec}`) };
}

// The deploy gate (docs/issue-qa.md → The deploy gate): an issue is tested only on a build
// published after its change merged. A pull request carrying the QA label stands for the issues it
// closes — GitHub's closing keywords before a `#<n>` of the same repository, read from its sanitized
// text (lib/pr-text.mjs) and nothing else of it.
const CLOSES = /(?:^|[^\w/#-])(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)[ \t]*:?[ \t]+#(\d{1,7})\b/gi;
export function closingRefs(pr) {
  const p = prOf(pr); const out = new Set();
  for (const t of [p.title, p.body]) for (const m of t.matchAll(CLOSES)) out.add(Number(m[1]));
  return [...out].filter((n) => n > 0 && n !== p.number).sort((a, b) => a - b);
}
// The labelled pull requests of a listing, each with the issues it closes.
export function labelledPrs(listing) {
  return listing.filter((x) => x && x.pull_request && Number.isInteger(x.number))
    .map((x) => ({ ...prOf(x), closes: closingRefs(x) }));
}
// issue: a listing item; prs: the labelled pull requests that close it; built: the candidate's
// publish time (ISO) or ''. The merge time is the latest of the merged pull requests' merged_at and,
// for an issue closed as completed, its closed_at: every change must be in the build.
export function deployGate(issue, prs, built, candidate = 'the candidate') {
  const open = prs.filter((p) => p.state === 'open');
  if (open.length) return { ok: false, reason: `pull request ${open.map((p) => `#${p.number}`).join(', ')} not merged yet` };
  const times = prs.filter((p) => p.state === 'merged' && p.merged_at).map((p) => p.merged_at);
  if (issue.state === 'closed' && (issue.state_reason ?? 'completed') === 'completed' && issue.closed_at) times.push(issue.closed_at);
  const merged = times.filter((t) => Number.isFinite(Date.parse(t))).sort((a, b) => Date.parse(a) - Date.parse(b)).pop();
  if (!merged) return { ok: false, reason: issue.state === 'closed'
    ? `closed as ${issue.state_reason ?? 'not completed'} and no merged pull request with the QA label closes it`
    : 'the issue is open and no merged pull request with the QA label closes it' };
  if (!built || !Number.isFinite(Date.parse(built))) return { ok: false, reason: `merged ${merged}; the publish time of ${candidate} is unknown (profile bin/build-time)` };
  if (Date.parse(built) < Date.parse(merged)) return { ok: false, reason: `merged ${merged}; ${candidate} was published ${built}, before it — waiting for a newer build` };
  return { ok: true, merged_at: merged };
}

if (import.meta.url === `file://${process.argv[1]}` && process.argv[2] === '--missing') {
  const listing = JSON.parse(readFileSync(process.argv[3], 'utf8'));
  const have = new Set(listing.filter((x) => !x.pull_request).map((x) => x.number));
  console.log(JSON.stringify([...new Set(labelledPrs(listing).flatMap((p) => p.closes))].filter((n) => !have.has(n)).sort((a, b) => a - b)));
} else if (import.meta.url === `file://${process.argv[1]}`) {
  const [listingPath, qaPath, eventsDir] = process.argv.slice(2);
  const retest = process.env.QI_RETEST_LABEL ?? 'qa:retest';
  const max = Number(process.env.QI_MAX_ISSUES ?? 1);
  const ttl = Number(process.env.QI_LOCK_TTL_MIN ?? 180);
  // free / dead: no run holds the environment, so an in_progress row is an orphan (lib/lock.sh).
  const orphaned = ['free', 'dead'].includes(process.env.QI_ENV_LOCK ?? '');
  const now = Number(process.env.QI_NOW_EPOCH ?? Math.floor(Date.now() / 1000));
  const listing = JSON.parse(readFileSync(listingPath, 'utf8'));
  const operator = process.env.QI_OPERATOR_FILE && existsSync(process.env.QI_OPERATOR_FILE)
    ? readFileSync(process.env.QI_OPERATOR_FILE, 'utf8') : '';

  const rows = new Map();
  if (existsSync(qaPath)) {
    for (const l of readFileSync(qaPath, 'utf8').split('\n').filter((x) => x.startsWith('|')).slice(2)) {
      const c = l.split('|').slice(1, -1).map((x) => x.trim());
      if (c[0]) rows.set(c[0], { hash: c[1], status: c[5], updated: c[6] });
    }
  }
  // Newest event time per issue, from the last two daily files.
  const lastEvent = new Map();
  if (existsSync(eventsDir)) {
    for (const f of readdirSync(eventsDir).filter((x) => /^events-.*\.jsonl$/.test(x)).sort().slice(-2)) {
      for (const line of readFileSync(join(eventsDir, f), 'utf8').split('\n')) {
        if (!line) continue;
        let e; try { e = JSON.parse(line); } catch { continue; }
        const m = /(?:^|\s)issue=(\d+)(?:\s|$)/.exec(e.msg ?? '');
        if (m) { const t = Date.parse(e.ts) / 1000; if (!(lastEvent.get(m[1]) > t)) lastEvent.set(m[1], t); }
      }
    }
  }
  const mins = (iso) => Math.floor((now - (Date.parse(iso) / 1000 || 0)) / 60);

  const gate = process.env.QI_DEPLOY_GATE !== 'disabled';
  const built = process.env.QI_CANDIDATE_BUILT ?? ''; const candidate = process.env.QI_CANDIDATE || 'the candidate';
  const prs = labelledPrs(listing);
  const due = []; const reports = []; const waiting = []; const logs = []; let deferred = 0;
  for (const p of prs) logs.push(p.closes.length ? `PR #${p.number} (${p.state}): closes ${p.closes.map((n) => `#${n}`).join(', ')}`
    : `PR #${p.number}: carries the QA label but closes no issue — ignored`);
  for (const it of listing.filter((x) => !x.pull_request).sort((a, b) => a.number - b.number)) {
    const n = it.number; const title = it.title ?? ''; const body = it.body ?? '';
    const answers = operatorAnswers(operator, n);
    const hash = textHash(answers ? `${specText(title, body)}${answers}\n` : specText(title, body));
    const isRetest = (it.labels ?? []).some((l) => l.name === retest);
    const row = rows.get(String(n));
    let kind = ''; let takeover = false;
    if (!row) kind = 'first';
    else if (row.status === 'in_progress') {
      const age = mins(row.updated); const silent = Math.floor((now - (lastEvent.get(String(n)) ?? 0)) / 60);
      if (orphaned) { kind = 'takeover'; takeover = true; logs.push(`issue #${n}: in progress, but no run holds the environment (${process.env.QI_ENV_LOCK}) — takeover`); }
      else if (age >= ttl && silent >= 30) { kind = 'takeover'; takeover = true; logs.push(`issue #${n}: stale lock (${age}m old, ${silent}m silent) — takeover`); }
      else { logs.push(`issue #${n}: in progress (${age}m) — skip`); continue; }
    } else if (row.status === 'report_pending') { reports.push({ issue: n, retest_label_present: isRetest }); logs.push(`issue #${n}: report pending delivery — due`); continue; }
    else if (isRetest) kind = 'retest';
    else if (row.hash !== hash) kind = 'ac_changed';
    else { logs.push(`issue #${n}: done at ac=${hash} — skip`); continue; }
    const via = prs.filter((p) => p.closes.includes(n));
    let merged = null;
    if (gate && !takeover) {
      const g = deployGate(it, via, built, candidate);
      if (!g.ok) { waiting.push({ issue: n, kind, reason: g.reason }); logs.push(`issue #${n}: ${kind} — waiting for the deploy: ${g.reason}`); continue; }
      merged = g.merged_at;
    }
    if (due.length >= max) { deferred++; logs.push(`issue #${n}: ${kind} — deferred (max_issues_per_run)`); continue; }
    due.push({ issue: n, ac_hash: hash, kind, takeover, has_done_when: hasDoneWhen(body), retest_label_present: isRetest,
      author_association: it.author_association ?? null, via_pr: via.map((p) => p.number), merged_at: merged, spec: specLint(title, body) });
    logs.push(`issue #${n}: ${kind} (ac=${hash}) — due`);
  }
  console.log(JSON.stringify({ due, reports, waiting, logs, deferred }));
}
