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
  credentials: {
    owner: {
      username: process.env.E2E_USER_OWNER_USERNAME ?? '',
      password: process.env.E2E_USER_OWNER_PASSWORD ?? '',
    },
  },
} satisfies E2EConfig;
