
/* Sidebar filtering, active-section tracking, CSS-based code collapsing and
   clipboard copying. No innerHTML rewriting: an earlier version rebuilt the
   collapsed <pre> from textContent, which silently discarded every syntax
   highlight span (colour only appeared after expanding). */
(function () {
  'use strict';

  /* ---------- sidebar filter ---------- */
  var filter = document.getElementById('navFilter');
  if (filter) {
    filter.addEventListener('input', function () {
      var q = this.value.trim().toLowerCase();
      document.querySelectorAll('.nav-item').forEach(function (el) {
        var hay = el.getAttribute('data-search') || el.textContent.toLowerCase();
        el.classList.toggle('hidden', q !== '' && hay.indexOf(q) === -1);
      });
      document.querySelectorAll('.nav-group').forEach(function (group) {
        var items = group.querySelectorAll('.nav-item');
        var any = Array.prototype.some.call(items, function (i) {
          return !i.classList.contains('hidden');
        });
        group.classList.toggle('hidden', items.length > 0 && !any);
      });
    });
    document.addEventListener('keydown', function (e) {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        filter.focus();
        filter.select();
      }
      if (e.key === 'Escape' && document.activeElement === filter) {
        filter.value = '';
        filter.dispatchEvent(new Event('input'));
        filter.blur();
      }
    });
  }

  /* ---------- collapse / expand (CSS class only) ---------- */
  document.querySelectorAll('.code-block.collapsible').forEach(function (block) {
    var btn = block.querySelector('.expand-btn');
    if (!btn) return;
    var total = block.getAttribute('data-lines') || '';
    btn.addEventListener('click', function () {
      var open = block.classList.toggle('is-open');
      btn.textContent = open ? strings.collapse : (strings.expand + total + strings.lines);
    });
  });

  /* ---------- copy ---------- */
  function legacyCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.setAttribute('readonly', '');
    ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0;pointer-events:none';
    document.body.appendChild(ta);
    ta.select();
    ta.setSelectionRange(0, text.length);
    var ok = false;
    try { ok = document.execCommand('copy'); } catch (err) { ok = false; }
    document.body.removeChild(ta);
    return ok;
  }

  document.querySelectorAll('.copy-btn').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var block = btn.closest('.code-block');
      var code = block ? block.querySelector('pre.code code') : null;
      if (!code) return;
      var text = code.textContent;

      function flash(ok) {
        btn.textContent = ok ? strings.copied : strings.failed;
        btn.classList.toggle('done', ok);
        setTimeout(function () {
          btn.textContent = strings.copy;
          btn.classList.remove('done');
        }, 1500);
      }

      // The clipboard API needs a secure context; a local file:// page is not
      // one in every browser, so fall back to execCommand.
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(
          function () { flash(true); },
          function () { flash(legacyCopy(text)); }
        );
      } else {
        flash(legacyCopy(text));
      }
    });
  });

  /* ---------- language ---------- */
  var LANGS = ['en', 'zh-Hans', 'ja', 'ko', 'fr'];
  var LANG_LABELS = {
    'en': {copy: 'Copy', copied: 'Copied', failed: 'Copy failed',
           collapse: 'Collapse', expand: 'Expand all ', lines: ' lines'},
    'zh-Hans': {copy: '复制', copied: '已复制', failed: '复制失败',
           collapse: '收起代码', expand: '展开全部 ', lines: ' 行'},
    'ja': {copy: 'コピー', copied: 'コピーしました', failed: 'コピー失敗',
           collapse: '折りたたむ', expand: 'すべて展開 ', lines: ' 行'},
    'ko': {copy: '복사', copied: '복사됨', failed: '복사 실패',
           collapse: '접기', expand: '전체 펼치기 ', lines: '행'},
    'fr': {copy: 'Copier', copied: 'Copié', failed: 'Échec de la copie',
           collapse: 'Réduire', expand: 'Tout afficher ', lines: ' lignes'}
  };
  var strings = LANG_LABELS['en'];

  function applyLanguage(code) {
    if (LANGS.indexOf(code) === -1) code = 'en';
    root.setAttribute('data-lang', code);
    root.setAttribute('lang', code);
    strings = LANG_LABELS[code] || LANG_LABELS['en'];
    var pick = document.getElementById('langPick');
    if (pick) pick.value = code;
    // Refresh the labels the script itself injects.
    document.querySelectorAll('.copy-btn').forEach(function (b) {
      if (!b.classList.contains('done')) b.textContent = strings.copy;
    });
    document.querySelectorAll('.code-block.collapsible').forEach(function (block) {
      var btn = block.querySelector('.expand-btn');
      if (!btn) return;
      var total = block.getAttribute('data-lines') || '';
      btn.textContent = block.classList.contains('is-open')
        ? strings.collapse : (strings.expand + total + strings.lines);
    });
    try { localStorage.setItem('ff-lang', code); } catch (e) {}
  }

  /* ---------- theme + font size ---------- */
  var THEMES = ['dark', 'dim', 'light', 'sepia'];
  var SCALES = [0.9, 1, 1.1, 1.25, 1.4, 1.6];
  var root = document.documentElement;

  function applyTheme(name) {
    if (THEMES.indexOf(name) === -1) name = 'dark';
    root.setAttribute('data-theme', name);
    try { localStorage.setItem('ff-theme', name); } catch (e) {}
    document.querySelectorAll('.theme-dots button').forEach(function (b) {
      b.setAttribute('aria-pressed', String(b.getAttribute('data-set') === name));
    });
  }

  function applyScale(index) {
    index = Math.max(0, Math.min(SCALES.length - 1, index));
    root.style.setProperty('--font-scale', String(SCALES[index]));
    var label = document.getElementById('fontLevel');
    if (label) label.textContent = Math.round(SCALES[index] * 100) + '%';
    try { localStorage.setItem('ff-scale', String(index)); } catch (e) {}
  }

  document.querySelectorAll('.theme-dots button').forEach(function (b) {
    b.addEventListener('click', function () { applyTheme(b.getAttribute('data-set')); });
  });

  var langPick = document.getElementById('langPick');
  if (langPick) {
    langPick.addEventListener('change', function () { applyLanguage(this.value); });
  }

  var scaleIndex = 1;
  var minus = document.getElementById('fontMinus');
  var plus = document.getElementById('fontPlus');
  if (minus) minus.addEventListener('click', function () { applyScale(--scaleIndex); });
  if (plus) plus.addEventListener('click', function () { applyScale(++scaleIndex); });

  // Keyboard: T cycles themes, +/- adjusts text size.
  document.addEventListener('keydown', function (e) {
    if (e.target && /INPUT|TEXTAREA/.test(e.target.tagName)) return;
    if (e.key === 't' || e.key === 'T') {
      var now = root.getAttribute('data-theme') || 'dark';
      applyTheme(THEMES[(THEMES.indexOf(now) + 1) % THEMES.length]);
    }
    if (e.key === '=' || e.key === '+') { applyScale(++scaleIndex); }
    if (e.key === '-' || e.key === '_') { applyScale(--scaleIndex); }
    if (e.key === '0') { scaleIndex = 1; applyScale(1); }
  });

  // Restore saved preferences.
  var savedTheme = 'dark', savedScale = '1';
  try {
    savedTheme = localStorage.getItem('ff-theme') || 'dark';
    savedScale = localStorage.getItem('ff-scale') || '1';
  } catch (e) {}
  applyTheme(savedTheme);
  var savedLang = 'en';
  try { savedLang = localStorage.getItem('ff-lang') || 'en'; } catch (e) {}
  applyLanguage(savedLang);
  scaleIndex = parseInt(savedScale, 10);
  if (isNaN(scaleIndex) || scaleIndex < 0 || scaleIndex >= SCALES.length) scaleIndex = 1;
  applyScale(scaleIndex);

  /* ---------- active section ---------- */
  var links = Array.prototype.slice.call(
    document.querySelectorAll('.nav-item[href^="#"]'));
  var byId = {};
  links.forEach(function (l) { byId[l.getAttribute('href').slice(1)] = l; });

  if ('IntersectionObserver' in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        links.forEach(function (l) { l.classList.remove('active'); });
        var link = byId[entry.target.id];
        if (link) {
          link.classList.add('active');
          var box = link.closest('.sidebar-scroll');
          if (box) {
            var top = link.offsetTop, h = box.clientHeight;
            if (top < box.scrollTop + 60 || top > box.scrollTop + h - 60) {
              box.scrollTop = top - h / 2;
            }
          }
        }
      });
    }, { rootMargin: '-80px 0px -70% 0px', threshold: 0 });
    document.querySelectorAll('section[id]').forEach(function (s) {
      observer.observe(s);
    });
  }
})();
