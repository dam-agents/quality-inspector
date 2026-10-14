#!/usr/bin/env node
// security-checks.mjs — the deterministic half of the security run: every check of the
// catalogue whose mechanism is "script", against the nested product only. The oracles are
// frozen in docs/security.md → Check catalogue; this file implements them, nothing more.
//
//   node security-checks.mjs <inventory.json> [--build <b>] [--out <dir>] [--base <app url>] [--failed-logins N]
//   node security-checks.mjs --dry-run <inventory.json>     the request plan as JSON; no network, no browser
//
// Writes <out>/findings.json ({build, generated_utc, counts, checks:[{id, target, status, severity,
// evidence, reason}]}) and <out>/e2e-input.json (what the e2e half needs); prints a summary.
// Default <out>: work/security/<build>.
//
// Reads credentials from work/env/credentials.env only to sign in, and keeps them in memory:
// no secret, cookie or token is ever printed or written — evidence holds statuses, a header
// allowlist and names. Writes nothing to the product except what a failing check provokes:
// DELETE is never replayed, other writes go with an empty body (docs/security.md → Rules).

import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { pattern } from './lib/url-pattern.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const flags = {}; const pos = [];
for (let i = 2; i < process.argv.length; i++) {
  const a = process.argv[i];
  if (a === '--dry-run') flags.dry = true;
  else if (a.startsWith('--')) flags[a.slice(2)] = process.argv[++i];
  else pos.push(a);
}
const usage = 'usage: security-checks.mjs [--dry-run] <inventory.json> [--build B] [--out DIR] [--base URL] [--failed-logins N]';
if (!pos[0]) { console.error(usage); process.exit(2); }

const WORK = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
// The config and the profile come through the one reader (scripts/lib/config.sh, profile.sh).
const sh = (expr) => {
  try {
    return execFileSync('bash', ['-c', `CONFIG="$WORK/CONFIG.md"; . "$LIB/config.sh"; . "$LIB/profile.sh"; ${expr}`],
      { env: { ...process.env, WORK, LIB: join(here, 'lib') }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return ''; }
};
const profileDir = sh('profile_dir');
const profile = (() => { try { return JSON.parse(readFileSync(join(profileDir, 'profile.json'), 'utf8')); } catch { return {}; } })();
const base = new URL(flags.base ?? process.env.APP_URL ?? profile.app?.url ?? 'http://localhost');
if (!['localhost', '127.0.0.1'].includes(base.hostname)) { console.error(`refusing ${base.origin}: only the nested product on localhost`); process.exit(2); }
const inv = JSON.parse(readFileSync(pos[0], 'utf8'));
const build = flags.build ?? inv.build ?? 'unknown';
const failedLogins = Math.max(3, Number(flags['failed-logins'] ?? (sh('cfg security_failed_logins') || 10)) || 10);

// Roles (docs/profile-contract.md → The bin/ contract): env first, then credentials.env.
const credFile = (() => {
  const o = {};
  try {
    for (const l of readFileSync(join(WORK, 'env', 'credentials.env'), 'utf8').split('\n')) {
      const m = /^\s*(?:export\s+)?([A-Z0-9_]+)=(.*)$/.exec(l);
      if (m) o[m[1]] = m[2].trim().replace(/^(['"])(.*)\1$/, '$2');
    }
  } catch { /* no file: env only */ }
  return o;
})();
const cred = (role) => {
  const u = process.env[`E2E_USER_${role}_USERNAME`] ?? credFile[`E2E_USER_${role}_USERNAME`];
  const p = process.env[`E2E_USER_${role}_PASSWORD`] ?? credFile[`E2E_USER_${role}_PASSWORD`];
  return u && p ? { username: u, password: p } : null;
};
const roles = Object.fromEntries(['OWNER', 'MEMBER', 'VIEWER', 'OUTSIDER'].map((r) => [r.toLowerCase(), !!cred(r)]));

const SEV = {
  'SEC-AUTH-1': 'high', 'SEC-AUTHZ-1': 'high', 'SEC-AUTHZ-2': 'medium', 'SEC-AUTHZ-3': 'high', 'SEC-SESS-1': 'medium',
  'SEC-BRUTE-1': 'medium', 'SEC-KEY-1': 'high', 'SEC-XSS-1': 'critical', 'SEC-XSS-2': 'critical', 'SEC-INPUT-1': 'low',
  'SEC-ERR-1': 'medium', 'SEC-HDR-1': 'medium', 'SEC-HDR-2': 'low', 'SEC-HDR-3': 'medium', 'SEC-HDR-4': 'medium',
  'SEC-CORS-1': 'medium', 'SEC-LEAK-1': 'high', 'SEC-MAP-1': 'low', 'SEC-DEP-1': 'medium', 'SEC-DEP-2': 'low',
  'SEC-DEP-3': 'low', 'SEC-DEP-4': 'low', 'SEC-DEP-5': 'medium',
};
const isRead = (m) => m === 'GET' || m === 'HEAD';

// ------------------------------------------------------------------ the plan (pure) ----
function context() {
  const skill = (() => { try { return readFileSync(join(profileDir, 'SKILL.md'), 'utf8'); } catch { return ''; } })();
  const helperSrc = (() => { try { return readFileSync(join(WORK, 'suite', 'lib', 'security-api.ts'), 'utf8'); } catch { return ''; } })();
  const exported = (n) => new RegExp(`export\\s+(?:async\\s+)?(?:function\\s+|const\\s+)${n}\\b`).test(helperSrc);
  const ns = profile.security?.namespace ?? profile.engine_config?.namespace;
  const k8s = profile.engine === 'helm-k3s' || (profile.requires?.commands ?? []).includes('kubectl');
  return {
    entity: profile.security?.entity ?? null,
    api_keys_named: /\bapi[ -]?keys?\b|\baccess tokens?\b/i.test(skill),
    api_helper: { createEntity: exported('createEntity'), createApiKey: exported('createApiKey'), callWithKey: exported('callWithKey') },
    deployment: !k8s ? { run: false, reason: `the profile's engine is ${profile.engine ?? 'none'} and it requires no kubectl` }
      : !ns ? { run: false, reason: 'no namespace (profile.json → security.namespace or engine_config.namespace)' }
        : { run: true, namespace: ns },
  };
}

function buildPlan(ctx) {
  const plan = []; const skipped = [];
  const skip = (id, reason, target = '*') => skipped.push({ id, target, status: 'skipped', severity: SEV[id], evidence: {}, reason });
  const routes = Object.entries(inv.routes ?? {}).filter(([, r]) => r && r.example && !r.error && !r.redirected);
  if (!routes.length) skip('SEC-AUTH-1', 'the UI map has no reachable pages');
  for (const [pat, r] of routes) plan.push({ id: 'SEC-AUTH-1', target: pat, as: 'anonymous', method: 'GET', path: r.example, via: 'browser' });

  const reqs = Array.isArray(inv.api_requests) ? inv.api_requests : null;
  if (!reqs) for (const id of ['SEC-AUTHZ-1', 'SEC-AUTHZ-2', 'SEC-AUTHZ-3', 'SEC-LEAK-1']) skip(id, 'the UI map has no api_requests (built before 2.8.0) — rebuild it');
  const all = reqs ?? [];
  const writes = all.filter((q) => !isRead(q.method) && q.method !== 'DELETE');
  const withId = all.filter((q) => q.method !== 'DELETE' && q.path_pattern.includes(':id'));
  for (const q of all.filter((x) => x.method === 'DELETE')) for (const id of ['SEC-AUTHZ-1', 'SEC-AUTHZ-2', 'SEC-AUTHZ-3']) skip(id, 'DELETE is never replayed (a broken check would delete data)', `DELETE ${q.path_pattern}`);
  for (const q of all.filter((x) => x.method !== 'DELETE')) plan.push({ id: 'SEC-AUTHZ-1', target: `${q.method} ${q.path_pattern}`, as: 'anonymous', method: q.method, path: q.example_path });
  if (reqs && !writes.length) skip('SEC-AUTHZ-2', 'the UI map recorded no write requests (a GET is allowed for a viewer)');
  else if (reqs && !roles.viewer) skip('SEC-AUTHZ-2', 'no VIEWER account (E2E_USER_VIEWER_*)');
  else for (const q of writes) plan.push({ id: 'SEC-AUTHZ-2', target: `${q.method} ${q.path_pattern}`, as: 'viewer', method: q.method, path: q.example_path });
  if (reqs && !withId.length) skip('SEC-AUTHZ-3', 'no recorded request names an object id');
  else if (reqs && !roles.outsider) skip('SEC-AUTHZ-3', 'no OUTSIDER account (E2E_USER_OUTSIDER_*)');
  else for (const q of withId) plan.push({ id: 'SEC-AUTHZ-3', target: `${q.method} ${q.path_pattern}`, as: 'outsider', method: q.method, path: q.example_path });
  const gets = all.filter((q) => q.method === 'GET');
  if (reqs && !gets.length) skip('SEC-LEAK-1', 'the UI map recorded no GET requests');
  for (const q of gets) plan.push({ id: 'SEC-LEAK-1', target: `GET ${q.path_pattern}`, as: 'owner', method: 'GET', path: q.example_path });

  const prefix = gets[0] ? `/${gets[0].path_pattern.split('/')[1] ?? ''}` : '';
  const probes = ['/qa-sec-missing-page', ...(prefix ? [`${prefix}/qa-sec-missing`] : [])];
  const idq = gets.find((q) => q.path_pattern.includes(':id'));
  if (idq) {
    const parts = idq.example_path.split('?')[0].split('/'); const pp = idq.path_pattern.split('/');
    probes.push(parts.map((s, i) => (pp[i] === ':id' ? '%27%22%3C%00' : s)).join('/'));
  }
  for (const p of probes) plan.push({ id: 'SEC-ERR-1', target: p, as: 'owner', method: 'GET', path: p });
  for (const id of ['SEC-HDR-1', 'SEC-HDR-2', 'SEC-HDR-3']) plan.push({ id, target: '/', as: 'anonymous+owner', method: 'GET', path: '/' });
  plan.push({ id: 'SEC-HDR-4', target: 'sign-in cookies', as: 'owner', method: 'browser', path: '/' });
  const corsPath = gets[0]?.example_path ?? '/';
  plan.push({ id: 'SEC-CORS-1', target: corsPath, as: 'owner', method: 'OPTIONS+GET', path: corsPath, origin: 'https://evil.example' });
  plan.push({ id: 'SEC-MAP-1', target: '<script src> of the sign-in page and the owner home, found at run time', as: 'anonymous', method: 'HEAD', path: '<src>.map' });
  plan.push({ id: 'SEC-SESS-1', target: gets[0] ? `GET ${gets[0].path_pattern}` : '/', as: 'owner', method: 'browser', path: gets[0]?.example_path ?? '/' });
  const brute = ['OUTSIDER', 'MEMBER', 'VIEWER'].find((r) => roles[r.toLowerCase()]) ?? 'nonexistent user';
  plan.push({ id: 'SEC-BRUTE-1', target: `${failedLogins} wrong-password sign-ins`, as: brute.toLowerCase(), method: 'browser', path: '/' });

  const e2e = [];
  if (ctx.entity) e2e.push('SEC-XSS-1', 'SEC-INPUT-1');
  else for (const id of ['SEC-XSS-1', 'SEC-XSS-2', 'SEC-INPUT-1']) skip(id, 'the profile names no creatable entity (profile.json → security.entity)');
  if (ctx.entity && ctx.api_helper.createEntity) e2e.push('SEC-XSS-2');
  else if (ctx.entity) skip('SEC-XSS-2', 'the profile ships no lib/security-api.ts createEntity');
  if (!ctx.api_keys_named) skip('SEC-KEY-1', "the profile's SKILL.md names no API keys");
  else if (ctx.api_helper.createApiKey && ctx.api_helper.callWithKey) e2e.push('SEC-KEY-1');
  else skip('SEC-KEY-1', 'the profile names API keys but ships no lib/security-api.ts createApiKey + callWithKey (a profile gap)');
  for (const id of ['SEC-DEP-1', 'SEC-DEP-2', 'SEC-DEP-3', 'SEC-DEP-4', 'SEC-DEP-5']) {
    if (ctx.deployment.run) plan.push({ id, target: `namespace ${ctx.deployment.namespace}`, as: 'kubectl', method: 'get -o json', path: 'pods,networkpolicies' });
    else skip(id, ctx.deployment.reason);
  }
  return { plan, skipped, e2e };
}

const ctx = context();
const { plan, skipped, e2e } = buildPlan(ctx);
if (flags.dry) {
  console.log(JSON.stringify({ base: base.origin, build, roles, failed_logins: failedLogins, deployment: ctx.deployment, e2e_checks: e2e, plan, skipped }, null, 2));
  process.exit(0);
}

// ------------------------------------------------------------------ the run ----
const results = [...skipped];
const add = (id, target, status, evidence = {}, reason = '', severity = SEV[id]) => results.push({ id, target, status, severity, evidence, reason });
const HDRS = ['content-type', 'location', 'content-security-policy', 'x-content-type-options', 'x-frame-options', 'access-control-allow-origin',
  'access-control-allow-credentials', 'access-control-allow-methods', 'retry-after', 'www-authenticate'];
const subset = (h) => Object.fromEntries(HDRS.map((k) => [k, typeof h.get === 'function' ? h.get(k) : h[k]]).filter(([, v]) => v != null));
const ok2 = (s) => s >= 200 && s < 300;
const of = (planned, id) => planned.filter((p) => p.id === id);
const msg = (e) => String(e?.message ?? e).split('\n')[0].slice(0, 160);

const req = createRequire(process.env.QI_PLAYWRIGHT_FROM ?? join(WORK, 'suite', 'package.json'));
let pw;
try { pw = req('playwright-core'); } catch { pw = createRequire(req.resolve('@e2e-dev/web'))('playwright-core'); }
const browser = await pw.chromium.launch({ headless: true });
const settle = async (page) => { await page.waitForLoadState('networkidle', { timeout: 10000 }).catch(() => {}); await page.waitForTimeout(500); };
const pwdVisible = async (page) => (await page.locator('input[type=password]').filter({ visible: true }).count()) > 0;
const local = (u) => { try { return ['localhost', '127.0.0.1'].includes(new URL(u).hostname); } catch { return false; } };
const sameOrigin = (u) => { try { return new URL(u).origin === base.origin; } catch { return false; } };

async function signIn(role) {
  const c = cred(role);
  if (!c) throw new Error(`no ${role} account`);
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();
  let auth = null;
  page.on('request', (r) => { const h = r.headers().authorization; if (!auth && h && sameOrigin(r.url())) auth = h; });
  await page.goto(base.href, { waitUntil: 'domcontentloaded' }); await settle(page);
  const before = await context.cookies();
  const pwd = page.locator('input[type=password]');
  if (await pwd.count()) {
    await page.locator('input[type=text]:visible, input[type=email]:visible, input[name=username]').first().fill(c.username);
    await pwd.first().fill(c.password);
    await Promise.all([page.waitForURL((u) => u.origin === base.origin, { timeout: 30000 }), pwd.first().press('Enter')]);
    await settle(page);
  }
  if (await pwdVisible(page)) throw new Error(`${role} sign-in failed`);
  const first = Object.values(inv.routes ?? {}).find((r) => r?.example && r.example !== '/');
  if (!auth && first) { await page.goto(new URL(first.example, base).href, { waitUntil: 'domcontentloaded' }).catch(() => {}); await settle(page); }
  return { role, context, page, auth, before, cookies: await context.cookies(base.href) };
}

async function http(s, method, path, extra = {}) {
  const url = new URL(path, base);
  if (url.origin !== base.origin) throw new Error(`refusing ${url.origin}`);
  const headers = { accept: 'application/json, text/html;q=0.9, */*;q=0.1', ...(extra.headers ?? {}) };
  if (s?.cookies?.length) headers.cookie = s.cookies.map((c) => `${c.name}=${c.value}`).join('; ');
  if (s?.auth) headers.authorization = s.auth;
  const body = ['GET', 'HEAD', 'OPTIONS'].includes(method) ? undefined : '{}';
  if (body) headers['content-type'] = 'application/json';
  return fetch(url, { method, headers, body, redirect: 'manual', signal: AbortSignal.timeout(20000) });
}
const drop = async (res) => { await res.body?.cancel().catch(() => {}); };
const evidence = (p, res, more = {}) => ({ request: `${p.method} ${p.path} as ${p.as}`, status: res.status, headers: subset(res.headers), ...more });
async function guarded(ids, fn) { try { await fn(); } catch (e) { for (const id of [ids].flat()) add(id, '*', 'skipped', {}, `could not run: ${msg(e)}`); } }

const scripts = new Set();
const publicSet = new Set();
const docs = [];

// SEC-AUTH-1 — every mapped page, opened without a session.
await guarded('SEC-AUTH-1', async () => {
  const ctxA = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctxA.newPage();
  let phase = 'sign-in';
  page.on('response', (r) => {
    const q = r.request();
    if (phase !== 'sign-in' || !ok2(r.status()) || !['xhr', 'fetch'].includes(q.resourceType()) || !sameOrigin(r.url())) return;
    publicSet.add(`${q.method()} ${pattern(new URL(r.url()))}`);
  });
  const signinResp = await page.goto(base.href, { waitUntil: 'domcontentloaded' }); await settle(page);
  if (signinResp) docs.push({ request: 'GET / as anonymous', status: signinResp.status(), headers: subset(signinResp.headers()) });
  const signinText = await page.evaluate(() => document.body?.innerText ?? '');
  for (const s of await page.evaluate(() => [...document.scripts].map((x) => x.src).filter(Boolean))) scripts.add(s);
  phase = 'routes';
  for (const p of of(plan, 'SEC-AUTH-1')) {
    let resp;
    try { resp = await page.goto(new URL(p.path, base).href, { waitUntil: 'domcontentloaded', timeout: 30000 }); } catch (e) { add(p.id, p.target, 'skipped', { request: `GET ${p.path} as anonymous` }, `page did not load: ${msg(e)}`); continue; }
    await settle(page);
    const status = resp?.status() ?? 0;
    const text = await page.evaluate(() => document.body?.innerText ?? '');
    const r = inv.routes[p.target] ?? {};
    const shown = [...(r.headings ?? []), ...(r.buttons ?? [])].filter((t) => t && t.length >= 3 && !signinText.includes(t) && text.includes(t)).slice(0, 5);
    const ev = { request: `GET ${p.path} as anonymous`, status, landed: new URL(page.url()).pathname, shown };
    if ([401, 403].includes(status) || (await pwdVisible(page)) || !shown.length) add(p.id, p.target, 'pass', ev);
    else add(p.id, p.target, 'fail', ev, `without a session the page shows ${shown.length} of its signed-in controls and no sign-in`);
  }
  await ctxA.close();
});

const owner = await signIn('OWNER').catch((e) => { console.error(`security-checks: ${msg(e)}`); process.exit(1); });
for (const s of await owner.page.evaluate(() => [...document.scripts].map((x) => x.src).filter(Boolean))) scripts.add(s);

// SEC-HDR-4 — cookies the sign-in set.
await guarded('SEC-HDR-4', async () => {
  const fresh = owner.cookies.filter((c) => !owner.before.some((b) => b.name === c.name && b.value === c.value));
  const bad = fresh.map((c) => ({ name: c.name, httpOnly: c.httpOnly, sameSite: c.sameSite, secure: c.secure,
    problems: [!c.httpOnly && !/csrf|xsrf/i.test(c.name) && 'not HttpOnly', !['Lax', 'Strict'].includes(c.sameSite) && `SameSite=${c.sameSite}`,
      base.protocol === 'https:' && !c.secure && 'not Secure'].filter(Boolean) }));
  const ev = { request: 'owner sign-in', cookies: bad.map(({ problems, ...c }) => ({ ...c, problems })) };
  if (!fresh.length) add('SEC-HDR-4', 'sign-in cookies', 'pass', ev, 'the sign-in set no cookie (token session)');
  else {
    const worst = bad.filter((c) => c.problems.length);
    add('SEC-HDR-4', 'sign-in cookies', worst.length ? 'fail' : 'pass', ev, worst.map((c) => `${c.name}: ${c.problems.join(', ')}`).join('; '));
  }
});

// SEC-HDR-1..3 — the app's HTML document, anonymous and signed in.
await guarded(['SEC-HDR-1', 'SEC-HDR-3'], async () => {
  let path = '/'; let res;
  for (let i = 0; i < 4; i++) {
    res = await http(owner, 'GET', path, { headers: { accept: 'text/html' } }); await drop(res);
    const loc = res.headers.get('location');
    if (res.status < 300 || res.status >= 400 || !loc || new URL(loc, base).origin !== base.origin) break;
    path = new URL(loc, base).pathname;
  }
  docs.push({ request: `GET ${path} as owner`, status: res.status, headers: subset(res.headers) });
  const csp = (d) => d.headers['content-security-policy'] ?? '';
  const no = (f) => docs.filter((d) => !f(d)).map((d) => d.request);
  const judge = (id, missing, why) => add(id, '/', missing.length ? 'fail' : 'pass', { documents: docs }, missing.length ? `${why}: ${missing.join(', ')}` : '');
  judge('SEC-HDR-1', no((d) => csp(d)), 'no Content-Security-Policy');
  judge('SEC-HDR-3', no((d) => /frame-ancestors/i.test(csp(d)) || /^(deny|sameorigin)$/i.test(d.headers['x-frame-options'] ?? '')), 'framing allowed');
});

// SEC-LEAK-1 (+ SEC-HDR-2 on every response) — the owner's own replays, JSON walked.
const nosniffMissing = docs.filter((d) => !/nosniff/i.test(d.headers['x-content-type-options'] ?? '')).map((d) => d.request);
await guarded('SEC-LEAK-1', async () => {
  const own = new Set([...owner.cookies.map((c) => c.value), owner.auth?.replace(/^\w+\s+/, '')].filter(Boolean));
  const KEY = /(^|_)(password|passwd|secret|token|hash|api_?key|private_?key)s?$/;
  const MASK = /^(\*+|•+|x+|redacted|hidden|null)$/i;
  for (const p of of(plan, 'SEC-LEAK-1')) {
    const res = await http(owner, 'GET', p.path);
    if (!/nosniff/i.test(res.headers.get('x-content-type-options') ?? '')) nosniffMissing.push(`GET ${p.path}`);
    if (!ok2(res.status)) { await drop(res); add(p.id, p.target, 'skipped', evidence(p, res), `the owner's replay answered ${res.status}`); continue; }
    if (!/json/i.test(res.headers.get('content-type') ?? '')) { await drop(res); add(p.id, p.target, 'pass', evidence(p, res), 'not JSON'); continue; }
    let body; try { body = JSON.parse((await res.text()).slice(0, 2_000_000)); } catch { add(p.id, p.target, 'pass', evidence(p, res), 'unparsable JSON'); continue; }
    const fields = [];
    const walk = (v, at) => {
      if (fields.length >= 20 || v == null || typeof v !== 'object') return;
      for (const [k, x] of Object.entries(v)) {
        const name = k.replace(/([a-z0-9])([A-Z])/g, '$1_$2').toLowerCase();
        if (typeof x === 'string' && x && KEY.test(name) && !MASK.test(x) && !own.has(x)) fields.push({ field: `${at}.${k}`, length: x.length });
        walk(x, Array.isArray(v) ? `${at}[${k}]` : `${at}.${k}`);
      }
    };
    walk(body, '$');
    add(p.id, p.target, fields.length ? 'fail' : 'pass', evidence(p, res, { fields }), fields.length ? 'secret-named fields with values (values never recorded)' : '');
  }
});
add('SEC-HDR-2', '/ and the mapped GETs', nosniffMissing.length ? 'fail' : 'pass', { missing: nosniffMissing.slice(0, 20) }, nosniffMissing.length ? `${nosniffMissing.length} responses without X-Content-Type-Options: nosniff` : '');

// SEC-ERR-1 — unknown and malformed paths: no stack trace in the answer.
const STACK = [['javascript', /\n\s+at [\w$.<>[\] ]+ \(?[^\s()]+:\d+:\d+\)?/], ['python', /Traceback \(most recent call last\)/], ['java', /\bat [\w$.]+\([\w$]+\.java:\d+\)/],
  ['dotnet', /\bat [\w.<>`]+\(.*\) in .+:line \d+/], ['go', /goroutine \d+ \[running\]/], ['php', /(Fatal error|Parse error|Warning): .+ in \/.+ on line \d+/], ['ruby', /\.rb:\d+:in `/]];
await guarded('SEC-ERR-1', async () => {
  for (const p of of(plan, 'SEC-ERR-1')) {
    const res = await http(owner, 'GET', p.path);
    const text = (await res.text()).slice(0, 200_000);
    const hit = STACK.filter(([, re]) => re.test(text)).map(([n]) => n);
    add(p.id, p.target, hit.length ? 'fail' : 'pass', evidence(p, res, { stack_trace: hit }), hit.length ? `a ${hit.join('/')} stack trace in the response (text not recorded)` : '');
  }
});

// SEC-CORS-1 — a foreign origin, preflight and plain.
await guarded('SEC-CORS-1', async () => {
  const p = of(plan, 'SEC-CORS-1')[0]; const evil = p.origin;
  const pre = await http(null, 'OPTIONS', p.path, { headers: { origin: evil, 'access-control-request-method': 'GET', 'access-control-request-headers': 'authorization' } }); await drop(pre);
  const get = await http(owner, 'GET', p.path, { headers: { origin: evil } }); await drop(get);
  const allowed = [pre, get].filter((r) => [evil, '*'].includes(r.headers.get('access-control-allow-origin') ?? ''));
  const creds = allowed.some((r) => r.headers.get('access-control-allow-credentials') === 'true' && r.headers.get('access-control-allow-origin') === evil);
  const ev = { preflight: { request: `OPTIONS ${p.path} Origin: ${evil}`, status: pre.status, headers: subset(pre.headers) }, simple: { request: `GET ${p.path} as owner Origin: ${evil}`, status: get.status, headers: subset(get.headers) } };
  add(p.id, p.path, allowed.length ? 'fail' : 'pass', ev, allowed.length ? `the foreign origin is allowed${creds ? ' with credentials' : ''}` : '', creds ? 'high' : SEV['SEC-CORS-1']);
});

// SEC-AUTHZ-1..3 — the owner's recorded requests, replayed as someone else.
async function replay(id, s, judge) {
  for (const p of of(plan, id)) {
    if (id === 'SEC-AUTHZ-1' && publicSet.has(p.target)) { add(p.id, p.target, 'skipped', { request: `${p.method} ${p.path} as anonymous` }, 'public: it answered 2xx to the sign-in page itself'); continue; }
    const res = await http(s, p.method, p.path); await drop(res);
    add(p.id, p.target, judge(p, res.status) ? 'pass' : 'fail', evidence(p, res), judge(p, res.status) ? '' : `answered ${res.status} to ${p.as}`);
  }
}
await guarded('SEC-AUTHZ-1', () => replay('SEC-AUTHZ-1', null, (p, st) => !ok2(st)));
for (const [id, role, judge] of [['SEC-AUTHZ-2', 'VIEWER', (p, st) => isRead(p.method) || !ok2(st)], ['SEC-AUTHZ-3', 'OUTSIDER', (p, st) => !ok2(st)]]) {
  if (!of(plan, id).length) continue;
  await guarded(id, async () => { const s = await signIn(role); try { await replay(id, s, judge); } finally { await s.context.close(); } });
}

// SEC-MAP-1 — source maps: status only, the body is never read.
await guarded('SEC-MAP-1', async () => {
  const srcs = [...scripts].filter(sameOrigin).slice(0, 30);
  if (!srcs.length) { add('SEC-MAP-1', '*', 'skipped', {}, 'no same-origin <script src>'); return; }
  for (const s of srcs) {
    const u = new URL(s); u.search = ''; u.pathname += '.map';
    let method = 'HEAD';
    let res = await fetch(u, { method, redirect: 'manual', signal: AbortSignal.timeout(20000) });
    if ([405, 501].includes(res.status)) { method = 'GET'; res = await fetch(u, { redirect: 'manual', signal: AbortSignal.timeout(20000) }); }
    await drop(res);
    add('SEC-MAP-1', u.pathname, res.status === 200 ? 'fail' : 'pass', { request: `${method} ${u.pathname}`, status: res.status }, res.status === 200 ? 'the source map is served (its content was not read)' : '');
  }
});

// SEC-SESS-1 — a signed-out session must stop working.
await guarded('SEC-SESS-1', async () => {
  const p = of(plan, 'SEC-SESS-1')[0];
  const s = await signIn('OWNER');
  await s.page.goto(base.href, { waitUntil: 'domcontentloaded' }); await settle(s.page);
  const find = async () => {
    for (const role of ['menuitem', 'button', 'link']) {
      const l = s.page.getByRole(role, { name: /sign ?out|log ?out/i }).filter({ visible: true });
      if (await l.count()) return l.first();
    }
    return null;
  };
  let ctl = await find();
  const openers = s.page.getByRole('button', { name: new RegExp(`account|profile|user|avatar|menu|${cred('OWNER').username.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`, 'i') }).filter({ visible: true })
    .or(s.page.locator('[aria-haspopup]:visible'));
  for (let i = 0; !ctl && i < Math.min(await openers.count(), 5); i++) { await openers.nth(i).click({ timeout: 5000 }).catch(() => {}); await s.page.waitForTimeout(500); ctl = await find(); }
  if (!ctl) { add(p.id, p.target, 'skipped', { request: 'sign out as owner' }, 'no sign-out control found'); await s.context.close(); return; }
  await ctl.click({ timeout: 5000 }); await settle(s.page);
  if (!(await pwdVisible(s.page))) { const c = await find(); if (c) { await c.click({ timeout: 5000 }).catch(() => {}); await settle(s.page); } }
  let ev; let alive;
  if (p.path !== '/') { const res = await http(s, 'GET', p.path); await drop(res); ev = evidence({ ...p, method: 'GET', as: 'owner after sign-out' }, res); alive = ok2(res.status); }
  else {
    const c2 = await browser.newContext(); await c2.addCookies(s.cookies); const pg = await c2.newPage();
    await pg.goto(base.href, { waitUntil: 'domcontentloaded' }); await settle(pg);
    alive = !(await pwdVisible(pg)); ev = { request: 'GET / with the signed-out cookies', signed_in: alive }; await c2.close();
  }
  add(p.id, p.target, alive ? 'fail' : 'pass', ev, alive ? 'the session still works after sign-out' : '');
  await s.context.close();
});

// SEC-BRUTE-1 — repeated wrong passwords must meet a limit.
await guarded('SEC-BRUTE-1', async () => {
  const p = of(plan, 'SEC-BRUTE-1')[0];
  const role = p.as.toUpperCase();
  const user = cred(role)?.username ?? `qa-sec-nobody-${Date.now()}`;
  const c = await browser.newContext(); const page = await c.newPage();
  const statuses = new Set();
  page.on('response', (r) => { if (local(r.url())) statuses.add(r.status()); });
  const LOCK = /too many|locked|lockout|try again (later|in)|temporarily (blocked|disabled)|rate.?limit|slow down|captcha/i;
  const times = []; let limited = null;
  for (let i = 0; i < failedLogins && !limited; i++) {
    if (!(await pwdVisible(page))) { await page.goto(base.href, { waitUntil: 'domcontentloaded' }); await settle(page); }
    if (!(await pwdVisible(page))) { limited = LOCK.test(await page.evaluate(() => document.body?.innerText ?? '')) ? 'message' : null; break; }
    await page.locator('input[type=text]:visible, input[type=email]:visible, input[name=username]').first().fill(user);
    await page.locator('input[type=password]').first().fill(`qa-wrong-${Date.now()}-${i}`);
    const t0 = Date.now(); await page.locator('input[type=password]').first().press('Enter'); await settle(page); times.push(Date.now() - t0 - 500);
    if (statuses.has(429)) limited = '429';
    else if (LOCK.test(await page.evaluate(() => document.body?.innerText ?? ''))) limited = 'message';
  }
  const med = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)] ?? 0;
  const first = med(times.slice(0, 3)); const last = med(times.slice(-3));
  if (!limited && times.length >= 6 && last >= 3 * first && last - first >= 1000) limited = 'delay';
  const ev = { request: `${times.length} wrong-password sign-ins as ${p.as}`, statuses: [...statuses].sort(), first_ms: first, last_ms: last, limited };
  add(p.id, p.target, limited ? 'pass' : 'fail', ev, limited ? '' : 'no 429, lockout message or growing delay');
  await c.close();
});

// SEC-DEP-1..5 — the live objects of the product's namespace, read-only.
if (ctx.deployment.run) {
  await guarded(['SEC-DEP-1', 'SEC-DEP-2', 'SEC-DEP-3', 'SEC-DEP-4', 'SEC-DEP-5'], async () => {
    const kc = (() => { try { execFileSync('sh', ['-c', 'command -v kubectl'], { stdio: 'ignore' }); return ['kubectl']; } catch { return ['k3s', 'kubectl']; } })();
    const get = (kind) => JSON.parse(execFileSync(kc[0], [...kc.slice(1), 'get', kind, '-n', ctx.deployment.namespace, '-o', 'json'], { encoding: 'utf8', maxBuffer: 64 << 20, stdio: ['ignore', 'pipe', 'pipe'] }));
    const pods = get('pods').items ?? []; const nps = get('networkpolicies').items ?? [];
    const DEFAULTS = new Set(['admin', 'administrator', 'password', 'passw0rd', 'changeme', 'change-me', 'changeit', 'secret', 'default', 'root', 'test',
      'guest', '123456', '12345678', 'letmein', 'postgres', 'mysql', 'minioadmin', 'minio123', 'redis', 'rabbitmq']);
    const off = { 'SEC-DEP-1': new Set(), 'SEC-DEP-2': new Set(), 'SEC-DEP-3': new Set(), 'SEC-DEP-5': new Set() };
    for (const pod of pods) {
      const owner_ = pod.metadata?.ownerReferences?.[0]?.name ?? pod.metadata?.name;
      const ps = pod.spec?.securityContext ?? {};
      for (const ct of [...(pod.spec?.containers ?? []), ...(pod.spec?.initContainers ?? [])]) {
        const cs = ct.securityContext ?? {}; const at = `${owner_}/${ct.name}`;
        const uid = cs.runAsUser ?? ps.runAsUser; const nonRoot = cs.runAsNonRoot ?? ps.runAsNonRoot;
        if (cs.privileged) off['SEC-DEP-1'].add(`${at}: privileged`);
        else if (uid === 0) off['SEC-DEP-1'].add(`${at}: runAsUser 0`);
        else if (uid == null && nonRoot !== true) off['SEC-DEP-1'].add(`${at}: may run as root (no runAsNonRoot/runAsUser)`);
        if (cs.allowPrivilegeEscalation === true) off['SEC-DEP-1'].add(`${at}: allowPrivilegeEscalation`);
        if (!ct.resources?.limits?.cpu || !ct.resources?.limits?.memory) off['SEC-DEP-2'].add(`${at}: no ${!ct.resources?.limits?.cpu ? 'cpu' : 'memory'} limit`);
        for (const e of ct.env ?? []) {
          if (e.valueFrom?.secretKeyRef) off['SEC-DEP-3'].add(`${at}: ${e.name}`);
          if (typeof e.value === 'string' && /pass|secret|token|key/i.test(e.name) && DEFAULTS.has(e.value.toLowerCase())) off['SEC-DEP-5'].add(`${at}: ${e.name}`);
        }
        for (const e of ct.envFrom ?? []) if (e.secretRef) off['SEC-DEP-3'].add(`${at}: envFrom ${e.secretRef.name}`);
      }
    }
    const target = `namespace ${ctx.deployment.namespace}`;
    const why = { 'SEC-DEP-1': 'containers that may run as root or privileged', 'SEC-DEP-2': 'containers without cpu and memory limits',
      'SEC-DEP-3': 'Secrets passed as environment variables', 'SEC-DEP-5': 'well-known default passwords in plain env values (values not recorded)' };
    for (const [id, set] of Object.entries(off)) add(id, target, set.size ? 'fail' : 'pass', { request: `kubectl get pods -n ${ctx.deployment.namespace} -o json`, pods: pods.length, offenders: [...set].slice(0, 20) }, set.size ? `${set.size} ${why[id]}` : '');
    add('SEC-DEP-4', target, nps.length ? 'pass' : 'fail', { request: `kubectl get networkpolicies -n ${ctx.deployment.namespace} -o json`, count: nps.length }, nps.length ? '' : 'no NetworkPolicy');
  });
}
await owner.context.close();
await browser.close();

// ------------------------------------------------------------------ output ----
const ORDER = ['critical', 'high', 'medium', 'low', 'info'];
const counts = Object.fromEntries(ORDER.map((s) => [s, results.filter((r) => r.status === 'fail' && r.severity === s).length]));
counts.skipped = results.filter((r) => r.status === 'skipped').length;
counts.passed = results.filter((r) => r.status === 'pass').length;
const out = flags.out ?? join(WORK, 'security', build);
mkdirSync(out, { recursive: true });
writeFileSync(join(out, 'findings.json'), `${JSON.stringify({ build, generated_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'), base: base.origin, counts, checks: results }, null, 2)}\n`);
writeFileSync(join(out, 'e2e-input.json'), `${JSON.stringify({ build, entity: ctx.entity, api_keys_named: ctx.api_keys_named, api_helper: ctx.api_helper, e2e_checks: e2e }, null, 2)}\n`);
console.log(JSON.stringify({ out, build, counts, e2e_checks: e2e }));
