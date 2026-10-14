import type { E2EConfig } from 'e2e';
import { web } from '@e2e-dev/web';
import { anthropic } from '@ai-sdk/anthropic';

const model = anthropic(process.env.E2E_MODEL ?? 'claude-sonnet-5');

export default {
  projectId: 'quality-inspector-suite',
  targets: [
    {
      name: 'web',
      engine: web({ browser: 'chromium' }),
      app: { url: process.env.APP_URL ?? 'http://localhost' },
    },
  ],
  tests: ['tests/**/*.e2e.ts'],
  timeout: 300_000,
  assertionTimeout: 15_000,
  retries: 0,
  workers: 1,
  cache: 'read-write',
  agents: { default: { model } },
  // The role convention (docs/profile-contract.md → The `bin/` contract): owner is always
  // provided; member, viewer and outsider are empty unless the profile writes them.
  credentials: Object.fromEntries(
    ['owner', 'member', 'viewer', 'outsider'].map((role) => [role, {
      username: process.env[`E2E_USER_${role.toUpperCase()}_USERNAME`] ?? '',
      password: process.env[`E2E_USER_${role.toUpperCase()}_PASSWORD`] ?? '',
    }]),
  ),
} satisfies E2EConfig;
