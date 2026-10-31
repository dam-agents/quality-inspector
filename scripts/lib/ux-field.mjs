// ux-field.mjs — what ux-signals.mjs and design-findings.mjs both know about a real-user signal
// (docs/ux-signals.md): its fingerprint, the route pattern it names, and when a field finding is
// quiet long enough to be resolved.

import { createHash } from 'node:crypto';
import { ID } from './url-pattern.mjs';

export const SIGNALS = ['rage_click', 'dead_click', 'error_shown', 'js_error', 'nav_bounce', 'abandoned_dialog', 'slow_request'];
export const CLASSES = ['bug', 'ux-friction', 'slow', 'not-reproduced'];
export const REPORTED = new Set(['bug', 'ux-friction', 'slow']);

// One page pattern for the product's route patterns and the UI map's: `:assetId`, `[id]`,
// `{id}` and anything ID-shaped become `:id`; no trailing slash.
export const routeKey = (r) => {
  const p = String(r ?? '').split('?')[0].split('/').map((s) => (/^[:[{]/.test(s) || ID.test(s) ? ':id' : s)).join('/');
  return p.length > 1 ? p.replace(/\/+$/, '') : p || '/';
};

// The same signal on the same element of the same page is the same finding on every build.
export const fingerprint = (signal, route, element) =>
  createHash('sha1').update(['field', signal, routeKey(route), element || '-'].join('|')).digest('hex').slice(0, 12);

// A finding last seen on `lastBuild` resolves when a newer build ran the whole period of `scored`
// (its firstSeen at or before the period's start) and no passing row of the finding is in it.
// Returns that build, or null.
export function quietBuild(f, scored) {
  if (!scored?.period?.from || (scored.candidates ?? []).some((c) => c.fingerprint === f.fingerprint)) return null;
  const seen = new Map((scored.builds ?? []).map((b) => [b.version, Date.parse(b.firstSeen)]));
  const from = Date.parse(scored.period.from);
  const ran = [...seen].filter(([, t]) => Number.isFinite(t) && t <= from).sort((a, b) => b[1] - a[1])[0];
  if (!ran || ran[0] === f.last_seen) return null;
  const last = seen.get(f.last_seen);
  return last === undefined || last < ran[1] ? ran[0] : null;
}
