import { test } from '@e2e-dev/web';
import { expect, unique } from 'e2e';
import { readFileSync } from 'node:fs';

// The e2e half of the security run. Oracles are frozen in docs/security.md → Check catalogue:
// repair only how a step reaches the screen, never what is checked. Which tests exist comes
// from the run's e2e-input.json (scripts/security-checks.mjs); a check it does not list is
// recorded as skipped there, with its reason. Every object is named qa-sec-… and deleted.

type Input = { entity?: string | null; api_keys_named?: boolean; api_helper?: Record<string, boolean>; e2e_checks?: string[] };
const input: Input = (() => {
  try { return JSON.parse(readFileSync(process.env.QI_SECURITY_INPUT ?? '', 'utf8')); } catch { return {}; }
})();
const has = (id: string) => (input.e2e_checks ?? []).includes(id);
const entity = input.entity ?? '';
const base = process.env.APP_URL ?? 'http://localhost';
const STACK = /\n\s+at [\w$.<>[\] ]+ \(?[^\s()]+:\d+:\d+\)?|Traceback \(most recent call last\)|\bat [\w$.]+\([\w$]+\.java:\d+\)|goroutine \d+ \[running\]/;

// Dialogs and 5xx answers, when the browser fixture exposes page events; the title marker
// below is the check that needs no events.
function watch(browser: unknown) {
  const b = browser as { on?: (e: string, f: (x: any) => void) => void };
  const seen = { dialogs: [] as string[], serverErrors: [] as string[] };
  b.on?.('dialog', (d) => { seen.dialogs.push(String(d.message?.() ?? 'dialog')); d.dismiss?.().catch?.(() => {}); });
  b.on?.('response', (r) => { const s = Number(r.status?.()); if (s >= 500) seen.serverErrors.push(`${s} ${new URL(r.url()).pathname}`); });
  return seen;
}
async function titleOf(browser: unknown): Promise<string> {
  const t = (browser as { title?: () => Promise<string> }).title;
  return typeof t === 'function' ? String(await t.call(browser)) : '';
}
const payloadFor = (id: string) => `${id}"><img src=x onerror="alert('${id}');document.title='${id}'"><script>alert('${id}')</script>`;

async function rendersAsText(id: string, ctx: { app: any; browser: any; screen: any }, seen: ReturnType<typeof watch>, step: string) {
  await ctx.app.screenshot(`${step}: the payload on screen`);
  await expect(ctx.screen.getByText(`<img src=x onerror`, { exact: false }).first()).toBeVisible();
  expect(seen.dialogs).toEqual([]);
  expect(await titleOf(ctx.browser)).not.toContain(id);
}

if (has('SEC-XSS-1')) {
  test('SEC-XSS-1: a stored script in a name is shown as text', { session: 'owner', tags: ['security', 'sec-xss-1'] },
    async ({ app, agent, browser, screen }) => {
      const seen = watch(browser);
      const id = unique(`qa-sec-${Date.now()}`);
      const payload = payloadFor(id);
      await app.open('/');
      await agent.act(`create a new ${entity} with the name {payload} and, if there is a description field, the description {payload}`, { params: { payload } });
      await agent.act(`open the ${entity} whose name starts with {id}`, { params: { id } });
      await rendersAsText(id, { app, browser, screen }, seen, 'SEC-XSS-1 detail');
      await agent.act(`open the list of all ${entity}s`);
      await rendersAsText(id, { app, browser, screen }, seen, 'SEC-XSS-1 list');
      await agent.act(`delete the ${entity} whose name starts with {id}, confirming if asked`, { params: { id } }).catch(() => {});
    });
}

if (has('SEC-XSS-2')) {
  test('SEC-XSS-2: a stored script created through the API is shown as text', { session: 'owner', tags: ['security', 'sec-xss-2'] },
    async ({ app, agent, browser, screen }) => {
      const api = await import('../lib/security-api.js');
      const seen = watch(browser);
      const id = unique(`qa-sec-${Date.now()}`);
      const made = await api.createEntity(base, payloadFor(id));
      try {
        await app.open('/');
        await agent.act(`open the ${entity} whose name starts with {id}`, { params: { id } });
        await rendersAsText(id, { app, browser, screen }, seen, 'SEC-XSS-2 detail');
      } finally { await made.remove().catch(() => {}); }
    });
}

if (has('SEC-INPUT-1')) {
  test('SEC-INPUT-1: hostile names get a validation error, never a server error', { session: 'owner', tags: ['security', 'sec-input-1'] },
    async ({ app, agent, browser, screen }) => {
      const seen = watch(browser);
      const id = unique(`qa-sec-${Date.now()}`);
      const names = [`${id}-${'a'.repeat(10000)}`, `${id} ‮evil‬ ́😀 ünïcødé 名前`, `${id}/../../../../etc/passwd`];
      for (const [i, name] of names.entries()) {
        await app.open('/');
        await agent.act(`try to create a new ${entity} named {name}; if the form shows a validation message, stop there`, { params: { name } });
        await app.screenshot(`SEC-INPUT-1: attempt ${i + 1}`);
        expect(seen.serverErrors).toEqual([]);
        await expect(screen.getByText(/internal server error|\b50[0-4]\b.*error/i)).toHaveCount(0);
        await expect(screen.getByText(STACK)).toHaveCount(0);
      }
      await agent.act(`delete every ${entity} whose name starts with {id}, confirming if asked`, { params: { id } }).catch(() => {});
    });
}

if (has('SEC-KEY-1')) {
  test('SEC-KEY-1: a deleted API key stops working', { session: 'owner', tags: ['security', 'sec-key-1'] }, async () => {
    const api = await import('../lib/security-api.js');
    const key = await api.createApiKey(base);
    let removed = false;
    try {
      expect(await api.callWithKey(base, key.key)).toBeLessThan(300);
      await key.remove(); removed = true;
      expect([401, 403]).toContain(await api.callWithKey(base, key.key));
    } finally { if (!removed) await key.remove().catch(() => {}); }
  });
}
