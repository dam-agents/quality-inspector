// The body of every AC block. The exact check runs first; when it fails because the UI
// changed under it (a renamed button, a moved field), the criterion's own Then sentence
// is judged on the current screen instead, so a redesign does not fail the suite. The
// failed exact step stays in report.json, which is how the run's triage finds every
// judged criterion and repairs its locator (docs/triage.md).
//
// QI_STRICT=1 (issue verification, red-green) turns the fallback off: there a check must
// discriminate on its own.
//
// The mark of a failed check (docs/test-authoring.md): a test imports `expect` from here, not
// from 'e2e'. It is e2e's own `expect`, which also keeps the last locator it was given; when a
// check fails, that locator's matches on screen are framed in the still
// `<id>: the failing check [mark x,y,w,h;…]` (CSS pixels of the viewport), drawn by the report
// and the catalog (scripts/lib/shot-mark.mjs). A check that found nothing on screen has no mark.
// Marking never changes the outcome: any error of it is swallowed and the check's error stands.

import { expect as e2eExpect } from 'e2e';

type Box = { x: number; y: number; width: number; height: number } | null;
type Target = { all(): Promise<Target[]>; boundingBox(): Promise<Box>; scrollIntoView(options?: { timeout?: number }): Promise<void> };
type Ctx = {
  agent: { assert(assertion: string, options?: { vision?: boolean | 'only' }): Promise<void> };
  app: { screenshot(label?: string): Promise<string> };
};

const MAX_BOXES = 8;
let lastTarget: Target | null = null;
const isTarget = (x: unknown): x is Target =>
  !!x && typeof (x as Target).boundingBox === 'function' && typeof (x as Target).all === 'function';
// A matcher that passed forgets its locator, so a later failure that is not an `expect` (an
// `agent.assert`, a timeout) is never marked on the wrong control.
function track<T extends object>(obj: T, target: Target | null): T {
  return new Proxy(obj, {
    get: (o, prop) => {
      const v = Reflect.get(o, prop, o);
      if (typeof v === 'function') {
        return (...a: unknown[]) => {
          const r = Reflect.apply(v, o, a) as { then?: unknown } | undefined;
          if (r && typeof r.then === 'function') (r as Promise<unknown>).then(() => { if (lastTarget === target) lastTarget = null; }, () => {});
          return r;
        };
      }
      return v && typeof v === 'object' ? track(v as object, target) : v;
    },
  });
}
const keep = (fn: (...a: unknown[]) => unknown) => (...args: unknown[]) => {
  const target = isTarget(args[0]) ? args[0] : null;
  lastTarget = target;
  const m = fn(...args);
  return m && typeof m === 'object' ? track(m as object, target) : m;
};

export const expect: typeof e2eExpect = new Proxy(e2eExpect, {
  apply: (fn, self, args) => keep((...a) => Reflect.apply(fn, self, a))(...args),
  get: (fn, prop, recv) => {
    const v = Reflect.get(fn, prop, recv);
    return prop === 'soft' && typeof v === 'function' ? keep(v.bind(fn)) : v;
  },
});

const within = <T>(p: Promise<T>, ms: number): Promise<T | null> =>
  Promise.race([p.catch(() => null), new Promise<null>((r) => setTimeout(() => r(null), ms))]);

async function markFailure(id: string, ctx: Ctx, target: Target | null): Promise<void> {
  if (!target) return;
  try {
    const all = (await within(target.all(), 3000)) ?? [];
    if (all.length === 1) await within(all[0].scrollIntoView({ timeout: 2000 }), 2500);
    const boxes: string[] = [];
    for (const t of all.slice(0, MAX_BOXES)) {
      const b = await within(t.boundingBox(), 2000);
      if (b && b.width > 0 && b.height > 0) boxes.push([b.x, b.y, b.width, b.height].map(Math.round).join(','));
    }
    if (boxes.length) await ctx.app.screenshot(`${id}: the failing check [mark ${boxes.join(';')}]`);
  } catch { /* the check's own error is the result */ }
}

export async function criterion(id: string, then: string, ctx: Ctx, check: () => Promise<void>): Promise<void> {
  lastTarget = null;
  let target: Target | null = null;
  try {
    await check();
    return;
  } catch (err) {
    target = lastTarget;
    if ((err as { code?: string }).code !== 'ASSERTION_FAILED' || process.env.QI_STRICT === '1') {
      await markFailure(id, ctx, target);
      throw err;
    }
  }
  // Judged true, the criterion holds and nothing is marked; judged false, the exact check's
  // locator is marked (the judge does not change the screen).
  await ctx.app.screenshot(`${id}: judged on screen`);
  try {
    await ctx.agent.assert(then, { vision: true });
  } catch (err) {
    await markFailure(id, ctx, target);
    throw err;
  }
}
