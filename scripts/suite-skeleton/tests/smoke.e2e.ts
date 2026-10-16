import { test } from '@e2e-dev/web';
import { expect } from 'e2e';

// Environment smoke: the nested product answers and the owner session works.
test('the nested product opens signed in', { session: 'owner', tags: ['smoke'] }, async ({ app, agent, browser, screen }) => {
  await app.open('/');
  await expect(browser).toHaveURL(new RegExp('^' + (process.env.APP_URL ?? 'http://localhost')));
  // A single-page app paints a blank frame first, and judging that one is inconclusive: wait for
  // its main landmark, or its navigation where it has none, before the judgement.
  await screen.getByRole('main').first().waitFor({ timeout: 20_000 })
    .catch(() => screen.getByRole('navigation').first().waitFor({ timeout: 10_000 }))
    .catch(() => undefined);
  await agent.assert('the main application view is shown, not an error page or a sign-in page');
});
