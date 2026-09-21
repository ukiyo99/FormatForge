(function () {
  var out = [];
  function ck(l, c, e) { out.push((c ? 'PASS' : 'FAIL') + ' | ' + l + (e ? ' | ' + e : '')); }

  // Accepts both "#rrggbb" (what CSS variables hold) and "rgb(r,g,b)".
  function toRGB(c) {
    c = c.trim();
    var hex = c.match(/^#([0-9a-f]{6})$/i);
    if (hex) {
      var n = parseInt(hex[1], 16);
      return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
    }
    var rgb = c.match(/rgba?\(([^)]+)\)/);
    if (rgb) {
      var parts = rgb[1].split(',').map(function (v) { return parseFloat(v); });
      return [parts[0], parts[1], parts[2]];
    }
    return null;
  }
  function lum(c) {
    var a = toRGB(c); if (!a) return NaN;
    a = a.map(function (v) {
      v = v / 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    });
    return 0.2126 * a[0] + 0.7152 * a[1] + 0.0722 * a[2];
  }
  function ratio(f, b) {
    var l1 = lum(f), l2 = lum(b);
    var hi = Math.max(l1, l2), lo = Math.min(l1, l2);
    return (hi + 0.05) / (lo + 0.05);
  }
  // Read the palette from CSS variables: computed colours on transparent
  // elements come back as rgba(0,0,0,0), which yields bogus ratios.
  function v(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  }

  var root = document.documentElement;
  var themes = ['dark', 'dim', 'light', 'sepia'];

  themes.forEach(function (t) {
    root.setAttribute('data-theme', t);
    var bg = v('--bg'), elev = v('--bg-elev'), card = v('--bg-card');
    var fg = v('--fg'), dim = v('--fg-dim'), mute = v('--fg-mute'), cmt = v('--c-comment');

    ck(t + ' 变量完整', /^#/.test(bg) && /^#/.test(fg) && /^#/.test(cmt), bg + ' / ' + fg);
    var rBody = ratio(fg, bg);
    ck(t + ' 正文对比度 ≥7:1', rBody >= 7, rBody.toFixed(2) + ':1');
    var rDim = ratio(dim, elev);
    ck(t + ' 侧边栏项目 ≥4.5:1', rDim >= 4.5, rDim.toFixed(2) + ':1');
    var rMute = ratio(mute, elev);
    ck(t + ' 侧边栏分组标题 ≥4.5:1', rMute >= 4.5, rMute.toFixed(2) + ':1');
    var rCmt = ratio(cmt, card);
    ck(t + ' 代码注释 ≥4.5:1', rCmt >= 4.5, rCmt.toFixed(2) + ':1');
  });

  // Font scaling.
  root.setAttribute('data-theme', 'dark');
  var base = parseFloat(getComputedStyle(document.body).fontSize);
  document.getElementById('fontPlus').click();
  var bigger = parseFloat(getComputedStyle(document.body).fontSize);
  document.getElementById('fontPlus').click();
  var bigger2 = parseFloat(getComputedStyle(document.body).fontSize);
  ck('字号可增大', bigger > base && bigger2 > bigger, base + ' → ' + bigger + ' → ' + bigger2);
  document.getElementById('fontMinus').click();
  document.getElementById('fontMinus').click();
  document.getElementById('fontMinus').click();
  var smaller = parseFloat(getComputedStyle(document.body).fontSize);
  ck('字号可减小', smaller < base, base + ' → ' + smaller);
  ck('字号显示百分比', /\d+%/.test(document.getElementById('fontLevel').textContent),
     document.getElementById('fontLevel').textContent);

  // Theme switching must actually change the palette.
  var d1 = v('--bg');
  document.querySelector('[data-set="light"]').click();
  var d2 = v('--bg');
  ck('主题切换生效', d1 !== d2, d1 + ' → ' + d2);
  ck('主题按钮状态更新',
     document.querySelector('[data-set="light"]').getAttribute('aria-pressed') === 'true');

  // Code blocks: highlighting must be present while collapsed.
  var collapsed = document.querySelector('.code-block.collapsible:not(.is-open)');
  if (collapsed) {
    var kw = collapsed.querySelector('.c-keyword');
    ck('折叠状态下仍有高亮', !!kw, kw ? kw.textContent.slice(0, 12) : '无');
    var sc = collapsed.querySelector('.code-scroll');
    ck('折叠使用 max-height', getComputedStyle(sc).maxHeight === '420px',
       getComputedStyle(sc).maxHeight);
  } else {
    ck('找到可折叠代码块', false);
  }
  ck('每个代码块都有复制按钮',
     document.querySelectorAll('.copy-btn').length === document.querySelectorAll('.code-block').length);
  ck('每个代码块都有红绿灯',
     document.querySelectorAll('.lights').length === document.querySelectorAll('.code-block').length);

  // Explanation content.
  ck('存在"为什么这样实现"', document.querySelectorAll('.why').length > 20,
     document.querySelectorAll('.why').length + ' 处');
  ck('存在踩坑记录', document.querySelectorAll('.pitfall').length > 15,
     document.querySelectorAll('.pitfall').length + ' 处');
  ck('存在图示', document.querySelectorAll('.diagram').length >= 10,
     document.querySelectorAll('.diagram').length + ' 张');
  ck('存在实现步骤', document.querySelectorAll('.steps').length > 40,
     document.querySelectorAll('.steps').length + ' 组');
  ck('每个工具都有实现原理', document.querySelectorAll('.tool').length > 0,
     document.querySelectorAll('.tool').length + ' 个工具卡片');

  // ------------------------------------------------------- head metadata
  // <title> and <meta> cannot hold markup: a browser would show the tags as
  // text, and every language's span at once. Both must be plain strings.
  var title = document.title || '';
  ck('标题不含 HTML 标签', title.indexOf('<') === -1 && title.length > 0, title);
  ck('标题只有一种语言',
     ['完全开发教程', '完全開発', '완전 개발'].every(function (t) { return title.indexOf(t) === -1; }),
     title);
  var desc = document.querySelector('meta[name="description"]');
  ck('描述不含 HTML 标签',
     !desc || desc.getAttribute('content').indexOf('<') === -1);

  // ------------------------------------------------------- rendered markup
  // Every translated unit is a real <span data-lang> element. If any of that
  // markup gets escaped it shows up as literal text in the page — the sidebar
  // once read "<SPAN DATA-LANG="EN">OVERALL ARCHITECTURE</SPAN>". Catch it by
  // looking for the tags in the rendered text.
  var bodyText = document.body.innerText || '';
  ck('正文没有暴露的 span 标记',
     bodyText.indexOf('data-lang=') === -1 && bodyText.indexOf('<span') === -1,
     bodyText.indexOf('data-lang=') !== -1 ? '发现字面 span 标签' : '');
  ck('正文没有 HTML 实体泄漏',
     bodyText.indexOf('&lt;') === -1 && bodyText.indexOf('&quot;') === -1);
  ck('侧栏条目都有文字',
     Array.prototype.every.call(document.querySelectorAll('.nav-item'),
       function (a) { return a.textContent.trim().length > 0; }),
     document.querySelectorAll('.nav-item').length + ' 个条目');

  // ---------------------------------------------------- structural integrity
  // A block is emitted once per language. Emitting the whole element each time
  // duplicated its id five times — invalid HTML, and anchor links then jumped
  // to whichever copy came first.
  var ids = {};
  var dupes = [];
  document.querySelectorAll('[id]').forEach(function (el) {
    var id = el.getAttribute('id');
    ids[id] = (ids[id] || 0) + 1;
    if (ids[id] === 2) dupes.push(id);
  });
  ck('没有重复的元素 id', dupes.length === 0, dupes.slice(0, 5).join(', '));

  // Every top-level section must be visible in the active language.
  ['overview', 'quickstart', 'architecture', 'articles', 'tools',
   'appendix', 'source-tree', 'deps', 'testing'].forEach(function (id) {
    var el = document.getElementById(id);
    ck('区块可见: ' + id, !!el && el.getClientRects().length > 0);
  });

  // The overview/quickstart/deps blocks are whole sections; they must follow
  // the language switch like the rest of the page.
  (function () {
    var pick = document.getElementById('langPick');
    if (!pick) return;
    var saved = pick.value;
    pick.value = 'zh-Hans';
    pick.dispatchEvent(new Event('change'));
    function shown(sel) {
      var all = document.querySelectorAll(sel);
      for (var i = 0; i < all.length; i++) {
        if (all[i].getClientRects().length > 0) return all[i].textContent;
      }
      return '';
    }
    ck('概览区块跟随语言', /[\u4e00-\u9fff]/.test(shown('#overview h2')),
       shown('#overview h2'));
    ck('工具卡片跟随语言', /[\u4e00-\u9fff]/.test(shown('.tool h3')),
       shown('.tool h3'));
    ck('依赖区块跟随语言', /[\u4e00-\u9fff]/.test(shown('#deps h3')),
       shown('#deps h3'));
    pick.value = saved;
    pick.dispatchEvent(new Event('change'));
  })();

  // ---------------------------------------------------------------- languages
  var pick = document.getElementById('langPick');
  ck('存在语言选择器', !!pick);
  var codes = pick ? Array.prototype.map.call(pick.options, function (o) { return o.value; }) : [];
  ck('提供 5 种语言', codes.length === 5, codes.join(', '));
  ck('语言列表完整',
     ['en', 'zh-Hans', 'ja', 'ko', 'fr'].every(function (c) { return codes.indexOf(c) !== -1; }));

  // Every language must have a full set of spans.
  var counts = {};
  ['en', 'zh-Hans', 'ja', 'ko', 'fr'].forEach(function (c) {
    counts[c] = document.querySelectorAll('[data-lang="' + c + '"]:not(html)').length;
  });
  var base = counts['en'];
  ck('每种语言的条目数一致',
     ['zh-Hans', 'ja', 'ko', 'fr'].every(function (c) { return counts[c] === base; }),
     JSON.stringify(counts));

  // Switching must reveal exactly one language.
  // A unit is visible only if it and every ancestor are rendered. Reading an
  // element's own display is not enough: it still reports "inline" when an
  // ancestor is hidden, which once let a fully invisible page pass.
  function isRendered(el) {
    if (el.getClientRects().length === 0) return false;
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
      if (window.getComputedStyle(n).display === 'none') return false;
    }
    return true;
  }

  function visibleLangSpans(code) {
    var hidden = 0, shown = 0;
    document.querySelectorAll('[data-lang]:not(html)').forEach(function (el) {
      var matches = el.getAttribute('data-lang') === code;
      var rendered = isRendered(el);
      if (matches && rendered) shown++;
      if (!matches && rendered) hidden++;
    });
    return { shown: shown, leaked: hidden };
  }

  // The page itself must be visible.
  ck('页面根元素可见', window.getComputedStyle(document.documentElement).display !== 'none',
     'display=' + window.getComputedStyle(document.documentElement).display);

  if (pick) {
    ['zh-Hans', 'ja', 'ko', 'fr', 'en'].forEach(function (code) {
      pick.value = code;
      pick.dispatchEvent(new Event('change'));
      var r = visibleLangSpans(code);
      ck('切换到 ' + code + ' 后只显示该语言', r.shown > 0 && r.leaked === 0,
         'shown=' + r.shown + ' leaked=' + r.leaked);
    });
    // Default language must be English.
    ck('默认语言是英文', document.documentElement.getAttribute('data-lang') === 'en');
  }

  return out.join('\n');
})()
