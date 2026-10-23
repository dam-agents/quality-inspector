#!/usr/bin/env node
// evidence-sheet.mjs — one picture of a report's proof for a channel answer: the screenshots
// render-report.mjs chose in <report-dir>/proof.json (per criterion its AC still, or the screen
// at failure, on each side that decides its verdict), captioned, drawn by the suite's own
// playwright-core into <report-dir>/evidence.png. A channel message carries one file, so the
// proof is one image (docs/slack.md → The answer in the thread). Reads only <report-dir>/proof.json
// and the files of its media/; the page it draws reaches no network.
//
//   node evidence-sheet.mjs <report-dir>
//     -> {"sheet": "<report-dir>/evidence.png" | null, "rows", "left_out", "bytes", "reason"}
//
// `sheet: null` (exit 0) is an answer, not an error: no criterion has a screenshot that shows its
// verdict (a CLI or API check, nothing judged), or no browser — the reply then goes without a
// picture. Exit 1: no proof.json (render the report first); exit 2: usage.

import { createRequire } from 'node:module';
import { existsSync, readFileSync, renameSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const [dir] = process.argv.slice(2);
if (!dir) {
  console.error('usage: evidence-sheet.mjs <report-dir>');
  process.exit(2);
}
const work = process.env.WORK_DIR ?? join(process.env.HOME ?? '/home/agent', 'work');
const out = join(dir, 'evidence.png');
const done = (o, code = 0) => { console.log(JSON.stringify(o)); process.exit(code); };
let proof;
try { proof = JSON.parse(readFileSync(join(dir, 'proof.json'), 'utf8')); } catch {
  done({ sheet: null, rows: 0, left_out: 0, bytes: 0, reason: 'no proof.json — render the report first (scripts/render-report.mjs)' }, 1);
}
rmSync(out, { force: true });

const MIME = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp' };
// Only a file of the report's own media/, named as render-report.mjs names it.
const image = (src) => {
  const m = /^media\/[A-Za-z0-9._-]+\.(png|jpe?g|webp)$/i.exec(String(src ?? ''));
  const p = m && !String(src).includes('..') ? join(dir, src) : null;
  return p && existsSync(p) ? `data:${MIME[m[1].toLowerCase()]};base64,${readFileSync(p).toString('base64')}` : null;
};
const rows = (proof.rows ?? []).map((r) => ({ ...r, shots: (r.shots ?? []).map((s) => ({ ...s, data: image(s.src) })).filter((s) => s.data) }))
  .filter((r) => r.shots.some((s) => s.side === 'candidate'));
const leftOut = Number(proof.left_out ?? 0);
if (!rows.length) done({ sheet: null, rows: 0, left_out: leftOut, bytes: 0, reason: 'no criterion has a screenshot that shows its verdict' });

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const scenario = proof.mode === 'scenario';
const LABEL = { verified: ['Verified', 'ok'], passed: ['Passed', 'ok'], failed: ['Failed', 'bad'], regression: ['Regression', 'bad'],
  inconclusive: ['Inconclusive', 'warn'], partial: ['Partial', 'warn'], 'needs-review': ['Needs review', 'warn'], blocked: ['Blocked', 'muted'],
  flaky: ['Flaky', 'warn'], 'not-testable': ['Not testable', 'muted'] };
const badge = (x) => { const [t, c] = LABEL[x] ?? [x ?? '–', 'muted']; return `<span class="badge ${c}">${esc(t)}</span>`; };
const sideName = (s) => (s.side === 'candidate' ? (scenario ? 'Build' : 'Candidate') : (scenario ? 'Last release' : 'Baseline'));
const html = `<!doctype html><html><head><meta charset="utf-8"><style>
*{box-sizing:border-box}body{margin:0;background:#fff;color:#1d1f23;font:15px/1.4 system-ui,-apple-system,Segoe UI,sans-serif;width:1200px}
main{padding:20px 24px}h1{font-size:20px;margin:0 0 4px;display:flex;gap:10px;align-items:center}.meta{color:#6b7078;margin:0 0 14px;font-size:13px}
.badge{display:inline-block;border-radius:999px;padding:2px 10px;font-size:12px;font-weight:600;white-space:nowrap}
.ok{color:#127a3a;background:#e3f5e9}.bad{color:#b42318;background:#fdecea}.warn{color:#8a5a00;background:#fff4d6}.muted{color:#555b63;background:#eceef1}
section{border-top:1px solid #e3e5e8;padding:12px 0 6px}h2{font-size:16px;margin:0 0 8px;display:flex;gap:8px;align-items:center}
.shots{display:grid;grid-template-columns:repeat(auto-fit,minmax(0,1fr));gap:12px}.shots.one{grid-template-columns:minmax(0,760px)}figure{margin:0}
img{width:100%;max-height:620px;object-fit:cover;object-position:top;border:1px solid #e3e5e8;border-radius:6px;display:block}
figcaption{font-size:12px;color:#6b7078;margin-top:4px;overflow-wrap:anywhere}figcaption b{color:#1d1f23}footer{color:#6b7078;font-size:12px;padding-top:6px}
</style></head><body><main>
<h1>${esc(proof.subject)} — ${esc(proof.title)} ${badge(proof.verdict)}</h1>
<p class="meta">${scenario ? 'build' : 'candidate'} ${esc(proof.candidate ?? '–')}${proof.baseline ? ` · ${scenario ? 'last release' : 'baseline'} ${esc(proof.baseline)}` : ''}</p>
${rows.map((r) => `<section><h2>${esc(r.id)} — ${esc(r.name)} ${badge(r.verdict)}</h2><div class="shots${r.shots.length === 1 ? ' one' : ''}">${r.shots.map((s) => `<figure><img src="${s.data}" alt=""><figcaption><b>${esc(sideName(s))} ${esc(s.build ?? '')}</b> — ${esc(s.state)} · ${esc(s.caption)}</figcaption></figure>`).join('')}</div></section>`).join('')}
${leftOut ? `<footer>${leftOut} more ${leftOut === 1 ? 'criterion' : 'criteria'} in the full report.</footer>` : ''}
</main></body></html>`;

let pw;
try {
  const req = createRequire(join(work, 'suite', 'package.json'));
  pw = await import(pathToFileURL(req.resolve('playwright-core')).href);
} catch { done({ sheet: null, rows: rows.length, left_out: leftOut, bytes: 0, reason: 'unavailable: playwright-core is not installed in work/suite' }); }
let browser;
try {
  browser = await (pw.chromium ?? pw.default.chromium).launch();
  const page = await browser.newPage({ viewport: { width: 1200, height: 800 } });
  await page.route('**', (r) => r.abort());
  await page.setContent(html, { waitUntil: 'load' });
  await page.evaluate(() => Promise.all([...document.images].map((i) => i.decode().catch(() => {}))));
  await page.screenshot({ path: `${out}.tmp.png`, fullPage: true, type: 'png' });
  renameSync(`${out}.tmp.png`, out);
} catch (e) {
  rmSync(`${out}.tmp.png`, { force: true });
  await browser?.close().catch(() => {});
  done({ sheet: null, rows: rows.length, left_out: leftOut, bytes: 0, reason: `unavailable: ${String(e.message).split('\n')[0].slice(0, 120)}` });
}
await browser?.close().catch(() => {});
done({ sheet: out, rows: rows.length, left_out: leftOut, bytes: statSync(out).size, reason: null });
