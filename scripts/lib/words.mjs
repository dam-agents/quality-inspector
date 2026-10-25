// words.mjs — words from a person or an issue (a feature query, name or alias; a proposal's basis)
// reach scripts/features.mjs and scripts/maintenance.mjs only through a file, never on a command
// line, where a quote in them would end the argument (docs/features.md, docs/maintenance.md). The
// file is one call's own: what `mktemp /tmp/quality-inspector-<kind>.XXXXXX` makes, so two sessions
// never share one, and the script removes it once read, so none is left behind. It lies in /tmp
// (/private/tmp on macOS), the one folder outside work/ where scripts/hooks/policy.sh lets the file
// tool write — never under $TMPDIR, which mktemp's own -t option would follow. QI_WORDS_DIR replaces /tmp in
// the offline tests.

import { readFileSync, rmSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';

const DIRS = process.env.QI_WORDS_DIR ? [resolve(process.env.QI_WORDS_DIR)] : ['/tmp', '/private/tmp'];

// takeWords(<path>, 'words'|'basis'): the file's text, the file then removed. Throws when the file is
// not one mktemp made for <kind> in /tmp, or cannot be read (it is then left as it is).
export function takeWords(path, kind) {
  if (!new RegExp(`^quality-inspector-${kind}\\.[A-Za-z0-9]{6,}$`).test(basename(String(path))) || !DIRS.includes(dirname(resolve(String(path))))) {
    throw new Error(`${path}: not a file of \`mktemp /tmp/quality-inspector-${kind}.XXXXXX\` — one per call`);
  }
  let text;
  try { text = readFileSync(path, 'utf8'); } catch { throw new Error(`${path}: cannot read the file`); }
  rmSync(path, { force: true });
  return text;
}
