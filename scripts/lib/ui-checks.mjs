// ui-checks.js — the deterministic UI checks of the sweep (docs/ui-sweep.md), as ONE plain
// browser function: no imports, no closure over this file, so ui-sweep.mjs hands it to
// `page.evaluate(qiUiChecks, opts)` as it is. It reads the rendered page only — it never
// clicks, types, scrolls or changes the DOM.
//
//   qiUiChecks({ mobile, minTap = 24, cap = 20 })
//     -> [{check, severity, target, text, box: {x, y, w, h}, detail}]   box in page CSS px
//   qiUiChecks({ describe: ['<css selector>', …] })
//     -> [{target, text, box} | null]   the same description for elements found elsewhere (axe)
//
// Checks (ids are the contract): overflow-x, offscreen, broken-image, placeholder-text and
// no-name are `major`; clipped-text, overlap, contrast and tap-target (mobile only) `minor`.
// `target` names an element as a user would — `“Save changes” button`, `unnamed link to
// /settings`, `image logo.png` — never by CSS. At most `cap` results per check, one per target;
// visible elements only (a box, not visibility:hidden, not opacity 0, not a screen-reader-only
// 1px box). Loaded by ui-sweep.mjs as text (`export` stripped), so any Node version runs it.

export async function qiUiChecks({ mobile = false, minTap = 24, cap = 20, describe = null } = {}) {
  const MAJOR = new Set(['overflow-x', 'offscreen', 'broken-image', 'placeholder-text', 'no-name']);
  const INTERACTIVE = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=tab],'
    + '[role=checkbox],[role=radio],[role=switch],[role=menuitem],[role=option],[role=combobox],[role=slider]';
  const de = document.documentElement;
  const vw = de.clientWidth || window.innerWidth;
  const sx = window.scrollX; const sy = window.scrollY;
  const styles = new Map();
  const style = (e) => { let s = styles.get(e); if (!s) { s = getComputedStyle(e); styles.set(e, s); } return s; };
  const clean = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
  const cut = (s, n = 60) => { const t = clean(s); return t.length > n ? `${t.slice(0, n - 1)}…` : t; };
  const box = (r) => ({ x: Math.round(r.left + sx), y: Math.round(r.top + sy), w: Math.round(r.width), h: Math.round(r.height) });
  const hiddenTree = (e) => !!e.closest('[aria-hidden="true"],[inert]');
  const srOnly = (e, r) => {
    const s = style(e);
    return r.width <= 2 || r.height <= 2 || (s.clip && s.clip !== 'auto') || /inset\(50%|circle\(0/.test(s.clipPath || '');
  };
  const shown = (e) => {
    const r = e.getBoundingClientRect();
    if (r.width < 1 || r.height < 1 || srOnly(e, r)) return false;
    if (e.checkVisibility) return e.checkVisibility({ opacityProperty: true, visibilityProperty: true });
    if (style(e).visibility !== 'visible') return false;
    for (let x = e; x; x = x.parentElement) if (style(x).opacity === '0') return false;
    return true;
  };
  // An ancestor that clips or scrolls sideways contains its content: nothing reaches the page.
  const contained = (e) => {
    for (let x = e.parentElement; x && x !== document.body && x !== de; x = x.parentElement) if (style(x).overflowX !== 'visible') return true;
    return false;
  };

  // ------------------------------------------------------------- naming an element
  const IMPLICIT = { A: 'link', BUTTON: 'button', SELECT: 'combobox', TEXTAREA: 'textbox', IMG: 'image', NAV: 'navigation',
    MAIN: 'main', HEADER: 'banner', FOOTER: 'contentinfo', ASIDE: 'complementary', FORM: 'form', DIALOG: 'dialog', SUMMARY: 'button',
    H1: 'heading', H2: 'heading', H3: 'heading', H4: 'heading', H5: 'heading', H6: 'heading', LI: 'list item', TH: 'column header',
    TD: 'cell', LABEL: 'label', P: 'paragraph', TABLE: 'table' };
  const INPUT_ROLE = { checkbox: 'checkbox', radio: 'radio', button: 'button', submit: 'button', reset: 'button', image: 'button',
    range: 'slider', number: 'spinbutton', search: 'searchbox', file: 'file input', color: 'color input' };
  const role = (e) => {
    const r = clean(e.getAttribute('role')).split(' ')[0];
    if (r) return r;
    if (e.tagName === 'A') return e.hasAttribute('href') ? 'link' : 'a';
    if (e.tagName === 'INPUT') return INPUT_ROLE[(e.type || 'text').toLowerCase()] ?? 'textbox';
    return IMPLICIT[e.tagName] ?? e.tagName.toLowerCase();
  };
  const byIds = (e, a) => clean((e.getAttribute(a) || '').split(/\s+/).filter(Boolean)
    .map((id) => document.getElementById(id)?.textContent ?? '').join(' '));
  const accName = (e) => {
    const t = e.tagName;
    const n = clean(e.getAttribute('aria-label')) || byIds(e, 'aria-labelledby');
    if (n) return n;
    if (t === 'INPUT' || t === 'SELECT' || t === 'TEXTAREA') {
      const l = clean([...(e.labels ?? [])].map((x) => x.innerText || x.textContent).join(' '));
      if (l) return l;
      if (t === 'INPUT') {
        const ty = (e.type || '').toLowerCase();
        if (ty === 'submit' || ty === 'reset') return clean(e.value) || (ty === 'submit' ? 'Submit' : 'Reset');
        if (ty === 'button') return clean(e.value) || clean(e.getAttribute('title'));
        if (ty === 'image') return clean(e.getAttribute('alt') || e.value || e.getAttribute('title'));
      }
      return clean(e.getAttribute('title') || e.getAttribute('placeholder'));
    }
    if (t === 'IMG') return clean(e.getAttribute('alt') || e.getAttribute('title'));
    const txt = clean(e.innerText);
    if (txt) return txt;
    const img = [...e.querySelectorAll('img[alt],[role=img][aria-label],svg[aria-label],svg title')]
      .map((x) => clean(x.getAttribute('alt') || x.getAttribute('aria-label') || x.textContent)).find(Boolean);
    return img || clean(e.getAttribute('title'));
  };
  const LANDMARK = 'nav,header,footer,main,aside,form,dialog,[role=dialog],[role=navigation],[role=banner],[role=search],[role=toolbar],[role=menu],[role=tablist]';
  const within = (e) => {
    const l = e.parentElement?.closest(LANDMARK);
    if (!l) return '';
    const n = cut(clean(l.getAttribute('aria-label')) || byIds(l, 'aria-labelledby'), 40);
    return ` in ${role(l)}${n ? ` “${n}”` : ''}`;
  };
  const describeEl = (e) => {
    if (e === de || e === document.body) return 'the page';
    const n = cut(accName(e));
    const r = role(e);
    if (n) return `“${n}” ${r}`;
    if (e.tagName === 'IMG') {
      const f = (e.getAttribute('src') || '').split(/[?#]/)[0].split('/').pop();
      if (f && !f.startsWith('data:')) return `image ${cut(f, 40)}`;
    }
    if (e.tagName === 'A' && e.getAttribute('href')) {
      try { const u = new URL(e.href); if (u.origin === location.origin) return `unnamed link to ${cut(u.pathname, 50)}`; } catch { /* no URL */ }
    }
    return `unnamed ${r}${within(e)}`;
  };

  if (Array.isArray(describe)) {
    return describe.map((sel) => {
      let e = null;
      try { e = document.querySelector(sel); } catch { /* not a selector */ }
      return e ? { target: describeEl(e), text: cut(e.innerText ?? '', 80), box: box(e.getBoundingClientRect()) } : null;
    });
  }

  // ------------------------------------------------------------- results
  const out = [];
  const seen = new Set();
  const per = {};
  const add = (check, target, text, b, detail) => {
    const k = `${check}|${target}`;
    if (seen.has(k) || (per[check] ?? 0) >= cap) return;
    seen.add(k); per[check] = (per[check] ?? 0) + 1;
    out.push({ check, severity: MAJOR.has(check) ? 'major' : 'minor', target, text: cut(text, 80), box: b, detail });
  };
  const body = document.body;
  if (!body) return out;
  const all = [...body.querySelectorAll('*')].slice(0, 8000);
  const interactive = [...body.querySelectorAll(INTERACTIVE)].filter((e) => shown(e) && !hiddenTree(e)).slice(0, 600);
  const isInteractive = new Set(interactive);
  const ownText = (e) => [...e.childNodes].some((n) => n.nodeType === 3 && n.data.trim());
  const SKIP_TEXT = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|CODE|PRE|KBD|SAMP|TEXTAREA|SVG)$/i;

  // overflow-x: the document scrolls sideways; the outermost elements that make it do. An
  // interactive element past the edge is `offscreen` instead.
  const docW = Math.max(de.scrollWidth, body.scrollWidth);
  if (docW > vw + 1) {
    add('overflow-x', 'the page', '', { x: 0, y: 0, w: docW, h: Math.round(Math.min(de.scrollHeight, window.innerHeight)) },
      `the page is ${docW}px wide in a ${vw}px viewport`);
    const over = (e) => e.getBoundingClientRect().right + sx > vw + 1;
    for (const e of all) {
      if (isInteractive.has(e) || !over(e) || style(e).position === 'fixed' || !shown(e) || hiddenTree(e) || contained(e)) continue;
      const p = e.parentElement;
      if (p && p !== body && over(p)) continue;
      const r = e.getBoundingClientRect();
      add('overflow-x', describeEl(e), e.innerText, box(r), `extends ${Math.round(r.right + sx - vw)}px past the right edge`);
    }
  }

  // offscreen: an interactive element not wholly inside [0, viewport width].
  for (const e of interactive) {
    const r = e.getBoundingClientRect();
    const L = r.left + sx; const R = r.right + sx;
    if ((L >= -1 && R <= vw + 1) || contained(e)) continue;
    const whole = R <= 0 || L >= vw;
    add('offscreen', describeEl(e), e.innerText, box(r), `${whole ? 'wholly' : 'partly'} outside the page: ${L < -1 ? `starts ${Math.round(-L)}px left of it` : `ends ${Math.round(R - vw)}px past its right edge`}`);
  }

  // clipped-text: a box that hides its own text's overflow without an ellipsis or a line clamp.
  for (const e of all) {
    const s = style(e);
    const hx = /hidden|clip/.test(s.overflowX); const hy = /hidden|clip/.test(s.overflowY);
    if (!hx && !hy) continue;
    if (!ownText(e) && !(isInteractive.has(e) && clean(e.innerText))) continue;
    if (SKIP_TEXT.test(e.tagName) || !shown(e)) continue;
    const x = hx && e.scrollWidth > e.clientWidth + 1 && s.textOverflow !== 'ellipsis';
    const y = hy && e.scrollHeight > e.clientHeight + 1 && (!s.webkitLineClamp || s.webkitLineClamp === 'none');
    if (!x && !y) continue;
    add('clipped-text', describeEl(e), e.innerText, box(e.getBoundingClientRect()),
      x ? `its text is ${e.scrollWidth - e.clientWidth}px wider than its box` : `its text is ${e.scrollHeight - e.clientHeight}px taller than its box`);
  }

  // overlap: two interactive elements, neither inside the other, covering > 25% of the smaller.
  const rects = interactive.slice(0, 400).map((e) => [e, e.getBoundingClientRect()]);
  for (let i = 0; i < rects.length; i++) {
    const [a, ra] = rects[i];
    for (let j = i + 1; j < rects.length; j++) {
      const [b, rb] = rects[j];
      const w = Math.min(ra.right, rb.right) - Math.max(ra.left, rb.left);
      const h = Math.min(ra.bottom, rb.bottom) - Math.max(ra.top, rb.top);
      if (w <= 0 || h <= 0 || a.contains(b) || b.contains(a)) continue;
      const small = Math.min(ra.width * ra.height, rb.width * rb.height);
      if (w * h <= 0.25 * small) continue;
      add('overlap', `${describeEl(a)} and ${describeEl(b)}`, '',
        box({ left: Math.max(ra.left, rb.left), top: Math.max(ra.top, rb.top), width: w, height: h }),
        `${Math.round((100 * w * h) / small)}% of the smaller one is covered`);
    }
  }

  // broken-image: an <img> the browser finished and could not decode.
  for (const img of [...document.images]) {
    if (!img.getAttribute('src') && !img.getAttribute('srcset')) continue;
    if (!img.complete || img.naturalWidth !== 0) continue;
    if (img.checkVisibility ? !img.checkVisibility({ opacityProperty: true, visibilityProperty: true }) : !img.offsetParent) continue;
    if (await img.decode().then(() => true, () => false)) continue; // an SVG without an intrinsic size decodes
    add('broken-image', describeEl(img), '', box(img.getBoundingClientRect()), 'the image did not load');
  }

  // placeholder-text: template residue a user can read.
  const RX = /\bundefined\b|\bNaN\b|\[object Object\]|\{\{.*?\}\}|^[a-z]+(\.[a-z_]+){2,}$/;
  const HOST = /\.(com|org|net|io|dev|app|ai|co|cz|sk|de|uk|eu|us|local|localhost|internal|svc|cluster|test|example)$/;
  const residue = (t) => { const m = RX.exec(t); return m && !(m[0] === t && HOST.test(t)) ? m[0] : null; };
  const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
  for (let n = walker.nextNode(), k = 0; n && k < 20000; n = walker.nextNode(), k++) {
    const p = n.parentElement;
    const t = clean(n.data);
    if (!t || !p || p.closest('script,style,noscript,template,code,pre,kbd,samp,textarea')) continue;
    const m = residue(t);
    if (m && shown(p)) add('placeholder-text', describeEl(p), t, box(p.getBoundingClientRect()), `shows “${cut(m, 40)}”`);
  }
  for (const e of body.querySelectorAll('input:not([type=hidden]):not([type=password]),textarea')) {
    for (const v of [e.value, e.getAttribute('placeholder')]) {
      const m = residue(clean(v));
      if (m && shown(e)) add('placeholder-text', describeEl(e), clean(v), box(e.getBoundingClientRect()), `shows “${cut(m, 40)}”`);
    }
  }

  // tap-target (mobile): smaller than minTap in either dimension; a link inside running text and
  // a control whose label is big enough are exempt (WCAG 2.5.8).
  if (mobile) {
    for (const e of interactive) {
      const r = e.getBoundingClientRect();
      if (r.width >= minTap && r.height >= minTap) continue;
      if (style(e).display === 'inline' && [...(e.parentElement?.childNodes ?? [])].some((n) => n.nodeType === 3 && n.data.trim())) continue;
      if ([...(e.labels ?? [])].some((l) => { const q = l.getBoundingClientRect(); return q.width >= minTap && q.height >= minTap; })) continue;
      add('tap-target', describeEl(e), e.innerText, box(r), `${Math.round(r.width)}×${Math.round(r.height)}px, below ${minTap}×${minTap}px`);
    }
  }

  // contrast: WCAG AA for each element's own text, against the backgrounds behind it in the DOM;
  // a background image or gradient on the way, or a colour it cannot read, skips the element.
  const parse = (s) => {
    let m = /^rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+)(%?))?\s*\)$/.exec(s || '');
    if (m) return [+m[1], +m[2], +m[3], m[4] == null ? 1 : m[5] ? +m[4] / 100 : +m[4]];
    m = /^color\(srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)(?:\s*\/\s*([\d.]+))?\)$/.exec(s || '');
    if (m) return [m[1] * 255, m[2] * 255, m[3] * 255, m[4] == null ? 1 : +m[4]];
    return null;
  };
  const blend = (c, b) => [0, 1, 2].map((i) => c[i] * c[3] + b[i] * (1 - c[3]));
  const backdrop = (e) => {
    const layers = [];
    for (let x = e; x; x = x.parentElement) {
      const s = style(x);
      if (s.backgroundImage && s.backgroundImage !== 'none') return null;
      const c = parse(s.backgroundColor);
      if (!c) return null;
      if (c[3] > 0) { layers.push(c); if (c[3] >= 1) break; }
    }
    return layers.reverse().reduce((b, c) => blend(c, b), [255, 255, 255]);
  };
  const lum = (c) => {
    const [r, g, b] = c.map((v) => { const s = v / 255; return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4; });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const hex = (c) => `#${c.map((v) => Math.round(v).toString(16).padStart(2, '0')).join('')}`;
  for (const e of all) {
    if (!ownText(e) || SKIP_TEXT.test(e.tagName) || e.closest(':disabled,[aria-disabled="true"]') || !shown(e)) continue;
    const s = style(e);
    const fg0 = parse(s.color);
    if (!fg0 || fg0[3] === 0) continue;
    const bg = backdrop(e);
    if (!bg) continue;
    const fg = blend(fg0, bg);
    const [hi, lo] = [lum(fg), lum(bg)].sort((p, q) => q - p);
    const ratio = (hi + 0.05) / (lo + 0.05);
    const size = parseFloat(s.fontSize) || 16;
    const large = size >= 24 || (size >= 18.66 && (parseInt(s.fontWeight, 10) || 400) >= 700);
    const need = large ? 3 : 4.5;
    if (ratio >= need) continue;
    add('contrast', describeEl(e), e.innerText, box(e.getBoundingClientRect()),
      `contrast ${ratio.toFixed(2)}:1, needs ${need}:1 (${hex(fg)} on ${hex(bg)})`);
  }

  // no-name: a control assistive technology announces with nothing.
  for (const e of body.querySelectorAll('button,a[href],input:not([type=hidden]),select,textarea,[role=button]')) {
    if (!shown(e) || hiddenTree(e) || accName(e)) continue;
    add('no-name', describeEl(e), '', box(e.getBoundingClientRect()), 'no aria-label, label, text, title or image alt');
  }
  return out;
}
