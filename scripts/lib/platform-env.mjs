#!/usr/bin/env node
// platform-env.mjs — this agent's platform Environments, through the platform's own MCP
// tools (create_environment, list_environments, update_environment, delete_environment), the
// way the image's `platform-env` reaches them: a JSON-RPC `tools/call` to the address in
// ~/.platform/platform-mcp-entry.json. docs/nested-env.md → Where the product runs.
//
//   platform-env.mjs available                  exit 0 when the tools answer (the owner has the
//                                               environments feature), 1 otherwise, with the reason
//   platform-env.mjs list                       a JSON array: {name, endpoints[{name, port, url}],
//                                               expiresAt, state, …} as the platform gives it
//   platform-env.mjs create <name> <spec json>  spec: {endpoints, start?, storage?, expires?}
//   platform-env.mjs extend <name> <expires>    "48h", "3d" or an ISO date-time
//   platform-env.mjs delete <name>
//
// A refusal prints the platform's message on stderr and exits 1; the cap reached (the
// platform's own message for it, exactly) exits 4, so a caller can free one and try again. Names this script makes start
// with `qi-` (env.sh), and it acts on no other.

import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const ENTRY = join(process.env.HOME ?? '/home/agent', '.platform', 'platform-mcp-entry.json');
const NAME = /^qi-[a-z0-9][a-z0-9-]{0,40}$/;
// The platform's refusal at its cap (api-server environments-service, create), word for word:
// any other refusal — storage, a rate limit, a name taken — is exit 1, never 4.
const CAP = /^this agent already holds \d+ Environments, the most it may; delete one first$/;
const die = (msg, code = 1) => { process.stderr.write(`platform-env: ${msg}\n`); process.exit(code); };

async function call(tool, args) {
  let entry;
  try { entry = JSON.parse(readFileSync(ENTRY, 'utf8')); } catch { die('this agent has no platform MCP address (not a running platform agent)'); }
  if (typeof entry?.url !== 'string') die('the platform MCP address names no url');
  let res;
  try {
    res = await fetch(entry.url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json, text/event-stream', ...(entry.headers ?? {}) },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: tool, arguments: args } }),
      signal: AbortSignal.timeout(60_000),
    });
  } catch (e) { die(`could not reach the platform: ${e.message}`); }
  const text = await res.text();
  const line = text.split('\n').find((l) => l.startsWith('data:'));
  let reply;
  try { reply = JSON.parse(line ? line.slice(5) : text); } catch { die(`the platform answered ${res.status} with no JSON-RPC reply`); }
  if (reply.error) die(reply.error.message ?? 'the platform refused');
  const content = reply.result?.content?.[0]?.text ?? 'null';
  if (reply.result?.isError) die(content, CAP.test(content) ? 4 : 1);
  try { return JSON.parse(content); } catch { return content; }
}

const [cmd, name, arg] = process.argv.slice(2);
const named = () => { if (!NAME.test(name ?? '')) die(`'${name ?? ''}' is not an Environment name of this agent (qi-…)`, 2); };
switch (cmd) {
  case 'available': await call('list_environments', {}); break;
  case 'list': process.stdout.write(`${JSON.stringify(await call('list_environments', {}) ?? [])}\n`); break;
  case 'create': {
    named();
    let spec;
    try { spec = JSON.parse(arg ?? ''); } catch { die('create needs a JSON spec', 2); }
    const out = await call('create_environment', { name, ...spec });
    process.stdout.write(`${JSON.stringify(out)}\n`);
    break;
  }
  case 'extend': named(); await call('update_environment', { name, expires: arg }); break;
  case 'delete': named(); await call('delete_environment', { name }); break;
  default: die('usage: platform-env.mjs available|list|create <name> <spec>|extend <name> <expires>|delete <name>', 2);
}
