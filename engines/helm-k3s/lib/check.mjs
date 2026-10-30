#!/usr/bin/env node
// check.mjs — offline validation of a profile's helm-k3s engine_config (README → Check).
//
// env: QI_ENGINE_CONFIG (the profile's engine_config), QI_PROFILE_CONFIG (its config,
// defaults resolved), QI_PROFILE_DIR (optional: app.url is compared with app_port).
// Prints "FAIL <problem>" / "WARN <note>" lines; exit 1 on any FAIL. No network: the
// placeholders are filled by render.mjs with throw-away credentials. An overlay's `when` is
// a profile config key, "@model" (on while the agent lends its model, QI_MODEL_KEY) or
// "@sandbox:<id>" (on while that sandbox account's credentials are filled).
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
let failed = false;
const fail = (m) => { failed = true; console.log(`FAIL ${m}`); };
const warn = (m) => console.log(`WARN ${m}`);
const obj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const str = (v) => typeof v === 'string' && v.length > 0;
const NAME = /^[a-z0-9_]+$/;
const K8S = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const KNOWN = ['chart', 'registry_api', 'release', 'namespace', 'app_port', 'traefik_port', 'apply_chart_crds',
  'channels', 'default_candidate', 'default_baseline', 'helm_version', 'credentials', 'prerequisites', 'values',
  'overlays', 'max_pages', 'prune_below_gi', 'kvm', 'host_dirs', 'environment_bridge'];

const json = (s, what) => { try { return JSON.parse(s || '{}'); } catch { fail(`${what} is not JSON`); return null; } };
const raw = json(process.env.QI_ENGINE_CONFIG, 'QI_ENGINE_CONFIG');
const pcfg = json(process.env.QI_PROFILE_CONFIG, 'QI_PROFILE_CONFIG');
if (!obj(raw) || !obj(pcfg)) { if (!failed) fail('engine_config is not an object'); process.exit(1); }

const render = (mode, input, env, args = []) => {
  const r = spawnSync(process.execPath, [join(here, 'render.mjs'), mode, ...args],
    { input: JSON.stringify(input), env: { ...process.env, ...env }, encoding: 'utf8' });
  return r.status === 0 ? { out: JSON.parse(r.stdout) } : { err: (r.stderr || r.error?.message || `exit ${r.status}`).trim().replace(/^render: /, '') };
};

for (const k of Object.keys(raw)) if (!KNOWN.includes(k)) warn(`unknown key '${k}' (README → Configuration)`);

// Placeholders: against the config defaults, then with every overlay switched on.
const overlays = raw.overlays ?? [];
if (!Array.isArray(overlays)) fail('overlays must be a list');
const ovl = Array.isArray(overlays) ? overlays : [];
const MODEL = '@model';
const ENVIRONMENT = '@environment';
const SANDBOX = /^@sandbox:([a-z][a-z0-9]{0,15})$/;
const special = (w) => w === MODEL || w === ENVIRONMENT || SANDBOX.test(w);
for (const o of ovl) {
  if (!obj(o) || !str(o.when)) { fail('every overlay needs `when` (a profile config key, "@model", "@environment" or "@sandbox:<id>") and `values`'); continue; }
  if (!special(o.when) && !(o.when in pcfg)) fail(`overlay when '${o.when}' is not a profile config key, "@model", "@environment" or "@sandbox:<id>"`);
  if (!obj(o.values)) fail(`overlay '${o.when}' has no values object`);
  if (o.tags !== undefined) { try { new RegExp(o.tags); if (!str(o.tags)) throw 0; } catch { fail(`overlay '${o.when}': tags '${o.tags}' is not a regex`); } }
}
// The defaults render lends no model; the "every overlay on" render lends a throw-away one.
const NO_MODEL = { QI_MODEL_KEY: '', QI_MODEL_KIND: '', QI_MODEL_BASE_URL: '', QI_GATEWAY_IP: '192.0.2.1' };
const LENT = { QI_MODEL_KEY: 'check:model', QI_MODEL_KIND: 'api-key', QI_MODEL_BASE_URL: '', QI_GATEWAY_IP: '192.0.2.1' };
// The every-overlay-on render runs as in a platform Environment, each endpoint the profile
// declares (profile.json → environment) at a throw-away address.
let envEps = [];
try { envEps = JSON.parse(readFileSync(join(process.env.QI_PROFILE_DIR ?? '', 'profile.json'), 'utf8')).environment?.endpoints ?? []; } catch { /* no profile.json here */ }
const IN_ENV = { QI_NESTED_TARGET: 'environment',
  QI_ENV_ENDPOINTS: JSON.stringify(Object.fromEntries((Array.isArray(envEps) ? envEps : []).map((e) => [e?.name, `https://${e?.name}-check.env.invalid`]))) };
// Throw-away sandbox credentials: one line per {{sandbox:<id>.<NAME>}} and per "@sandbox:<id>"
// overlay, in a credentials file of their own — so the defaults render has every sandbox off.
const sbVars = new Set([...JSON.stringify(raw).matchAll(/\{\{sandbox:([a-z][a-z0-9]*)\.([A-Z][A-Z0-9_]*)\}\}/g)]
  .map(([, id, n]) => `E2E_SANDBOX_${id.toUpperCase()}_${n}`));
for (const o of ovl) { const m = obj(o) && str(o.when) && o.when.match(SANDBOX); if (m) sbVars.add(`E2E_SANDBOX_${m[1].toUpperCase()}_CHECK`); }
const sbDir = mkdtempSync(join(tmpdir(), 'quality-inspector-check-'));
writeFileSync(join(sbDir, 'credentials.env'), [...sbVars].map((v) => `${v}=check`).join('\n') + '\n', { mode: 0o600 });
const base = render('config', raw, { QI_PROFILE_CONFIG: JSON.stringify(pcfg), QI_ENV_DIR: '', ...NO_MODEL });
if (base.err) fail(`placeholders: ${base.err}`);
const on = { ...pcfg };
for (const o of ovl) if (obj(o) && str(o.when) && !special(o.when) && !on[o.when]) on[o.when] = 'registry.invalid/check:on';
const all = ovl.length ? render('config', raw, { QI_PROFILE_CONFIG: JSON.stringify(on), QI_ENV_DIR: sbDir, ...LENT, ...IN_ENV }) : base;
rmSync(sbDir, { recursive: true, force: true });
if (all.err && !base.err) fail(`placeholders with every overlay on: ${all.err}`);
const cfg = base.out ?? raw;
const { values: _v, ...outside } = cfg;
const stray = JSON.stringify(outside).match(/\{\{[^}]*\}\}/g);
if (base.out && stray) fail(`placeholders outside values: ${[...new Set(stray)].join(', ')}`);

// The chart and where the UI answers.
if (!/^oci:\/\/[^/\s]+\/\S+$/.test(String(cfg.chart ?? ''))) fail(`chart '${cfg.chart ?? ''}' is not oci://<host>/<repository>`);
const api = cfg.registry_api ?? 'oci';
if (!['quay', 'oci'].includes(api)) fail(`registry_api '${api}' is not quay or oci`);
if (api === 'quay' && !String(cfg.chart ?? '').startsWith('oci://quay.io/')) fail('registry_api quay needs a chart on quay.io');
for (const k of ['release', 'namespace']) {
  if (cfg[k] !== undefined && !K8S.test(String(cfg[k]))) fail(`${k} '${cfg[k]}' is not a Kubernetes name`);
}
const port = Number(cfg.app_port);
if (!Number.isInteger(port) || port < 1 || port > 65535) fail(`app_port '${cfg.app_port ?? ''}' is not a port number`);
for (const k of ['traefik_port', 'apply_chart_crds', 'kvm']) {
  if (cfg[k] !== undefined && typeof cfg[k] !== 'boolean') fail(`${k} must be true or false`);
}
if (process.env.QI_PROFILE_DIR && Number.isInteger(port)) {
  try {
    const url = new URL(JSON.parse(readFileSync(join(process.env.QI_PROFILE_DIR, 'profile.json'), 'utf8')).app.url);
    const up = Number(url.port || 80);
    if (up !== port) fail(`app.url answers on port ${up}, app_port is ${port}`);
  } catch { /* no readable app.url: the profile checker reports it */ }
}
if (cfg.helm_version !== undefined && !/^v\d+\.\d+\.\d+$/.test(String(cfg.helm_version))) {
  fail(`helm_version '${cfg.helm_version}' is not v<major>.<minor>.<patch>`);
}
if (cfg.prune_below_gi !== undefined && !(Number.isInteger(cfg.prune_below_gi) && cfg.prune_below_gi >= 0)) {
  fail(`prune_below_gi '${cfg.prune_below_gi}' is not a whole number of Gi (0 or more)`);
}
// host_dirs: a directory the engine bind-mounts over (README → KVM), never one the system or
// the engine itself owns — k3s' data, the kubelet's root, the home the sources live in.
const SYSTEM = ['/var', '/var/lib'];
const OWNED = ['/etc', '/usr', '/bin', '/sbin', '/lib', '/lib64', '/boot', '/dev', '/proc', '/sys', '/run', '/tmp',
  '/home', '/root', '/var/run', '/var/lib/rancher', '/var/lib/kubelet', '/var/lib/cni'];
const hd = cfg.host_dirs ?? [];
if (!Array.isArray(hd)) fail('host_dirs must be a list of absolute paths');
else {
  const seenDirs = new Set();
  for (const d of hd) {
    const n = str(d) ? d.replace(/\/+/g, '/').replace(/(.)\/$/, '$1') : '';
    if (!str(d) || !d.startsWith('/') || d.split('/').includes('..') || d.split('/').includes('.') || /\s/.test(d)) fail(`host_dirs entry '${d}' is not an absolute path`);
    else if (n === '/' || SYSTEM.includes(n) || OWNED.some((o) => n === o || n.startsWith(`${o}/`))) fail(`host_dirs entry '${d}' is or lies under a directory the system or the engine owns`);
    else if (seenDirs.has(n)) fail(`host_dirs entry '${d}' is listed twice`);
    else seenDirs.add(n);
  }
}

// The host-name bridge of an install in a platform Environment: every endpoint the profile
// declares answers on its port (README → Environment).
const eb = cfg.environment_bridge;
if (eb !== undefined) {
  const ebPort = obj(eb) ? Number(eb.port) : NaN;
  if (!obj(eb) || !str(eb.image) || !Number.isInteger(ebPort) || ebPort < 1 || ebPort > 65535) fail('environment_bridge needs an image and a port');
  else if (ebPort === Number(cfg.app_port)) fail('environment_bridge.port must differ from app_port (the ingress listens there)');
  else if (!envEps.length) warn('environment_bridge without an `environment` in profile.json — the product never runs in an Environment');
  else for (const e of envEps) if (Number(e?.port) !== ebPort) fail(`environment endpoint '${e?.name}' is on port ${e?.port}, the bridge on ${ebPort}`);
}

// Channels and their defaults.
const ch = cfg.channels;
if (!obj(ch) || !Object.keys(ch).length) fail('channels: none defined');
for (const [n, d] of Object.entries(obj(ch) ? ch : {})) {
  if (n === 'none') fail('a channel may not be called none (it means no baseline)');
  if (!obj(d) || !str(d.tag)) { fail(`channel '${n}' has no tag regex`); continue; }
  try { new RegExp(d.tag); } catch { fail(`channel '${n}': tag '${d.tag}' is not a regex`); }
  if (!d.tag.startsWith('^') || !d.tag.endsWith('$')) warn(`channel '${n}': tag regex is not anchored (^…$) — it may also match latest, -rc or signature tags`);
  if (!['semver', 'numeric-suffix', 'time'].includes(d.order)) fail(`channel '${n}': order '${d.order ?? ''}' is not semver, numeric-suffix or time`);
  if (d.order === 'time' && api !== 'quay') fail(`channel '${n}': order time needs registry_api quay`);
}
if (!str(cfg.default_candidate)) fail('default_candidate: missing — an instance with an empty candidate_channel would have no candidate');
else if (obj(ch) && !(cfg.default_candidate in ch)) fail(`default_candidate '${cfg.default_candidate}' is not a channel`);
const db = cfg.default_baseline ?? 'none';
if (db === 'none') warn('default_baseline is none — red-green is off unless an instance sets baseline_channel');
else if (obj(ch) && !(db in ch)) fail(`default_baseline '${db}' is not a channel or none`);

// The accounts and secrets bin/env init generates.
const cr = obj(cfg.credentials) ? cfg.credentials : {};
const users = obj(cr.users) ? cr.users : {};
if (!obj(users.owner)) fail('credentials.users.owner: missing — the suite signs in as owner (E2E_USER_OWNER_*)');
for (const [u, d] of Object.entries(users)) {
  if (!NAME.test(u)) fail(`credentials user '${u}' is not [a-z0-9_]`);
  if (!obj(d) || !str(d.username)) fail(`credentials user '${u}' has no username`);
}
const secrets = cr.secrets ?? [];
if (!Array.isArray(secrets) || secrets.some((s) => !NAME.test(String(s)))) fail('credentials.secrets must be a list of [a-z0-9_] names');

// Prerequisites.
const NEED = { manifest: [], helm: ['repo', 'chart', 'version', 'namespace'], 'adopt-crds': ['crds', 'release', 'namespace'] };
const pre = cfg.prerequisites ?? [];
if (!Array.isArray(pre)) fail('prerequisites must be a list');
const seen = new Set();
for (const [i, p] of (Array.isArray(pre) ? pre : []).entries()) {
  const id = `prerequisite ${i + 1}${obj(p) && str(p.name) ? ` (${p.name})` : ''}`;
  if (!obj(p) || !(p.kind in NEED)) { fail(`${id}: kind '${obj(p) ? p.kind ?? '' : ''}' is not manifest, helm or adopt-crds`); continue; }
  if (!str(p.name)) fail(`${id}: no name`);
  else if (seen.has(p.name)) fail(`${id}: name used twice`);
  else seen.add(p.name);
  for (const f of NEED[p.kind]) if (p[f] === undefined || p[f] === '') fail(`${id}: ${p.kind} needs ${f}`);
  if (p.kind === 'manifest') {
    if ((p.url !== undefined) === (p.file !== undefined)) fail(`${id}: manifest needs exactly one of url and file`);
    else if (p.file !== undefined && !str(p.file)) fail(`${id}: file must be a non-empty string`);
    else if (p.url !== undefined && !str(p.url)) fail(`${id}: url must be a non-empty string`);
    else if (str(p.file)) {
      if (isAbsolute(p.file) || p.file.split('/').includes('..')) fail(`${id}: file must be a path inside the profile directory`);
      else if (process.env.QI_PROFILE_DIR && !existsSync(join(process.env.QI_PROFILE_DIR, p.file))) fail(`${id}: file ${p.file} is not in the profile`);
    }
  }
  if (p.kind === 'adopt-crds' && !Array.isArray(p.crds)) fail(`${id}: crds must be a list`);
  if (p.wait !== undefined && (!obj(p.wait) || !str(p.wait.namespace))) fail(`${id}: wait needs a namespace`);
}

// The Helm values, filled with throw-away credentials.
if (!obj(raw.values)) fail('values: missing — the Helm values of the QA install');
else if (!JSON.stringify(raw.values).includes('{{user:owner.')) {
  warn('values never use {{user:owner.username}} / {{user:owner.password}} — how does a fresh install get the owner account?');
}
const tmp = mkdtempSync(join(tmpdir(), 'quality-inspector-check-'));
try {
  const cred = join(tmp, 'credentials.env');
  writeFileSync(cred, [
    ...Object.keys(users).flatMap((u) => [`E2E_USER_${u.toUpperCase()}_USERNAME=check-${u}`, `E2E_USER_${u.toUpperCase()}_PASSWORD=check`]),
    ...(Array.isArray(secrets) ? secrets : []).map((s) => `QI_SECRET_${String(s).toUpperCase()}=check`),
    ...[...sbVars].map((v) => `${v}=check`),
  ].join('\n') + '\n', { mode: 0o600 });
  const runs = ovl.length ? [['', base.out, NO_MODEL], [' with every overlay on', all.out, { ...LENT, ...IN_ENV }]] : [['', base.out, NO_MODEL]];
  for (const [label, c, model] of runs) {
    if (!c || !obj(c.values)) continue;
    const v = render('values', c, model, [cred]);
    if (v.err) { fail(`values${label}: ${v.err}`); continue; }
    const left = JSON.stringify(v.out).match(/\{\{[^}]*\}\}/g);
    if (left) fail(`values${label}: unknown placeholder ${[...new Set(left)].join(', ')}`);
  }
} finally {
  rmSync(tmp, { recursive: true, force: true });
}

process.exit(failed ? 1 : 0);
