// match.mjs — how a test source is matched against the UI map, shared by impact.mjs (what a
// UI change touches) and coverage.mjs (what the suite reaches). Pure functions, no I/O.

export const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// A test opens a page when a quoted URL literal (or one after `${base}`) starts with its
// pattern; `:id` segments match any one segment. `subpaths` also counts '/a/b' as opening '/a'.
export function pageRe(pattern, { subpaths = false } = {}) {
  const body = pattern.split('/').map((s) => (s === ':id' ? '[^/\'"`?#\\s]+' : esc(s))).join('/');
  return new RegExp(`['"\`}]${body}(?:[?#'"\`${subpaths ? '/' : ''}])`);
}

// A control is named when its label appears as a whole word (any case); `quoted` requires
// it inside one quoted string — a locator name or an agent instruction.
export function controlRe(name, { quoted = false } = {}) {
  const word = `(?<![A-Za-z0-9])${esc(name)}(?![A-Za-z0-9])`;
  return new RegExp(quoted ? `['"\`][^'"\`\\n]*?${word}[^'"\`\\n]*?['"\`]` : word, 'i');
}

// Too short to match on its own ("OK", "Go").
export const matchable = (s) => !!s && s.length >= 3;

// The 0-based line of the first match, or -1.
export const firstLine = (src, re) => src.split('\n').findIndex((l) => re.test(l));

// Whether line `idx` sits inside an `// AC-<k> begin` … `end` block.
export function insideAc(src, idx) {
  const lines = src.split('\n');
  for (let i = idx; i >= 0; i--) {
    if (/\/\/\s*AC-\d+\s+end/.test(lines[i]) && i !== idx) return false;
    if (/\/\/\s*AC-\d+\s+begin/.test(lines[i])) return true;
  }
  return false;
}
