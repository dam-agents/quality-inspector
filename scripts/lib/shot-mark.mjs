// shot-mark.mjs — the mark on an evidence screenshot: a frame around what a failed check found.
// Two sources (docs/test-authoring.md → The mark of a failed check, docs/reporting.md → The mark):
//   - the test: criterion() (work/suite/lib/criterion.ts) reads the box of the locator whose check
//     failed and takes `app.screenshot('<id>: the failing check [mark x,y,w,h;…]')` — CSS pixels of
//     the viewport, which is the screenshot's pixels (the web engine captures at CSS scale);
//   - the agent: a verdicts entry's `mark` ({box | boxes, saw}), pixels of the AC's still — drawn
//     only where the test left no mark of its own.
// Pure Node: PNG in, PNG out (8-bit RGB or RGBA, not interlaced); anything else -> null, and the
// caller shows the screenshot without its mark.

import { deflateSync, inflateSync } from 'node:zlib';

const MARK = /\s*\[mark ((?:-?\d+,-?\d+,\d+,\d+;?){1,8})\]\s*$/;
export const MAX_BOXES = 8;
export const TEST_RGB = [230, 0, 0]; // a test's mark: what the failed check found
export const AGENT_RGB = [245, 158, 11]; // the agent's mark: what it saw on the screen

// `AC-8: the failing check [mark 10,20,300,40]` -> { label: 'AC-8: the failing check', boxes: [{x,y,w,h}] }
export function splitMark(label) {
  const s = String(label ?? '');
  const m = MARK.exec(s);
  if (!m) return { label: s, boxes: [] };
  const boxes = m[1].split(';').filter(Boolean).map((b) => { const [x, y, w, h] = b.split(',').map(Number); return { x, y, w, h }; });
  return { label: s.slice(0, m.index), boxes: boxes.slice(0, MAX_BOXES) };
}

// A verdicts entry's `mark` -> its boxes, or [] when it has none that can be drawn.
export function agentBoxes(mark) {
  if (!mark || typeof mark !== 'object') return [];
  const list = Array.isArray(mark.boxes) ? mark.boxes : mark.box ? [mark.box] : [];
  return list.filter((b) => b && [b.x, b.y, b.w, b.h].every(Number.isFinite) && b.w > 0 && b.h > 0).slice(0, MAX_BOXES)
    .map((b) => ({ x: Math.round(b.x), y: Math.round(b.y), w: Math.round(b.w), h: Math.round(b.h) }));
}

const CRC = new Int32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c; });
const crc32 = (buf) => { let c = -1; for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ -1) >>> 0; };
const SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

export function decodePng(buf) {
  if (!Buffer.isBuffer(buf) || buf.length < 33 || !buf.subarray(0, 8).equals(SIG)) return null;
  let off = 8; let ihdr = null; const idat = [];
  while (off + 8 <= buf.length) {
    const len = buf.readUInt32BE(off); const type = buf.toString('latin1', off + 4, off + 8);
    const data = buf.subarray(off + 8, off + 8 + len);
    if (type === 'IHDR') ihdr = data; else if (type === 'IDAT') idat.push(data); else if (type === 'IEND') break;
    off += 12 + len;
  }
  if (!ihdr || !idat.length) return null;
  const w = ihdr.readUInt32BE(0); const h = ihdr.readUInt32BE(4);
  const [depth, color, , , interlace] = ihdr.subarray(8, 13);
  if (depth !== 8 || interlace !== 0 || ![2, 6].includes(color) || !w || !h) return null;
  const bpp = color === 6 ? 4 : 3; const stride = w * bpp;
  let raw; try { raw = inflateSync(Buffer.concat(idat)); } catch { return null; }
  if (raw.length < (stride + 1) * h) return null;
  const px = Buffer.alloc(stride * h);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)]; const src = y * (stride + 1) + 1; const row = y * stride; const up = row - stride;
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? px[row + i - bpp] : 0; const b = y ? px[up + i] : 0; const c = y && i >= bpp ? px[up + i - bpp] : 0;
      let p = raw[src + i];
      if (f === 1) p += a; else if (f === 2) p += b; else if (f === 3) p += (a + b) >> 1;
      else if (f === 4) { const q = a + b - c; const pa = Math.abs(q - a); const pb = Math.abs(q - b); const pc = Math.abs(q - c); p += pa <= pb && pa <= pc ? a : pb <= pc ? b : c; } else if (f !== 0) return null;
      px[row + i] = p & 0xff;
    }
  }
  return { w, h, bpp, color, px };
}

export function encodePng({ w, h, bpp, color, px }) {
  const stride = w * bpp; const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) { // filter 1 (Sub) on every row: small enough for a flat UI screen
    const o = y * (stride + 1); raw[o] = 1;
    for (let i = 0; i < stride; i++) raw[o + 1 + i] = (px[y * stride + i] - (i >= bpp ? px[y * stride + i - bpp] : 0)) & 0xff;
  }
  const chunk = (type, data) => {
    const t = Buffer.from(type, 'latin1'); const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(Buffer.concat([t, data])));
    return Buffer.concat([len, t, data, crc]);
  };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr.set([8, color, 0, 0, 0], 8);
  return Buffer.concat([SIG, chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

// The PNG with a frame `t` pixels wide around each box, outside the box where the screen allows
// it, so the framed control stays readable. A box off the screen is clipped; one fully off it is
// left out. -> { png, drawn } or null (not a PNG this can draw on).
export function drawMarks(buf, boxes, rgb = TEST_RGB, t = 3) {
  const img = decodePng(buf);
  if (!img) return null;
  const { w, h, bpp, px } = img;
  const fill = (x0, y0, x1, y1) => {
    for (let y = Math.max(0, y0); y < Math.min(h, y1); y++) {
      for (let x = Math.max(0, x0); x < Math.min(w, x1); x++) {
        const i = (y * w + x) * bpp; px[i] = rgb[0]; px[i + 1] = rgb[1]; px[i + 2] = rgb[2]; if (bpp === 4) px[i + 3] = 255;
      }
    }
  };
  let drawn = 0;
  for (const b of boxes) {
    const x0 = Math.round(b.x) - t; const y0 = Math.round(b.y) - t; const x1 = Math.round(b.x + b.w) + t; const y1 = Math.round(b.y + b.h) + t;
    if (x1 <= 0 || y1 <= 0 || x0 >= w || y0 >= h) continue;
    fill(x0, y0, x1, y0 + t); fill(x0, y1 - t, x1, y1); fill(x0, y0, x0 + t, y1); fill(x1 - t, y0, x1, y1);
    drawn++;
  }
  return drawn ? { png: encodePng(img), drawn } : null;
}
