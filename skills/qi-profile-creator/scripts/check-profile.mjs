#!/usr/bin/env node
// check-profile.mjs — check a quality-inspector product profile against the contract
// (docs/profile-contract.md of the quality-inspector definition) before it ships.
//
//   node check-profile.mjs [--core <dir>] [--live] [--set <key>=<value>]...
//                          [--candidate <channel>] [--baseline <channel>] <profile-dir>
//
// --core      the quality-inspector definition (default: $QI_CORE, else the definition
//             this skill ships in); needed for engine profiles and the engine's own check.
// --live      also run the read-only commands (bin/versions, bin/build-time) against the
//             real registry. bin/env is never run.
// --set       a non-default profile setting, as an instance would write it.
// Prints PASS/WARN/FAIL lines; exit 0 = no FAIL, 1 = at least one, 2 = usage.
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, delimiter, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const usage = (code = 2) => {
  console.error('usage: check-profile.mjs [--core <dir>] [--live] [--set <key>=<value>]... [--candidate <channel>] [--baseline <channel>] <profile-dir>');
  process.exit(code);
};
let core = process.env.QI_CORE || '';
let live = false;
let dir = '';
let candidate = '';
let baseline = '';
const sets = {};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--core') core = argv[++i] ?? usage();
  else if (a === '--live') live = true;
  else if (a === '--candidate') candidate = argv[++i] ?? usage();
  else if (a === '--baseline') baseline = argv[++i] ?? usage();
  else if (a === '--set') {
    const kv = argv[++i] ?? usage();
    const j = kv.indexOf('=');
    if (j < 1) usage();
    sets[kv.slice(0, j)] = kv.slice(j + 1);
  } else if (a === '-h' || a === '--help') usage(0);
  else if (a.startsWith('--') || dir) usage();
  else dir = a;
}
if (!dir) usage();

let fails = 0;
let warns = 0;
const pass = (m) => console.log(`PASS  ${m}`);
const warn = (m) => { warns++; console.log(`WARN  ${m}`); };
const fail = (m) => { fails++; console.log(`FAIL  ${m}`); };
const finish = () => {
  console.log(`\ncheck-profile: ${fails} fail, ${warns} warn`);
  process.exit(fails ? 1 : 0);
};
const obj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const str = (v) => typeof v === 'string' && v.trim().length > 0;
const read = (f) => { try { return readFileSync(f, 'utf8'); } catch { return null; } };
const isExec = (f) => { try { return (statSync(f).mode & 0o111) !== 0; } catch { return false; } };
// How the core starts a profile's bin/<cmd> (scripts/lib/profile.sh → profile_run): itself
// with its exec bit; without it — a profile installed through the platform is plain files —
// through the interpreter its #! line names; bash when it has none (bash runs such a file
// as a script even with its exec bit).
const shebang = (f) => { const l = (read(f) ?? '').split('\n')[0].replace(/\r$/, ''); return l.startsWith('#!') ? l.slice(2).trim().split(/\s+/).filter(Boolean) : null; };
const argvOf = (f) => { const sb = shebang(f); return sb === null ? ['bash', f] : isExec(f) ? [f] : [...sb, f]; };
// The same node for every child (an older system node may come first on PATH).
const PATH = `${dirname(process.execPath)}${delimiter}${process.env.PATH ?? ''}`;

// ------------------------------------------------------------------ the core ----
if (!core) {
  const own = resolve(dirname(realpathSync(fileURLToPath(import.meta.url))), '../../..');
  if (existsSync(join(own, 'docs/profile-contract.md'))) core = own;
}
// Absolute: the engine's check and egress-rules.sh run with another working directory.
if (core) core = resolve(core);
if (core && !existsSync(join(core, 'docs/profile-contract.md'))) {
  fail(`--core ${core} is not the quality-inspector definition (no docs/profile-contract.md)`);
  core = '';
}
if (core) pass(`core: ${core} (${(read(join(core, 'VERSION')) ?? '?').trim()})`);
else warn('no core given (--core or QI_CORE) — engine and suite checks are skipped');

// --------------------------------------------------------------- the files ----
dir = resolve(dir);
if (!existsSync(dir) || !statSync(dir).isDirectory()) { fail(`no such profile directory: ${dir}`); finish(); }
const name = basename(dir);
// The kit's egress opens one directory of a repository, whichever: .quality-inspector/
// (docs/profile-contract.md → Where it lives). A profile anywhere else cannot be installed.
if (basename(dirname(dir)) === '.quality-inspector') pass(`location: .quality-inspector/${name}`);
else warn(`location: ${basename(dirname(dir))}/${name} — the platform installs a profile only from .quality-inspector/<profile>/ of its repository`);
const files = [];
const rel = (f) => relative(dir, f);
// A profile is fetched by directory: plain files only, so a symlink or a submodule fails.
const odd = new Set();
const notPlain = (p, what) => { if (!odd.has(p)) { odd.add(p); fail(`${p}: ${what} — a profile fetched by directory holds plain files only`); } };
const walk = (d) => {
  for (const e of readdirSync(d, { withFileTypes: true })) {
    const p = join(d, e.name);
    if (e.name === '.git') { if (d !== dir) notPlain(rel(d), 'a git submodule'); continue; }
    if (e.name === 'node_modules') continue;
    if (e.isSymbolicLink()) notPlain(rel(p), 'a symlink');
    else if (e.isDirectory()) walk(p);
    else if (e.isFile()) files.push(p);
  }
};
walk(dir);
// What git tracks there, too: an uninitialised submodule is an empty directory on disk.
const tracked = spawnSync('git', ['-C', dir, 'ls-files', '-s', '--', '.'], { encoding: 'utf8' });
if (tracked.status === 0) {
  for (const line of tracked.stdout.split('\n')) {
    const t = line.match(/^(120000|160000) \S+ \d+\t(.+)$/);
    if (t) notPlain(t[2], t[1] === '160000' ? 'a git submodule' : 'a symlink');
  }
}

// ------------------------------------------------------------- profile.json ----
const manifestText = read(join(dir, 'profile.json'));
let m = null;
if (manifestText === null) fail('profile.json: missing');
else {
  try { m = JSON.parse(manifestText); pass('profile.json parses'); } catch (e) { fail(`profile.json: not JSON (${e.message})`); }
}
if (m !== null && !obj(m)) { fail('profile.json: not an object'); m = null; }

if (m) {
  const TOP = ['schema', 'product', 'app', 'issues', 'engine', 'engine_config', 'boundary', 'egress', 'requires', 'security', 'canary', 'interfaces', 'validation', 'expected_requests', 'environment', 'config', 'sandbox', 'operator_credentials'];
  for (const k of Object.keys(m)) if (!TOP.includes(k)) warn(`profile.json: unknown key '${k}' — the core ignores it`);
  m.schema === 'qi-profile/v1' ? pass('schema qi-profile/v1') : fail(`schema '${m.schema ?? ''}' is not qi-profile/v1`);
  str(m.product) ? pass(`product: ${m.product}`) : fail('product: missing');

  const url = obj(m.app) ? m.app.url : undefined;
  /^http:\/\/(localhost|127\.0\.0\.1)(:\d{1,5})?(\/|$)/.test(String(url ?? ''))
    ? pass(`app.url ${url}`)
    : fail(`app.url '${url ?? ''}' must be http://localhost or http://127.0.0.1 — the product runs inside the agent's VM`);

  if (m.issues === undefined) warn('issues.provider: missing — github is the only provider today');
  else if (!obj(m.issues) || m.issues.provider !== 'github') fail(`issues.provider '${obj(m.issues) ? m.issues.provider ?? '' : ''}' is not github`);
  else pass('issues.provider github');

  // How it runs: the profile's own bin/<cmd>, else its engine's.
  const engine = m.engine;
  let engineDir = '';
  if (engine !== undefined) {
    if (!str(engine)) fail('engine: not a name');
    else if (!core) warn(`engine '${engine}': not verified without the core`);
    else if (!existsSync(join(core, 'engines', engine))) fail(`engine '${engine}': the core has no engines/${engine}`);
    else { engineDir = join(core, 'engines', engine); pass(`engine ${engine}`); }
    if (!obj(m.engine_config)) fail('engine_config: missing or not an object (the engine reads its product from it)');
  } else if (m.engine_config !== undefined) warn('engine_config without engine — nothing reads it');

  // A profile's own bin/<cmd>: its #! line decides how it starts (the exec bit is optional),
  // and an interpreter other than bash must be on the VM (requires.commands).
  const ownBin = (cmd) => {
    const own = join(dir, 'bin', cmd);
    const sb = shebang(own);
    if (!sb) warn(`bin/${cmd}: no #! line — it runs through bash`);
    else if (!sb.length) { fail(`bin/${cmd}: its #! line names no interpreter`); return false; }
    const interp = sb ? basename(sb[0] === '/usr/bin/env' || basename(sb[0]) === 'env' ? sb.find((a, i) => i > 0 && !a.startsWith('-')) ?? '' : sb[0]) : 'bash';
    if (!['bash', 'sh'].includes(interp)) {
      const cmds = obj(m.requires) && Array.isArray(m.requires.commands) ? m.requires.commands : [];
      if (!cmds.includes(interp)) warn(`bin/${cmd}: runs through ${interp}, which requires.commands does not list — the VM may lack it`);
      pass(`bin/${cmd}: own, through ${interp}`);
      return true;
    }
    const r = spawnSync('bash', ['-n', own], { encoding: 'utf8' });
    if (r.error) warn(`bin/${cmd}: bash -n could not run — ${r.error.message}`);
    else if (r.status === 0) pass(`bin/${cmd}: own, bash -n clean`);
    else { fail(`bin/${cmd}: syntax error — ${(r.stderr || '').trim().split('\n')[0]}`); return false; }
    return true;
  };
  for (const cmd of ['env', 'versions', 'build-time']) {
    const own = join(dir, 'bin', cmd);
    if (existsSync(own)) ownBin(cmd);
    else if (engineDir && isExec(join(engineDir, 'bin', cmd))) pass(`bin/${cmd}: from engine ${engine}`);
    else if (engine !== undefined && !engineDir) warn(`bin/${cmd}: expected from engine '${engine}', not verified`);
    else fail(`bin/${cmd}: neither the profile nor an engine provides it`);
  }
  const binDir = join(dir, 'bin');
  if (existsSync(binDir)) {
    for (const f of readdirSync(binDir)) {
      if (!['env', 'versions', 'build-time', 'sandbox'].includes(f)) warn(`bin/${f}: not a contract command — the core never calls it`);
    }
  }

  // boundary
  if (m.boundary !== undefined) {
    if (!obj(m.boundary)) fail('boundary: not an object');
    else {
      const gp = m.boundary.github_paths ?? [];
      if (!Array.isArray(gp) || gp.some((p) => !str(p))) fail('boundary.github_paths: must be a list of paths');
      else if (gp.some((p) => /^\/?repos\//.test(p))) fail('boundary.github_paths: paths are relative to repos/<target>/ — drop the repos/ prefix');
      const urls = m.boundary.urls ?? [];
      if (!Array.isArray(urls) || urls.some((u) => !/^https?:\/\/\S+$/.test(String(u)))) fail('boundary.urls: must be a list of full URLs');
      const pk = m.boundary.packages ?? [];
      if (!Array.isArray(pk) || pk.some((p) => !str(p) || /[\s\\]|^[./]|node_modules/.test(p))) {
        fail('boundary.packages: must be a list of npm scopes or package names (@acme, acme-cli)');
      }
      if (Array.isArray(gp) && Array.isArray(urls) && Array.isArray(pk)) {
        pass(`boundary: ${gp.length} repository path(s), ${urls.length} URL(s) probed, ${pk.length} package(s) refused under node_modules/`);
      }
    }
  } else warn('boundary: none — the core\'s own probes only');

  // egress
  if (m.egress === undefined || (Array.isArray(m.egress) && !m.egress.length)) {
    warn('egress: empty — does the install download nothing?');
  } else if (!Array.isArray(m.egress)) fail('egress: not a list');
  else {
    let ok = true;
    for (const [i, e] of m.egress.entries()) {
      const id = `egress[${i}]`;
      if (!obj(e) || !str(e.host) || /[/:\s]/.test(e.host)) { fail(`${id}: host must be a bare host name (no scheme, port or path)`); ok = false; continue; }
      // The keys scripts/egress-rules.sh reads: verdict, method, host, pathPattern (or path), why.
      if (e.method !== undefined && !['*', 'GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'].includes(e.method)) { fail(`${id} (${e.host}): method '${e.method}' is not * or an HTTP method`); ok = false; }
      if (e.verdict !== undefined && !['allow', 'deny'].includes(e.verdict)) { fail(`${id} (${e.host}): verdict '${e.verdict}' is not allow or deny`); ok = false; }
      for (const k of ['path', 'pathPattern']) {
        if (e[k] !== undefined && !(e[k] === '*' || String(e[k]).startsWith('/'))) { fail(`${id} (${e.host}): ${k} must be * or start with /`); ok = false; }
      }
      if (e.path !== undefined && e.pathPattern !== undefined) warn(`${id} (${e.host}): both path and pathPattern — pathPattern wins`);
      if (!str(e.why)) warn(`${id} (${e.host}): no why — the operator applies it without knowing what it is for`);
    }
    if (ok) pass(`egress: ${m.egress.length} host rule(s)`);
  }

  // sandbox — the external test accounts the nested product connects to (scripts/sandbox.sh
  // reads the same rules).
  if (m.sandbox !== undefined) {
    const acc = obj(m.sandbox) ? m.sandbox.accounts : undefined;
    if (!Array.isArray(acc) || !acc.length) fail('sandbox.accounts: must be a non-empty list');
    else {
      let ok = true; const ids = new Set();
      for (const [i, a] of acc.entries()) {
        const id = obj(a) && typeof a.id === 'string' ? a.id : `sandbox.accounts[${i}]`;
        if (!obj(a) || !/^[a-z][a-z0-9]{0,15}$/.test(String(a.id ?? ''))) { fail(`${id}: id must be [a-z][a-z0-9]{0,15}`); ok = false; continue; }
        if (ids.has(a.id)) { fail(`sandbox ${id}: declared twice`); ok = false; } ids.add(a.id);
        if (!str(a.what)) { fail(`sandbox ${id}: no what — the operator is told what to create`); ok = false; }
        if (!/^sandbox\/[a-z0-9-]+\.md$/.test(String(a.guide ?? ''))) { fail(`sandbox ${id}: guide must be sandbox/<name>.md`); ok = false; }
        else if (!existsSync(join(dir, a.guide))) { fail(`sandbox ${id}: ${a.guide} is missing`); ok = false; }
        if (!Array.isArray(a.credentials) || !a.credentials.length || a.credentials.some((k) => !/^[A-Z][A-Z0-9_]{0,31}$/.test(String(k)))) {
          fail(`sandbox ${id}: credentials must be a non-empty list of [A-Z][A-Z0-9_]{0,31} names`); ok = false;
        }
      }
      const own = join(dir, 'bin', 'sandbox');
      if (!existsSync(own)) warn('sandbox: no bin/sandbox — nothing checks the accounts at onboarding');
      else if (!ownBin('sandbox')) ok = false;
      if (ok) pass(`sandbox: ${acc.length} account(s) — ${acc.map((a) => a.id).join(', ')}`);
    }
  }
  // operator_credentials — values the operator supplies once, seeded as empty E2E_<NAME> lines
  // by scripts/env.sh init (docs/profile-contract.md → `operator_credentials`).
  if (m.operator_credentials !== undefined) {
    const list = m.operator_credentials;
    if (!Array.isArray(list) || !list.length) fail('operator_credentials: must be a non-empty list');
    else {
      let ok = true; const names = new Set();
      for (const [i, c] of list.entries()) {
        const idx = `operator_credentials[${i}]`;
        const name = obj(c) ? String(c.name ?? '') : '';
        if (!/^[A-Z][A-Z0-9_]{0,31}$/.test(name)) { fail(`${idx}: name must be [A-Z][A-Z0-9_]{0,31}`); ok = false; continue; }
        if (!/(^|_)(PASSWORD|TOKEN|SECRET|KEY)(_|$)/.test(name)) { fail(`operator credential ${name}: name needs a PASSWORD, TOKEN, SECRET or KEY segment, so its value is masked`); ok = false; }
        if (names.has(name)) { fail(`operator credential ${name}: declared twice`); ok = false; } names.add(name);
        const id = name;
        if (!str(c.what)) { fail(`operator credential ${id}: no what — the operator is told what to fill`); ok = false; }
        if (c.required !== undefined && typeof c.required !== 'boolean') { fail(`operator credential ${id}: required must be true or false`); ok = false; }
      }
      if (ok) pass(`operator_credentials: ${list.length} — ${list.map((c) => 'E2E_' + c.name).join(', ')}`);
    }
  }
  // egress placeholders name profile keys that exist.
  if (Array.isArray(m.egress)) {
    for (const e of m.egress) {
      for (const k of `${e?.host ?? ''} ${e?.pathPattern ?? e?.path ?? ''}`.matchAll(/\{profile\.([a-z0-9_]+)\}/g)) {
        if (!obj(m.config) || !obj(m.config[k[1]])) fail(`egress (${e.host}): {profile.${k[1]}} names no config key`);
      }
    }
  }

  // requires
  if (m.requires === undefined) warn('requires: none — onboarding cannot check the VM fits the product');
  else if (!obj(m.requires)) fail('requires: not an object');
  else {
    const r = m.requires;
    const before = fails;
    if (r.root !== undefined && typeof r.root !== 'boolean') fail('requires.root: must be true or false');
    if (r.commands !== undefined && (!Array.isArray(r.commands) || r.commands.some((c) => !str(c) || /\s/.test(c)))) fail('requires.commands: must be a list of command names');
    if (r.memory_gi !== undefined && !(typeof r.memory_gi === 'number' && r.memory_gi > 0)) fail('requires.memory_gi: must be a positive number');
    if (fails === before) pass(`requires: root ${r.root === true}, commands ${(r.commands ?? []).join(' ') || '-'}, memory ${r.memory_gi ?? '-'} GiB`);
  }

  // canary: optional; without it the injection canary asks the act model to find an object.
  if (m.canary !== undefined) {
    const c = m.canary, before = fails;
    if (!obj(c)) fail('canary: not an object');
    else if (c.none !== undefined) { if (!str(c.none)) fail('canary.none: must say why the product has no such object'); }
    else {
      if (!str(c.thing)) fail('canary.thing: the noun of an object a user creates, and where (e.g. "project, under Projects → New")');
      if (c.field !== undefined && !str(c.field)) fail('canary.field: the free-text field that shows the text ("description" by default, "name" for the name itself)');
    }
    if (fails === before) pass(c.none !== undefined ? `canary: none — ${c.none}` : `canary: ${c.thing}, text in its ${c.field ?? 'description'}`);
  }
  // security and interfaces: optional; without them the core skips what needs them.
  if (m.security === undefined) warn('security: none — the security run skips its entity checks');
  else if (!obj(m.security)) fail('security: not an object');
  else {
    const s = m.security;
    const before = fails;
    if (s.entity !== undefined && !str(s.entity)) fail('security.entity: must be the noun of the main object a user creates');
    if (s.namespace !== undefined && !/^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/.test(String(s.namespace))) fail(`security.namespace '${s.namespace}' is not a Kubernetes name`);
    if (fails === before) pass(`security: entity ${s.entity ?? '-'}, namespace ${s.namespace ?? '-'}`);
  }
  if (m.interfaces !== undefined) {
    const it = m.interfaces;
    const before = fails;
    if (!obj(it)) fail('interfaces: not an object');
    else {
      if (it.cli !== undefined && !str(it.cli)) fail('interfaces.cli: must be the published CLI\'s command');
      if (it.openapi !== undefined && !/^\/\S*$/.test(String(it.openapi))) fail('interfaces.openapi: must be a path under app.url (/…)');
      if (fails === before) pass(`interfaces: cli ${it.cli ?? '-'}, openapi ${it.openapi ?? '-'}`);
    }
  }

  // expected_requests: optional; a failed request the tested install answers ≥ 400 on purpose.
  if (m.expected_requests !== undefined) {
    const er = m.expected_requests;
    if (!Array.isArray(er)) fail('expected_requests: not a list');
    else {
      const before = fails;
      const METHODS = ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'];
      er.forEach((e, i) => {
        if (!obj(e)) { fail(`expected_requests[${i}]: not an object`); return; }
        if (!METHODS.includes(e.method)) fail(`expected_requests[${i}].method '${e.method ?? ''}': one of ${METHODS.join(', ')}`);
        if (!/^\/[^\s?#*]*$/.test(String(e.path ?? ''))) fail(`expected_requests[${i}].path '${e.path ?? ''}': a path pattern as the UI map records it (/api/x/:id), no query or wildcard`);
        if (!Number.isInteger(e.status) || e.status < 400 || e.status > 599) fail(`expected_requests[${i}].status '${e.status ?? ''}': an integer 400-599`);
        if (!str(e.why)) fail(`expected_requests[${i}].why: must say why the tested install answers it with an error`);
      });
      if (fails === before) pass(`expected_requests: ${er.map((e) => `${e.method} ${e.path} → ${e.status}`).join(', ') || 'none'}`);
    }
  }

  // environment: optional; the platform Environment the product may run in (docs/nested-env.md).
  if (m.environment !== undefined) {
    const en = m.environment;
    const before = fails;
    if (!obj(en) || !Array.isArray(en.endpoints) || !en.endpoints.length) fail('environment.endpoints: a non-empty list of {name, port}');
    else {
      const names = new Set();
      en.endpoints.forEach((e, i) => {
        if (!obj(e) || !/^[a-z0-9]{1,20}$/.test(String(e.name ?? ''))) fail(`environment.endpoints[${i}].name: lowercase letters and digits`);
        else if (names.has(e.name)) fail(`environment.endpoints[${i}].name '${e.name}': used twice`);
        else names.add(e.name);
        if (!obj(e) || !Number.isInteger(e.port) || e.port < 1 || e.port > 65535) fail(`environment.endpoints[${i}].port: a port number`);
      });
      if (!names.has('app')) fail("environment.endpoints: needs 'app', the address a person opens");
      if (en.storage !== undefined && !/^\d+Gi$/.test(String(en.storage))) fail(`environment.storage '${en.storage}': e.g. 40Gi`);
      if (en.account !== undefined && (!/^[a-z0-9_]+$/.test(String(en.account)) || (m.engine_config?.credentials?.users && !(en.account in m.engine_config.credentials.users)))) {
        fail(`environment.account '${en.account}': the role of the account a person signs in with (a credentials user)`);
      }
    }
    if (fails === before) pass(`environment: ${en.endpoints.map((e) => `${e.name}:${e.port}`).join(', ')}${en.storage ? `, ${en.storage}` : ''}`);
  }

  // config
  const config = m.config ?? {};
  if (!obj(config)) fail('config: not an object');
  else {
    let ok = true;
    for (const [k, d] of Object.entries(config)) {
      if (!/^[a-z][a-z0-9_]*$/.test(k)) { fail(`config.${k}: names are [a-z][a-z0-9_]* (placeholders and CONFIG.md match nothing else)`); ok = false; }
      if (!obj(d)) { fail(`config.${k}: not an object`); ok = false; continue; }
      if (typeof d.default !== 'string') { fail(`config.${k}: default must be a string ("" when empty)`); ok = false; }
      if (!str(d.about)) { fail(`config.${k}: about is the onboarding question — one sentence`); ok = false; }
      if (d.ask !== undefined && typeof d.ask !== 'boolean') { fail(`config.${k}: ask must be true or false`); ok = false; }
    }
    if (ok) pass(`config: ${Object.keys(config).length} key(s), asked: ${Object.keys(config).filter((k) => config[k].ask === true).join(' ') || '-'}`);
  }
  for (const k of Object.keys(sets)) if (!obj(config) || !(k in config)) fail(`--set ${k}: not a config key of this profile`);
}

// ------------------------------------------------------------------ SKILL.md ----
const skill = read(join(dir, 'SKILL.md'));
if (skill === null) fail('SKILL.md: missing — the tester\'s knowledge of the product');
else {
  const fm = skill.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!fm) fail('SKILL.md: no frontmatter (--- name, description ---)');
  else {
    const head = fm[1].split(/\r?\n/);
    const field = (k) => {
      const i = head.findIndex((l) => l.startsWith(`${k}:`));
      if (i < 0) return '';
      const v = head[i].slice(k.length + 1).trim();
      if (!/^[>|][-+]?$/.test(v)) return v.replace(/^["']|["']$/g, '');
      const out = [];
      for (const l of head.slice(i + 1)) { if (/^\S/.test(l)) break; out.push(l.trim()); }
      return out.join(' ').trim();
    };
    const sname = field('name');
    if (sname !== name) fail(`SKILL.md: name '${sname}' differs from the directory '${name}' — the platform installs the skill under its name`);
    else if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(sname)) fail(`SKILL.md: name '${sname}' is not lowercase-hyphenated`);
    else pass(`SKILL.md: name ${sname}`);
    if (!sname.startsWith('qi-profile-')) warn('SKILL.md: name does not start with qi-profile- (the convention)');
    const desc = field('description');
    if (!desc) fail('SKILL.md: no description');
    else if (!/quality-inspector/i.test(desc)) warn('SKILL.md: description does not say it is a quality-inspector profile — the harness loads skills by it');
    else pass('SKILL.md: description');
    const body = fm[2];
    const lines = body.split('\n').length;
    lines > 120 ? warn(`SKILL.md: ${lines} lines — it is read for every issue; aim for about 80`) : pass(`SKILL.md: ${lines} lines`);
    if (!/^#+ .*cannot/im.test(body)) warn('SKILL.md: no "cannot do" section — it is what makes criteria testable: no');
    // Black-box hints: things a user could not have written.
    const code = body.match(/(?:^|[\s`("'])((?:src|lib|pkg|internal|cmd|apps?|packages|server|backend|frontend|services)\/[\w./-]+|[\w./-]+\.(?:ts|tsx|jsx|mjs|py|go|rs|java|kt|rb|php|cs|sql|proto))(?=$|[\s`)"',.;:])/gm);
    // The profile's own suite/ helpers are named for the tester on purpose (profile-contract → sandbox).
    const paths = [...new Set((code ?? []).map((s) => s.trim().replace(/^[`("']/, '')))].filter((p) => !p.startsWith('suite/'));
    if (paths.length) warn(`SKILL.md: looks like source paths — ${paths.slice(0, 3).join(', ')} (user-facing knowledge only)`);
    const links = body.match(/https?:\/\/(?:www\.)?(?:github\.com|gitlab\.com|bitbucket\.org)\/[^\s)]*\/(?:blob|tree|commit|pull|merge_requests|-\/blob)\/[^\s)]*/g);
    if (links) warn(`SKILL.md: links into a code host — ${links.slice(0, 2).join(', ')}`);
  }
}
existsSync(join(dir, 'README.md')) ? pass('README.md present') : warn('README.md: missing — maintainers need delivery, channels, config and diagnosis');

// ---------------------------------------------------------------- scenarios/ ----
// The product team's scenarios (docs/profile-contract.md → `scenarios/`): the nightly
// regression run adopts each one; its text is the oracle, so it must be criteria a tester
// can freeze — a title, AC blocks with Given/When/Then — and nothing a user could not write.
// A <slug>.feature is Gherkin, read by the core's own parser (scripts/lib/gherkin.mjs).
const scenDir = join(dir, 'scenarios');
if (existsSync(scenDir) && statSync(scenDir).isDirectory()) {
  let n = 0;
  const gherkinLib = core && join(core, 'scripts/lib/gherkin.mjs');
  const gherkin = gherkinLib && existsSync(gherkinLib) ? await import(pathToFileURL(gherkinLib).href) : null;
  const files = readdirSync(scenDir).sort();
  for (const f of files) {
    const id = `scenarios/${f}`;
    if (!/^[a-z0-9][a-z0-9-]{0,47}\.(md|feature)$/.test(f)) { fail(`${id}: not <slug>.md or <slug>.feature ([a-z0-9-], at most 48) — the run skips it`); continue; }
    if (statSync(join(scenDir, f)).size > 65536) { fail(`${id}: over 64 KiB — the run skips it`); continue; }
    const t = read(join(scenDir, f)) ?? '';
    if (f.endsWith('.feature')) {
      if (files.includes(f.replace(/\.feature$/, '.md'))) { fail(`${id}: ${f.replace(/\.feature$/, '.md')} has the same slug — the run skips the .feature`); continue; }
      n++;
      if (!gherkin) { warn(`${id}: Gherkin not checked without the core`); continue; }
      const p = gherkin.parseFile(f, t);
      for (const e of p.errors) fail(`${id}: ${e}`);
      for (const w of p.warnings) warn(`${id}: ${w}`);
      if (!p.acs.length && !p.errors.length) fail(`${id}: no Scenario`);
      if (/https?:\/\//.test(t)) warn(`${id}: a URL — the agent freezes words a user could write, and never follows a link`);
      continue;
    }
    n++;
    if (!/^# \S/m.test(t)) fail(`${id}: no "# <title>" line`);
    const acs = [...t.matchAll(/^## (AC-(\d+)) — \S.*$/gm)];
    if (!acs.length) { fail(`${id}: no "## AC-<k> — <name>" block`); continue; }
    const nums = acs.map((m) => +m[2]);
    if (nums.some((k, i) => k !== i + 1)) fail(`${id}: AC blocks are not numbered AC-1, AC-2, … in order`);
    for (const [i, m] of acs.entries()) {
      const body = t.slice(m.index, acs[i + 1]?.index ?? t.length);
      for (const w of ['Given', 'When', 'Then']) if (!new RegExp(`^${w} \\S`, 'm').test(body)) fail(`${id} ${m[1]}: no "${w} …" line`);
    }
    if (/https?:\/\/|```/.test(t)) warn(`${id}: a URL or a code block — the agent freezes words a user could write, and never follows a link`);
    const req = t.match(/^requires: *(\S+)/m)?.[1];
    if (req && !['member', 'viewer', 'outsider'].includes(req.toLowerCase())) warn(`${id}: requires '${req}' is not a role of the convention (member, viewer, outsider)`);
  }
  n ? pass(`scenarios/: ${n} scenario(s)`) : warn('scenarios/: empty');
}

// -------------------------------------------- template leftovers and secrets ----
const SECRETS = [
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----/, 'a private key'],
  [/\bgh[pousr]_[A-Za-z0-9]{30,}/, 'a GitHub token'],
  [/\bgithub_pat_[A-Za-z0-9_]{30,}/, 'a GitHub token'],
  [/\bsk-ant-[A-Za-z0-9_-]{20,}/, 'an Anthropic key'],
  [/\bsk-[A-Za-z0-9]{32,}/, 'an API key'],
  [/\bAKIA[0-9A-Z]{16}\b/, 'an AWS key'],
  [/\bxox[abprs]-[A-Za-z0-9-]{10,}/, 'a Slack token'],
  [/"(?:password|passwd|secret|token|api_?key)"\s*:\s*"(?!\{\{)[^"]+"/i, 'a literal credential (generate it in bin/env init, or use a {{user:…}} / {{secret:…}} placeholder)'],
];
let leftovers = 0;
for (const f of files) {
  const t = read(f);
  if (t === null || t.includes('\0')) continue;
  const at = t.split('\n').flatMap((line, i) => (/<fill:|TODO\(profile\)/.test(line) ? [i + 1] : []));
  if (at.length) {
    leftovers += at.length;
    fail(`${rel(f)}: ${at.length} unresolved template marker(s) (<fill: …> / TODO(profile)) on line ${at.slice(0, 8).join(', ')}${at.length > 8 ? ', …' : ''}`);
  }
  for (const [re, what] of SECRETS) if (re.test(t)) fail(`${rel(f)}: looks like ${what}`);
}
if (!leftovers) pass('no template markers left');

// --------------------------------------------------------------------- suite/ ----
const suiteFiles = files.filter((f) => rel(f).startsWith(`suite${'/'}`));
for (const f of suiteFiles) {
  const p = rel(f).slice('suite/'.length);
  if (/\.e2e\.ts$/.test(p)) warn(`suite/${p}: tests belong to the agent's suite, not the profile`);
  if (core && existsSync(join(core, 'scripts/suite-skeleton', p))) warn(`suite/${p}: the core skeleton has this path — this copy is never used`);
}

// ---------------------------------------------------- the resolved config ----
const resolved = {};
if (m && obj(m.config)) for (const [k, d] of Object.entries(m.config)) resolved[k] = obj(d) && typeof d.default === 'string' ? d.default : '';
Object.assign(resolved, sets);
const childEnv = (work) => ({
  ...process.env,
  PATH,
  QI_WORK: work,
  QI_ENV_DIR: join(work, 'env'),
  QI_PROFILE_DIR: dir,
  QI_PROFILE_CONFIG: JSON.stringify(resolved),
  QI_ENGINE_CONFIG: JSON.stringify(m && obj(m.engine_config) ? m.engine_config : {}),
  QI_CANDIDATE_CHANNEL: candidate,
  QI_BASELINE_CHANNEL: baseline,
});

// -------------------------------------------------- the engine's own check ----
const engineCheck = m && core && str(m.engine) ? join(core, 'engines', m.engine, 'bin', 'check') : '';
if (engineCheck && isExec(engineCheck)) {
  const work = mkdtempSync(join(tmpdir(), 'quality-inspector-check-'));
  try {
    const r = spawnSync(engineCheck, [], { cwd: work, env: childEnv(work), encoding: 'utf8', timeout: 60000 });
    let said = 0;
    for (const line of (r.stdout || '').split('\n')) {
      const mm = line.match(/^(FAIL|WARN) (.*)$/);
      if (!mm) continue;
      said++;
      (mm[1] === 'FAIL' ? fail : warn)(`engine_config: ${mm[2]}`);
    }
    if (r.status === 0 && !said) pass(`engine_config: ${m.engine}'s check is clean`);
    else if (r.status !== 0 && !(r.stdout || '').includes('FAIL ')) fail(`engine_config: ${m.engine}'s check exited ${r.status} — ${(r.stderr || r.error?.message || 'no output').trim().split('\n').pop()}`);
  } finally { rmSync(work, { recursive: true, force: true }); }
} else if (engineCheck && existsSync(join(core, 'engines', m.engine))) {
  pass(`engine_config: ${m.engine} has no offline check`);
}

// ------------------------------------------- how the egress lands on the agent ----
// The core's scripts/egress-rules.sh lists each rule the way onboarding hands it to the
// operator (docs/black-box.md → Egress rules): prompt, by-hand, kit or refused.
const egressRules = m && core && Array.isArray(m.egress) && m.egress.length ? join(core, 'scripts', 'egress-rules.sh') : '';
if (egressRules && existsSync(egressRules)) {
  const work = mkdtempSync(join(tmpdir(), 'quality-inspector-check-'));
  try {
    const conf = [`- profile: ${name}`, ...Object.entries(resolved).filter(([, v]) => v !== '').map(([k, v]) => `- profile.${k}: ${v}`)];
    writeFileSync(join(work, 'CONFIG.md'), `${conf.join('\n')}\n`);
    const r = spawnSync('bash', [egressRules, '--json'], {
      cwd: work, env: { ...process.env, PATH, WORK_DIR: work, QI_PROFILE_DIR: dir, QI_TARGET_REPO: '' }, encoding: 'utf8', timeout: 60000,
    });
    let rows = null;
    try { rows = r.status === 0 ? JSON.parse(r.stdout).rules.filter((x) => x.source === 'profile') : null; } catch { rows = null; }
    if (!rows) warn(`egress: the core's egress-rules.sh did not classify it — ${(r.stderr || r.error?.message || 'no output').trim().split('\n').pop()}`);
    else {
      const n = { prompt: 0, 'by-hand': 0, kit: 0 };
      for (const x of rows) {
        const at = `${x.method} ${x.host} ${x.path}`;
        if (x.how === 'refused') {
          // Unclassified only while a key it names is empty; a value that is set but not a
          // plain name is refused at onboarding too.
          if ([...`${x.host}${x.path}`.matchAll(/\{profile\.([a-z0-9_]+)\}/g)].some((k) => (resolved[k[1]] ?? '') === '')) warn(`egress ${at}: its profile key has no value here — --set <key>=<value> to classify it`);
          else fail(`egress ${at}: refused — ${x.why}`);
        } else {
          n[x.how] = (n[x.how] ?? 0) + 1;
          if (x.how === 'kit') warn(`egress ${at}: the kit already allows it — drop it`);
        }
      }
      pass(`egress lands: ${n.prompt} by prompt, ${n['by-hand']} by hand (no prompt appears; the operator adds each in the agent's network settings), ${n.kit} by the kit`);
    }
  } finally { rmSync(work, { recursive: true, force: true }); }
}

// ---------------------------------------------------------------------- live ----
if (live && m) {
  const exe = (cmd) => {
    const own = join(dir, 'bin', cmd);
    if (existsSync(own)) return own;
    if (core && str(m.engine)) { const e = join(core, 'engines', m.engine, 'bin', cmd); if (existsSync(e)) return e; }
    return '';
  };
  const work = mkdtempSync(join(tmpdir(), 'quality-inspector-check-'));
  const run = (cmd, args, env = {}) => {
    const [bin, ...pre] = argvOf(exe(cmd));
    const r = spawnSync(bin, [...pre, ...args], { cwd: work, env: { ...childEnv(work), ...env }, encoding: 'utf8', timeout: 120000 });
    return { ok: r.status === 0, out: (r.stdout || '').trim(), err: (r.stderr || r.error?.message || '').trim().split('\n').pop() };
  };
  const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/;
  try {
    if (!exe('versions') || !exe('build-time')) fail('live: bin/versions or bin/build-time cannot be resolved');
    else {
      const t0 = Date.now();
      const v = run('versions', []);
      const secs = Math.round((Date.now() - t0) / 1000);
      if (secs > 30) warn(`live: bin/versions took ${secs}s — the pre-flight calls it inside a two-minute budget (references/custom-bin.md)`);
      let builds = null;
      try { builds = v.ok ? JSON.parse(v.out) : null; } catch { builds = null; }
      if (!v.ok) fail(`live: bin/versions failed — ${v.err || `exit without output`}`);
      else if (!obj(builds) || !str(builds.candidate) || !(builds.baseline === null || str(builds.baseline))) {
        fail(`live: bin/versions printed '${v.out.slice(0, 120)}', not {"candidate": "<build>", "baseline": "<build>"|null}`);
      } else {
        pass(`live: candidate ${builds.candidate}, baseline ${builds.baseline ?? 'none'}`);
        for (const b of [builds.candidate, builds.baseline].filter(Boolean)) {
          const t = run('build-time', [b]);
          t.ok && ISO.test(t.out) ? pass(`live: ${b} published ${t.out}`)
            : fail(`live: bin/build-time ${b} — ${t.ok ? `'${t.out.slice(0, 60)}' is not ISO-8601 UTC` : t.err || 'failed'}`);
        }
        const n = run('versions', [], { QI_BASELINE_CHANNEL: 'none' });
        let nb = null;
        try { nb = n.ok ? JSON.parse(n.out) : null; } catch { nb = null; }
        obj(nb) && nb.baseline === null && str(nb.candidate) ? pass('live: baseline none gives no baseline')
          : fail(`live: with baseline_channel none, bin/versions must print baseline null — got ${n.ok ? n.out.slice(0, 80) : n.err}`);
      }
    }
  } finally { rmSync(work, { recursive: true, force: true }); }
}

finish();
