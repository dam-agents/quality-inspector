// mutex.mjs — the short critical section of lib/lock.sh `lock_mutex`, for the node writers of a
// work/ state table (scripts/features.mjs, scripts/maintenance.mjs): a lock file created
// exclusively, holding the writer's pid; up to <tries> × 0.1 s (100); one older than a minute is a
// dead writer's and is removed. `writeAtomic` writes through a temp path unique to the writer, so
// two writers never share one.

import { openSync, closeSync, writeSync, rmSync, statSync, renameSync, writeFileSync } from 'node:fs';

const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

// withMutex(<lock file>, fn): fn's result; throws when the lock stays taken.
export function withMutex(lock, fn, tries = 100) {
  for (let i = 0; i < tries; i++) {
    let fd = null;
    try { fd = openSync(lock, 'wx'); } catch (e) { if (e.code !== 'EEXIST') throw e; }
    if (fd != null) {
      writeSync(fd, `${process.pid}\n`); closeSync(fd);
      try { return fn(); } finally { rmSync(lock, { force: true }); }
    }
    try { if (Date.now() - statSync(lock).mtimeMs > 60000) rmSync(lock, { recursive: true, force: true }); } catch { /* gone meanwhile */ }
    pause(100);
  }
  throw new Error(`${lock} stays locked`);
}

export function writeAtomic(file, text) {
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, text);
  renameSync(tmp, file);
}
