#!/usr/bin/env node
// render.mjs — fill the helm-k3s engine's placeholders (README → Placeholders).
//
//   render.mjs config                  stdin: the profile's engine_config; env QI_PROFILE_CONFIG.
//                                      Resolves {{config:k}}, {{config_repo:k}}, {{config_tag:k}},
//                                      folds every overlay whose `when` key is set into `values`.
//   render.mjs values <credentials>    stdin: the resolved config. Prints the Helm values (JSON)
//                                      with {{user:NAME.username|password}}, {{secret:name}} and
//                                      {{app_port}} filled from the credentials file.
import { readFileSync } from 'node:fs';

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
  for (const o of overlays) {
    if (!o.when) fail('an overlay needs `when`');
    if (String(cfg[o.when] ?? '') !== '') out = { ...out, values: merge(out.values ?? {}, walk(o.values ?? {}, fill)) };
  }
  console.log(JSON.stringify(out));
} else if (mode === 'values') {
  const env = Object.fromEntries(readFileSync(process.argv[3], 'utf8').split('\n')
    .map((l) => l.match(/^([A-Z0-9_]+)=(.*)$/)).filter(Boolean).map((m) => [m[1], m[2]]));
  const get = (k) => { if (!(k in env)) fail(`credentials have no ${k}`); return env[k]; };
  const fill = (s) => s
    .replace(/\{\{user:([A-Za-z0-9_]+)\.(username|password)\}\}/g, (_, u, f) => get(`E2E_USER_${u.toUpperCase()}_${f.toUpperCase()}`))
    .replace(/\{\{secret:([a-z0-9_]+)\}\}/g, (_, k) => get(`QI_SECRET_${k.toUpperCase()}`))
    .replace(/\{\{app_port\}\}/g, String(input.app_port ?? ''));
  console.log(JSON.stringify(walk(input.values ?? {}, fill)));
} else {
  fail('usage: render.mjs config | values <credentials.env>');
}
