// design-probe.mjs — what the design checks read from a rendered page (docs/design-checks.md), as
// ONE plain browser function like lib/ui-checks.mjs: no imports, no closure over this file, so
// design-check.mjs and consistency.mjs hand it to `page.evaluate(qiDesignProbe, opts)` as it is. It
// reads the page; its one write is a `data-qi-d` attribute on each element it reports, so the caller
// names that element through qiUiChecks({describe: [sel]}). It never clicks, types or scrolls.
//
//   {mode: 'tokens', prefixes, step} -> {colors: [[r,g,b]], lengths: [px], step: px|null, names}
//        the custom properties the page's own style sheets set on :root, html or :host (only those
//        with one of `prefixes`, when given), resolved: a colour as sRGB, a length in px
//   {mode: 'usage'}    -> [{prop: color|background|border|font-size|radius, value: [r,g,b]|px, alpha, count, sel, box}]
//   {mode: 'texts'}    -> [{text, sel, box}]   visible text, and aria-label, placeholder and title
//   {mode: 'state'}    -> {text, rows, loading, error, empty, bg}   the main region's text length, its
//        repeated rows, and a sign of a loading, an error and an empty state ({sel, text} or null);
//        `bg` is the page's background luminance
//   {mode: 'patterns'} -> [{kind: page-header|spacing|button|empty-state, group, sig, label, sel, box}]
//   {mode: 'focus', prev} -> {sel, shown, box, style, prev_style}   the focused element and its look;
//        `prev_style`: the look of the element `prev` names now that focus left it
//
// Visible only: a box, not visibility:hidden, not opacity 0. Code, pre, svg, canvas and frames are
// not read. Loaded as text (`export` stripped), so any Node version runs it.

export function qiDesignProbe({ mode, prefixes = [], step = null, prev = null } = {}) {
  const de = document.documentElement;
  const body = document.body;
  const sx = window.scrollX; const sy = window.scrollY;
  const styles = new Map();
  const style = (e) => { let s = styles.get(e); if (!s) { s = getComputedStyle(e); styles.set(e, s); } return s; };
  const clean = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
  const box = (e) => { const r = e.getBoundingClientRect(); return { x: Math.round(r.left + sx), y: Math.round(r.top + sy), w: Math.round(r.width), h: Math.round(r.height) }; };
  const shown = (e) => {
    const r = e.getBoundingClientRect();
    if (r.width < 1 || r.height < 1) return false;
    if (e.checkVisibility) return e.checkVisibility({ opacityProperty: true, visibilityProperty: true });
    return style(e).visibility === 'visible' && style(e).opacity !== '0';
  };
  const SKIP = 'script,style,noscript,template,code,pre,kbd,samp,svg,canvas,iframe,video';
  window.__qiD = window.__qiD ?? 0;
  const mark = (e) => { let v = e.getAttribute('data-qi-d'); if (!v) { v = String(++window.__qiD); e.setAttribute('data-qi-d', v); } return `[data-qi-d="${v}"]`; };
  const ownText = (e) => [...e.childNodes].some((n) => n.nodeType === 3 && n.data.trim());

  // A CSS colour as [r, g, b, a] in sRGB, through a 1×1 canvas: any notation the browser knows.
  const cv = document.createElement('canvas'); cv.width = 1; cv.height = 1;
  const g = cv.getContext('2d', { willReadFrequently: true });
  const rgba = (s) => {
    if (!s || /^(transparent|none|auto|inherit|initial|unset|currentcolor)$/i.test(s.trim())) return null;
    g.clearRect(0, 0, 1, 1); g.fillStyle = '#010203'; g.fillStyle = s;
    if (g.fillStyle === '#010203' && !/^#010203$/i.test(s.trim())) return null;
    g.fillRect(0, 0, 1, 1);
    const d = g.getImageData(0, 0, 1, 1).data;
    return d[3] === 0 ? null : [d[0], d[1], d[2], Math.round((d[3] / 255) * 100) / 100];
  };
  const lum = (c) => { const [r, gg, b] = c.slice(0, 3).map((v) => { const x = v / 255; return x <= 0.03928 ? x / 12.92 : ((x + 0.055) / 1.055) ** 2.4; }); return 0.2126 * r + 0.7152 * gg + 0.0722 * b; };
  const bgOf = (e) => {
    for (let x = e; x; x = x.parentElement) { const c = rgba(style(x).backgroundColor); if (c && c[3] >= 0.5) return c; }
    return [255, 255, 255, 1];
  };
  const px = (v) => Math.round(parseFloat(v) * 100) / 100;

  if (mode === 'tokens') {
    const names = new Set();
    const ROOT = /(^|,)\s*(:root|html|:host)\b/;
    const walk = (rules) => {
      for (const r of rules ?? []) {
        if (r.style && r.selectorText && ROOT.test(r.selectorText)) for (const p of r.style) if (p.startsWith('--')) names.add(p);
        if (r.cssRules) walk(r.cssRules);
      }
    };
    for (const sh of document.styleSheets) { try { walk(sh.cssRules); } catch { /* a cross-origin sheet: not the product's tokens */ } }
    for (const p of de.style) if (p.startsWith('--')) names.add(p);
    const rs = style(de);
    const probe = document.createElement('div');
    probe.style.cssText = 'position:absolute;visibility:hidden;left:-9999px;top:0;width:0;height:0';
    body.appendChild(probe);
    const colors = []; const lengths = [];
    let stepPx = null;
    const toPx = (v) => { if (/%|^\s*$/.test(v)) return null; probe.style.width = '0px'; probe.style.width = v; const w = parseFloat(getComputedStyle(probe).width); return probe.style.width && Number.isFinite(w) ? Math.round(w * 100) / 100 : null; };
    for (const n of names) {
      const v = rs.getPropertyValue(n).trim();
      if (n === step) stepPx = toPx(v);
      if (prefixes.length && !prefixes.some((p) => n.startsWith(p))) continue;
      if (!v) continue;
      if (CSS.supports('color', v)) { const c = rgba(v); if (c) colors.push(c.slice(0, 3)); continue; }
      if (CSS.supports('width', v)) { const l = toPx(v); if (l != null && l > 0 && l < 2000) lengths.push(l); }
    }
    probe.remove();
    return { colors, lengths: [...new Set(lengths)], step: stepPx, names: names.size };
  }

  if (mode === 'usage') {
    const seen = new Map();
    const add = (prop, value, e, alpha) => {
      const k = `${prop}|${Array.isArray(value) ? value.join(',') : value}`;
      const u = seen.get(k);
      if (u) { u.count++; return; }
      seen.set(k, { prop, value, alpha: alpha ?? 1, count: 1, sel: mark(e), box: box(e) });
    };
    const all = [...body.querySelectorAll('*')].slice(0, 4000);
    const W = Math.max(de.scrollWidth, de.clientWidth);
    for (const e of all) {
      if (e.closest(SKIP) || !shown(e)) continue;
      // Moved off the page (a skip link, a screen-reader-only text): no one sees its colours.
      const rr = e.getBoundingClientRect();
      if (rr.right + sx <= 0 || rr.left + sx >= W || rr.bottom + sy <= 0) continue;
      const s = style(e);
      const text = ownText(e);
      if (text) {
        const c = rgba(s.color); if (c) add('color', c.slice(0, 3), e, c[3]);
        add('font-size', px(s.fontSize), e);
      }
      if (!s.backgroundImage || s.backgroundImage === 'none') { const b = rgba(s.backgroundColor); if (b && b[3] >= 0.1) add('background', b.slice(0, 3), e, b[3]); }
      for (const side of ['Top', 'Right', 'Bottom', 'Left']) {
        if (parseFloat(s[`border${side}Width`]) >= 1 && s[`border${side}Style`] !== 'none') { const b = rgba(s[`border${side}Color`]); if (b && b[3] >= 0.1) { add('border', b.slice(0, 3), e, b[3]); break; } }
      }
      const r = px(s.borderTopLeftRadius);
      if (r > 0 && r < 999 && !/%/.test(s.borderTopLeftRadius)) add('radius', r, e);
    }
    return [...seen.values()];
  }

  if (mode === 'texts') {
    const out = [];
    const byEl = new Map();
    const w = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
    for (let n = w.nextNode(), k = 0; n && k < 20000; n = w.nextNode(), k++) {
      const p = n.parentElement; const t = clean(n.data);
      if (!t || !p || p.closest(SKIP)) continue;
      byEl.set(p, `${byEl.get(p) ?? ''} ${t}`);
    }
    for (const [e, t] of byEl) if (shown(e)) out.push({ text: clean(t).slice(0, 300), sel: mark(e), box: box(e) });
    for (const e of body.querySelectorAll('[aria-label],[placeholder],[title]')) {
      if (e.closest(SKIP) || !shown(e)) continue;
      for (const a of ['aria-label', 'placeholder', 'title']) { const t = clean(e.getAttribute(a)); if (t) out.push({ text: t.slice(0, 300), sel: mark(e), box: box(e) }); }
    }
    return out.slice(0, 3000);
  }

  const main = document.querySelector('main,[role=main]') ?? body;
  const EMPTY = /\b(no\s[\p{L}\s]{0,30}\b(yet|found|available|here|to show)|nothing\s(here|yet|to show|found)|(is|are)\sempty|empty\b|get started|create your first|you (do not|don['’]t) have any|there (are|is) no|haven['’]t)/iu;
  const ERROR = /\b(error|failed|failure|went wrong|try again|retry|could not|couldn['’]t|cannot|can['’]t|unable to|unavailable|problem)\b/i;
  const LOADING = /\b(loading|please wait|fetching)\b/i;
  const visibleText = (root, rx) => {
    const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    for (let n = w.nextNode(), k = 0; n && k < 20000; n = w.nextNode(), k++) {
      const p = n.parentElement; const t = clean(n.data);
      if (t && p && !p.closest(SKIP) && rx.test(t) && shown(p)) return { sel: mark(p), text: t.slice(0, 120), el: p };
    }
    return null;
  };

  if (mode === 'state') {
    const vis = (q) => [...main.querySelectorAll(q)].find((e) => shown(e));
    const loadingEl = vis('[aria-busy="true"],[role=progressbar],progress,[class*="skeleton" i],[class*="spinner" i],[class*="loading" i],[class*="shimmer" i],[data-loading]');
    const loading = loadingEl ? { sel: mark(loadingEl), text: clean(loadingEl.getAttribute('aria-label') || loadingEl.innerText).slice(0, 80) } : visibleText(main, LOADING);
    const alertEl = [...document.querySelectorAll('[role=alert],[aria-live=assertive],[role=alertdialog]')].find((e) => shown(e) && clean(e.innerText));
    const error = alertEl ? { sel: mark(alertEl), text: clean(alertEl.innerText).slice(0, 120) } : visibleText(main, ERROR);
    const emptyEl = vis('[class*="empty" i]');
    const empty = visibleText(main, EMPTY) ?? (emptyEl && clean(emptyEl.innerText) ? { sel: mark(emptyEl), text: clean(emptyEl.innerText).slice(0, 120) } : null);
    const rows = [...main.querySelectorAll('tbody tr,[role=row],li,[role=listitem],[role=article]')].filter(shown).length;
    const strip = (o) => (o ? { sel: o.sel, text: o.text } : null);
    return { text: clean(main.innerText).length, rows, loading: strip(loading), error: strip(error), empty: strip(empty), bg: Math.round(lum(bgOf(body)) * 1000) / 1000 };
  }

  if (mode === 'patterns') {
    const out = [];
    const r4 = (v) => Math.round(v / 4) * 4;
    const fam = (s) => clean(s.fontFamily.split(',')[0]).replace(/["']/g, '').toLowerCase();
    const hexOf = (c) => `#${c.slice(0, 3).map((v) => v.toString(16).padStart(2, '0')).join('')}`;
    // The page header: the first visible level-1 heading (else the main region's first heading).
    const h = [...document.querySelectorAll('main h1,[role=main] h1,h1,[role=heading][aria-level="1"]')].find(shown)
      ?? [...main.querySelectorAll('h2,[role=heading]')].find(shown);
    if (h) {
      const s = style(h);
      const c = rgba(s.color) ?? [0, 0, 0, 1];
      const fs = px(s.fontSize); const fw = Math.round(parseInt(s.fontWeight, 10) / 100) * 100 || 400;
      const tt = s.textTransform === 'none' ? '' : `, ${s.textTransform}`;
      out.push({ kind: 'page-header', group: '', sig: `${fs}|${fw}|${fam(s)}|${hexOf(c)}|${s.textTransform}`, label: `title ${fs}px, weight ${fw}, ${fam(s)}, ${hexOf(c)}${tt}`, sel: mark(h), box: box(h) });
      // The page margins: where the header starts inside the main region.
      const m = main === body ? (h.closest('section,article,div') ?? body) : main;
      const mr = m.getBoundingClientRect(); const hr = h.getBoundingClientRect();
      const left = r4(hr.left - mr.left); const top = r4(hr.top - mr.top);
      if (left >= 0 && top >= 0 && left < 400 && top < 400) out.push({ kind: 'spacing', group: '', sig: `${left}|${top}`, label: `content ${left}px from the left and ${top}px from the top of the content area`, sel: mark(h), box: box(h) });
    }
    // Buttons with text, by look: filled, outlined, or filled for deleting. A text-only button,
    // one in navigation, a tab list or a menu is not compared.
    const seenSig = new Set();
    for (const b of [...body.querySelectorAll('button,[role=button],input[type=submit],input[type=button],a[class*="btn" i],a[class*="button" i]')].slice(0, 300)) {
      if (!shown(b) || b.closest('nav,[role=navigation],[role=tablist],[role=menu],[role=menubar],[role=toolbar],table,[role=grid]')) continue;
      const t = clean(b.innerText || b.value);
      if (!t || t.length > 40) continue;
      const s = style(b); const r = b.getBoundingClientRect();
      const bg = rgba(s.backgroundColor); const back = bgOf(b.parentElement ?? body);
      const filled = bg && bg[3] >= 0.5 && (!s.backgroundImage || s.backgroundImage === 'none')
        && Math.abs(lum(bg) - lum(back)) > 0.08;
      const outlined = !filled && parseFloat(s.borderTopWidth) >= 1 && s.borderTopStyle !== 'none' && (rgba(s.borderTopColor)?.[3] ?? 0) >= 0.3;
      if (!filled && !outlined) continue;
      const group = filled ? (/\b(delete|remove|destroy|revoke|discard|erase)\b/i.test(t) ? 'danger' : 'filled') : 'outlined';
      const rad = px(s.borderTopLeftRadius);
      const shape = rad >= r.height / 2 - 1 ? 'pill' : rad === 0 ? 'square' : `${Math.round(rad)}px corners`;
      const fw = Math.round(parseInt(s.fontWeight, 10) / 100) * 100 || 400;
      const sig = `${shape}|${fw}|${s.textTransform}|${fam(s)}`;
      if (seenSig.has(`${group}|${sig}`)) continue;
      seenSig.add(`${group}|${sig}`);
      out.push({ kind: 'button', group, sig, label: `${shape}, weight ${fw}, ${s.textTransform === 'none' ? 'normal case' : s.textTransform}, ${fam(s)}`, sel: mark(b), box: box(b) });
    }
    // The empty state: the block around a sentence that says there is nothing yet.
    const hit = visibleText(main, EMPTY);
    if (hit) {
      // The block: up from the sentence while the text around it grows little (a card, not the page);
      // its frame and alignment may sit on any element of that chain.
      const chain = [hit.el];
      for (let c = hit.el, i = 0; i < 5; i++) {
        const up = c.parentElement;
        if (!up || up === main || up === body) break;
        const a = clean(c.innerText).length; const b = clean(up.innerText).length;
        if (b > 400 || b > Math.max(a * 1.5, a + 80)) break;
        chain.push(up); c = up;
      }
      const c = chain[chain.length - 1];
      const pics = [...c.querySelectorAll('svg,img,[role=img]')].filter(shown).map((x) => x.getBoundingClientRect());
      const big = Math.max(0, ...pics.map((x) => Math.max(x.width, x.height)));
      const pic = !pics.length ? 'no picture' : big >= 48 ? 'picture' : 'icon';
      const head = [...c.querySelectorAll('h2,h3,h4,h5,h6,[role=heading],strong,b')].some(shown) ? 'title' : 'no title';
      const act = [...c.querySelectorAll('button,a[href],[role=button]')].some(shown) ? 'action' : 'no action';
      const align = chain.some((x) => style(x).textAlign === 'center' || (style(x).display.includes('flex') && style(x).alignItems === 'center')) ? 'centered' : 'left-aligned';
      const framed = chain.some((x) => {
        const s = style(x); const xb = rgba(s.backgroundColor);
        return (parseFloat(s.borderTopWidth) >= 1 && s.borderTopStyle !== 'none') || (xb && xb[3] >= 0.5 && Math.abs(lum(xb) - lum(bgOf(x.parentElement ?? body))) > 0.02);
      }) ? 'framed' : 'no frame';
      out.push({ kind: 'empty-state', group: '', sig: `${pic}|${head}|${act}|${align}|${framed}`, label: `${pic}, ${head}, ${act}, ${align}, ${framed}`, sel: mark(c), box: box(c) });
    }
    return out;
  }

  if (mode === 'focus') {
    const look = (e) => { const s = getComputedStyle(e); return [s.outlineStyle === 'none' ? 'none' : `${s.outlineStyle} ${s.outlineWidth} ${s.outlineColor}`, s.boxShadow, s.borderColor, s.backgroundColor, s.textDecorationLine, s.color].join('|'); };
    let p = null; try { p = prev ? document.querySelector(prev) : null; } catch { p = null; }
    let a = document.activeElement;
    while (a?.shadowRoot?.activeElement) a = a.shadowRoot.activeElement;
    if (!a || a === body || a === de) return { sel: null, shown: false, box: null, style: null, prev_style: p ? look(p) : null };
    const r = a.getBoundingClientRect();
    const inView = r.right > 0 && r.bottom > 0 && r.left < (de.clientWidth || innerWidth) + 1 && r.top + sy >= 0;
    return { sel: mark(a), shown: shown(a) && inView, box: box(a), style: look(a), prev_style: p ? look(p) : null };
  }
  return null;
}
