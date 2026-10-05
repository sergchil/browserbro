/* BrowserBro product page. Plain JS, no dependencies. */
(() => {
  'use strict';

  const root = document.documentElement;
  root.classList.add('js');
  const motionQuery = matchMedia('(prefers-reduced-motion: reduce)');
  const reduced = () => motionQuery.matches;

  /* ───────────── Theme toggle: auto → light → dark ───────────── */
  const toggle = document.querySelector('.theme-toggle');
  const modes = ['auto', 'light', 'dark'];
  const labels = { auto: 'Color theme: automatic', light: 'Color theme: light', dark: 'Color theme: dark' };
  function applyTheme(mode) {
    if (mode === 'auto') delete root.dataset.theme; else root.dataset.theme = mode;
    toggle.dataset.mode = mode;
    toggle.setAttribute('aria-label', labels[mode]);
    try { mode === 'auto' ? localStorage.removeItem('bb-theme') : localStorage.setItem('bb-theme', mode); } catch (e) { /* private mode */ }
  }
  applyTheme(root.dataset.theme || 'auto');
  toggle.addEventListener('click', () => {
    const next = modes[(modes.indexOf(toggle.dataset.mode) + 1) % modes.length];
    applyTheme(next);
  });

  /* ───────────── Scroll reveals: fallback when view() timelines are missing ───────────── */
  if (!CSS.supports('animation-timeline: view()') && 'IntersectionObserver' in window) {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.05 });
    document.querySelectorAll('.reveal').forEach((el) => io.observe(el));
  } else {
    document.querySelectorAll('.reveal').forEach((el) => el.classList.add('in'));
  }

  /* ───────────── Subtle parallax on the background mesh ───────────── */
  let ticking = false;
  addEventListener('scroll', () => {
    if (ticking || reduced()) return;
    ticking = true;
    requestAnimationFrame(() => { root.style.setProperty('--py', String(scrollY)); ticking = false; });
  }, { passive: true });

  /* ───────────── Magnetic buttons ───────────── */
  if (matchMedia('(hover: hover) and (pointer: fine)').matches) {
    document.querySelectorAll('.magnetic').forEach((el) => {
      el.addEventListener('pointermove', (e) => {
        if (reduced()) return;
        const r = el.getBoundingClientRect();
        const dx = e.clientX - (r.left + r.width / 2);
        const dy = e.clientY - (r.top + r.height / 2);
        el.style.setProperty('--mx', (dx * 0.22).toFixed(1) + 'px');
        el.style.setProperty('--my', (dy * 0.3).toFixed(1) + 'px');
      });
      el.addEventListener('pointerleave', () => { el.style.setProperty('--mx', '0px'); el.style.setProperty('--my', '0px'); });
    });
  }

  /* ───────────── Copy buttons ───────────── */
  document.querySelectorAll('.copy').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const text = document.getElementById(btn.dataset.copy).innerText.trim();
      let ok = false;
      try { await navigator.clipboard.writeText(text); ok = true; } catch (e) {
        const ta = document.createElement('textarea');
        ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.opacity = '0';
        document.body.appendChild(ta); ta.select();
        try { ok = document.execCommand('copy'); } catch (e2) { ok = false; }
        ta.remove();
      }
      btn.textContent = ok ? 'Copied' : 'Press ⌘C';
      btn.classList.toggle('done', ok);
      setTimeout(() => { btn.textContent = 'Copy'; btn.classList.remove('done'); }, 1600);
    });
  });

  /* ───────────── Hero video: plays only when visible and motion is allowed ───────────── */
  const videos = [...document.querySelectorAll('.hero-media video')];
  const shown = (v) => v.offsetParent !== null; // hidden theme copy has display: none
  function syncVideos() {
    for (const v of videos) {
      if (shown(v) && !reduced() && !document.hidden) {
        const p = v.play();
        if (p) p.catch(() => {}); // autoplay can be refused; the poster stays
      } else {
        v.pause();
      }
    }
  }
  syncVideos();
  motionQuery.addEventListener('change', syncVideos);
  document.addEventListener('visibilitychange', syncVideos);
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', syncVideos);
  toggle.addEventListener('click', () => requestAnimationFrame(syncVideos));
})();
