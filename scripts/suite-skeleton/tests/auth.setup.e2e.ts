import { test } from '@e2e-dev/web';
import { expect, credentials } from 'e2e';

// Signs each provided role in once per run and saves its session under the role's name:
// the owner always, member / viewer / outsider only when the profile wrote a username for
// them (docs/explorations.md → Identities). Agent-maintained: adjust the steps to what the
// nested platform actually shows, keeping the final check and the session names.
const ROLES = ['owner', 'member', 'viewer', 'outsider'] as const;
const provided = ROLES.filter((role) => role === 'owner' || (process.env[`E2E_USER_${role.toUpperCase()}_USERNAME`] ?? '') !== '');

for (const role of provided) {
  test.setup(`the ${role} signs in`, { sessions: [role] }, async ({ app, agent, browser, session }) => {
    const user = credentials.user(role);
    await app.open('/');
    await agent.act(`sign in with the username {username} and the ${role} password`, {
      params: { username: user.username, password: user.password },
    });
    await agent.act('if a terms or consent page is shown, accept it; otherwise do nothing');
    await expect(browser).toHaveURL(new RegExp('^' + (process.env.APP_URL ?? 'http://localhost')));
    await agent.assert('the application is shown to a signed-in user, not a sign-in page');
    await session.save(role);
  });
}
