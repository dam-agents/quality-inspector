#!/usr/bin/env node
// iface-snapshot.mjs — the nested product's published interfaces for one build: its CLI's
// `--help`, recursively over the subcommands it lists, and the API description it serves.
// Black-box: the CLI is only run (never its files read), and the API description is one
// HTTP GET to the nested product. Which CLI and which path come from the profile's
// `interfaces` (docs/profile-contract.md). Two snapshots diff with iface-diff.mjs.
// Rationale: docs/change-awareness.md.
//
//   node iface-snapshot.mjs <build> <out-dir>   -> <out-dir>/iface.json, a summary on stdout
//
// The profile names no interfaces -> {"skipped": …} on stdout, nothing written, exit 0.
// The CLI runs with an empty HOME, no credentials, no stdin and a timeout, so a subcommand
// that ignores --help has nothing to act with.

import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const [build, outDir] = process.argv.slice(2);
if (!build || !outDir) { console.error('usage: iface-snapshot.mjs <build> <out-dir>'); process.exit(2); }
const scripts = dirname(fileURLToPath(import.meta.url));
const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');

// The profile is found by the one shell resolver (scripts/lib/profile.sh), never re-implemented.
const found = spawnSync('bash', ['-c', 'CONFIG="$1/CONFIG.md"; . "$2/lib/config.sh" && . "$2/lib/profile.sh" && profile_dir', '_', work, scripts], { encoding: 'utf8' });
const pdir = found.status === 0 ? found.stdout.trim() : '';
if (!pdir) { console.error('iface-snapshot: profile not installed (config key profile)'); process.exit(1); }
const manifest = JSON.parse(readFileSync(join(pdir, 'profile.json'), 'utf8'));
const { cli, openapi } = manifest.interfaces ?? {};
if (!cli && !openapi) { console.log(JSON.stringify({ skipped: 'the profile names no interfaces' })); process.exit(0); }

const MAX_DEPTH = 3;
const MAX_COMMANDS = 300;
const stripAnsi = (s) => s.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '');

// One --help text -> the subcommands it lists and the flags it documents.
function parseHelp(text, prefix) {
  const commands = new Set();
  const flags = new Set();
  let section = null;
  for (const raw of stripAnsi(text).split('\n')) {
    const line = raw.replace(/\s+$/, '');
    if (!line.trim()) continue;
    const head = /^\s{0,2}([A-Za-z][A-Za-z ]*):$/.exec(line);
    if (head) {
      const h = head[1].toLowerCase();
      section = /command/.test(h) ? 'commands' : /(option|flag)/.test(h) ? 'flags' : 'other';
      continue;
    }
    if (!/^\s/.test(line)) { section = /^\S[^:]*:\s/.test(line) ? 'other' : section; continue; }
    const first = line.trim().split(/\s{2,}|\t/)[0];
    if (first.startsWith('-')) {
      for (const t of first.split(/[\s,=]+/)) {
        const m = /^(-{1,2}[A-Za-z0-9][\w-]*)/.exec(t.replace(/^\[|\]$/g, ''));
        if (m) flags.add(m[1]);
      }
      continue;
    }
    if (section !== 'commands') continue;
    const words = first.split(/\s+/);
    let i = 0;
    while (i < prefix.length && words[i] === prefix[i]) i++; // yargs repeats the full path
    const name = (words[i] ?? '').split('|')[0].replace(/,$/, '');
    if (/^[A-Za-z][\w:-]*$/.test(name) && name !== 'help') commands.add(name);
  }
  return { commands: [...commands], flags: [...flags].sort() };
}

function snapshotCli(command) {
  const argv = command.trim().split(/\s+/);
  const program = argv.at(-1);
  const home = mkdtempSync('/tmp/quality-inspector-iface-');
  const env = {
    PATH: `${join(work, 'suite', 'node_modules', '.bin')}:${process.env.PATH ?? ''}`,
    HOME: home, NO_COLOR: '1', TERM: 'dumb', CI: '1',
  };
  const help = (path) => {
    const r = spawnSync(argv[0], [...argv.slice(1), ...path, '--help'], { encoding: 'utf8', env, timeout: 15000, stdio: ['ignore', 'pipe', 'pipe'] });
    if (r.error) return { error: r.error.code === 'ENOENT' ? `${argv[0]} not found` : String(r.error.message) };
    const text = `${r.stdout ?? ''}\n${r.stderr ?? ''}`;
    return text.trim() ? { text } : { error: `no help output (exit ${r.status})` };
  };
  try {
    const root = help([]);
    if (root.error) return { command, program, error: root.error };
    const commands = {};
    const queue = [{ path: [], text: root.text, parent: null }];
    while (queue.length && Object.keys(commands).length < MAX_COMMANDS) {
      const { path, text, parent } = queue.shift();
      const parsed = parseHelp(text, [program, ...path]);
      commands[path.join(' ')] = parsed.flags;
      // A CLI that prints its parent's help for an unknown subcommand ends the descent there.
      if (path.length >= MAX_DEPTH || text === parent) continue;
      for (const c of parsed.commands) {
        const sub = [...path, c];
        if (commands[sub.join(' ')]) continue;
        const h = help(sub);
        if (h.error) commands[sub.join(' ')] = [];
        else queue.push({ path: sub, text: h.text, parent: text });
      }
    }
    return { command, program, commands };
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

// An OpenAPI / Swagger document -> {"METHOD /path": [response field paths]} for 2xx JSON responses.
function apiShape(spec) {
  const deref = (s) => {
    if (!s?.$ref?.startsWith('#/')) return s;
    return s.$ref.slice(2).split('/').reduce((x, p) => x?.[p.replace(/~1/g, '/').replace(/~0/g, '~')], spec);
  };
  const walk = (schema0, prefix, depth, out, seen) => {
    if (!schema0 || depth > 3) return;
    const ref = schema0.$ref;
    if (ref && seen.has(ref)) return;
    const next = ref ? new Set([...seen, ref]) : seen;
    const schema = deref(schema0);
    if (!schema) return;
    for (const k of ['allOf', 'oneOf', 'anyOf']) for (const s of schema[k] ?? []) walk(s, prefix, depth, out, next);
    if (schema.items) walk(schema.items, `${prefix}[]`, depth + 1, out, next);
    for (const [k, v] of Object.entries(schema.properties ?? {})) {
      const name = prefix ? `${prefix}.${k}` : k;
      out.add(name);
      walk(v, name, depth + 1, out, next);
    }
  };
  const endpoints = {};
  for (const [path, item] of Object.entries(spec.paths ?? {})) {
    for (const m of ['get', 'put', 'post', 'delete', 'patch']) {
      const op = item?.[m];
      if (!op) continue;
      const out = new Set();
      for (const [code, r0] of Object.entries(op.responses ?? {})) {
        if (!/^2/.test(code)) continue;
        const r = deref(r0);
        const content = r?.content ?? {};
        walk(content['application/json']?.schema ?? Object.values(content)[0]?.schema ?? r?.schema, '', 0, out, new Set());
      }
      endpoints[`${m.toUpperCase()} ${path}`] = [...out].sort();
    }
  }
  return endpoints;
}

async function snapshotApi(path) {
  const base = new URL(manifest.app?.url ?? 'http://localhost');
  const url = new URL(path, base);
  if (!['localhost', '127.0.0.1'].includes(base.hostname) || url.origin !== base.origin) {
    return { path, error: `refusing ${url}: only the nested product at ${base.origin}` };
  }
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(20000), headers: { accept: 'application/json' } });
    if (!res.ok) return { path, error: `HTTP ${res.status}` };
    return { path, endpoints: apiShape(JSON.parse(await res.text())) };
  } catch (e) {
    return { path, error: e instanceof SyntaxError ? 'not JSON' : String(e.message ?? e) };
  }
}

const snap = {
  build,
  generated_utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
  cli: cli ? snapshotCli(cli) : null,
  api: openapi ? await snapshotApi(openapi) : null,
};
mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, 'iface.json'), `${JSON.stringify(snap, null, 2)}\n`);
console.log(JSON.stringify({
  out: join(outDir, 'iface.json'),
  commands: snap.cli?.commands ? Object.keys(snap.cli.commands).length : 0,
  endpoints: snap.api?.endpoints ? Object.keys(snap.api.endpoints).length : 0,
  errors: [snap.cli?.error && `cli: ${snap.cli.error}`, snap.api?.error && `api: ${snap.api.error}`].filter(Boolean),
}));
