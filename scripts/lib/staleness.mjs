// staleness.mjs — which recurring tests the night's change context predicts broken, before they
// replay: impact.mjs output (the UI-map and interface diffs, matched per test) and the tiers of
// work/SUITE.md in, proposal candidates out. Pure, no I/O; maintenance.mjs predict opens them
// (docs/maintenance.md → Predicted from the change context).
//
// - Only the tiers `regression`, `promotable` and `quarantined`; a file of no such row (an
//   exploration, a rerun, an unsaved scenario) is out of scope.
// - A control renamed, moved or removed counts only inside a frozen block (AC-<k>, IN-<k>): outside
//   one it is a navigation step the replay cache relearns. A removed page, command, flag, endpoint or
//   response field counts wherever the test names it: no relearning finds what is gone.
// - `obsolete` (a removal): `retire` on the whole test when every frozen block of it has one, else
//   `rewrite` per block (per test for a hit outside the blocks). `moved` / `renamed` per block, not
//   where the block is obsolete: `heal`, or `review` for a likely rename (same place, unlike text).

export const RECURRING = new Set(['regression', 'promotable', 'quarantined']);
const IDS = [
  [/^issue-(\d{1,7})\.e2e\.ts$/, (m) => `#${m[1]}`],
  [/^scenario-(\d{1,6})\.e2e\.ts$/, (m) => `S-${m[1]}`],
  [/^profile-([a-z0-9][a-z0-9-]{0,40})\.e2e\.ts$/, (m) => `P-${m[1]}`],
];
const IFACE = new Set(['command-removed', 'flag-removed', 'endpoint-removed', 'field-removed']);
const ANYWHERE = new Set(['page-removed', ...IFACE]);
const GONE = new Set(['removed', ...ANYWHERE]);

export const idOf = (name) => { for (const [re, f] of IDS) { const m = re.exec(name); if (m) return f(m); } return null; };
const basisOf = (h) => `${IFACE.has(h.type) ? 'iface' : 'ui-map'}: ${String(h.change ?? '')}`;

// predict(<impact.json object>, <Map "tests/<file>" -> tier>) -> [{test, kind, proposal, basis, file, line}]
export function predict(impact, tiers) {
  const out = [];
  for (const t of impact?.impacted ?? []) {
    const name = String(t.test ?? '').split('/').at(-1);
    const id = idOf(name);
    if (!id || !RECURRING.has(tiers.get(`tests/${name}`))) continue;
    // A scenario has no intent test: its IN block, if any, names the test as a whole.
    const at = (b) => (b && (id.startsWith('#') || b.startsWith('AC-')) ? `${id} ${b}` : id);
    const hits = (Array.isArray(t.hits) ? t.hits : []).filter((h) => h && (h.block || ANYWHERE.has(h.type)));
    const blocks = Array.isArray(t.blocks) ? t.blocks : [];
    const gone = hits.filter((h) => GONE.has(h.type));
    const goneBlocks = new Set(gone.map((h) => h.block).filter(Boolean));
    const seen = new Map();
    const add = (test, kind, proposal, h) => {
      if (!seen.has(`${test}~${kind}`)) seen.set(`${test}~${kind}`, { test, kind, proposal, basis: basisOf(h), file: `tests/${name}`, line: h.line ?? null });
    };
    if (gone.length && blocks.length && blocks.every((b) => goneBlocks.has(b))) add(id, 'obsolete', 'retire', gone[0]);
    else for (const h of gone) add(at(h.block), 'obsolete', 'rewrite', h);
    for (const h of hits) {
      if (!h.block || goneBlocks.has(h.block) || !['moved', 'renamed', 'renamed-likely'].includes(h.type)) continue;
      add(at(h.block), h.type === 'moved' ? 'moved' : 'renamed', h.type === 'renamed-likely' ? 'review' : 'heal', h);
    }
    out.push(...seen.values());
  }
  return out;
}
