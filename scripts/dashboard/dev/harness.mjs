#!/usr/bin/env node
// Development only: serves the dashboard page with a stand-in for the platform bridge, so the page
// can be opened in a local browser against a local dashboard server (docs/catalog.md → The server).
//   WORK_DIR=/tmp/w node scripts/catalog.mjs              (builds work/catalog/data.json)
//   WORK_DIR=/tmp/w node scripts/dashboard/dev/harness.mjs 5600 5599
//   open "http://localhost:5600/"                          (the operator, on the page live.html is: scripts/dashboard/page.html)
//   open "http://localhost:5600/?as=pat@example.com&role=viewer"
//   open "http://localhost:5600/?static=1"                 (the static page, index.html, as published without the server)
//   open "http://localhost:5600/?page=old"                 (the old page, scripts/catalog/viewer.html, as index.html shows it)
// The harness starts the server itself on the second port (QI_DASHBOARD_PORT), unless one answers
// there already. The stand-in sets the caller headers the platform's relay would set; sendPrompt only
// logs. It is never part of a deployment. The page is read again on every load.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const [port = '5600', apiPort = '5599'] = process.argv.slice(2);
const HERE = dirname(fileURLToPath(import.meta.url));
const viewer = join(HERE, '..', '..', 'catalog', 'viewer.html');
const page = join(HERE, '..', 'page.html');
const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');

const up = await fetch(`http://127.0.0.1:${apiPort}/health`).then((r) => r.ok, () => false);
// Its own process, as the Login item starts it: modules.sh writes the operator's settings only for a
// child of scripts/dashboard/server.mjs (docs/modules.md → Control).
if (!up) {
  const child = spawn(process.execPath, [join(HERE, '..', 'server.mjs')], { env: { ...process.env, QI_DASHBOARD_PORT: apiPort, WORK_DIR: work }, stdio: ['ignore', 'inherit', 'inherit'] });
  process.on('exit', () => child.kill());
  for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { child.kill(); process.exit(0); });
  for (let k = 0; k < 50 && !(await fetch(`http://127.0.0.1:${apiPort}/health`).then((r) => r.ok, () => false)); k++) await new Promise((ok) => setTimeout(ok, 100));
}

const shim = `<script>
window.platform = (() => {
  const q = new URLSearchParams(location.search);
  const as = q.get("as") || "owner@example.com", role = q.get("role") || "owner";
  return Object.freeze({
    sendPrompt(p, o) { console.log("[sendPrompt]", p, o || ""); },
    async request({ method, path, body, contentType }) {
      const r = await fetch("/relay" + path, { method, body, headers: { "content-type": contentType || "text/plain", "x-as": as, "x-role": role } });
      return { status: r.status, contentType: r.headers.get("content-type"), body: await r.text() };
    },
    async whoami() { return { role, email: as, sub: "dev-" + as }; },
  });
})();
</script>`;

createServer(async (req, res) => {
  if (req.url.startsWith('/relay/')) {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const as = String(req.headers['x-as'] || ''); const role = String(req.headers['x-role'] || 'viewer');
    let r;
    try {
      r = await fetch(`http://127.0.0.1:${apiPort}${req.url.slice('/relay'.length)}`, {
        method: req.method, body: chunks.length ? Buffer.concat(chunks) : undefined,
        headers: { 'content-type': 'application/json', 'x-platform-caller-role': role, 'x-platform-caller-email': as, 'x-platform-caller-sub': `dev-${as}` },
      });
    } catch (e) {
      res.writeHead(502, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ error: `The dashboard server on port ${apiPort} does not answer (${e.cause?.code || e.message}).` }));
    }
    res.writeHead(r.status, { 'content-type': r.headers.get('content-type') || 'application/json' });
    return res.end(Buffer.from(await r.arrayBuffer()));
  }
  const url = new URL(req.url, 'http://x');
  let html;
  if (url.searchParams.get('static') === '1') {
    try { html = readFileSync(join(work, 'catalog', 'index.html'), 'utf8'); } catch { html = '<p>No work/catalog/index.html: run scripts/catalog.mjs first.</p>'; }
  } else if (url.searchParams.get('page') === 'old') {
    html = readFileSync(viewer, 'utf8').replace('__QI_CATALOG_DATA__', 'null').replace('<head>', `<head>${shim}`);
  } else {
    html = readFileSync(page, 'utf8').replace('<head>', `<head>${shim}`);
  }
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(html);
}).listen(Number(port), '127.0.0.1', () => console.error(`harness on http://localhost:${port} → dashboard server 127.0.0.1:${apiPort}`));
