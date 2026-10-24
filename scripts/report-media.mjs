#!/usr/bin/env node
// report-media.mjs — make a rendered report one self-contained file before it is published. The
// platform's artifact is one file: a viewer never gets the report's media/ folder, so a relative
// `media/<name>` link answers 404 (docs/reporting.md → Delivery step 1). Two ways out:
//
//   public  every media file is an artifact of its own, published public; the page links each one
//           by its absolute address (`<share link>/raw?v=<version>`), so the page stays small.
//   private nothing has an address a viewer can open: the media go into the page as data: URIs,
//           screenshots first, then the candidate's videos, then the rest, while the page stays
//           under QI_REPORT_PAGE_MAX bytes (9 MiB; the platform renders up to 10). What does not
//           fit is a line that says so; a trace.zip is never inlined.
//
//   node report-media.mjs list <report-dir>
//     -> {"media": [{"path": "media/<name>", "bytes", "sha256", "url": <address> | null}]}
//        the files the page names; `url: null` = not uploaded yet (public)
//   node report-media.mjs set <report-dir> media/<name> <share-url> <version>
//     -> {"path", "url"} — records one uploaded media artifact
//   node report-media.mjs publish <report-dir> public|private
//     -> {"file": "<report-dir>/publish.html", "bytes", "linked", "inlined", "left_out": [path]}
//        exit 1 (public): a media file without its address — nothing is written, `missing` lists them
//
// The addresses are kept by content (sha256) in media-urls.json beside the report directory, so a
// new revision of the same report uploads only what changed. Reads only <report-dir> and that file;
// writes only publish.html and media-urls.json. Exit 2: usage or a refused value.

import { createHash } from 'node:crypto';
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';

const [cmd, dirArg, ...rest] = process.argv.slice(2);
const usage = 'usage: report-media.mjs list <report-dir> | set <report-dir> media/<name> <share-url> <version> | publish <report-dir> public|private';
const die = (m, code = 2) => { console.error(m ? `report-media: ${m}` : usage); process.exit(code); };
if (!cmd || !dirArg) die();
const dir = resolve(dirArg);
const page = join(dir, 'index.html');
if (!existsSync(page)) die(`no ${page} — render the report first`, 1);
const mapFile = join(dirname(dir), 'media-urls.json');
const PAGE_MAX = Number(process.env.QI_REPORT_PAGE_MAX ?? 9 * 1024 * 1024);
const MIME = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp', gif: 'image/gif', webm: 'video/webm', mp4: 'video/mp4' };
const SHARE = /^https:\/\/[A-Za-z0-9.-]+(?::\d+)?\/a\/[A-Za-z0-9_-]{1,64}$/;

const unesc = (s) => s.replace(/&(amp|lt|gt|quot|#39);/g, (_, e) => ({ amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'" })[e]);
const sha = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');
// No file yet is an empty map; a file that does not parse is an error, never a silent empty map.
const readMap = () => {
  if (!existsSync(mapFile)) return {};
  let m; try { m = JSON.parse(readFileSync(mapFile, 'utf8')); } catch { m = null; }
  if (!m || typeof m !== 'object' || Array.isArray(m)) die(`${mapFile} is not a JSON object — repair or remove it`, 1);
  return m;
};
const html = readFileSync(page, 'utf8');
// Every `src`, `href` and `poster` that names a file of media/, in page order. A name with a
// path in it, or one that is not in media/, is refused: the page must not reach anything else.
const REF = /(\s(?:src|href|poster)=")(media\/[^"]+)(")/g;
const refs = [];
for (const [, , raw] of html.matchAll(REF)) {
  const path = unesc(raw); const name = path.slice('media/'.length);
  if (!name || name !== basename(name) || name.startsWith('.')) die(`refused media reference ${JSON.stringify(path)}`);
  if (!existsSync(join(dir, 'media', name))) die(`${path} is named by the page but missing`, 1);
  if (!refs.includes(path)) refs.push(path);
}
const info = (path) => { const f = join(dir, path); return { path, bytes: statSync(f).size, sha256: sha(f) }; };

if (cmd === 'list') {
  const map = readMap();
  console.log(JSON.stringify({ media: refs.map((p) => { const i = info(p); return { ...i, url: map[i.sha256] ?? null }; }) }));
} else if (cmd === 'set') {
  const [path, share, version] = rest;
  if (!refs.includes(path)) die(`${path} is not a media file of this page`);
  if (!SHARE.test(share ?? '')) die('the share link must be https://<host>/a/<slug>');
  if (!/^[1-9]\d{0,6}$/.test(version ?? '')) die('the version must be a positive integer');
  const map = readMap(); const url = `${share}/raw?v=${version}`;
  map[info(path).sha256] = url;
  writeFileSync(mapFile, `${JSON.stringify(map, null, 1)}\n`);
  console.log(JSON.stringify({ path, url }));
} else if (cmd === 'publish' && (rest[0] === 'public' || rest[0] === 'private')) {
  const out = join(dir, 'publish.html');
  if (rest[0] === 'public') {
    const map = readMap(); const urls = new Map(refs.map((p) => [p, map[info(p).sha256]]));
    const missing = refs.filter((p) => !urls.get(p));
    if (missing.length) { console.log(JSON.stringify({ file: null, missing })); process.exit(1); }
    const body = html.replace(REF, (_, a, raw, z) => `${a}${urls.get(unesc(raw))}${z}`);
    writeFileSync(out, body);
    console.log(JSON.stringify({ file: out, bytes: Buffer.byteLength(body), linked: refs.length, inlined: 0, left_out: [] }));
  } else {
    // Inline: the order of what matters most, then the page budget.
    const ext = (p) => p.split('.').pop().toLowerCase();
    const kind = (p) => (MIME[ext(p)]?.startsWith('image/') ? 0 : MIME[ext(p)] ? (/-candidate-/.test(p) ? 1 : 2) : 3);
    // Without media/, a link to a full-size image and a video's poster only repeat bytes: they go.
    let body = html.replace(/<a href="media\/[^"]+"(?: target="_blank")?>(<img [^>]*>)<\/a>/g, '$1').replace(/ poster="media\/[^"]+"/g, '');
    let size = Buffer.byteLength(body);
    const data = new Map(); const leftOut = [];
    for (const p of [...refs].sort((a, b) => kind(a) - kind(b) || refs.indexOf(a) - refs.indexOf(b))) {
      const used = (body.match(new RegExp(`"${p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/&/g, '&amp;')}"`, 'g')) ?? []).length;
      if (!used) continue;
      const uri = kind(p) < 3 ? `data:${MIME[ext(p)]};base64,${readFileSync(join(dir, p)).toString('base64')}` : null;
      const grow = uri ? used * (uri.length - p.length) : Infinity;
      if (size + grow <= PAGE_MAX) { data.set(p, uri); size += grow; } else leftOut.push(p);
    }
    const NOTE = '<p class="dim">This private report has a size limit. This file is not in it. With report_visibility: public, the report shows all its files.</p>';
    const gone = (raw) => !data.has(unesc(raw));
    body = body
      .replace(/<video [^>]*src="(media\/[^"]+)"[^>]*><\/video>/g, (m, raw) => (gone(raw) ? NOTE : m))
      .replace(/<figure><img [^>]*src="(media\/[^"]+)"[^>]*><figcaption>([\s\S]*?)<\/figcaption><\/figure>/g, (m, raw, cap) => (gone(raw) ? `<figure>${NOTE}<figcaption>${cap}</figcaption></figure>` : m))
      .replace(/<img [^>]*src="(media\/[^"]+)"[^>]*>/g, (m, raw) => (gone(raw) ? NOTE : m))
      .replace(/<a href="(media\/[^"]+)">([^<]*)<\/a>/g, (m, raw, text) => (gone(raw) ? `${text} (not in this private report)` : m))
      .replace(REF, (_, a, raw, z) => `${a}${data.get(unesc(raw)) ?? '#'}${z}`);
    writeFileSync(out, body);
    console.log(JSON.stringify({ file: out, bytes: Buffer.byteLength(body), linked: 0, inlined: data.size, left_out: leftOut }));
  }
} else die();
