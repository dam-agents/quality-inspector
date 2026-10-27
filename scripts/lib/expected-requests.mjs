// expected-requests.mjs — the failed requests a profile declares expected (profile.json →
// expected_requests: [{method, path, status, why}]): a same-origin request the product's UI
// sends and the tested install answers ≥ 400 on purpose, for a feature that install leaves out.
// The UI sweep records no `failed-request` finding for one (ui-sweep.mjs) and the UI diff no new
// signal (ui-diff.mjs); the UI map keeps it. A match is exact — method, the path's pattern
// (lib/url-pattern.mjs: ids as :id) and status — so the list never hides another failure.
// Rationale: docs/profile-contract.md → `expected_requests`.

import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const METHODS = ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'];
export const validExpected = (e) => !!e && typeof e === 'object' && !Array.isArray(e)
  && METHODS.includes(e.method)
  && typeof e.path === 'string' && /^\/[^\s?#*]*$/.test(e.path)
  && Number.isInteger(e.status) && e.status >= 400 && e.status <= 599
  && typeof e.why === 'string' && e.why.trim() !== '';

// {list, notes} from a parsed profile.json; an invalid entry is left out with a note.
export function parseExpected(profile) {
  const raw = profile?.expected_requests;
  if (raw === undefined) return { list: [], notes: [] };
  if (!Array.isArray(raw)) return { list: [], notes: ['profile.json expected_requests is not a list — none is applied'] };
  const list = []; const notes = [];
  raw.forEach((e, i) => {
    if (validExpected(e)) list.push({ method: e.method, path: e.path, status: e.status });
    else notes.push(`profile.json expected_requests[${i}] is invalid (method, path, status 400-599, why) — left out`);
  });
  return { list, notes };
}

export const isExpected = (list, method, path, status) =>
  list.some((e) => e.method === method && e.path === path && e.status === status);

// The installed profile's list (lib/profile.sh → profile_dir); none without a profile.
export function profileExpected() {
  const lib = dirname(fileURLToPath(import.meta.url));
  const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
  let dir = '';
  try {
    dir = execFileSync('bash', ['-c', 'CONFIG="$WORK/CONFIG.md"; . "$LIB/config.sh"; . "$LIB/profile.sh"; profile_dir'],
      { env: { ...process.env, WORK: work, LIB: lib }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return { list: [], notes: [] }; }
  let profile;
  try { profile = JSON.parse(readFileSync(join(dir, 'profile.json'), 'utf8')); } catch { return { list: [], notes: [] }; }
  return parseExpected(profile);
}
