// words.mjs — words from a person or an issue (a feature query, name or alias; a proposal's basis)
// reach scripts/features.mjs and scripts/maintenance.mjs only through a file, never on a command
// line, where a quote in them would end the argument (docs/features.md, docs/maintenance.md). The
// file is one call's own: its name is what `mktemp -t quality-inspector-<kind>.XXXXXX` makes, so
// two sessions never share one, and the script removes it once read, so none is left behind.

import { readFileSync, rmSync } from 'node:fs';
import { basename } from 'node:path';

// takeWords(<path>, 'words'|'basis'): the file's text, the file then removed. Throws when the name is
// not one mktemp made for <kind>, or the file cannot be read (it is then left as it is).
export function takeWords(path, kind) {
  // GNU mktemp fills the X's; BSD's -t adds its own random part after them.
  if (!new RegExp(`^quality-inspector-${kind}\\.[A-Za-z0-9.]{6,}$`).test(basename(String(path)))) {
    throw new Error(`${path}: not a file of \`mktemp -t quality-inspector-${kind}.XXXXXX\` — one per call`);
  }
  let text;
  try { text = readFileSync(path, 'utf8'); } catch { throw new Error(`${path}: cannot read the file`); }
  rmSync(path, { force: true });
  return text;
}
