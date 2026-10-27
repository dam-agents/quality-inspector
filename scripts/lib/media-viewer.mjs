// media-viewer.mjs — the in-page viewer of a report's screenshots and videos (render-report.mjs,
// issue-draft.mjs). A click on a screenshot, or "Enlarge" under a video, shows it larger over the
// page, with zoom in and out, "fit" and "1:1". Never a link to the media file: a strict viewer
// opens an empty page for it, and the published file downloads (docs/reporting.md → Delivery).
// The video moves into the viewer and back, so it keeps playing where it was.

export const VIEWER_CSS = `main figure img{cursor:zoom-in}
.enlarge{margin:6px 0 0;font:600 13px/1.2 system-ui,sans-serif;padding:5px 12px;border-radius:999px;border:1px solid var(--line,#ccc);background:transparent;color:inherit;cursor:pointer}
#zoom{position:fixed;inset:0;z-index:100;overflow:auto;background:rgba(8,10,14,.94);color:#fff;font:13px/1.4 system-ui,sans-serif}
#zoom[hidden]{display:none}
#zoom .bar{position:sticky;top:0;left:0;z-index:1;display:flex;flex-wrap:wrap;gap:6px;align-items:center;padding:8px 16px;background:rgba(8,10,14,.85)}
#zoom .bar button{font:600 13px/1.2 system-ui,sans-serif;min-width:34px;padding:6px 10px;border-radius:6px;border:1px solid rgba(255,255,255,.3);background:rgba(255,255,255,.08);color:#fff;cursor:pointer}
#zoom .bar button:hover{background:rgba(255,255,255,.18)}
#zoom .bar .pct{min-width:48px;text-align:center}
#zoom .bar .hint{opacity:.7;margin-left:auto}
#zoom .bar .close{margin-left:8px}
#zoom .stage{padding:16px}
#zoom .stage>*{display:block;margin:0 auto;max-width:none;height:auto;aspect-ratio:auto;border:0;border-radius:0;background:#000}
#zoom .stage>img{cursor:zoom-in;background:#fff}
#zoom.real .stage>img{cursor:zoom-out}`;

export const VIEWER_HTML = `<div id="zoom" role="dialog" aria-modal="true" aria-label="Larger view" tabindex="-1" hidden>
<div class="bar"><button type="button" data-z="out" title="Zoom out (−)" aria-label="Zoom out">−</button><span class="pct">100%</span><button type="button" data-z="in" title="Zoom in (+)" aria-label="Zoom in">+</button><button type="button" data-z="fit" title="Fit to the window (0)">Fit</button><button type="button" data-z="real" title="Real size (1)">1:1</button><span class="hint">+ and − zoom. Ctrl and the wheel zoom too. Esc closes.</span><button type="button" class="close" data-z="close">Close ✕</button></div>
<div class="stage"></div></div>
<script>
(() => {
  const z = document.getElementById('zoom'), stage = z.querySelector('.stage'), pct = z.querySelector('.pct');
  let el = null, home = null, opener = null, scale = 1, fit = true;
  const size = () => (el.tagName === 'VIDEO' ? [el.videoWidth || 1280, el.videoHeight || 720] : [el.naturalWidth || 800, el.naturalHeight || 600]);
  const draw = () => {
    if (!el) return;
    const [w, h] = size();
    if (fit) scale = Math.max(0.05, Math.min((z.clientWidth - 32) / w, (z.clientHeight - stage.offsetTop - 32) / h));
    el.style.width = Math.round(w * scale) + 'px';
    pct.textContent = Math.round(scale * 100) + '%';
    z.classList.toggle('real', !fit && scale >= 1);
  };
  const set = (s) => { fit = false; scale = Math.min(8, Math.max(0.1, s)); draw(); };
  const open = (src) => {
    opener = document.activeElement;
    if (src.tagName === 'VIDEO') {
      // Moved, not copied: the video keeps its place and keeps playing.
      home = document.createComment('video'); src.replaceWith(home); el = src;
      if (!el.videoWidth) el.addEventListener('loadedmetadata', draw, { once: true });
    } else {
      el = new Image(); el.alt = src.alt || ''; el.addEventListener('load', draw); el.src = src.currentSrc || src.src;
    }
    stage.append(el); z.hidden = false; fit = true; draw(); z.focus();
  };
  const close = () => {
    if (!el) return;
    if (home) { el.style.width = ''; home.replaceWith(el); home = null; } else el.remove();
    el = null; z.hidden = true; z.classList.remove('real');
    if (opener && opener.focus) opener.focus();
  };
  for (const v of document.querySelectorAll('main video')) {
    const b = document.createElement('button');
    b.type = 'button'; b.className = 'enlarge'; b.textContent = '⤢ Enlarge the video';
    b.addEventListener('click', () => open(v)); v.after(b);
    v.addEventListener('dblclick', (e) => { e.preventDefault(); if (!el) open(v); });
  }
  document.addEventListener('click', (e) => {
    if (el || !e.target.closest) return;
    const fig = e.target.closest('main figure');
    const img = e.target.tagName === 'IMG' ? e.target : (fig ? fig.querySelector('img') : null);
    if (!img || !img.closest('main')) return;
    e.preventDefault(); open(img);
  });
  z.addEventListener('click', (e) => {
    const b = e.target.closest('button');
    if (b) {
      const k = b.dataset.z;
      if (k === 'close') close(); else if (k === 'in') set(scale * 1.25); else if (k === 'out') set(scale / 1.25);
      else if (k === 'real') set(1); else if (k === 'fit') { fit = true; draw(); }
      return;
    }
    if (e.target === el && el.tagName === 'IMG') { if (fit || scale < 1) set(1); else { fit = true; draw(); } return; }
    if (e.target === z || e.target === stage) close();
  });
  z.addEventListener('wheel', (e) => { if (!el || !(e.ctrlKey || e.metaKey)) return; e.preventDefault(); set(scale * (e.deltaY < 0 ? 1.1 : 1 / 1.1)); }, { passive: false });
  document.addEventListener('keydown', (e) => {
    if (!el) return;
    if (e.key === 'Escape') { e.preventDefault(); close(); }
    else if (e.key === '+' || e.key === '=') { e.preventDefault(); set(scale * 1.25); }
    else if (e.key === '-') { e.preventDefault(); set(scale / 1.25); }
    else if (e.key === '0') { e.preventDefault(); fit = true; draw(); }
    else if (e.key === '1') { e.preventDefault(); set(1); }
  });
  addEventListener('resize', () => { if (fit) draw(); });
})();
</script>`;
