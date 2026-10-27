#!/usr/bin/env node
// report-media.mjs — make a rendered report one self-contained file before it is published. The
// platform's artifact is one file: a viewer never gets the report's media/ folder, so a relative
// `media/<name>` link answers 404 (docs/reporting.md → Delivery step 1). Two ways out:
//
//   public  every image and download (a trace.zip) is an artifact of its own, published public; the
//           page links each one by its absolute address (`<share link>/raw?v=<version>`). A video is
//           never uploaded: the platform's raw link serves only images inline — any other type
//           as application/octet-stream with Content-Disposition: attachment, which no <video>
//           plays. So the videos, and the files of a type the platform was seen to refuse, go into
//           the page as data: URIs within the same page budget as private.
//   private nothing has an address a viewer can open: the media go into the page as data: URIs,
//           screenshots first, then the candidate's videos, then the rest, while the page stays
//           under QI_REPORT_PAGE_MAX bytes (9 MiB; the platform renders up to 10). What does not
//           fit is a line that says so; a trace.zip is never inlined.
//
//   node report-media.mjs list <report-dir>
//     -> {"media": [{"path": "media/<name>", "bytes", "sha256", "content_type", "upload", "url": <address> | null}]}
//        the files the page names; `upload: false` = never uploaded, the page carries it (a video,
//        or a refused type); `upload: true, url: null` = not uploaded yet (public). Every upload sends
//        `Content-Type: <content_type>`: without it the platform stores the artifact as
//        application/x-www-form-urlencoded and serves it as a download, which an <img> or a
//        <video> of a strict viewer does not show.
//   node report-media.mjs set <report-dir> media/<name> <share-url> <version> [--served-type <type>]
//     -> {"path", "url", "content_type"} — records one media artifact uploaded with that type.
//        --served-type: the Content-Type a HEAD of the address answered (the run's first image,
//        docs/reporting.md); another type than the file's -> exit 1, no address recorded, the type
//        recorded as refused: from then on `list` gives its files `upload: false` and `publish
//        public` puts them into the page, {"path", "url": null, "content_type", "served_type", "refused": true}.
//        A video is refused with exit 2: it is never uploaded.
//   node report-media.mjs unblock <report-dir>
//     -> {"unblocked": [<refusal>]} — the operator's, once the platform serves the type again
//   node report-media.mjs publish <report-dir> public|private
//     -> {"file": "<report-dir>/publish.html", "content_type": "text/html; charset=utf-8", "bytes", "linked", "inlined", "left_out": [path]}
//        exit 1 (public): a file to upload without its address — nothing is written, `missing` lists them
//
// The addresses are kept by content (sha256) in media-urls.json beside the report directory (the
// refused types under its key `refused`, never a sha256; a `blocked` refusal of 3.33.1 is read as
// one), so a new revision of the same report uploads only what changed. An address recorded without its type
// (before 3.32.1, uploaded untyped) counts as no address, so the next revision uploads it again.
// Reads only <report-dir> and that file; writes only publish.html and media-urls.json. Exit 2:
// usage or a refused value.

import { createHash } from 'node:crypto';
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';

const [cmd, dirArg, ...rest] = process.argv.slice(2);
const usage = 'usage: report-media.mjs list <report-dir> | set <report-dir> media/<name> <share-url> <version> [--served-type <type>] | unblock <report-dir> | publish <report-dir> public|private';
const die = (m, code = 2) => { console.error(m ? `report-media: ${m}` : usage); process.exit(code); };
if (!cmd || !dirArg) die();
const dir = resolve(dirArg);
const page = join(dir, 'index.html');
if (!existsSync(page)) die(`no ${page} — render the report first`, 1);
const mapFile = join(dirname(dir), 'media-urls.json');
const HTML_TYPE = 'text/html; charset=utf-8';
const PAGE_MAX = Number(process.env.QI_REPORT_PAGE_MAX ?? 9 * 1024 * 1024);
const MIME = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg', webp: 'image/webp', gif: 'image/gif', webm: 'video/webm', mp4: 'video/mp4' };
const TYPE = { ...MIME, zip: 'application/zip' };
const typeOf = (p) => TYPE[p.split('.').pop().toLowerCase()] ?? 'application/octet-stream';
const SHARE = /^https:\/\/[A-Za-z0-9.-]+(?::\d+)?\/a\/[A-Za-z0-9_-]{1,64}$/;

const unesc = (s) => s.replace(/&(amp|lt|gt|quot|#39);/g, (_, e) => ({ amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'" })[e]);
const sha = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');
// No file yet is an empty map; a file that does not parse is an error, never a silent empty map.
const readMap = () => {
  if (!existsSync(mapFile)) return { refused: {} };
  let m; try { m = JSON.parse(readFileSync(mapFile, 'utf8')); } catch { m = null; }
  if (!m || typeof m !== 'object' || Array.isArray(m)) die(`${mapFile} is not a JSON object — repair or remove it`, 1);
  if (!m.refused || typeof m.refused !== 'object' || Array.isArray(m.refused)) m.refused = {};
  // 3.33.1 stopped the whole report at one refused file; now that file's type goes into the page.
  if (m.blocked && typeof m.blocked.content_type === 'string') m.refused[m.blocked.content_type] ??= m.blocked;
  delete m.blocked;
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
const info = (path) => { const f = join(dir, path); return { path, bytes: statSync(f).size, sha256: sha(f), content_type: typeOf(path) }; };
// A video, or a file of a refused type, is never uploaded: the page carries it.
const uploads = (map, i) => !i.content_type.startsWith('video/') && !map.refused[i.content_type];
// The address of one file, only when it was recorded with the type this file is uploaded with.
const addr = (map, i) => { const e = map[i.sha256]; return e && typeof e === 'object' && e.content_type === i.content_type && typeof e.url === 'string' ? e.url : null; };

const writeMap = (map) => {
  const out = { ...map }; if (!Object.keys(out.refused).length) delete out.refused;
  writeFileSync(mapFile, `${JSON.stringify(out, null, 1)}\n`);
};
const ext = (p) => p.split('.').pop().toLowerCase();
// Put `paths` into the page as data: URIs — screenshots first, then the candidate's videos, then
// the rest — while the page stays under PAGE_MAX; a trace is never inlined. Every other media/
// reference becomes `link(path)`. A file that does not fit is `note` in the page, and a link to
// one is `<text> (<gap>)`.
const inline = (body, paths, link, note, gap) => {
  const kind = (p) => (MIME[ext(p)]?.startsWith('image/') ? 0 : MIME[ext(p)] ? (/-candidate-/.test(p) ? 1 : 2) : 3);
  let size = Buffer.byteLength(body);
  const data = new Map(); const leftOut = [];
  for (const p of [...paths].sort((a, b) => kind(a) - kind(b) || paths.indexOf(a) - paths.indexOf(b))) {
    const used = (body.match(new RegExp(`"${p.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/&/g, '&amp;')}"`, 'g')) ?? []).length;
    if (!used) continue;
    const uri = kind(p) < 3 ? `data:${MIME[ext(p)]};base64,${readFileSync(join(dir, p)).toString('base64')}` : null;
    const grow = uri ? used * (uri.length - p.length) : Infinity;
    if (size + grow <= PAGE_MAX) { data.set(p, uri); size += grow; } else leftOut.push(p);
  }
  const gone = (raw) => { const p = unesc(raw); return paths.includes(p) && !data.has(p); };
  body = body
    .replace(/<video [^>]*src="(media\/[^"]+)"[^>]*><\/video>/g, (m, raw) => (gone(raw) ? note : m))
    .replace(/<figure><img [^>]*src="(media\/[^"]+)"[^>]*><figcaption>([\s\S]*?)<\/figcaption><\/figure>/g, (m, raw, cap) => (gone(raw) ? `<figure>${note}<figcaption>${cap}</figcaption></figure>` : m))
    .replace(/<img [^>]*src="(media\/[^"]+)"[^>]*>/g, (m, raw) => (gone(raw) ? note : m))
    .replace(/<a href="(media\/[^"]+)">([^<]*)<\/a>/g, (m, raw, text) => (gone(raw) ? `${text} (${gap})` : m))
    .replace(REF, (_, a, raw, z) => { const p = unesc(raw); return `${a}${data.get(p) ?? link(p) ?? '#'}${z}`; });
  return { body, inlined: data.size, leftOut };
};

if (cmd === 'list') {
  const map = readMap();
  console.log(JSON.stringify({ media: refs.map((p) => { const i = info(p); const up = uploads(map, i); return { ...i, upload: up, url: up ? addr(map, i) : null }; }) }));
} else if (cmd === 'set') {
  const [path, share, version, flag, served, ...extra] = rest;
  if (!refs.includes(path)) die(`${path} is not a media file of this page`);
  if (!SHARE.test(share ?? '')) die('the share link must be https://<host>/a/<slug>');
  if (!/^[1-9]\d{0,6}$/.test(version ?? '')) die('the version must be a positive integer');
  if (extra.length || (flag !== undefined && (flag !== '--served-type' || !served))) die();
  const i = info(path);
  const map = readMap(); const url = `${share}/raw?v=${version}`;
  if (!uploads(map, i)) die(`${path} is ${i.content_type}, which the page carries — never uploaded`);
  // A served type is compared without its parameters (`; charset=…`) and its letter case.
  if (served !== undefined && served.split(';')[0].trim().toLowerCase() !== i.content_type) {
    map.refused[i.content_type] = { path, url, content_type: i.content_type, served_type: served, utc: new Date().toISOString().replace(/\.\d+Z$/, 'Z') };
    writeMap(map);
    console.log(JSON.stringify({ path, url: null, content_type: i.content_type, served_type: served, refused: true }));
    process.exit(1);
  }
  map[i.sha256] = { url, content_type: i.content_type };
  writeMap(map);
  console.log(JSON.stringify({ path, url, content_type: i.content_type }));
} else if (cmd === 'unblock' && !rest.length) {
  const map = readMap(); const was = Object.values(map.refused);
  map.refused = {}; if (existsSync(mapFile)) writeMap(map);
  console.log(JSON.stringify({ unblocked: was }));
} else if (cmd === 'publish' && (rest[0] === 'public' || rest[0] === 'private')) {
  const out = join(dir, 'publish.html');
  if (rest[0] === 'public') {
    const map = readMap(); const items = refs.map(info);
    const up = items.filter((i) => uploads(map, i)); const urls = new Map(up.map((i) => [i.path, addr(map, i)]));
    const missing = up.filter((i) => !urls.get(i.path)).map((i) => i.path);
    if (missing.length) { console.log(JSON.stringify({ file: null, missing })); process.exit(1); }
    // A poster of a file the page carries only repeats bytes: it goes.
    const html1 = html.replace(/ poster="(media\/[^"]+)"/g, (m, raw) => (urls.has(unesc(raw)) ? m : ''));
    const NOTE = '<p class="dim">This report has a size limit. This file is not in it.</p>';
    const r = inline(html1, items.filter((i) => !urls.has(i.path)).map((i) => i.path), (p) => urls.get(p), NOTE, 'not in this report');
    writeFileSync(out, r.body);
    console.log(JSON.stringify({ file: out, content_type: HTML_TYPE, bytes: Buffer.byteLength(r.body), linked: urls.size, inlined: r.inlined, left_out: r.leftOut }));
  } else {
    // Without media/, a video's poster only repeats bytes: it goes.
    const NOTE = '<p class="dim">This private report has a size limit. This file is not in it. With report_visibility: public, the report links its screenshots and has more space for its videos.</p>';
    const r = inline(html.replace(/ poster="media\/[^"]+"/g, ''), refs, () => null, NOTE, 'not in this private report');
    writeFileSync(out, r.body);
    console.log(JSON.stringify({ file: out, content_type: HTML_TYPE, bytes: Buffer.byteLength(r.body), linked: 0, inlined: r.inlined, left_out: r.leftOut }));
  }
} else die();
