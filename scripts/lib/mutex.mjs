// mutex.mjs — the short critical section of lib/lock.sh `lock_mutex`, for the node writers of a
// work/ state table (scripts/features.mjs, scripts/maintenance.mjs): a lock file created
// exclusively, holding the writer's token (pid and a random part); up to <tries> × 0.1 s (100); one
// older than a minute is a dead writer's. `writeAtomic` writes through a temp path unique to the
// writer, so two writers never share one.
//
// Nothing is removed by its name alone, since a name can change hands between two calls: a stale
// lock and the writer's own lock are first renamed to a name unique to this writer — one rename
// wins — and the moved file is then checked. A stale lock that turns out fresh, or a lock that no
// longer holds this writer's token, is linked back unless a new lock already stands. The limit: a
// third writer that takes the lock in that instant leaves two holders; it needs three writers within
// one rename and a lock left for a minute.

import { closeSync, linkSync, openSync, readFileSync, renameSync, rmSync, statSync, writeFileSync, writeSync } from 'node:fs';
import { randomBytes } from 'node:crypto';

const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const STALE_MS = 60000;
const unique = () => `${process.pid}.${randomBytes(6).toString('hex')}`;
const stat = (p) => { try { return statSync(p); } catch { return null; } };
const read = (p) => { try { return readFileSync(p, 'utf8'); } catch { return null; } };

// Move <lock> aside under a unique name; keep it removed when keep(<moved file's stat, text>) is
// true, else link it back (a new lock that stands meanwhile wins). false: nothing was moved.
function moveAside(lock, keep) {
  const aside = `${lock}.${unique()}.aside`;
  try { renameSync(lock, aside); } catch { return false; }
  const st = stat(aside);
  if (!st || !keep(st, read(aside))) { try { linkSync(aside, lock); } catch { /* a new lock stands */ } }
  rmSync(aside, { recursive: true, force: true });
  return true;
}

// withMutex(<lock file>, fn): fn's result; throws when the lock stays taken.
export function withMutex(lock, fn, tries = 100) {
  const token = `${unique()}\n`;
  for (let i = 0; i < tries; i++) {
    let fd = null;
    try { fd = openSync(lock, 'wx'); } catch (e) { if (e.code !== 'EEXIST') throw e; }
    if (fd != null) {
      try { writeSync(fd, token); } finally { closeSync(fd); }
      try { return fn(); } finally { moveAside(lock, (_, text) => text === token); }
    }
    const st = stat(lock);
    // Stale: older than a minute when looked at, and still that same file once moved aside.
    if (st && Date.now() - st.mtimeMs > STALE_MS) {
      moveAside(lock, (moved) => moved.ino === st.ino && moved.mtimeMs === st.mtimeMs);
      continue;
    }
    pause(100);
  }
  throw new Error(`${lock} stays locked`);
}

export function writeAtomic(file, text) {
  const tmp = `${file}.${unique()}.tmp`;
  writeFileSync(tmp, text);
  renameSync(tmp, file);
}
