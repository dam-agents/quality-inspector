// The body of every AC block. The exact check runs first; when it fails because the UI
// changed under it (a renamed button, a moved field), the criterion's own Then sentence
// is judged on the current screen instead, so a redesign does not fail the suite. The
// failed exact step stays in report.json, which is how the run's triage finds every
// judged criterion and repairs its locator (docs/triage.md).
//
// QI_STRICT=1 (issue verification, red-green) turns the fallback off: there a check must
// discriminate on its own.

type Ctx = {
  agent: { assert(assertion: string, options?: { vision?: boolean | 'only' }): Promise<void> };
  app: { screenshot(label?: string): Promise<string> };
};

export async function criterion(id: string, then: string, ctx: Ctx, check: () => Promise<void>): Promise<void> {
  try {
    await check();
    return;
  } catch (err) {
    if ((err as { code?: string }).code !== 'ASSERTION_FAILED' || process.env.QI_STRICT === '1') throw err;
  }
  await ctx.app.screenshot(`${id}: judged on screen`);
  await ctx.agent.assert(then, { vision: true });
}
