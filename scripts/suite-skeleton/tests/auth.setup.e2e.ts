import { test } from '@e2e-dev/web';
import { expect, credentials } from 'e2e';

// Signs the owner in once per run. Agent-maintained: adjust the steps to what the
// nested platform actually shows, keeping the final check and the session name.
test.setup('the owner signs in', { sessions: ['owner'] }, async ({ app, agent, browser, session }) => {
  const owner = credentials.user('owner');
  await app.open('/');
  await agent.act('sign in with the username {username} and the owner password', {
    params: { username: owner.username, password: owner.password },
  });
  await agent.act('if a terms or consent page is shown, accept it; otherwise do nothing');
  await expect(browser).toHaveURL(new RegExp('^' + (process.env.APP_URL ?? 'http://localhost')));
  await agent.assert('the application is shown to a signed-in user, not a sign-in page');
  await session.save('owner');
});
