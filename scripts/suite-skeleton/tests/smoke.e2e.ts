import { test } from '@e2e-dev/web';
import { expect } from 'e2e';

// Environment smoke: the nested product answers and the owner session works.
test('the nested product opens signed in', { session: 'owner', tags: ['smoke'] }, async ({ app, agent, browser }) => {
  await app.open('/');
  await expect(browser).toHaveURL(new RegExp('^' + (process.env.APP_URL ?? 'http://localhost')));
  await agent.assert('the main application view is shown, not an error page or a sign-in page');
});
