/* Upright site: the app's interface rebuilt in HTML, and the scenes that animate it.
   No dependencies. Each stage builds a complete still frame first; the animation only runs
   while the stage is on screen, and not at all with reduced motion. */
(() => {
  'use strict';

  const RM = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const ICON = 'assets/icon-256.png';
  const CANCEL = new Error('autoplay interrupted');
  const IDLE_MS = 30000;

  // ---------- Helpers ----------

  const h = (html) => {
    const t = document.createElement('template');
    t.innerHTML = html.trim();
    return t.content.firstElementChild;
  };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const nf = (n) => Math.round(n).toLocaleString('en-US');
  const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
  const reflow = (el) => void el.getBoundingClientRect();

  function tween(ms, fn, e = ease) {
    return new Promise((resolve) => {
      const t0 = performance.now();
      const step = (now) => {
        const t = Math.min(1, (now - t0) / ms);
        fn(e(t));
        if (t < 1) requestAnimationFrame(step);
        else resolve();
      };
      requestAnimationFrame(step);
    });
  }

  async function swap(el, html) {
    el.style.opacity = '0';
    await sleep(170);
    el.innerHTML = html;
    el.style.opacity = '1';
  }

  function pos(el, x, y, w, hh) {
    el.style.left = x + 'px';
    el.style.top = y + 'px';
    if (w != null) el.style.width = w + 'px';
    if (hh != null) el.style.height = hh + 'px';
    return el;
  }

  // ---------- Icons (drawn to look like the SF Symbols the app uses) ----------

  const P = {
    'chev-l-circ': '<circle cx="12" cy="12" r="9"/><path d="M13.6 8.4 10 12l3.6 3.6"/>',
    'chev-r-circ': '<circle cx="12" cy="12" r="9"/><path d="M10.4 8.4 14 12l-3.6 3.6"/>',
    gauge: '<circle cx="12" cy="12" r="9"/><path d="M12 12.5l3.8-4"/><path d="M7.2 15.6h0M6.6 11.2h0M8.6 7.6h0M12 6.2h0"/>',
    'rec-circ': '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3.3" fill="currentColor" stroke="none"/>',
    gear: '<circle cx="12" cy="12" r="2.8"/><circle cx="12" cy="12" r="6.4"/><path d="M12 2.8v3M12 18.2v3M21.2 12h-3M5.8 12h-3M18.5 5.5l-2.1 2.1M7.6 16.4l-2.1 2.1M18.5 18.5l-2.1-2.1M7.6 7.6 5.5 5.5"/>',
    refresh: '<path d="M19 12a7 7 0 1 1-2.05-4.95"/><path d="M19 4.5V8h-3.5"/>',
    power: '<path d="M12 3.5v8"/><path d="M7.2 6.6a7 7 0 1 0 9.6 0"/>',
    bt: '<circle cx="12" cy="12" r="1.7" fill="currentColor" stroke="none"/><path d="M8.7 8.7a4.7 4.7 0 0 0 0 6.6M15.3 8.7a4.7 4.7 0 0 1 0 6.6M5.9 5.9a8.6 8.6 0 0 0 0 12.2M18.1 5.9a8.6 8.6 0 0 1 0 12.2"/>',
    antenna: '<circle cx="12" cy="9.5" r="1.7" fill="currentColor" stroke="none"/><path d="M12 11.5V20M9 6.5a4.2 4.2 0 0 0 0 6M15 6.5a4.2 4.2 0 0 1 0 6M6.4 4a7.8 7.8 0 0 0 0 11M17.6 4a7.8 7.8 0 0 1 0 11"/>',
    'laptop-arrow': '<path d="M4.5 16V7.5A1.5 1.5 0 0 1 6 6h2.5M15.5 6H18a1.5 1.5 0 0 1 1.5 1.5V16"/><path d="M2.5 18.5h19"/><path d="M12 3.5v8.5M9 9l3 3 3-3"/>',
    hand: '<path d="M9.4 12.2V5.6a1.5 1.5 0 0 1 3 0v5.6m0-1.4a1.5 1.5 0 0 1 3 0v2m0-.8a1.5 1.5 0 0 1 3 0v3.2c0 3.5-2.4 5.9-5.6 5.9-2.3 0-3.7-1-5-3l-2.3-3.4a1.4 1.4 0 0 1 2.2-1.7l1.7 2"/><path d="M5.2 4.6 3.6 3.4M8 3 7.6 1.6M4 7.6l-1.7-.2"/>',
    mc: '<rect x="3" y="5" width="7.2" height="6" rx="1.4"/><rect x="3" y="13" width="7.2" height="6" rx="1.4"/><rect x="12.6" y="5" width="8.4" height="14" rx="1.4"/>',
    expose: '<rect x="3.5" y="8.5" width="17" height="11" rx="2"/><path d="M6 6h12M8 3.5h8"/>',
    desktop: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M6.5 15.8h11"/>',
    'space-l': '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M8 5v14"/><path d="M17.5 12h-6M14 9.5 11.5 12l2.5 2.5"/>',
    'space-r': '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M16 5v14"/><path d="M6.5 12h6M10 9.5l2.5 2.5-2.5 2.5"/>',
    'arrow-r': '<path d="M4.5 12h15M14 6.5l5.5 5.5-5.5 5.5"/>',
    'arrow-l': '<path d="M19.5 12h-15M10 6.5 4.5 12l5.5 5.5"/>',
    'arrow-u': '<path d="M12 19.5v-15M6.5 10 12 4.5l5.5 5.5"/>',
    'arrow-d': '<path d="M12 4.5v15M6.5 14 12 19.5l5.5-5.5"/>',
    'tab-l': '<path d="M4.5 5v14M20 12H8.5M13 7.5 8.5 12l4.5 4.5"/>',
    'tab-r': '<path d="M19.5 5v14M4 12h11.5M11 7.5l4.5 4.5-4.5 4.5"/>',
    mouse: '<rect x="6.5" y="3" width="11" height="18" rx="5.5"/><path d="M12 3v6"/>',
    nosign: '<circle cx="12" cy="12" r="8.5"/><path d="M6 6l12 12"/>',
    keyboard: '<rect x="2.5" y="6" width="19" height="12" rx="2"/><path d="M6 10h0M9 10h0M12 10h0M15 10h0M18 10h0M8.5 14.5h7"/>',
    app: '<rect x="4" y="4" width="16" height="16" rx="4.5"/>',
    link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
    layers: '<path d="M12 3.5 3.5 8 12 12.5 20.5 8Z"/><path d="M3.5 12 12 16.5 20.5 12M3.5 16 12 20.5 20.5 16"/>',
    globe: '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.4 2.6 3.5 5.4 3.5 8.5s-1.1 5.9-3.5 8.5c-2.4-2.6-3.5-5.4-3.5-8.5s1.1-5.9 3.5-8.5Z"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    'chev-d': '<path d="M7.5 10 12 14.5 16.5 10"/>',
    updown: '<path d="M8 9.5 12 5.5l4 4M8 14.5l4 4 4-4"/>',
    check: '<path d="M5 12.5 10 17.5 19 7"/>',
    'chev-r': '<path d="M10 6.5 15.5 12 10 17.5"/>',
    wifi: '<path d="M2.6 9.2a14 14 0 0 1 18.8 0M5.6 12.4a9.6 9.6 0 0 1 12.8 0M8.7 15.6a5 5 0 0 1 6.6 0"/><circle cx="12" cy="18.8" r="1.3" fill="currentColor" stroke="none"/>',
    cc: '<rect x="3" y="5" width="18" height="6" rx="3"/><rect x="3" y="13" width="18" height="6" rx="3"/><circle cx="16" cy="8" r="1.4" fill="currentColor"/><circle cx="8" cy="16" r="1.4" fill="currentColor"/>',
    search: '<circle cx="10.5" cy="10.5" r="6"/><path d="M15 15l5 5"/>',
    'mouse-fill': '<path d="M11.2 3.1A5.7 5.7 0 0 0 6.3 8.7v1.9h4.9ZM12.8 3.1v7.5h4.9V8.7a5.7 5.7 0 0 0-4.9-5.6ZM6.3 12.1v3.2a5.7 5.7 0 0 0 11.4 0v-3.2Z" fill="currentColor" stroke="none"/>',
    scroll: '<path d="M8.5 4H17a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H8.5"/><path d="M8.5 4A2.5 2.5 0 0 0 6 6.5V8h4.5M10.5 10h5M10.5 13h5M10.5 16h3"/>',
    'hand-raised': '<path d="M8 13V6.6a1.3 1.3 0 0 1 2.6 0V11M10.6 10.4V4.9a1.3 1.3 0 0 1 2.6 0V11M13.2 10.6V5.9a1.3 1.3 0 0 1 2.6 0V12M15.8 11V8.6a1.3 1.3 0 0 1 2.6 0v5c0 4-2.6 6.4-6.2 6.4-2.6 0-4-1.2-5.4-3.4L5 13.2a1.3 1.3 0 0 1 2.1-1.5L8 13"/>',
    info: '<circle cx="12" cy="12" r="8.5"/><path d="M12 11v6M12 7.6h0"/>',
    compass: '<circle cx="12" cy="12" r="8.5"/><path d="M15.6 8.4 13.2 13.2 8.4 15.6l2.4-4.8Z" fill="currentColor"/>',
    folder: '<path d="M3 7.5A1.5 1.5 0 0 1 4.5 6H9l2 2h8.5A1.5 1.5 0 0 1 21 9.5v8a1.5 1.5 0 0 1-1.5 1.5h-15A1.5 1.5 0 0 1 3 17.5Z"/>',
    envelope: '<rect x="3" y="5.5" width="18" height="13" rx="2"/><path d="M3.5 7l8.5 6 8.5-6"/>',
    note: '<rect x="5" y="3.5" width="14" height="17" rx="2"/><path d="M8.5 8h7M8.5 11.5h7M8.5 15h4"/>',
    revert: '<path d="M9 14 4.5 9.5 9 5"/><path d="M4.5 9.5H14a5.5 5.5 0 0 1 0 11h-2"/>',
    pause: '<circle cx="12" cy="12" r="8.5"/><path d="M10 9v6M14 9v6"/>',
  };
  const ic = (n, cls = '') => `<svg class="i${cls ? ' ' + cls : ''}" viewBox="0 0 24 24" aria-hidden="true">${P[n]}</svg>`;
  const batt = (pct) =>
    `<svg class="i" viewBox="0 0 24 24" aria-hidden="true"><rect x="2.5" y="7.5" width="17" height="9" rx="2.6"/><path d="M21.6 10.6v2.8"/><rect class="lvl" x="4.4" y="9.4" width="${((13.2 * pct) / 100).toFixed(1)}" height="5.2" rx="1.1" fill="currentColor" stroke="none"/></svg>`;

  const CURSOR =
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 2.6v16.6l4.2-4.1 2.7 6.2 2.8-1.2-2.7-6.1h5.9Z" fill="#111" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg>';

  // ---------- Data from the app ----------

  const ACT = {
    default: { t: 'Default', i: 'mouse' },
    forward: { t: 'Forward', i: 'arrow-r' },
    back: { t: 'Back', i: 'arrow-l' },
    prevTab: { t: 'Previous Tab', i: 'tab-l' },
    nextTab: { t: 'Next Tab', i: 'tab-r' },
    mc: { t: 'Mission Control', i: 'mc' },
    expose: { t: 'App Exposé', i: 'expose' },
    desktop: { t: 'Show Desktop', i: 'desktop' },
    spaceL: { t: 'Space Left', i: 'space-l' },
    spaceR: { t: 'Space Right', i: 'space-r' },
    gestures: { t: 'Gestures', i: 'hand' },
    cycle: { t: 'Cycle Pointer Speed', i: 'gauge' },
    none: { t: 'Do Nothing', i: 'nosign' },
  };

  // The MX Vertical's four divertable controls, as the Buttons pane names them.
  const CONTROLS = [
    { id: 'back', name: 'Back Button', sub: 'Lower thumb button', i: 'chev-l-circ' },
    { id: 'fwd', name: 'Forward Button', sub: 'Upper thumb button', i: 'chev-r-circ' },
    { id: 'top', name: 'Top Button', sub: 'Pointer-speed (DPI) button behind the wheel', i: 'gauge' },
    { id: 'wheel', name: 'Wheel Click', sub: 'Press the scroll wheel', i: 'rec-circ' },
  ];

  const CONN = {
    bt: { i: 'bt', t: 'Bluetooth' },
    unifying: { i: 'antenna', t: 'Unifying' },
    bolt: { i: 'antenna', t: 'Bolt' },
  };

  // Demo Mode's simulated mice.
  const MICE = [
    { id: 'lift', name: 'Lift', conn: 'bt', batt: 45 },
    { id: 'mxv', name: 'MX Vertical', conn: 'unifying', batt: 85 },
    { id: 'mx3s', name: 'MX Master 3S', conn: 'bolt', batt: 60 },
  ];

  const DPI_PRESETS = [800, 1200, 1600, 2400];
  const dpiToV = (d) => (d - 400) / 3600;

  // ---------- Stage, cursor and timing ----------

  // `crop` is the part of the stage to show on narrow screens, so the interface stays legible.
  function stage(host, W, H, crop) {
    const canvas = h('<div class="canvas" aria-hidden="true"></div>');
    canvas.style.setProperty('--w', W);
    canvas.style.setProperty('--h', H);
    const screen = h('<div class="screen"></div>');
    canvas.append(screen);
    host.append(canvas);
    const st = { host, canvas, screen, W, H, scale: 1, view: { x: 0, y: 0, w: W, h: H } };
    const fit = () => {
      const narrow = crop && host.parentElement && host.parentElement.clientWidth < 560;
      st.view = narrow ? { x: crop.x, y: crop.y || 0, w: crop.w, h: crop.h || H } : { x: 0, y: 0, w: W, h: H };
      host.classList.toggle('crop', !!narrow);
      host.style.setProperty('--ar', `${st.view.w} / ${st.view.h}`);
      st.scale = Math.max(0.05, host.clientWidth / st.view.w);
      canvas.style.setProperty('--s', st.scale);
      canvas.style.setProperty('--vx', -st.view.x + 'px');
      canvas.style.setProperty('--vy', -st.view.y + 'px');
    };
    fit();
    if ('ResizeObserver' in window) new ResizeObserver(fit).observe(host.parentElement || host);
    else window.addEventListener('resize', fit);
    return st;
  }

  // Position of an element in the stage's own (unscaled) coordinates.
  function rel(st, el) {
    const r = el.getBoundingClientRect();
    const c = st.canvas.getBoundingClientRect();
    const s = st.scale;
    return { x: (r.left - c.left) / s, y: (r.top - c.top) / s, w: r.width / s, h: r.height / s };
  }

  class Director {
    constructor(st, x, y) {
      this.st = st;
      this.visible = false;
      this.waiters = [];
      this.cur = h(`<div class="cur" style="margin:-2.6px 0 0 -4px">${CURSOR}</div>`);
      st.canvas.append(this.cur);
      this.place(x ?? st.W * 0.62, y ?? st.H * 0.7, 0);
      if (RM) this.cur.style.display = 'none';
      if ('IntersectionObserver' in window) {
        new IntersectionObserver(
          (entries) => {
            for (const e of entries) this.visible = e.isIntersecting;
            this.flush();
          },
          { threshold: 0.2 }
        ).observe(st.host);
      } else {
        this.visible = true;
      }
      document.addEventListener('visibilitychange', () => this.flush());
    }
    get running() {
      return this.visible && !document.hidden;
    }
    flush() {
      if (!this.running) return;
      const w = this.waiters;
      this.waiters = [];
      w.forEach((f) => f());
    }
    gate() {
      return this.running ? Promise.resolve() : new Promise((r) => this.waiters.push(r));
    }
    // Hands the stage to the visitor: the autoplay stops at its next step and comes back after
    // a while without input.
    interrupt() {
      if (!this.manual) {
        this.manual = true;
        this.cur.style.opacity = '0';
        if (this.onManual) this.onManual();
      }
      clearTimeout(this.idleTimer);
      this.idleTimer = setTimeout(() => this.resume(), IDLE_MS);
    }
    resume() {
      this.manual = false;
      if (this.onResume) this.onResume();
      this.cur.style.opacity = '1';
      const w = this.idleWaiters || [];
      this.idleWaiters = [];
      w.forEach((f) => f());
    }
    untilIdle() {
      if (!this.manual) return Promise.resolve();
      return new Promise((r) => (this.idleWaiters = (this.idleWaiters || []).concat(r)));
    }
    async wait(ms) {
      if (this.manual) throw CANCEL;
      await sleep(ms);
      if (this.manual) throw CANCEL;
      await this.gate();
      if (this.manual) throw CANCEL;
    }
    place(x, y, dur) {
      this.cur.style.transitionDuration = dur + 'ms';
      this.cur.style.transform = `translate(${x}px, ${y}px)`;
      this.x = x;
      this.y = y;
    }
    at(el, fx = 0.5, fy = 0.5) {
      const r = rel(this.st, el);
      return { x: r.x + r.w * fx, y: r.y + r.h * fy };
    }
    async move(target, o = {}) {
      const p = target instanceof Element ? this.at(target, o.fx, o.fy) : target;
      const d = Math.hypot(p.x - this.x, p.y - this.y);
      const dur = o.dur ?? Math.round(Math.max(280, Math.min(950, 260 + d * 1.15)));
      this.place(p.x, p.y, dur);
      await this.wait(dur + 40);
    }
    // Moves the cursor by hand, frame by frame, calling fn(t) so a dragged control can follow.
    async drag(to, ms, fn) {
      const x0 = this.x;
      const y0 = this.y;
      this.cur.classList.add('down');
      this.cur.style.transitionDuration = '0ms';
      await tween(ms, (t) => {
        this.x = x0 + (to.x - x0) * t;
        this.y = y0 + (to.y - y0) * t;
        this.cur.style.transform = `translate(${this.x}px, ${this.y}px)`;
        fn(t);
      });
      this.cur.classList.remove('down');
      await this.wait(60);
    }
    async click() {
      this.cur.classList.add('down');
      const r = h('<div class="ripple"></div>');
      r.style.left = this.x + 'px';
      r.style.top = this.y + 'px';
      this.st.canvas.append(r);
      setTimeout(() => r.remove(), 500);
      await sleep(120);
      this.cur.classList.remove('down');
      await this.wait(80);
    }
  }

  function loop(dir, body) {
    if (RM) return;
    (async () => {
      await dir.gate();
      for (let first = true; ; first = false) {
        try {
          if (first) await dir.wait(450);
          await body();
        } catch (err) {
          if (err !== CANCEL) {
            console.error(err);
            await sleep(1500);
          }
        }
        await dir.untilIdle();
      }
    })();
  }

  // ---------- macOS pieces ----------

  const MENUS = {
    Finder: ['File', 'Edit', 'View', 'Go', 'Window', 'Help'],
    Safari: ['File', 'Edit', 'View', 'History', 'Bookmarks', 'Window', 'Help'],
    Notes: ['File', 'Edit', 'Format', 'View', 'Window', 'Help'],
    Upright: ['Edit', 'Window', 'Help'],
  };

  function menuBar(app, label = '') {
    const el = h(`<div class="mbar">
      <span class="app"></span><span class="menus"></span>
      <div class="right">
        <span class="mbi up">${ic('mouse-fill')}<span class="lab"></span></span>
        <span class="mbi">${ic('wifi')}</span>
        <span class="mbi">${ic('search')}</span>
        <span class="mbi">${ic('cc')}</span>
        <span class="clock">Mon 9:41</span>
      </div>
    </div>`);
    const appEl = el.querySelector('.app');
    const menus = el.querySelector('.menus');
    const lab = el.querySelector('.lab');
    const setApp = (name) => {
      appEl.textContent = name;
      menus.innerHTML = (MENUS[name] || MENUS.Finder).map((m) => `<span class="mi">${m}</span>`).join('');
    };
    const setLabel = (t) => {
      lab.textContent = t;
      lab.style.display = t ? '' : 'none';
    };
    setApp(app);
    setLabel(label);
    return {
      el,
      up: el.querySelector('.mbi.up'),
      setLabel,
      async app(name) {
        appEl.style.opacity = '0';
        menus.style.opacity = '0';
        await sleep(140);
        setApp(name);
        appEl.style.opacity = '1';
        menus.style.opacity = '1';
      },
    };
  }

  function mouseRow(m, active) {
    return h(`<div class="mp-mouse${active ? ' active' : ''}" data-id="${m.id}">
      ${ic(CONN[m.conn].i)}
      <div style="min-width:0"><div class="nm">${m.name}</div><div class="st"><span class="dot"></span><span class="stt">${CONN[m.conn].t} · Connected</span></div></div>
      <span class="batt">${batt(m.batt)}<span class="pct">${m.batt}%</span></span>
    </div>`);
  }

  // The Upright menu-bar panel.
  function panel(o) {
    const acts = Object.assign({ back: 'default', fwd: 'forward', top: 'gestures', wheel: 'mc' }, o.acts);
    const el = h(`<div class="mp">
      <div class="mp-head">
        <div class="mp-logo">${ic('mouse-fill')}</div>
        <div><div class="mp-title">Upright</div><div class="mp-sub"><span class="dot"></span><span class="cnt"></span></div></div>
        <div class="mtog on"></div>
      </div>
      <div class="mp-sep"></div>
      <div class="mp-list"></div>
      <div class="mp-sep"></div>
      <div class="mp-section">
        <div class="mp-label">MX Vertical</div>
        <div class="mp-row">${ic('gauge')}<span>Pointer speed</span><span class="val dpiv"></span></div>
        <div class="mp-chips">${DPI_PRESETS.map((v) => `<div class="mp-chip" data-v="${v}">${v}</div>`).join('')}<div class="mp-ind"></div></div>
        <div class="mp-row">${ic('laptop-arrow')}<span>Easy-Switch</span><span class="val">Channel 1 · Demo Mac</span></div>
      </div>
      <div class="mp-sep"></div>
      <div class="mp-section">
        <div class="mp-label blab"><span class="bl">Buttons · MX Vertical</span><span class="mp-pause">${ic('pause')}Paused — mouse defaults</span></div>
        ${CONTROLS.map((c) => `<div class="mp-row" data-c="${c.id}">${ic(c.i)}<span>${c.name}</span><span class="val"></span></div>`).join('')}
      </div>
      <div class="mp-sep"></div>
      <div class="mp-section">
        <div class="mp-row">${ic('gear')}<span>Settings…</span><span class="key">⌘,</span></div>
        <div class="mp-row">${ic('refresh')}<span>Reconnect All Mice</span></div>
        <div class="mp-row">${ic('power')}<span>Quit Upright</span><span class="key">⌘Q</span></div>
      </div>
    </div>`);
    const list = el.querySelector('.mp-list');
    const rows = {};
    for (const m of o.mice || MICE) {
      rows[m.id] = mouseRow(m, m.id === (o.active || 'mxv'));
      list.append(rows[m.id]);
    }
    const cnt = el.querySelector('.cnt');
    const headDot = el.querySelector('.mp-head .dot');
    const ind = el.querySelector('.mp-ind');
    const dpiv = el.querySelector('.dpiv');
    const blab = el.querySelector('.blab .bl');
    const tog = el.querySelector('.mp-head .mtog');
    const actHTML = (k) => (k === 'gestures' ? `${ic('hand')}${ACT[k].t}` : ACT[k].t);

    const api = {
      el,
      rows,
      chip: (v) => el.querySelector(`.mp-chip[data-v="${v}"]`),
      row: (c) => el.querySelector(`.mp-row[data-c="${c}"]`),
      count() {
        const n = Object.values(rows).filter((r) => !r.classList.contains('gone')).length;
        cnt.textContent = n === 1 ? '1 mouse connected' : `${n} mice connected`;
        headDot.className = 'dot';
      },
      connecting(id, on) {
        const r = rows[id];
        const m = (o.mice || MICE).find((x) => x.id === id);
        r.querySelector('.dot').className = on ? 'dot wait' : 'dot';
        r.querySelector('.stt').textContent = `${CONN[m.conn].t} · ${on ? 'Connecting…' : 'Connected'}`;
        r.querySelector('.batt').style.opacity = on ? '0' : '1';
      },
      show(id, on) {
        rows[id].classList.toggle('gone', !on);
      },
      batt(id, pct) {
        const b = rows[id].querySelector('.batt');
        b.querySelector('.lvl').setAttribute('width', ((13.2 * pct) / 100).toFixed(1));
        b.querySelector('.pct').textContent = Math.round(pct) + '%';
      },
      dpi(v) {
        dpiv.textContent = nf(v) + ' DPI';
        const chip = api.chip(v);
        if (chip) ind.style.transform = `translateX(${chip.offsetLeft - 4 + (chip.offsetWidth - 26) / 2}px)`;
      },
      tog,
      pause(on) {
        el.classList.toggle('paused', on);
        tog.classList.toggle('on', !on);
      },
      act(c, k, animate) {
        const v = api.row(c).querySelector('.val');
        v.classList.toggle('def', k === 'default');
        if (animate) swap(v, actHTML(k));
        else v.innerHTML = actHTML(k);
      },
      async flash(c) {
        const r = api.row(c);
        r.classList.add('flash');
        await sleep(260);
        r.classList.remove('flash');
      },
      header(t, animate) {
        if (animate) swap(blab, t);
        else blab.textContent = t;
      },
      open() {
        el.classList.remove('closed');
      },
      close() {
        el.classList.add('closed');
      },
    };
    for (const c of CONTROLS) api.act(c.id, acts[c.id]);
    api.count();
    // Wait for layout before placing the chip indicator.
    requestAnimationFrame(() => api.dpi(o.dpi || 1600));
    api.dpi(o.dpi || 1600);
    return api;
  }

  const SIDE = [
    { id: 'buttons', t: 'Buttons', c: 'fill', i: 'mouse-fill' },
    { id: 'scrolling', t: 'Scrolling', c: 'teal', i: 'scroll' },
    { id: 'mice', t: 'Mice', c: 'green', i: 'bt' },
    { id: 'general', t: 'General', c: 'gray', i: 'gear' },
    { id: 'permissions', t: 'Permissions', c: 'orange', i: 'hand-raised' },
    { id: 'about', t: 'About', c: 'indigo', i: 'info' },
  ];

  // The Settings window, with its sidebar. Panes fill `main`.
  function settingsWindow(pane, geo) {
    const el = h(`<div class="mwin">
      <div class="mwin-side">
        <div class="lights"><i></i><i></i><i></i></div>
        <div class="side-items">${SIDE.map((s) => `<div class="side-item${s.id === pane ? ' on' : ''}"><span class="sq ${s.c}">${ic(s.i)}</span>${s.t}</div>`).join('')}</div>
      </div>
      <div class="mwin-main"></div>
    </div>`);
    pos(el, geo.x, geo.y, geo.w, geo.h);
    return { el, geo, main: el.querySelector('.mwin-main') };
  }

  const popHTML = (k, chevron = 'chev-d') =>
    `<span class="pop"><span class="lbl">${ic(ACT[k].i)}${ACT[k].t}</span><span class="cv">${ic(chevron)}</span></span>`;

  function buttonsPane(win, acts) {
    win.main.innerHTML = `
      <div class="mwin-title">Buttons</div>
      <div class="mg"><div class="mg-row">
        <span class="sq fill">${ic('mouse-fill')}</span>
        <div class="tt"><div class="t1">Configure</div><div class="t2">Connected: MX Vertical</div></div>
        <span class="pop"><span class="lbl">MX Vertical</span><span class="cv">${ic('updown')}</span></span>
      </div></div>
      <div class="mg-label">Profile</div>
      <div class="mg"><div class="mg-row">
        <div class="t1">Edit mappings for</div>
        <span class="pop"><span class="lbl">${ic('globe')}All Apps (Global)</span><span class="cv">${ic('updown')}</span></span>
        <span class="pop" style="margin-left:16px"><span class="lbl">${ic('plus')}Add App</span><span class="cv">${ic('chev-d')}</span></span>
      </div></div>
      <div class="mg-note">In effect now: the global actions (Finder has no active profile).</div>
      <div class="mg-label">Buttons</div>
      <div class="mg">${CONTROLS.map(
        (c) => `<div class="mg-row" data-c="${c.id}">
          <span class="sq">${ic(c.i)}</span>
          <div class="tt"><div class="t1">${c.name}</div><div class="t2">${c.sub}</div></div>
          ${popHTML(acts[c.id])}
        </div>`
      ).join('')}</div>`;
    return {
      row: (c) => win.main.querySelector(`.mg-row[data-c="${c}"]`),
      pop: (c) => win.main.querySelector(`.mg-row[data-c="${c}"] .pop`),
      set(c, k) {
        swap(win.main.querySelector(`.mg-row[data-c="${c}"] .lbl`), `${ic(ACT[k].i)}${ACT[k].t}`);
      },
    };
  }

  // The action pop-up menu, laid out like ActionPicker.swift.
  function actionMenu(st) {
    const CATS = [
      ['nav', 'Navigation'],
      ['win', 'Windows & Spaces'],
      ['sys', 'System'],
      ['mbtn', 'Mouse Buttons'],
      ['media', 'Media'],
      ['edit', 'Editing'],
      ['dpi', 'Pointer Speed'],
      ['easy', 'Easy-Switch'],
    ];
    const item = (k, t, i, sub) =>
      `<div class="mmi" data-k="${k}"><span class="ck">${ic('check')}</span>${i ? `<span class="ic">${ic(i)}</span>` : ''}<span>${t}</span>${sub ? `<span class="sub">${ic('chev-r')}</span>` : ''}</div>`;
    const main = h(`<div class="mmenu">
      ${item('default', 'Default', 'mouse')}
      ${item('none', 'Do Nothing', 'nosign')}
      <div class="mms"></div>
      ${CATS.map(([k, t]) => item(k, t, null, true)).join('')}
      <div class="mms"></div>
      ${item('kb', 'Keyboard Shortcut…', 'keyboard')}
      ${item('app', 'Open App…', 'app')}
      ${item('url', 'Open URL…', 'link')}
      ${item('sc', 'Run Shortcut…', 'layers')}
      <div class="mms"></div>
      ${item('gest', 'Gestures…', 'hand')}
    </div>`);
    const sub = h(`<div class="mmenu" style="transform-origin:100% 0">
      ${['mc', 'expose', 'desktop', 'spaceL', 'spaceR'].map((k) => item(k, ACT[k].t, ACT[k].i)).join('')}
    </div>`);
    st.screen.append(main, sub);
    let mx = 0;
    let my = 0;
    const clear = (m) => m.querySelectorAll('.hl').forEach((e) => e.classList.remove('hl'));
    return {
      item: (k) => main.querySelector(`[data-k="${k}"]`),
      subItem: (k) => sub.querySelector(`[data-k="${k}"]`),
      select(k) {
        [main, sub].forEach((m) => m.querySelectorAll('.mmi').forEach((e) => e.classList.toggle('sel', e.dataset.k === k)));
      },
      openAbove(anchor) {
        const a = rel(st, anchor);
        mx = Math.round(a.x + a.w + 6 - main.offsetWidth);
        my = Math.round(a.y - main.offsetHeight - 4);
        pos(main, mx, my);
        clear(main);
        main.classList.remove('fade');
        main.classList.add('open');
      },
      openSub(cat) {
        pos(sub, mx - sub.offsetWidth + 3, my + cat.offsetTop - 5);
        clear(sub);
        sub.classList.remove('fade');
        sub.classList.add('open');
        return { x: mx - sub.offsetWidth + 3, w: sub.offsetWidth };
      },
      hl(el) {
        clear(el.parentElement);
        el.classList.add('hl');
      },
      async blink(el) {
        el.classList.remove('hl');
        await sleep(70);
        el.classList.add('hl');
        await sleep(70);
      },
      close() {
        [main, sub].forEach((m) => {
          m.classList.add('fade');
          m.classList.remove('open');
        });
      },
    };
  }

  // Ordinary app windows that sit on the desktop around Upright.
  function appWindow(kind, geo, o = {}) {
    const lights = '<div class="lights"><i></i><i></i><i></i></div>';
    let bar;
    let pages;
    if (kind === 'browser') {
      const tabs = o.tabs || ['Getting started', 'Changelog', 'Forum'];
      bar = `<div class="fw-bar">${lights}<div class="tabs">${tabs.map((t, i) => `<div class="tab${i === 0 ? ' on' : ''}"><i></i>${t}</div>`).join('')}</div></div>`;
      pages = [
        '<div class="ln h"></div><div class="blk"></div><div class="ln"></div><div class="ln m"></div><div class="ln s"></div><div class="ln"></div><div class="ln m"></div>',
        '<div class="ln h" style="width:44%"></div><div class="ln"></div><div class="ln m"></div><div class="blk warm"></div><div class="ln s"></div><div class="ln"></div>',
        '<div class="ln h" style="width:70%"></div><div class="blk green" style="height:46px"></div><div class="ln m"></div><div class="ln"></div><div class="ln s"></div><div class="ln m"></div>',
      ];
    } else if (kind === 'finder') {
      bar = `<div class="fw-bar">${lights}<div class="fw-title">${o.title || 'Documents'}</div></div>`;
      const grid = (n, c) =>
        `<div style="display:grid;grid-template-columns:repeat(4,1fr);gap:14px 8px;padding-top:4px">${Array.from(
          { length: n },
          (_, i) =>
            `<div style="display:grid;justify-items:center;gap:5px"><div style="font-size:40px;color:${c};line-height:0">${ic('folder')}</div><div class="ln" style="width:70%;height:6px;margin:0"></div></div>`
        ).join('')}</div>`;
      pages = [grid(8, '#5aa8f5'), grid(6, '#74b9f7'), grid(7, '#5aa8f5')];
    } else {
      bar = `<div class="fw-bar">${lights}<div class="fw-title">${o.title || 'Notes'}</div></div>`;
      pages = [
        '<div class="ln h" style="width:50%;background:color-mix(in srgb,#f5b400 55%,transparent)"></div><div class="ln"></div><div class="ln m"></div><div class="ln"></div><div class="ln s"></div><div class="ln m"></div><div class="ln"></div><div class="ln s"></div>',
      ];
    }
    const el = h(`<div class="fw">${bar}<div class="fw-body" style="height:calc(100% - 30px)">${pages
      .map((p, i) => `<div class="page" style="transform:translateX(${i * 105}%)">${p}</div>`)
      .join('')}</div></div>`);
    pos(el, geo.x, geo.y, geo.w, geo.h);
    const pageEls = Array.from(el.querySelectorAll('.page'));
    const tabEls = Array.from(el.querySelectorAll('.tab'));
    let at = 0;
    const visits = pages.map(() => 0);
    return {
      el,
      geo,
      // Back or forward within the current tab: the page slides out and a different one comes in.
      hist(d) {
        const pg = pageEls[at];
        if (!pg.animate) return;
        const out = pg.animate([{ transform: 'translateX(0)', opacity: 1 }, { transform: `translateX(${-d * 36}px)`, opacity: 0 }], { duration: 160, easing: 'ease-in' });
        out.onfinish = () => {
          visits[at] = (visits[at] + (d > 0 ? 1 : pages.length - 1)) % pages.length;
          pg.innerHTML = pages[(at + visits[at]) % pages.length];
          pg.animate([{ transform: `translateX(${d * 36}px)`, opacity: 0 }, { transform: 'translateX(0)', opacity: 1 }], { duration: 220, easing: 'ease-out' });
        };
      },
      go(i) {
        at = Math.max(0, Math.min(pageEls.length - 1, i));
        pageEls.forEach((p, j) => (p.style.transform = `translateX(${(j - at) * 105}%)`));
        tabEls.forEach((t, j) => t.classList.toggle('on', j === at));
      },
      get page() {
        return at;
      },
    };
  }

  // Moves a window so its center lands on (cx, cy) at scale s; used for Mission Control etc.
  function fly(win, cx, cy, s) {
    const g = win.geo;
    win.el.style.transform = `translate(${cx - (g.x + g.w / 2)}px, ${cy - (g.y + g.h / 2)}px) scale(${s})`;
  }
  function shove(win, dx, dy) {
    win.el.style.transform = `translate(${dx}px, ${dy}px)`;
  }
  function home(win) {
    win.el.style.transform = '';
  }

  function desktopIcons(st, items) {
    for (const d of items) {
      const el = h(`<div class="dicon">${ic('folder')}<span>${d.t}</span></div>`);
      pos(el, d.x, d.y);
      st.screen.append(el);
    }
  }

  function spacesStrip() {
    return h('<div class="spaces"><div data-n="Desktop 1"></div><div data-n="Desktop 2"></div><div data-n="Desktop 3"></div></div>');
  }

  function notification(title, body) {
    return h(`<div class="mnote"><img src="${ICON}" alt=""><div><div class="t">${title}</div><div class="b">${body}</div></div><span class="ago">now</span></div>`);
  }

  // The mouse, drawn top-down in the app icon's style. Parts: wheel, top, fwd, back.
  function mouseArt(mini) {
    const ring = (p, cx, cy, r) => `<circle class="ring" data-r="${p}" cx="${cx}" cy="${cy}" r="${r}"/>`;
    const arrow = (d, shaft, head) => `<g class="arrow" data-a="${d}"><path class="shaft" d="${shaft}"/><path d="${head}"/></g>`;
    const el = h(`<svg class="mouse${mini ? ' mini' : ''}" viewBox="${mini ? '22 2 156 296' : '-60 -64 320 432'}" aria-hidden="true">
      <g transform="rotate(-16 100 150)">
        <rect class="body" x="40" y="16" width="120" height="268" rx="60"/>
        <path class="seam" d="M100 18V58M46 146Q100 160 154 146"/>
        <rect class="part" data-p="wheel" x="91" y="58" width="18" height="40" rx="9"/>
        <rect class="part" data-p="top" x="92" y="110" width="16" height="16" rx="5"/>
        <rect class="part" data-p="fwd" x="29" y="150" width="17" height="32" rx="8.5"/>
        <rect class="part" data-p="back" x="29" y="188" width="17" height="32" rx="8.5"/>
        ${mini ? '' : ring('wheel', 100, 78, 20) + ring('top', 100, 118, 14) + ring('fwd', 37.5, 166, 18) + ring('back', 37.5, 204, 18)}
      </g>
      ${
        mini
          ? ''
          : arrow('up', 'M100 -6V-54', 'M84 -38 100 -54 116 -38') +
            arrow('down', 'M100 306V354', 'M84 338 100 354 116 338') +
            arrow('left', 'M10 150H-40', 'M-24 134-40 150-24 166') +
            arrow('right', 'M190 150H240', 'M224 134 240 150 224 166')
      }
    </svg>`);
    const part = (p) => el.querySelector(`[data-p="${p}"]`);
    const ringEl = (p) => el.querySelector(`[data-r="${p}"]`);
    return {
      el,
      async press(p, ms = 240) {
        part(p).classList.add('hot');
        const r = ringEl(p);
        if (r) {
          r.classList.remove('go', 'hold');
          reflow(el);
          r.classList.add('go');
        }
        await sleep(ms);
        part(p).classList.remove('hot');
      },
      hold(p, on) {
        part(p).classList.toggle('hot', on);
        const r = ringEl(p);
        if (r) {
          r.classList.remove('go');
          r.classList.toggle('hold', on);
        }
      },
      arrow(d, on) {
        const a = el.querySelector(`[data-a="${d}"]`);
        if (a) a.classList.toggle('on', on);
      },
    };
  }

  // A small floating label that says which mouse button was pressed. `x` may be a function of
  // the visible area, for stages that crop on narrow screens.
  function pressTag(st, x, y) {
    const el = h('<div class="ptag"><span class="mm"></span><span class="txt"></span></div>');
    const mini = mouseArt(true);
    el.querySelector('.mm').append(mini.el);
    const place = () => pos(el, typeof x === 'function' ? x(st.view) : x, y);
    place();
    st.screen.append(el);
    const txt = el.querySelector('.txt');
    let timer;
    return {
      el,
      show(p, name, action) {
        clearTimeout(timer);
        place();
        txt.innerHTML = `${name}${action ? ` <small>· ${action}</small>` : ''}`;
        el.classList.add('on');
        mini.press(p, 320);
      },
      hide(after = 0) {
        clearTimeout(timer);
        timer = setTimeout(() => el.classList.remove('on'), after);
      },
    };
  }

  function dock(st, items, cx) {
    const el = h(`<div class="mdock">${items.map((d) => `<div class="dk ${d.c}${d.run ? ' run' : ''}" data-k="${d.k}">${ic(d.i)}</div>`).join('')}</div>`);
    if (cx != null) el.style.left = cx + 'px';
    st.screen.append(el);
    return {
      el,
      get: (k) => el.querySelector(`[data-k="${k}"]`),
      bounce(k) {
        const d = el.querySelector(`[data-k="${k}"]`);
        d.classList.remove('bounce');
        reflow(d);
        d.classList.add('bounce');
      },
    };
  }

  function sliderHTML(v, w, cls = '') {
    return `<div class="msl ${cls}" style="--v:${v};--w:${w}px;width:${w}px"><div class="track"></div><div class="fill"></div><div class="ticks"></div><div class="knob"></div></div>`;
  }

  // ---------- Scenes ----------

  // The hero is a working demo: the visitor can press the mouse's buttons, use the panel and
  // switch apps. Until they do, it plays itself.
  function sceneHero(host) {
    const st = stage(host, 1100, 620, { x: 500, w: 600 });
    const sc = st.screen;
    desktopIcons(st, [
      { t: 'Projects', x: 30, y: 52 },
      { t: 'Screenshots', x: 30, y: 140 },
    ]);
    const web = appWindow('browser', { x: 300, y: 76, w: 520, h: 360 });
    const finder = appWindow('finder', { x: 110, y: 250, w: 360, h: 270 }, { title: 'Documents' });
    web.el.style.zIndex = '1';
    finder.el.style.zIndex = '3';
    sc.append(web.el, finder.el);
    const wins = { Safari: web, Finder: finder };
    const dim = h('<div class="dim" style="z-index:-1"></div>');
    const spaces = spacesStrip();
    sc.append(dim, spaces);
    const mb = menuBar('Finder');
    sc.append(mb.el);
    const p = panel({ dpi: 1600 });
    pos(p.el, 752, 31);
    sc.append(p.el);
    mb.up.classList.add('on');

    const mouse = mouseArt(false);
    mouse.el.classList.add('live');
    pos(mouse.el, 520, 330, 210, 284);
    mouse.el.style.zIndex = '28';
    sc.append(mouse.el);
    const tag = pressTag(st, (v) => Math.max(470, v.x + 24), 560);
    const dir = new Director(st, 930, 470);

    const NAMES = { back: 'Back Button', fwd: 'Forward Button', top: 'Top Button', wheel: 'Wheel Click' };
    const CIDS = Object.keys(NAMES);
    const GLOBAL = { back: 'default', fwd: 'forward', top: 'gestures', wheel: 'mc' };
    const SAFARI = { back: 'prevTab', fwd: 'nextTab' };
    let global = { ...GLOBAL };
    let safari = { ...SAFARI };
    let app = 'Finder';
    let paused = false;
    let mode = null;
    let panelBeforeMode = false;
    const shown = {};

    const effective = (c) => (app === 'Safari' && safari[c]) || global[c];
    const panelOpen = () => !p.el.classList.contains('closed');
    const showPanel = (on) => {
      p.el.classList.toggle('closed', !on);
      mb.up.classList.toggle('on', on);
    };

    const refreshPanel = (animate) => {
      const head = app === 'Safari' ? 'In Safari · MX Vertical' : 'Buttons · MX Vertical';
      if (shown.head !== head) {
        p.header(head, animate);
        shown.head = head;
      }
      for (const c of CIDS) {
        const k = effective(c);
        if (shown[c] === k) continue;
        p.act(c, k, animate);
        shown[c] = k;
        if (animate) setTimeout(() => p.flash(c), 180);
      }
    };
    refreshPanel(false);

    const bar = document.querySelector('.demo-bar');
    const syncBar = () => {
      if (!bar) return;
      bar.querySelectorAll('[data-app]').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.app === app)));
    };

    const front = (name) => {
      if (app === name) return;
      app = name;
      web.el.style.zIndex = name === 'Safari' ? '3' : '1';
      finder.el.style.zIndex = name === 'Finder' ? '3' : '1';
      mb.app(name);
      syncBar();
      refreshPanel(true);
    };

    // Mission Control, App Exposé and Show Desktop. Asking for the one that's showing turns it off.
    const setMode = (m) => {
      const next = m && m !== mode ? m : null;
      if (!mode && next) panelBeforeMode = panelOpen();
      if (next) showPanel(false);
      else if (mode && panelBeforeMode) showPanel(true);
      mode = next;
      dim.classList.toggle('on', next === 'mc' || next === 'expose');
      dim.style.zIndex = next === 'expose' ? '2' : '-1';
      spaces.classList.toggle('on', next === 'mc');
      mb.el.style.opacity = next === 'mc' ? '0' : '1';
      home(web);
      home(finder);
      if (next === 'mc') {
        fly(web, 420, 300, 0.56);
        fly(finder, 760, 320, 0.6);
      } else if (next === 'expose') {
        fly(wins[app], 520, 320, 0.74);
      } else if (next === 'desktop') {
        shove(web, 760, 190);
        shove(finder, -430, 330);
      }
    };

    const nav = (d) => {
      if (app === 'Safari') web.hist(d);
      else finder.go(finder.page + d);
    };

    // What happens on the desktop when a button is pressed, given its current mapping.
    const press = (c) => {
      mouse.press(c);
      const k = paused ? 'default' : effective(c);
      if (!paused) p.flash(c);
      const MODES = ['mc', 'expose', 'desktop'];
      if (mode && !MODES.includes(k) && k !== 'gestures') setMode(null);
      let label;
      switch (k) {
        case 'default':
          if (c === 'back') {
            nav(-1);
            label = 'Back';
          } else if (c === 'fwd') {
            nav(1);
            label = 'Forward';
          } else if (c === 'top') {
            const next = DPI_PRESETS[(DPI_PRESETS.indexOf(currentDPI) + 1) % DPI_PRESETS.length] || 800;
            setDPI(next);
            label = `Pointer speed ${nf(next)} DPI`;
          } else {
            label = 'Middle Click';
          }
          if (paused) label += ' (paused)';
          break;
        case 'back':
        case 'forward':
          nav(k === 'back' ? -1 : 1);
          label = ACT[k].t;
          break;
        case 'prevTab':
        case 'nextTab':
          if (app === 'Safari') web.go((web.page + (k === 'nextTab' ? 1 : 2)) % 3);
          label = ACT[k].t;
          break;
        case 'gestures':
          setMode('mc');
          label = 'Gestures · Click → Mission Control';
          break;
        case 'none':
          label = 'Do Nothing';
          break;
        default:
          setMode(k);
          label = ACT[k].t;
      }
      tag.show(c, NAMES[c], label);
      tag.hide(1500);
    };

    let currentDPI = 1600;
    const setDPI = (v) => {
      currentDPI = v;
      p.dpi(v);
    };

    // The action picker, opened from a button row.
    const PICK = ['default', 'none', '-', 'back', 'forward', 'prevTab', 'nextTab', '-', 'mc', 'expose', 'desktop', '-', 'gestures'];
    const picker = h(`<div class="mmenu pick">${PICK.map((k) =>
      k === '-'
        ? '<div class="mms"></div>'
        : `<div class="mmi tap" data-k="${k}"><span class="ck">${ic('check')}</span><span class="ic">${ic(ACT[k].i)}</span><span>${k === 'gestures' ? 'Gestures…' : ACT[k].t}</span></div>`
    ).join('')}</div>`);
    sc.append(picker);
    let picking = null;
    const closePicker = () => {
      picker.classList.remove('open');
      picking = null;
    };
    const openPicker = (c) => {
      picking = c;
      const cur = effective(c);
      picker.querySelectorAll('.mmi').forEach((e) => e.classList.toggle('sel', e.dataset.k === cur));
      const pr = rel(st, p.el);
      const rr = rel(st, p.row(c));
      const mh = picker.offsetHeight;
      pos(picker, Math.round(pr.x - picker.offsetWidth - 6), Math.round(Math.max(32, Math.min(st.H - mh - 8, rr.y - 60))));
      picker.style.transformOrigin = '100% 30%';
      picker.classList.add('open');
    };
    picker.addEventListener('click', (e) => {
      const it = e.target.closest('.mmi');
      if (!it || !picking) return;
      const c = picking;
      if (app === 'Safari' && (c === 'back' || c === 'fwd')) safari[c] = it.dataset.k;
      else global[c] = it.dataset.k;
      closePicker();
      refreshPanel(true);
    });

    // ----- Pointer input -----
    st.canvas.addEventListener('pointerdown', (e) => {
      dir.interrupt();
      if (picking && !picker.contains(e.target)) closePicker();
    }, true);

    const g = mouse.el.querySelector('g');
    const HITS = { wheel: [100, 78, 30], top: [100, 120, 22], fwd: [34, 164, 26], back: [34, 206, 26] };
    for (const [c, [cx, cy, r]] of Object.entries(HITS)) {
      const hit = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
      hit.setAttribute('class', 'hit');
      hit.setAttribute('cx', cx);
      hit.setAttribute('cy', cy);
      hit.setAttribute('r', r);
      g.append(hit);
      const part = mouse.el.querySelector(`[data-p="${c}"]`);
      hit.addEventListener('pointerenter', () => part.classList.add('hover'));
      hit.addEventListener('pointerleave', () => part.classList.remove('hover'));
      hit.addEventListener('click', () => press(c));
    }

    mb.up.classList.add('tap');
    mb.up.addEventListener('click', () => {
      if (mode) setMode(null);
      showPanel(!panelOpen());
    });
    p.el.querySelectorAll('.mp-chip').forEach((chip) => {
      chip.classList.add('tap');
      chip.addEventListener('click', () => setDPI(+chip.dataset.v));
    });
    p.tog.classList.add('tap');
    p.tog.addEventListener('click', () => {
      paused = !paused;
      p.pause(paused);
    });
    for (const c of CIDS) {
      const row = p.row(c);
      row.classList.add('tap');
      row.addEventListener('click', () => (picking === c ? closePicker() : openPicker(c)));
    }
    const footRows = p.el.querySelectorAll('.mp-section:last-child .mp-row');
    footRows.forEach((r) => r.classList.add('tap'));
    footRows[0].addEventListener('click', () => {
      const f = document.getElementById('features');
      if (f) f.scrollIntoView({ behavior: RM ? 'auto' : 'smooth' });
    });
    footRows[1].addEventListener('click', () => {
      for (const id of Object.keys(p.rows)) {
        p.connecting(id, true);
        setTimeout(() => p.connecting(id, false), 700 + Math.random() * 700);
      }
    });
    footRows[2].addEventListener('click', () => showPanel(false));

    for (const [name, w] of Object.entries(wins)) {
      w.el.classList.add('tap');
      w.el.addEventListener('click', () => {
        if (mode) setMode(null);
        front(name);
      });
    }
    sc.addEventListener('click', (e) => {
      if (mode && (e.target === sc || spaces.contains(e.target))) setMode(null);
    });

    if (bar) {
      bar.querySelectorAll('[data-press]').forEach((b) =>
        b.addEventListener('click', () => {
          dir.interrupt();
          press(b.dataset.press);
          b.classList.add('pressed');
          setTimeout(() => b.classList.remove('pressed'), 180);
        })
      );
      bar.querySelectorAll('[data-app]').forEach((b) =>
        b.addEventListener('click', () => {
          dir.interrupt();
          if (mode) setMode(null);
          front(b.dataset.app);
        })
      );
    }

    dir.onManual = () => tag.hide(0);
    dir.onResume = () => {
      closePicker();
      setMode(null);
      global = { ...GLOBAL };
      safari = { ...SAFARI };
      paused = false;
      p.pause(false);
      front('Finder');
      setDPI(1600);
      finder.go(0);
      web.go(0);
      showPanel(true);
      refreshPanel(false);
    };

    // ----- Autoplay -----
    let fast = true;
    loop(dir, async () => {
      await dir.wait(900);
      press('fwd');
      await dir.wait(1500);

      const target = fast ? 2400 : 1600;
      fast = !fast;
      await dir.move(p.chip(target));
      await dir.click();
      setDPI(target);
      await dir.wait(1000);

      await dir.move(web.el, { fx: 0.62, fy: 0.05 });
      await dir.click();
      front('Safari');
      await dir.wait(1500);
      press('fwd');
      await dir.wait(1300);
      press('back');
      await dir.wait(1300);

      await dir.move({ x: 690, y: 590 });
      press('wheel');
      await dir.wait(2000);
      press('wheel');
      await dir.wait(1100);

      await dir.move(finder.el, { fx: 0.3, fy: 0.05 });
      await dir.click();
      front('Finder');
      await dir.wait(1200);
      press('back');
      await dir.wait(1600);
      await dir.move({ x: 1000, y: 360 });
    });
  }

  function sceneRemap(host) {
    const st = stage(host, 760, 560);
    const sc = st.screen;
    desktopIcons(st, [
      { t: 'Projects', x: 560, y: 110 },
      { t: 'Screenshots', x: 560, y: 198 },
    ]);
    const web = appWindow('browser', { x: 120, y: 80, w: 420, h: 300 });
    const notes = appWindow('notes', { x: 320, y: 170, w: 300, h: 260 });
    sc.append(web.el, notes.el);
    const dim = h('<div class="dim"></div>');
    const spaces = spacesStrip();
    sc.append(dim);
    const win = settingsWindow('buttons', { x: 16, y: 42, w: 680, h: 500 });
    sc.append(win.el, spaces);
    const pane = buttonsPane(win, { back: 'default', fwd: 'forward', top: 'gestures', wheel: 'default' });
    const mb = menuBar('Upright');
    sc.append(mb.el);
    const menu = actionMenu(st);
    const tag = pressTag(st, 270, 500);
    const dir = new Director(st, 560, 300);

    const all = [win, web, notes];
    const fx = {
      async mc(on) {
        dim.style.zIndex = '-1';
        dim.classList.toggle('on', on);
        spaces.classList.toggle('on', on);
        mb.el.style.opacity = on ? '0' : '1';
        if (on) {
          fly(win, 236, 330, 0.5);
          fly(web, 566, 248, 0.56);
          fly(notes, 566, 438, 0.56);
        } else all.forEach(home);
        await dir.wait(650);
      },
      async expose(on) {
        dim.style.zIndex = '5';
        win.el.style.zIndex = '6';
        dim.classList.toggle('on', on);
        if (on) fly(win, 380, 300, 0.7);
        else home(win);
        await dir.wait(650);
      },
      async desktop(on) {
        if (on) {
          shove(win, -652, -474);
          shove(web, 600, 40);
          shove(notes, 420, 360);
        } else all.forEach(home);
        await dir.wait(700);
      },
    };

    const order = ['mc', 'expose', 'desktop'];
    let n = 0;
    let current = 'default';
    loop(dir, async () => {
      const target = order[n++ % order.length];
      await dir.wait(700);
      const cv = pane.pop('wheel').querySelector('.cv');
      await dir.move(cv);
      await dir.click();
      menu.select(current);
      menu.openAbove(cv);
      await dir.wait(450);
      const cat = menu.item('win');
      await dir.move(cat, { fx: 0.5 });
      menu.hl(cat);
      await dir.wait(200);
      const sub = menu.openSub(cat);
      await dir.wait(260);
      await dir.move({ x: sub.x + sub.w * 0.7, y: dir.y }, { dur: 300 });
      const it = menu.subItem(target);
      await dir.move(it, { fx: 0.55 });
      menu.hl(it);
      await dir.wait(280);
      await dir.click();
      await menu.blink(it);
      menu.close();
      pane.set('wheel', target);
      current = target;
      const row = pane.row('wheel');
      row.classList.add('flash');
      setTimeout(() => row.classList.remove('flash'), 400);
      await dir.wait(800);
      await dir.move({ x: 470, y: 470 });
      await dir.wait(300);

      tag.show('wheel', 'Wheel Click', ACT[target].t);
      await fx[target](true);
      await dir.wait(1600);
      await fx[target](false);
      tag.hide(300);
      await dir.wait(700);
    });
  }

  function sceneGestures(host) {
    const st = stage(host, 760, 560);
    const sc = st.screen;
    desktopIcons(st, [
      { t: 'Projects', x: 30, y: 52 },
      { t: 'Screenshots', x: 30, y: 140 },
    ]);
    const spA = h('<div class="layer"></div>');
    const spB = h('<div class="layer" style="transform:translateX(-100%)"></div>');
    const web2 = appWindow('browser', { x: 150, y: 96, w: 360, h: 250 }, { tabs: ['Inbox', 'Calendar'] });
    const notes = appWindow('notes', { x: 300, y: 230, w: 290, h: 230 });
    const web = appWindow('browser', { x: 120, y: 64, w: 380, h: 270 });
    spA.append(web2.el, notes.el, web.el);
    const finder = appWindow('finder', { x: 150, y: 110, w: 380, h: 260 }, { title: 'Downloads' });
    spB.append(finder.el);
    const dim = h('<div class="dim"></div>');
    const spaces = spacesStrip();
    sc.append(spA, spB, dim, spaces);
    const mb = menuBar('Safari');
    sc.append(mb.el);

    const rowsHTML = [
      ['click', 'hand', 'Click', 'mc'],
      ['up', 'arrow-u', 'Move Up', 'desktop'],
      ['down', 'arrow-d', 'Move Down', 'expose'],
      ['left', 'arrow-l', 'Move Left', 'spaceL'],
      ['right', 'arrow-r', 'Move Right', 'spaceR'],
    ]
      .map(
        ([g, i, t, a]) =>
          `<div class="mg-row" data-g="${g}" style="min-height:40px"><span class="gi">${ic(i)}</span><div class="t1">${t}</div><span class="pop"><span class="lbl">${ic(ACT[a].i)}${ACT[a].t}</span><span class="cv">${ic('chev-d')}</span></span></div>`
      )
      .join('');
    const card = h(`<div class="mp gcard"><div class="gtitle">Gestures: Top Button</div><div class="mg">${rowsHTML}</div><div class="mg-note">Hold the button and move the mouse to trigger a direction. Click it without moving to trigger Click.</div></div>`);
    pos(card, 424, 44, 322);
    sc.append(card);

    const mouse = mouseArt(false);
    pos(mouse.el, 40, 318, 164, 221);
    sc.append(mouse.el);
    const dir = new Director(st, 340, 430);

    const back = [web, web2, notes];
    const fx = {
      async up(on) {
        if (on) {
          shove(web, -470, -300);
          shove(web2, -520, 330);
          shove(notes, 470, 300);
        } else back.forEach(home);
        await dir.wait(650);
      },
      async down(on) {
        dim.style.zIndex = '-1';
        dim.classList.toggle('on', on);
        notes.el.style.opacity = on ? '0' : '1';
        if (on) {
          fly(web, 190, 290, 0.62);
          fly(web2, 400, 290, 0.62);
        } else {
          home(web);
          home(web2);
        }
        await dir.wait(650);
      },
      async left() {
        spA.style.transform = 'translateX(100%)';
        spB.style.transform = 'translateX(0)';
        mb.app('Finder');
        await dir.wait(700);
      },
      async right() {
        spA.style.transform = 'translateX(0)';
        spB.style.transform = 'translateX(-100%)';
        mb.app('Safari');
        await dir.wait(700);
      },
      async click(on) {
        dim.style.zIndex = '-1';
        dim.classList.toggle('on', on);
        spaces.classList.toggle('on', on);
        mb.el.style.opacity = on ? '0' : '1';
        if (on) {
          fly(web, 150, 250, 0.5);
          fly(web2, 330, 380, 0.5);
          fly(notes, 330, 210, 0.52);
        } else back.forEach(home);
        await dir.wait(650);
      },
    };

    loop(dir, async () => {
      for (const g of ['up', 'down', 'left', 'right', 'click']) {
        await dir.wait(800);
        const row = card.querySelector(`[data-g="${g}"]`);
        if (g === 'click') {
          mouse.press('top', 260);
          row.classList.add('flash');
          await dir.wait(200);
          await fx.click(true);
          await dir.wait(1500);
          await fx.click(false);
          row.classList.remove('flash');
          continue;
        }
        mouse.hold('top', true);
        await dir.wait(280);
        mouse.arrow(g, true);
        row.classList.add('flash');
        await dir.wait(260);
        await fx[g](true);
        await dir.wait(900);
        mouse.arrow(g, false);
        mouse.hold('top', false);
        if (g === 'up' || g === 'down') {
          await dir.wait(500);
          await fx[g](false);
        }
        row.classList.remove('flash');
      }
    });
  }

  function sceneProfiles(host) {
    const st = stage(host, 760, 560, { x: 300, w: 460 });
    const sc = st.screen;
    const web = appWindow('browser', { x: 70, y: 110, w: 380, h: 280 }, { tabs: ['Getting started', 'Changelog', 'Forum'] });
    const finder = appWindow('finder', { x: 24, y: 52, w: 360, h: 270 }, { title: 'Documents' });
    web.el.style.zIndex = '1';
    finder.el.style.zIndex = '2';
    sc.append(web.el, finder.el);
    const d = dock(
      st,
      [
        { k: 'finder', c: 'finder', i: 'folder', run: true },
        { k: 'web', c: 'web', i: 'compass', run: true },
        { k: 'mail', c: 'mail', i: 'envelope' },
        { k: 'notes', c: 'notes', i: 'note' },
      ],
      230
    );
    const mb = menuBar('Finder');
    sc.append(mb.el);
    const wrap = h('<div style="position:absolute;left:410px;top:31px;transform:scale(0.88);transform-origin:100% 0;z-index:25"></div>');
    const p = panel({ dpi: 1600 });
    p.el.style.position = 'relative';
    wrap.append(p.el);
    sc.append(wrap);
    mb.up.classList.add('on');
    const tag = pressTag(st, (v) => v.x + 40, 420);
    const dir = new Director(st, 380, 470);

    const toSafari = async () => {
      await dir.move(d.get('web'));
      await dir.click();
      d.bounce('web');
      web.el.style.zIndex = '3';
      await mb.app('Safari');
      p.header('In Safari · MX Vertical', true);
      p.act('back', 'prevTab', true);
      p.act('fwd', 'nextTab', true);
      await sleep(200);
      p.flash('back');
      p.flash('fwd');
    };
    const toFinder = async () => {
      await dir.move(d.get('finder'));
      await dir.click();
      web.el.style.zIndex = '1';
      await mb.app('Finder');
      p.header('Buttons · MX Vertical', true);
      p.act('back', 'default', true);
      p.act('fwd', 'forward', true);
      await sleep(200);
      p.flash('back');
      p.flash('fwd');
    };
    const press = async (c, name, action, then) => {
      tag.show(c, name, action);
      p.flash(c);
      then();
      tag.hide(1100);
      await dir.wait(1300);
    };

    loop(dir, async () => {
      await dir.wait(700);
      await press('fwd', 'Forward Button', 'Forward', () => finder.go(1));
      await press('back', 'Back Button', 'Default', () => finder.go(0));
      await toSafari();
      await dir.wait(900);
      await dir.move({ x: 330, y: 300 });
      await press('fwd', 'Forward Button', 'Next Tab', () => web.go(1));
      await press('fwd', 'Forward Button', 'Next Tab', () => web.go(2));
      await press('back', 'Back Button', 'Previous Tab', () => web.go(1));
      await dir.wait(300);
      await toFinder();
      web.go(0);
      await dir.wait(900);
      await dir.move({ x: 380, y: 470 });
    });
  }

  function sceneMice(host) {
    const st = stage(host, 760, 560, { x: 300, w: 460 });
    const sc = st.screen;
    const fdr = appWindow('finder', { x: 26, y: 58, w: 340, h: 250 }, { title: 'Documents' });
    const nts = appWindow('notes', { x: 120, y: 250, w: 260, h: 240 });
    sc.append(fdr.el, nts.el);
    const mb = menuBar('Finder', '85%');
    sc.append(mb.el);
    const wrap = h('<div style="position:absolute;left:400px;top:31px;transform:scale(0.92);transform-origin:100% 0;z-index:25"></div>');
    const p = panel({ dpi: 1600 });
    p.el.style.position = 'relative';
    wrap.append(p.el);
    sc.append(wrap);
    mb.up.classList.add('on');
    const note = notification('Lift battery is low', '15% left. Charge it soon.');
    sc.append(note);

    const card = (m) => {
      const el = h(`<div class="devcard"><span class="glyph">${ic('mouse-fill')}</span><div>${m.name}<small>${ic(CONN[m.conn].i)} ${CONN[m.conn].t}</small></div></div>`);
      sc.append(el);
      return el;
    };
    const cards = { lift: card(MICE[0]), mx3s: card(MICE[2]) };
    pos(cards.lift, 90, 170);
    pos(cards.mx3s, 90, 300);
    const dir = new Director(st, 300, 470);

    const lowest = () =>
      Math.min(...MICE.filter((m) => !p.rows[m.id].classList.contains('gone')).map((m) => m.cur ?? m.batt));
    const prep = (c) => {
      c.style.transition = 'none';
      c.style.opacity = '0';
      c.style.transform = 'translateY(10px)';
      reflow(c);
      c.style.transition = '';
    };
    mb.setLabel(lowest() + '%');

    const join = async (id) => {
      const c = cards[id];
      pos(c, st.view.x + (st.view.x ? 30 : 90), id === 'lift' ? 170 : 300);
      prep(c);
      c.style.opacity = '1';
      c.style.transform = 'none';
      await dir.wait(900);
      p.connecting(id, true);
      p.show(id, true);
      await dir.wait(380);
      const r = rel(st, p.rows[id]);
      const cr = rel(st, c);
      c.style.transform = `translate(${r.x - cr.x}px, ${r.y - cr.y}px) scale(0.7)`;
      c.style.opacity = '0';
      await dir.wait(700);
      p.connecting(id, false);
      p.count();
      mb.setLabel(lowest() + '%');
      await dir.wait(500);
    };

    // Starts from the still frame: three mice connected.
    loop(dir, async () => {
      await dir.wait(900);
      const lift = MICE[0];
      await tween(1600, (t) => {
        lift.cur = 45 - 30 * t;
        p.batt('lift', lift.cur);
        mb.setLabel(Math.round(lowest()) + '%');
      });
      lift.cur = 15;
      await dir.wait(300);
      note.classList.add('in');
      await dir.wait(2800);
      note.classList.remove('in');
      await dir.wait(800);

      p.show('lift', false);
      p.show('mx3s', false);
      p.count();
      lift.cur = lift.batt;
      p.batt('lift', lift.batt);
      mb.setLabel(lowest() + '%');
      await dir.wait(900);
      await join('lift');
      await join('mx3s');
      await dir.wait(600);
    });
  }

  function sceneSpeed(host) {
    const st = stage(host, 760, 560);
    const sc = st.screen;
    const mb = menuBar('Upright');
    sc.append(mb.el);
    const win = settingsWindow('mice', { x: 12, y: 40, w: 736, h: 508 });
    sc.append(win.el);
    const presetRow = (v, extra = '') =>
      `<div class="mg-row${extra}" data-v="${v}" style="min-height:30px"><div class="t1">${nf(v)} DPI</div><span class="minus"></span></div>`;
    win.main.innerHTML = `
      <div class="mwin-title">Mice</div>
      <div class="mg"><div class="mg-row" style="min-height:56px">
        <div class="mp-logo" style="width:40px;height:40px;font-size:21px">${ic('mouse-fill')}</div>
        <div class="tt"><div class="t1" style="font-size:15px;font-weight:650">MX Vertical</div><div class="t2" style="display:flex;align-items:center;gap:6px;font-size:12px"><span class="dot"></span>Connected via Unifying receiver, slot 1</div></div>
        <span class="batt grow">${batt(85)}<span class="pct">85%</span></span>
      </div></div>
      <div class="mg-label">Pointer Speed</div>
      <div class="mg">
        <div class="mg-row"><div class="t1">Speed</div><span class="grow"></span>${sliderHTML(dpiToV(1600), 210, 'spd')}<span class="gi" style="color:var(--m-text-2)">${ic('updown')}</span><span class="dpi">1,600 DPI</span></div>
        <div class="mg-row" style="gap:8px"><div class="t2" style="margin:0;font-size:11px">Supported: 400–4,000 DPI · Default 1,000 DPI</div><span class="mbtn grow">Use Default</span><span class="mbtn">Let the Mouse Decide</span></div>
      </div>
      <div class="mg-label">Speed Presets</div>
      <div class="mg presets">
        ${DPI_PRESETS.map((v) => presetRow(v)).join('')}
        ${presetRow(3200, ' gone')}
        <div class="mg-row"><div class="t1">Add a speed</div><span class="mfield" style="margin-left:14px">e.g. 1000</span><span class="mbtn add">Add</span><span class="mbtn grow">Use Suggested</span></div>
      </div>`;
    const m = win.main;
    const sl = m.querySelector('.msl');
    const knob = sl.querySelector('.knob');
    const dpiEl = m.querySelector('.dpi');
    const field = m.querySelector('.mfield');
    const addBtn = m.querySelector('.mbtn.add');
    const r3200 = m.querySelector('[data-v="3200"]');
    const tag = pressTag(st, 452, 52);
    const dir = new Director(st, 520, 300);

    let dpi = 1600;
    const setDPI = (v, animate) => {
      dpi = v;
      sl.classList.toggle('anim', !!animate);
      sl.style.setProperty('--v', dpiToV(v));
      dpiEl.textContent = nf(v) + ' DPI';
    };
    const flashPreset = (v) => {
      const r = m.querySelector(`.presets [data-v="${v}"]`);
      r.classList.add('flash');
      setTimeout(() => r.classList.remove('flash'), 380);
    };

    loop(dir, async () => {
      await dir.wait(700);
      // Drag the slider from 1,600 to 2,400 DPI.
      await dir.move(knob, { fx: 0.5, fy: 0.55 });
      const r = rel(st, sl);
      const from = dpi;
      const to = 2400;
      const kx = (v) => r.x + 10 + dpiToV(v) * (r.w - 20);
      sl.classList.remove('anim');
      await dir.drag({ x: kx(to), y: dir.y }, 900, (t) => {
        const raw = from + (to - from) * t;
        sl.style.setProperty('--v', dpiToV(raw));
        dpiEl.textContent = nf(Math.round(raw / 50) * 50) + ' DPI';
      });
      setDPI(to);
      await dir.wait(700);

      // Add a 3,200 DPI preset.
      await dir.move(field, { fx: 0.6 });
      await dir.click();
      field.classList.add('focus');
      field.textContent = '';
      for (const ch of '3200') {
        await dir.wait(140);
        field.textContent += ch;
        field.classList.add('typed');
      }
      await dir.wait(300);
      await dir.move(addBtn);
      await dir.click();
      addBtn.classList.add('press');
      setTimeout(() => addBtn.classList.remove('press'), 140);
      r3200.classList.remove('gone');
      field.classList.remove('focus', 'typed');
      field.textContent = 'e.g. 1000';
      await dir.wait(400);
      flashPreset(3200);
      await dir.wait(700);
      await dir.move({ x: 560, y: 470 });

      // The top button, set to Cycle Pointer Speed, steps through the presets.
      const cycle = [...DPI_PRESETS, 3200];
      for (let i = 0; i < 3; i++) {
        const next = cycle[(cycle.indexOf(dpi) + 1) % cycle.length];
        tag.show('top', 'Top Button', ACT.cycle.t);
        setDPI(next, true);
        flashPreset(next);
        await dir.wait(1100);
      }
      tag.hide(400);
      await dir.wait(800);

      r3200.classList.add('gone');
      setDPI(1600, true);
      await dir.wait(900);
    });
  }

  function sceneScrolling(host) {
    const st = stage(host, 760, 560);
    const sc = st.screen;
    const mb = menuBar('Upright');
    sc.append(mb.el);
    const win = settingsWindow('scrolling', { x: 18, y: 42, w: 500, h: 486 });
    sc.append(win.el);
    win.main.innerHTML = `
      <div class="mwin-title">Scrolling</div>
      <div class="mg-label" style="margin-top:4px">Direction</div>
      <div class="mg">
        <div class="mg-row"><div class="tt"><div class="t1">Reverse vertical scrolling</div><div class="t2 wrap">Turn the wheel down to move content up, independently of the trackpad's Natural Scrolling.</div></div><div class="mtog grow rev"></div></div>
        <div class="mg-row"><div class="tt"><div class="t1">Reverse horizontal scrolling</div><div class="t2 wrap">Applies to tilt and Shift-scroll.</div></div><div class="mtog grow"></div></div>
      </div>
      <div class="mg-label">Feel</div>
      <div class="mg">
        <div class="mg-row"><div class="t1">Speed</div><span class="grow"></span>${sliderHTML(0.2, 130, 'spd')}<span class="dpi spdv" style="min-width:44px">1×</span></div>
        <div class="mg-row"><div class="tt"><div class="t1">Smooth scrolling<span class="badge-exp">EXPERIMENTAL</span></div><div class="t2 wrap">Turns each wheel notch into a short, eased glide.</div></div><div class="mtog grow smooth"></div></div>
      </div>
      <div class="mg" style="margin-top:12px">
        <div class="mg-row"><div class="tt"><div class="t1">Only while a Logitech mouse is connected</div><div class="t2 wrap">Applies to every mouse wheel. Trackpads are never changed.</div></div><div class="mtog grow on"></div></div>
      </div>`;
    const m = win.main;
    const rev = m.querySelector('.mtog.rev');
    const smooth = m.querySelector('.mtog.smooth');
    const sl = m.querySelector('.msl');
    const knob = sl.querySelector('.knob');
    const spdv = m.querySelector('.spdv');

    const prev = h(`<div class="sprev"><div class="fw-bar"><div class="lights"><i></i><i></i><i></i></div><div class="fw-title">Article</div></div><div class="vp"><div class="doc">${
      '<div class="ln h"></div><div class="ln"></div><div class="ln m"></div><div class="ln"></div><div class="blk"></div><div class="ln s"></div><div class="ln"></div><div class="ln m"></div><div class="ln"></div><div class="blk warm"></div><div class="ln"></div><div class="ln s"></div><div class="ln m"></div><div class="ln"></div><div class="blk green"></div><div class="ln"></div><div class="ln m"></div><div class="ln s"></div><div class="ln"></div><div class="ln m"></div><div class="blk"></div><div class="ln"></div><div class="ln s"></div><div class="ln m"></div><div class="ln"></div>'
    }</div></div><div class="wheel">${ic('arrow-d')}</div></div>`);
    pos(prev, 534, 64, 208, 450);
    sc.append(prev);
    const doc = prev.querySelector('.doc');
    const wheel = prev.querySelector('.wheel');
    const dir = new Director(st, 430, 540);

    let y = -150;
    let speed = 1;
    doc.style.transform = `translateY(${y}px)`;

    const notches = async (n, down) => {
      wheel.classList.toggle('flip', !down);
      for (let i = 0; i < n; i++) {
        wheel.classList.remove('tick');
        reflow(wheel);
        wheel.classList.add('tick');
        const reversed = rev.classList.contains('on');
        const contentUp = down !== reversed;
        y += (contentUp ? -1 : 1) * 34 * speed;
        doc.classList.toggle('glide', smooth.classList.contains('on'));
        doc.style.transform = `translateY(${y}px)`;
        await dir.wait(smooth.classList.contains('on') ? 420 : 300);
      }
    };
    const roll = async () => {
      await notches(3, true);
      await dir.wait(400);
      await notches(3, false);
      await dir.wait(400);
    };
    const toggle = async (t) => {
      await dir.move(t);
      await dir.click();
      t.classList.toggle('on');
      await dir.wait(400);
      await dir.move({ x: 430, y: 540 });
    };
    const setSpeed = (s) => {
      speed = s;
      sl.style.setProperty('--v', (s - 0.5) / 2.5);
      spdv.textContent = (Math.round(s * 4) / 4).toString().replace(/\.0+$/, '') + '×';
    };

    loop(dir, async () => {
      await dir.wait(500);
      await roll();
      await toggle(smooth);
      await roll();

      await dir.move(knob, { fx: 0.5, fy: 0.55 });
      const r = rel(st, sl);
      const kx = (s) => r.x + 10 + ((s - 0.5) / 2.5) * (r.w - 20);
      await dir.drag({ x: kx(2), y: dir.y }, 800, (t) => setSpeed(1 + t));
      setSpeed(2);
      await dir.wait(300);
      await dir.move({ x: 430, y: 540 });
      await roll();

      await toggle(rev);
      await roll();

      await dir.wait(600);
      rev.classList.remove('on');
      smooth.classList.remove('on');
      sl.classList.add('anim');
      setSpeed(1);
      await dir.wait(500);
      sl.classList.remove('anim');
    });
  }

  const SCENES = {
    hero: sceneHero,
    remap: sceneRemap,
    gestures: sceneGestures,
    profiles: sceneProfiles,
    mice: sceneMice,
    speed: sceneSpeed,
    scrolling: sceneScrolling,
  };

  const build = (host) => {
    const make = SCENES[host.dataset.scene];
    if (!make) return;
    try {
      make(host);
    } catch (err) {
      console.error(err);
    }
  };

  // The hero is built right away. The others wait until they come near the screen, so the
  // first load only pays for what's visible; their aspect ratio already holds their space.
  const later = [];
  document.querySelectorAll('.stage[data-scene]').forEach((host) => {
    if (host.dataset.scene === 'hero' || !('IntersectionObserver' in window)) build(host);
    else later.push(host);
  });
  if (later.length) {
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (!e.isIntersecting) continue;
          io.unobserve(e.target);
          build(e.target);
        }
      },
      { rootMargin: '800px 0px' }
    );
    later.forEach((host) => io.observe(host));
  }
})();
