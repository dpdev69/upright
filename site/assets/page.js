/* Upright site: page behavior outside the demo stages. Reveals sections as they scroll in,
   gives the nav a hairline once the page scrolls, and wires up the copy buttons. No
   dependencies, no tracking. */
(() => {
  'use strict';

  const RM = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ---------- Reveal on scroll ----------

  const reveals = document.querySelectorAll('.reveal');
  if (RM || !('IntersectionObserver' in window)) {
    reveals.forEach((el) => el.classList.add('in'));
  } else {
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (!e.isIntersecting) continue;
          e.target.classList.add('in');
          io.unobserve(e.target);
        }
      },
      { rootMargin: '0px 0px -8% 0px', threshold: 0.08 }
    );
    reveals.forEach((el) => io.observe(el));
  }

  // ---------- Nav ----------

  const nav = document.querySelector('.nav');
  if (nav) {
    let raf = 0;
    const update = () => {
      raf = 0;
      nav.classList.toggle('scrolled', window.scrollY > 8);
    };
    update();
    window.addEventListener('scroll', () => raf || (raf = requestAnimationFrame(update)), { passive: true });
  }

  // ---------- Copy buttons ----------

  // An ordered list is copied as numbered lines; anything else as its text.
  const textOf = (el) =>
    el.tagName === 'OL'
      ? [...el.children].map((li, i) => `${i + 1}. ${li.textContent.trim().replace(/\s+/g, ' ')}`).join('\n')
      : el.textContent.trim();

  async function copy(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.cssText = 'position:fixed;opacity:0;pointer-events:none';
      document.body.append(ta);
      ta.select();
      let ok = false;
      try {
        ok = document.execCommand('copy');
      } catch {}
      ta.remove();
      return ok;
    }
  }

  const status = document.createElement('div');
  status.setAttribute('role', 'status');
  status.setAttribute('aria-live', 'polite');
  status.style.cssText = 'position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0 0 0 0)';
  document.body.append(status);

  document.querySelectorAll('.copy[data-copy]').forEach((btn) => {
    const src = document.querySelector(btn.dataset.copy);
    if (!src) return;
    const label = btn.querySelector('span');
    const original = label ? label.textContent : '';
    let timer;
    btn.addEventListener('click', async () => {
      if (!(await copy(textOf(src)))) return;
      btn.classList.add('done');
      if (label) label.textContent = 'Copied';
      status.textContent = 'Copied to clipboard';
      clearTimeout(timer);
      timer = setTimeout(() => {
        btn.classList.remove('done');
        if (label) label.textContent = original;
        status.textContent = '';
      }, 1800);
    });
  });
})();
