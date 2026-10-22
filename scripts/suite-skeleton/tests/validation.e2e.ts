import { test } from '@e2e-dev/web';
import { expect } from 'e2e';
import { readFileSync } from 'node:fs';

/** @qi-summary Form inputs the UI map found are refused visibly or kept intact, never an error. @qi-area validation */
// The validation module's e2e half. Which tests exist comes from the plan named by
// QI_VALIDATION_INPUT (scripts/validation-plan.mjs); the oracles are frozen in
// docs/validation.md: repair only how a step reaches the screen, never what is checked.
// Deterministic only — no agent step, no judged fallback. A failure names its oracle in
// brackets ([no-server-error], [no-uncaught-error], [no-error-page], [refused-visibly],
// [value-intact], [single-effect]); [setup] means the case never reached its check.

type Fill = string | { check: true } | { select: 'first' };
type Case = {
  id: string; page: string; example: string; form: string; submit: string; field: string | null; type: string | null;
  kind: string; value: string | null; fill: Record<string, Fill>; oracle: 'refused-visibly' | 'refused-or-intact' | 'single-effect'; maxlength?: number;
};
// The locator surface this file uses; the fixture's screen is Playwright-like.
type Loc = {
  first(): Loc; or(o: Loc): Loc; count(): Promise<number>; fill(v: string): Promise<void>;
  check(): Promise<void>; uncheck(): Promise<void>; selectOption(v: string): Promise<unknown>; inputValue(o?: { timeout?: number }): Promise<string>;
  click(o?: { timeout?: number }): Promise<void>; dblclick(o?: { timeout?: number }): Promise<void>; allInnerTexts(): Promise<string[]>;
  filter(o: { visible?: boolean }): Loc;
  evaluate<R>(f: (el: any) => R, arg?: unknown, o?: { timeout?: number }): Promise<R>;
  getByLabel(n: string | RegExp, o?: { exact?: boolean }): Loc; getByPlaceholder(n: string | RegExp, o?: { exact?: boolean }): Loc;
  getByRole(r: string, o?: { name?: string | RegExp; exact?: boolean }): Loc; getByText(t: string | RegExp, o?: { exact?: boolean }): Loc;
};

const plan: { cases?: Case[] } | null = (() => {
  try { return JSON.parse(readFileSync(process.env.QI_VALIDATION_INPUT ?? '', 'utf8')); } catch { return null; }
})();
const cases = Array.isArray(plan?.cases) ? plan.cases : [];
const origin = (() => { try { return new URL(process.env.APP_URL ?? 'http://localhost').origin; } catch { return 'http://localhost'; } })();
const ERROR_PAGE = /something went wrong|internal server error|unexpected error|stack trace/i;
const REFUSAL = /required|invalid|must (be|contain|have)|please (enter|fill|provide|select|use|match)|too (long|short|large|small)|not (a )?valid|at (most|least) \d|exceeds/i;
// The part of a value that survives being shown mangled: found without the whole value = mangled.
const PROBE: Record<string, string> = { unicode: 'Žluťoučký', rtl: 'שלום', emoji: '🙂', html: 'img src=x' };
const stamp = Date.now().toString(36);
const esc = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// 5xx answers from the product and uncaught page errors, when the browser fixture exposes page events.
function watch(browser: unknown) {
  const b = browser as { on?: (e: string, f: (x: any) => void) => void };
  const seen = { serverErrors: [] as string[], pageErrors: [] as string[] };
  b.on?.('dialog', (d) => { d.dismiss?.().catch?.(() => {}); });
  b.on?.('response', (r) => {
    const s = Number(r.status?.());
    try { const u = new URL(r.url()); if (s >= 500 && u.origin === origin) seen.serverErrors.push(`${s} ${r.request?.().method?.() ?? ''} ${u.pathname}`.replace('  ', ' ')); } catch { /* not a URL */ }
  });
  b.on?.('pageerror', (e) => { seen.pageErrors.push(String(e?.message ?? e).split('\n')[0]); });
  return seen;
}
async function settle(browser: unknown) {
  const b = browser as { waitForLoadState?: (s: string, o: { timeout: number }) => Promise<void> };
  await b.waitForLoadState?.('networkidle', { timeout: 10_000 }).catch(() => {});
  await new Promise((r) => setTimeout(r, 500));
}
// Names the oracle a failure broke, keeping the error itself (and its code) intact.
async function oracle(name: string, f: () => Promise<void>) {
  try { await f(); } catch (err) {
    if (err instanceof Error) err.message = `[${name}] ${err.message}`;
    throw err;
  }
}
// A field by its label as the UI map read it: <label>/aria-label, else placeholder; a trailing
// required asterisk in the accessible name is tolerated.
const fieldOf = (scope: Loc, label: string) => {
  const re = new RegExp(`^\\s*${esc(label)}\\s*\\*?\\s*$`);
  return scope.getByLabel(re).or(scope.getByPlaceholder(label, { exact: true })).first();
};
// What a refusal shows: the alerts on the page (getByRole leaves hidden ones out) and the
// visible refusal-like texts in the form's scope, each text with how often it shows. Taken
// before the case's input and after the submit: only a text that shows more often after is
// a refusal, so a static "Required fields are marked *" or an older alert never counts.
type Shown = { alerts: Map<string, number>; refusals: Map<string, number> };
const tally = (texts: string[]) => {
  const m = new Map<string, number>();
  for (const t of texts.map((x) => x.replace(/\s+/g, ' ').trim()).filter(Boolean)) m.set(t, (m.get(t) ?? 0) + 1);
  return m;
};
const shown = async (page: Loc, scope: Loc): Promise<Shown> => ({
  alerts: tally(await page.getByRole('alert').allInnerTexts().catch(() => [] as string[])),
  refusals: tally(await scope.getByText(REFUSAL).filter({ visible: true }).allInnerTexts().catch(() => [] as string[])),
});
const grew = (before: Map<string, number>, after: Map<string, number>) => [...after].some(([t, n]) => n > (before.get(t) ?? 0));
// A run-unique filler, so a second run's objects do not collide with the first's.
const fresh = (v: string) => v.replace(/^qa-val-(\d+)/, `qa-val-$1-${stamp}`);

async function put(loc: Loc, v: Fill | string) {
  if (typeof v === 'object' && 'check' in v) return loc.check();
  if (typeof v === 'object' && 'select' in v) {
    const first = await loc.evaluate((el) => [...(el.options ?? [])].find((o: any) => o.value !== '' && !o.disabled)?.value ?? null);
    if (first !== null) await loc.selectOption(first);
    return;
  }
  return loc.fill(fresh(v));
}

if (!cases.length) {
  test('VAL: form validation', { session: 'owner', tags: ['validation'] }, async () => {
    test.skip(true, plan ? 'the validation plan has no cases' : 'no validation plan (QI_VALIDATION_INPUT is unset or unreadable)');
  });
}

for (const c of cases) {
  const k = c.id.replace(/^VAL-/, '');
  test(`${c.id}: ${c.kind} on ${c.field ?? 'the form'} (${c.form} @ ${c.page})`, { session: 'owner', tags: ['validation', `val-${k}`] },
    async ({ app, browser, screen }) => {
      const seen = watch(browser);
      const s = screen as unknown as Loc;
      // Set inside the setup step (the `as` keeps the compiler from narrowing them to null).
      let field = null as Loc | null;
      let typed = null as string | null;
      let inputRefused = false as boolean;
      let scope: Loc = s;
      let before = null as Shown | null;
      await oracle('setup', async () => {
        await app.open(c.example);
        await settle(browser);
        const named = s.getByRole('form', { name: c.form, exact: true });
        if ((await named.count()) === 1) scope = named;
        for (const [label, v] of Object.entries(c.fill)) await put(fieldOf(scope, label), v);
        // Before the case's input: a message its typing brings up is a refusal of it too.
        before = await shown(s, scope);
        if (c.field !== null) {
          field = fieldOf(scope, c.field);
          if (c.type === 'checkbox') await field.uncheck();
          else {
            try { await field.fill(c.value ?? ''); } catch (err) {
              // A number or date input refuses a malformed value itself: that is the refusal.
              if (c.kind !== 'wrong-type') throw err;
              inputRefused = true;
            }
            typed = inputRefused ? null : await field.inputValue().catch(() => null);
          }
        }
        const btn = scope.getByRole('button', { name: c.submit, exact: true }).first();
        if (c.kind === 'duplicate-submit') await btn.dblclick();
        else await btn.click();
        await settle(browser);
      });
      await app.screenshot(`${c.id}: after submit`);

      await oracle('no-server-error', async () => { expect(seen.serverErrors).toEqual([]); });
      await oracle('no-uncaught-error', async () => { expect(seen.pageErrors).toEqual([]); });
      await oracle('no-error-page', async () => { await expect(screen.getByText(ERROR_PAGE)).toHaveCount(0); });

      // Refused visibly: the field is marked invalid (aria-invalid, or natively where the form
      // validates natively), the input itself refused or capped the value, or a new alert or
      // refusal text shows that was not there before the input (shown/grew above).
      const refused = async (): Promise<boolean> => {
        if (inputRefused) return true;
        if (c.kind === 'max-len+1' && typed !== null && c.maxlength != null && typed.length <= c.maxlength) return true;
        if (field) {
          const invalid = await field.evaluate((el) => el.getAttribute('aria-invalid') === 'true'
            || (typeof el.checkValidity === 'function' && !(el.form && el.form.noValidate) && !el.checkValidity()), undefined, { timeout: 3_000 }).catch(() => false);
          if (invalid) return true;
        }
        const was = before ?? { alerts: new Map<string, number>(), refusals: new Map<string, number>() };
        const now = await shown(s, scope);
        return grew(was.alerts, now.alerts) || grew(was.refusals, now.refusals);
      };

      if (c.oracle === 'refused-visibly') {
        await oracle('refused-visibly', async () => { expect(await refused(), `${c.field} accepted ${JSON.stringify((c.value ?? '').slice(0, 40))} with no visible refusal`).toBe(true); });
      }
      if (c.oracle === 'refused-or-intact' && !(await refused())) {
        await oracle('value-intact', async () => {
          const v = c.value ?? '';
          // The field, when it is still there and filled, holds exactly what was typed.
          const now = field ? await field.inputValue({ timeout: 2_000 }).catch(() => null) : null;
          if (now) expect(now, `${c.field} holds a changed value`).toBe(v);
          if (typed !== null) expect(typed, `${c.field} did not take the value as typed`).toBe(v);
          // Shown on the page: a recognizable part without the whole value is a mangled value.
          const probe = PROBE[c.kind];
          if (probe && v.length <= 200 && (await s.getByText(probe, { exact: false }).count()) > 0) {
            expect(await s.getByText(v.trim(), { exact: false }).count(), `the page shows ${c.field}'s value changed`).toBeGreaterThan(0);
          }
        });
      }
      if (c.oracle === 'single-effect') {
        await oracle('single-effect', async () => {
          const texts = [...await s.getByRole('status').allInnerTexts().catch(() => [] as string[]),
            ...await s.getByRole('alert').allInnerTexts().catch(() => [] as string[])].map((t) => t.trim()).filter(Boolean);
          const twice = texts.filter((t, i) => texts.indexOf(t) !== i);
          expect(twice, 'the same confirmation is shown twice after a double submit').toEqual([]);
        });
      }
    });
}
