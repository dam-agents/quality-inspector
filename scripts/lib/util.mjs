// util.mjs — the small helpers the node scripts share: work/, a file read that never throws, a
// markdown table's cells, the UTC time of a state row, HTML escaping, a short error message, and
// one expression of lib/config.sh and lib/profile.sh (the one CONFIG.md reader).

import { execFileSync } from 'node:child_process';
import { readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const WORK = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');

// A file's text, its JSON, its mtime (ms): null, null, 0 when it cannot be read.
export const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };
export const readJson = (p) => { try { return JSON.parse(readFileSync(p, 'utf8')); } catch { return null; } };
export const mtime = (p) => { try { return statSync(p).mtimeMs; } catch { return 0; } };

// The data rows of a markdown table text (after the header and its separator), as trimmed cells.
export const tableRows = (text) => (text ?? '').split('\n').filter((l) => l.startsWith('|')).slice(2)
  .map((l) => l.split('|').slice(1, -1).map((c) => c.trim()));

// The actual UTC time, to the second: 2026-11-02T10:00:00Z.
export const now = () => new Date().toISOString().replace(/\.\d+Z$/, 'Z');

export const escHtml = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

// An error's first line, at most 160 characters.
export const msg = (e) => String(e?.message ?? e).split('\n')[0].slice(0, 160);

// One expression of lib/config.sh and lib/profile.sh (`reg <key>`, `cfg <key>`, `profile_dir`,
// `profile_run …`): its stdout, '' on any failure; with { status: true } {out, code, err}.
export function sh(expr, { status = false } = {}) {
  try {
    const out = execFileSync('bash', ['-c', `CONFIG="$WORK/CONFIG.md"; . "$LIB/config.sh"; . "$LIB/profile.sh"; ${expr}`],
      { env: { ...process.env, WORK, LIB: here }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 90000 }).trim();
    return status ? { out, code: 0 } : out;
  } catch (e) { return status ? { out: String(e.stdout ?? '').trim(), code: e.status ?? 1, err: String(e.stderr ?? '').trim().split('\n')[0] } : ''; }
}
