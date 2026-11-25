// walk.mjs — one test case, several checks (docs/test-authoring.md → One walk, several checks).
// A test case is one `test()` of the suite: one walk through the product. It checks one or more
// criteria on that walk — a `criterion('<id>', …)` block each, tagged `<id>` in lower case, with the
// still `<id>: …` taken right before its block. This file reads a report.json result back as its checks:
//
//   checksOf(result) -> [{ id, at, status }]   in the order of the walk
//     id      AC-k, IN-k or EX-k, from the result's tags (ac-k, in-k, ex-k)
//     at      the 0-based step of the check's still, null when the test took none
//     status  the result's own status when the test checks one criterion — nothing changes for it;
//             for several: 'passed' before the check that stopped the walk, that check the result's
//             status ('failed' or 'timed-out'), 'not-reached' after it. A walk that stopped before
//             its first check reaches none of them.
//
// The check that stopped the walk: the one whose still `<id>: the failing check` the run took
// (lib/criterion.ts marks it), else the last one whose still came at or before the step that failed.
// Pure: no file access, so the catalog, the reports and the reruns read a walk the same way.

const TAG = /^(ac|in|ex)-(\d+)$/;
const STILL = /^((?:AC|IN|EX)-\d+):/;
const STOPPED = /^((?:AC|IN|EX)-\d+): the failing check\b/;

export const idsOf = (result) => [...new Set((result?.tags ?? []).map((t) => TAG.exec(String(t))).filter(Boolean).map((m) => `${m[1].toUpperCase()}-${m[2]}`))];

export function checksOf(result) {
  const ids = idsOf(result);
  const steps = result?.attempts?.at(-1)?.steps ?? [];
  const at = new Map();
  steps.forEach((s, n) => { const m = s?.api === 'app.screenshot' ? STILL.exec(String(s.label ?? '')) : null; if (m && ids.includes(m[1]) && !at.has(m[1])) at.set(m[1], n); });
  const pos = (id) => (at.has(id) ? at.get(id) : Infinity);
  const order = ids.slice().sort((a, b) => pos(a) - pos(b));
  const st = result?.status ?? null;
  const one = (id, status) => ({ id, at: at.get(id) ?? null, status });
  if (order.length < 2 || !['failed', 'timed-out'].includes(st)) return order.map((id) => one(id, st));
  let stop = null;
  for (const s of steps) { const m = STOPPED.exec(String(s?.label ?? '')); if (m && ids.includes(m[1])) stop = m[1]; }
  if (!stop) {
    const failed = steps.findIndex((s) => s?.status === 'failed' || s?.status === 'timed-out');
    const n = failed >= 0 ? failed : steps.length;
    stop = order.filter((id) => at.has(id) && at.get(id) <= n).at(-1) ?? null;
  }
  if (!stop) return order.map((id) => one(id, 'not-reached'));
  return order.map((id) => one(id, id === stop ? st : pos(id) < pos(stop) ? 'passed' : 'not-reached'));
}

// One criterion's status in a result: its check's, else the result's own.
export const checkOf = (result, id) => checksOf(result).find((c) => c.id === id)?.status ?? result?.status ?? null;

// node walk.mjs <report.json> -> one array per result of the report, in its order: [{id, status}] —
// scripts/suite.sh adds it to each result of its summary as `checks`.
if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  const { readFileSync } = await import('node:fs');
  let report = null; try { report = JSON.parse(readFileSync(process.argv[2], 'utf8')); } catch { /* none */ }
  console.log(JSON.stringify((report?.run?.results ?? []).map((r) => checksOf(r).map(({ id, status }) => ({ id, status })))));
}
