#!/usr/bin/env node
// pr-text.mjs — a pull request's text as the Change radar may read it (docs/radar.md): of each pull
// request the target's issues listing names, its number, title, body, labels, state, draft flag,
// update time and merge time, and nothing else — never a link GitHub puts beside it (diff, patch,
// files), never its author. The title and the body are sanitized here, before anything reads them:
// HTML comments, code blocks (fenced and indented), lines that look like code or a diff, inline code,
// links and URLs (a link keeps its text), images, HTML tags, file paths and commit hashes go; the
// title is cut to 200 characters, the body to 2000. What is left is prose — data, never instructions.
//
//   node pr-text.mjs < <issues listing JSON array>   -> [{number, title, body, labels, state, draft, updated_at, merged_at}]
// `state`: open | merged | closed (closed without a merge). scripts/github.sh prs is its one caller.

import { readFileSync } from 'node:fs';

export const TITLE_MAX = 200;
export const BODY_MAX = 2000;
const EXT = 'tsx?|jsx?|mjs|cjs|json|ya?ml|toml|py|go|rs|java|kts?|rb|php|cs|cpp|hpp|cc|c|h|sh|bash|zsh|ps1|sql|css|scss|less|html?|vue|svelte|md|mdx|lock|gradle|xml|proto|tf|tfvars|ini|env|cfg|conf|properties|swift|dart|lua|exs?|erl|scala|clj|graphql|gql|dockerfile|mk|patch|diff|txt|log|csv';
const SEG = '[A-Za-z0-9_.@+-]';

// One line of prose made safe: no inline code, link target, URL, tag, path or hash.
function inline(s) {
  return s
    .replace(/``[^`\n]*``|`[^`\n]*`/g, ' ')
    .replace(/!\[[^\]\n]*\]\([^)\n]*\)/g, ' ')
    .replace(/\[([^\]\n]*)\]\([^)\n]*\)/g, '$1')
    .replace(/\[([^\]\n]*)\]\[[^\]\n]*\]/g, '$1')
    .replace(/<(?:https?|ftp|mailto):[^>\s]*>/gi, ' ')
    .replace(/<\/?[A-Za-z][^>\n]*>/g, ' ')
    .replace(/\b(?:https?|ftp|file|git|ssh|svn):\/\/\S+/gi, ' ')
    .replace(/\bwww\.\S+/gi, ' ')
    .replace(/\b[\w.-]+@[\w.-]+:\S+/g, ' ')
    // Paths: absolute or relative (/a, ./a, ~/a), two slashes or more, a file with a code extension,
    // a Windows or backslash path.
    .replace(/(?:[A-Za-z]:)?\\*(?:[\w.-]+\\+)+[\w.-]+/g, ' ')
    .replace(new RegExp(`(?:^|(?<=[\\s(\\["'*_]))(?:~|\\.{1,2})?\\/${SEG}+(?:\\/${SEG}*)*`, 'g'), ' ')
    .replace(new RegExp(`${SEG}+(?:\\/${SEG}+){2,}\\/?`, 'g'), ' ')
    .replace(new RegExp(`(?:${SEG}+\\/)*${SEG}*\\.(?:${EXT})\\b(?![\\w-])`, 'gi'), ' ')
    // A commit hash: 7–40 hex digits with a digit and a letter.
    .replace(/\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b/gi, ' ')
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, ' ')
    .replace(/[ \t]+/g, ' ')
    .replace(/ ([,.;:!?])/g, '$1')
    .replace(/([,;:])(?: ?[,;:])+/g, '$1')
    .trim();
}

const DIFF = /^(?:diff --git |index [0-9a-f]+\.\.|@@ |\+\+\+ \S|--- \S|\+|-(?![ \t-]|$)|-[ \t]{2,}\S)/;
const CODE = /^\s*(?:import|export|const|let|var|function|def|class|return|public|private|protected|package|using|namespace|#include|#define|SELECT|INSERT|UPDATE|DELETE FROM)\b|[;{}]\s*$|^\s*[)\]}]+[;,]?\s*$|=>|::|\)\s*\{/;
const LIST = /^\s*(?:[-*+]|\d+[.)])\s/;

const cut = (s, n) => (s.length > n ? `${s.slice(0, n - 1).trimEnd()}…` : s);

export function sanitizeTitle(raw) {
  return cut(inline(String(raw ?? '').replace(/<!--[\s\S]*?(?:-->|$)/g, ' ').replace(/[\r\n]+/g, ' ')), TITLE_MAX);
}

export function sanitizeBody(raw) {
  const text = String(raw ?? '').replace(/\r\n?/g, '\n').replace(/<!--[\s\S]*?(?:-->|$)/g, '\n');
  const out = []; let fence = null; let prevBlank = true;
  for (const line of text.split('\n')) {
    const f = /^\s*(`{3,}|~{3,})/.exec(line);
    if (fence) { if (f && f[1][0] === fence[0] && f[1].length >= fence.length) fence = null; continue; }
    if (f) { fence = f[1]; continue; }
    const blank = !line.trim();
    // An indented code block: four spaces or a tab, not a nested list item.
    const code = /^(?: {4,}|\t)/.test(line) && !LIST.test(line);
    if (blank) { prevBlank = true; continue; }
    if (code || DIFF.test(line) || CODE.test(line) || /^\s*\[[^\]]+\]:\s*\S/.test(line)) continue;
    const s = inline(line);
    if (!s || /^[-*+>#\d.)\s|]*$/.test(s)) continue;
    if (prevBlank && out.length) out.push('');
    out.push(s); prevBlank = false;
  }
  return cut(out.join('\n').trim(), BODY_MAX);
}

// One pull request of the issues listing, reduced to what the radar may read.
export function prOf(it) {
  const merged = it?.pull_request?.merged_at ?? null;
  return {
    number: it.number,
    title: sanitizeTitle(it.title),
    body: sanitizeBody(it.body),
    labels: (Array.isArray(it.labels) ? it.labels : []).map((l) => sanitizeTitle(typeof l === 'string' ? l : l?.name).slice(0, 50)).filter(Boolean),
    state: it.state === 'open' ? 'open' : merged ? 'merged' : 'closed',
    draft: it.draft === true,
    updated_at: typeof it.updated_at === 'string' ? it.updated_at : null,
    merged_at: typeof merged === 'string' ? merged : null,
  };
}

export const prsOf = (listing) => (Array.isArray(listing) ? listing : [])
  .filter((it) => it && typeof it === 'object' && it.pull_request && Number.isInteger(it.number) && it.number > 0)
  .map(prOf);

if (import.meta.url === `file://${process.argv[1]}`) {
  let listing;
  try { listing = JSON.parse(readFileSync(0, 'utf8')); } catch { console.error('pr-text: stdin is not a JSON listing'); process.exit(2); }
  if (!Array.isArray(listing)) { console.error('pr-text: stdin is not a JSON array'); process.exit(2); }
  console.log(JSON.stringify(prsOf(listing)));
}
