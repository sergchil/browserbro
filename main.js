/* BrowserBro product page. Plain JS, no dependencies. */
(() => {
  'use strict';

  const root = document.documentElement;
  root.classList.add('js');
  const motionQuery = matchMedia('(prefers-reduced-motion: reduce)');
  const reduced = () => motionQuery.matches;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

  /* ───────────── Placeholder download links ───────────── */
  document.querySelectorAll('[data-todo="download-url"]').forEach((a) => {
    a.addEventListener('click', (e) => { if (a.getAttribute('href') === '#') { e.preventDefault(); location.hash = '#build'; } });
  });

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

  /* ───────────── Hero demo: the picker at the pointer ───────────── */
  const stage = document.getElementById('demo');
  if (stage) {
    const cursor = stage.querySelector('.cursor');
    const drop = stage.querySelector('.drop');
    const tiles = [...stage.querySelectorAll('.tile')];
    const lens = stage.querySelector('.lens');
    const pulse = stage.querySelector('.pulse');
    const keyhint = stage.querySelector('.keyhint');
    const linkA = stage.querySelector('[data-link="a"]');
    const linkB = stage.querySelector('[data-link="b"]');

    let visible = false;
    new IntersectionObserver(([e]) => { visible = e.isIntersecting; }, { threshold: 0.2 }).observe(stage);
    const active = () => visible && !document.hidden && !reduced();
    async function wait(ms) { await sleep(ms); while (!active()) await sleep(250); }

    // Offset of el inside ancestor, ignoring CSS transforms.
    function offsetIn(el, ancestor) {
      let x = 0, y = 0, n = el;
      while (n && n !== ancestor) { x += n.offsetLeft; y += n.offsetTop; n = n.offsetParent; }
      return { x, y };
    }
    function centerOf(el) { const o = offsetIn(el, stage); return { x: o.x + el.offsetWidth / 2, y: o.y + el.offsetHeight / 2 }; }
    // Where a person clicks a link: near its start, not its middle.
    function clickPointOf(el) { const o = offsetIn(el, stage); return { x: o.x + Math.min(el.offsetWidth * 0.18, 36), y: o.y + el.offsetHeight / 2 }; }

    // The arrow tip of the cursor glyph sits at about (21%, 12%) of its box.
    function moveCursor(p, instant) {
      // SVG elements have no offsetWidth; read the box instead.
      const s = cursor.getBoundingClientRect().width;
      if (instant) cursor.style.transition = 'none';
      cursor.style.setProperty('--cx', (p.x - s * 0.21) + 'px');
      cursor.style.setProperty('--cy', (p.y - s * 0.12) + 'px');
      if (instant) { cursor.getBoundingClientRect(); cursor.style.transition = ''; }
    }
    function clickCursor() { cursor.classList.remove('click'); cursor.getBoundingClientRect(); cursor.classList.add('click'); }

    function setLens(i, instant) {
      const t = tiles[i];
      if (instant) lens.style.transition = 'none';
      lens.style.width = t.offsetWidth + 'px';
      lens.style.height = t.offsetHeight + 'px';
      lens.style.transform = `translate(${t.offsetLeft}px, ${t.offsetTop}px)`;
      if (instant) { void lens.offsetWidth; lens.style.transition = ''; }
    }

    // Place the card so tile 1's icon sits under the pointer, clamped inside the stage.
    function placeDrop(p) {
      const icon = tiles[0].querySelector('.bicon');
      const io = offsetIn(icon, drop);
      const W = stage.clientWidth, H = stage.clientHeight, inset = 8;
      let left = p.x - (io.x + icon.offsetWidth / 2);
      let top = p.y - (io.y + icon.offsetHeight / 2);
      left = Math.max(inset, Math.min(left, W - drop.offsetWidth - inset));
      top = Math.max(inset, Math.min(top, H - drop.offsetHeight - inset));
      drop.style.left = left + 'px';
      drop.style.top = top + 'px';
      drop.style.transformOrigin = `${p.x - left}px ${p.y - top}px`;
    }

    function showKey(label) { keyhint.querySelector('kbd').textContent = label; keyhint.classList.add('show'); }
    function hideKey() { keyhint.classList.remove('show'); }

    function staticFrame() {
      const a = clickPointOf(linkA);
      placeDrop(a);
      drop.classList.remove('closing');
      drop.classList.add('open');
      setLens(0, true);
      moveCursor(centerOf(tiles[0].querySelector('.bicon')), true);
    }

    async function loop() {
      for (;;) {
        await wait(0);
        // Reset
        drop.classList.remove('open', 'closing');
        pulse.classList.remove('show', 'hide');
        linkA.classList.remove('hit'); linkB.classList.remove('hit');
        moveCursor({ x: stage.clientWidth * 0.86, y: stage.clientHeight * 0.86 }, true);
        await wait(700);

        // Scene 1: no rule matches → the picker opens at the pointer.
        const a = clickPointOf(linkA);
        moveCursor(a);
        await wait(1150);
        clickCursor(); linkA.classList.add('hit');
        await wait(160);
        placeDrop(a);
        setLens(0, true);
        drop.classList.add('open');
        await wait(1100);

        showKey('→'); setLens(1); await wait(700);
        hideKey(); await wait(200);
        showKey('→'); setLens(2); await wait(800);
        hideKey(); await wait(250);

        // Hover a tile: the lens follows the pointer.
        const t3 = tiles[3].querySelector('.bicon');
        moveCursor(centerOf(t3)); await wait(450); setLens(3); await wait(700);
        moveCursor(centerOf(tiles[0].querySelector('.bicon'))); await wait(500); setLens(0); await wait(750);
        clickCursor(); tiles[0].classList.add('press');
        await wait(220);
        tiles[0].classList.remove('press');
        // Shrink back into the pointer.
        const o = centerOf(tiles[0].querySelector('.bicon'));
        drop.style.transformOrigin = `${o.x - drop.offsetLeft}px ${o.y - drop.offsetTop}px`;
        drop.classList.add('closing');
        await wait(350);
        drop.classList.remove('open', 'closing');
        linkA.classList.remove('hit');
        await wait(900);

        // Scene 2: a rule matches → the Pulse shows where the link went.
        const b = clickPointOf(linkB);
        moveCursor(b);
        await wait(1100);
        clickCursor(); linkB.classList.add('hit');
        await wait(200);
        pulse.style.left = Math.min(b.x + 10, stage.clientWidth - pulse.offsetWidth - 8) + 'px';
        pulse.style.top = (b.y + 18) + 'px';
        pulse.classList.add('show');
        await wait(2000);
        pulse.classList.replace('show', 'hide');
        linkB.classList.remove('hit');
        await wait(1200);
      }
    }

    function start() {
      if (reduced()) { staticFrame(); return; }
      loop();
    }
    // Wait one frame so layout (and container units) are settled.
    requestAnimationFrame(start);
    addEventListener('resize', () => { if (reduced()) staticFrame(); else if (drop.classList.contains('open')) setLens(0, true); });
  }

  /* ───────────── Rule sentence builder ───────────── */
  const builder = document.getElementById('builder');
  if (builder) {
    const $ = (s) => builder.querySelector(s);
    const slots = { mode: $('.s-mode'), kind: $('.s-kind'), not: $('.s-not'), val: $('.s-val'), target: $('.s-target') };
    const icon = slots.target.querySelector('.bicon');
    const tText = slots.target.querySelector('.t');
    const turl = $('.turl');
    const examples = [
      { mode: 'any', kind: 'Domain', not: false, val: 'linear.app', icon: 'chrome', target: 'Chrome · Work', url: 'https://linear.app/acme/issue/ENG-142' },
      { mode: 'all', kind: 'Path prefix', not: false, val: 'github.com/acme/', icon: 'firefox', target: 'Firefox · Dev', url: 'https://github.com/acme/app/pull/88' },
      { mode: 'any', kind: 'Source app', not: false, val: 'Slack', icon: 'arc', target: 'Arc · Side', url: 'a link clicked in Slack' },
      { mode: 'any', kind: 'Regex', not: false, val: '^https://(www\\.)?figma\\.com/file/', icon: 'chrome', target: 'Chrome · Work', url: 'https://www.figma.com/file/onboarding' },
      { mode: 'all', kind: 'Wildcard', not: false, val: '*.atlassian.net/*', icon: 'edge', target: 'Edge · Work', url: 'https://acme.atlassian.net/wiki' },
      { mode: 'all', kind: 'Source app', not: true, val: 'Slack', icon: 'safari', target: 'Safari', url: 'a link clicked in Mail' },
      { mode: 'any', kind: 'Modifier key', not: false, val: '⌥ Option held', icon: 'firefox', target: 'Firefox · Dev', url: 'any link, clicked with ⌥' },
      { mode: 'any', kind: 'URL contains', not: false, val: '/meet/', icon: 'chrome', target: 'Chrome · Personal', url: 'https://example.com/meet/abc' },
    ];
    let i = 0;
    function render(ex) {
      slots.mode.textContent = ex.mode;
      slots.kind.textContent = ex.kind;
      slots.not.classList.toggle('off', !ex.not);
      slots.val.textContent = ex.val;
      icon.className = 'bicon mini ' + ex.icon;
      tText.textContent = ex.target;
      turl.textContent = ex.url;
    }
    render(examples[0]);
    if (!reduced()) {
      let shown = false;
      new IntersectionObserver(([e]) => { shown = e.isIntersecting; }).observe(builder);
      setInterval(async () => {
        if (!shown || document.hidden || reduced()) return;
        const prev = examples[i];
        i = (i + 1) % examples.length;
        const ex = examples[i];
        const changed = Object.values(slots).filter((el) => el !== slots.not);
        const keys = ['mode', 'kind', 'val', 'target'];
        const which = changed.filter((_, k) => prev[keys[k]] !== ex[keys[k]] || keys[k] === 'val');
        which.forEach((el, k) => setTimeout(() => el.classList.add('swap'), k * 70));
        await sleep(320 + which.length * 70);
        render(ex);
        which.forEach((el, k) => setTimeout(() => el.classList.remove('swap'), k * 90));
      }, 3200);
    }
  }
})();
