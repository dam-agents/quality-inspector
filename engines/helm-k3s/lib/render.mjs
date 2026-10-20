#!/usr/bin/env node
// render.mjs — fill the helm-k3s engine's placeholders (README → Placeholders).
//
//   render.mjs config                  stdin: the profile's engine_config; env QI_PROFILE_CONFIG.
//                                      Resolves {{config:k}}, {{config_repo:k}}, {{config_tag:k}},
//                                      folds every overlay whose `when` key is set into `values`.
//   render.mjs values <credentials>    stdin: the resolved config. Prints the Helm values (JSON)
//                                      with {{user:NAME.username|password}}, {{secret:name}} and
//                                      {{app_port}} filled from the credentials file, and
//                                      {{model:key|kind|base_url}}, {{proxy:https|http|no}},
//                                      {{gateway_ca}}, {{gateway_ip}} from the environment.
// An overlay whose `when` is "@model" applies while the agent lends its model (QI_MODEL_KEY);
// "@sandbox:<id>" while that sandbox account's lines in $QI_ENV_DIR/credentials.env are all
// filled (docs/profile-contract.md → `sandbox`), and its {{sandbox:<id>.<NAME>}} fill values.
import { existsSync, readFileSync } from 'node:fs';

const input = JSON.parse(readFileSync(0, 'utf8'));
const mode = process.argv[2];
const walk = (v, f) => (Array.isArray(v) ? v.map((x) => walk(x, f)) : v && typeof v === 'object'
  ? Object.fromEntries(Object.entries(v).map(([k, x]) => [k, walk(x, f)])) : typeof v === 'string' ? f(v) : v);
const merge = (a, b) => {
  if (!b || typeof b !== 'object' || Array.isArray(b)) return b;
  const out = { ...(a && typeof a === 'object' && !Array.isArray(a) ? a : {}) };
  for (const [k, v] of Object.entries(b)) out[k] = merge(out[k], v);
  return out;
};
const fail = (m) => { console.error(`render: ${m}`); process.exit(1); };
// A credentials file as {NAME: value}: `export` and one layer of quotes allowed.
const readEnv = (f) => Object.fromEntries(readFileSync(f, 'utf8').split('\n')
  .map((l) => l.replace(/^export\s+/, '').match(/^([A-Z0-9_]+)=(.*)$/)).filter(Boolean)
  .map((m) => [m[1], m[2].trim().replace(/^(["'])(.*)\1$/, '$2')]));
const sandboxVar = (id, name) => `E2E_SANDBOX_${id.toUpperCase()}_${name}`;

if (mode === 'config') {
  const cfg = JSON.parse(process.env.QI_PROFILE_CONFIG || '{}');
  const ref = (k) => { if (!(k in cfg)) fail(`unknown config key '${k}' in a placeholder`); return String(cfg[k] ?? ''); };
  // An image ref's repository and tag: the tag is what follows the last ':' after the last '/'.
  const split = (r) => { const i = r.lastIndexOf(':'); return i > r.lastIndexOf('/') ? [r.slice(0, i), r.slice(i + 1)] : [r, 'latest']; };
  const fill = (s) => s
    .replace(/\{\{config:([a-z0-9_]+)\}\}/g, (_, k) => ref(k))
    .replace(/\{\{config_repo:([a-z0-9_]+)\}\}/g, (_, k) => split(ref(k))[0])
    .replace(/\{\{config_tag:([a-z0-9_]+)\}\}/g, (_, k) => split(ref(k))[1]);
  const { overlays = [], ...rest } = input;
  let out = walk(rest, fill);
  const credFile = process.env.QI_ENV_DIR ? `${process.env.QI_ENV_DIR}/credentials.env` : '';
  const cred = credFile && existsSync(credFile) ? readEnv(credFile) : {};
  const sandboxOn = (id) => {
    const vals = Object.entries(cred).filter(([k]) => k.startsWith(sandboxVar(id, ''))).map(([, v]) => v);
    return vals.length > 0 && vals.every((v) => v !== '');
  };
  const on = (w) => (w === '@model' ? !!process.env.QI_MODEL_KEY
    : w.startsWith('@sandbox:') ? sandboxOn(w.slice(9)) : String(cfg[w] ?? '') !== '');
  for (const o of overlays) {
    if (!o.when) fail('an overlay needs `when`');
    if (on(o.when)) out = { ...out, values: merge(out.values ?? {}, walk(o.values ?? {}, fill)) };
  }
  console.log(JSON.stringify(out));
} else if (mode === 'values') {
  const env = readEnv(process.argv[3]);
  const get = (k) => { if (!(k in env)) fail(`credentials have no ${k}`); return env[k]; };
  const e = process.env;
  // Pods reach the outside only through the gateway; cluster-internal traffic never does.
  const proxy = { https: e.HTTPS_PROXY ?? e.https_proxy ?? '', http: e.HTTP_PROXY ?? e.http_proxy ?? '',
    no: [e.NO_PROXY ?? e.no_proxy, 'localhost,127.0.0.1,::1,10.42.0.0/16,10.43.0.0/16,.svc,.cluster.local'].filter(Boolean).join(',') };
  // The CA the gateway presents, as PEM — the file the VM's own Node or OpenSSL trust names.
  const ca = () => { for (const f of [e.NODE_EXTRA_CA_CERTS, e.SSL_CERT_FILE]) { try { if (f) return readFileSync(f, 'utf8'); } catch {} } return ''; };
  const fill = (s) => s
    .replace(/\{\{user:([A-Za-z0-9_]+)\.(username|password)\}\}/g, (_, u, f) => get(`E2E_USER_${u.toUpperCase()}_${f.toUpperCase()}`))
    .replace(/\{\{secret:([a-z0-9_]+)\}\}/g, (_, k) => get(`QI_SECRET_${k.toUpperCase()}`))
    .replace(/\{\{sandbox:([a-z][a-z0-9]*)\.([A-Z][A-Z0-9_]*)\}\}/g, (_, id, n) => get(sandboxVar(id, n)))
    .replace(/\{\{app_port\}\}/g, String(input.app_port ?? ''))
    .replace(/\{\{model:(key|kind|base_url)\}\}/g, (_, k) => e[`QI_MODEL_${k.toUpperCase()}`] ?? '')
    .replace(/\{\{proxy:(https|http|no)\}\}/g, (_, k) => proxy[k])
    .replace(/\{\{gateway_ca\}\}/g, () => ca())
    .replace(/\{\{gateway_ip\}\}/g, () => /^\d{1,3}(\.\d{1,3}){3}$/.test(e.QI_GATEWAY_IP ?? '') ? e.QI_GATEWAY_IP
      : fail("{{gateway_ip}}: the VM's gateway address did not resolve (getent ahostsv4 github.com)"));
  console.log(JSON.stringify(walk(input.values ?? {}, fill)));
} else {
  fail('usage: render.mjs config | values <credentials.env>');
}
