/* ============================================================================
   code-hl.js —— 代码块着色（highlight.js 本地版，ui/vendor 里）

   为什么自己写这么一层而不直接在页面里调 hljs：
     1) contenteditable 里的代码块被"重新着色"就等于把里面的 DOM 全换掉，
        换掉那一刻光标就没了。所以必须严格限定"什么时候可以重画"。
     2) 代码块的正本是"纯文本"，着色只是 span 外套一层皮。任何一次着色都必须
        保证 textContent 一个字符都不变，否则存进库里的 Markdown 会走样。

   两条硬规矩（都是踩过的坑换来的）：
     · 只画"光标不在里面"的代码块。正在打字的那块一律不碰 —— 换 DOM 会跳光标，
       严重时还会把刚敲的字吃掉。
     · 换行用真换行符，不用 <br>：<pre> 本来就是 white-space: pre-wrap，真换行
       照样显示成换行，而 textContent / Markdown 转换都能原样读回来。
       混进来的 <br>（用户按回车时 Chromium 爱插）由 textOf() 统一折算成 \n。

   语言标记：代码块上的 data-lang（取值为 hljs 的语言名）+ <code class="language-x">，
   两个都写，前者给页面用、后者是 Markdown/HTML 导出的通行写法。
   ========================================================================== */

(function (root) {
  'use strict';

  const has = () => !!(root.hljs && root.hljs.highlight);

  /* 菜单里出现的语言。改这里要同步改 lib\note-window.ahk 的 CodeLangs()：
     宿主只负责画菜单，真正干活的是这张表。 */
  const LANGS = [
    ['', '自动识别'],
    ['text', '纯文本'],
    ['javascript', 'JavaScript'],
    ['typescript', 'TypeScript'],
    ['python', 'Python'],
    ['xml', 'HTML / XML'],
    ['css', 'CSS'],
    ['json', 'JSON'],
    ['bash', 'Bash / Shell'],
    ['sql', 'SQL'],
    ['c', 'C'],
    ['cpp', 'C++'],
    ['csharp', 'C#'],
    ['java', 'Java'],
    ['go', 'Go'],
    ['rust', 'Rust'],
    ['yaml', 'YAML'],
    ['markdown', 'Markdown'],
    ['diff', 'Diff'],
    ['lua', 'Lua'],
    ['php', 'PHP'],
    ['ruby', 'Ruby'],
    ['swift', 'Swift'],
    ['kotlin', 'Kotlin']
  ];

  /* 自动识别的候选集：hljs 的全量语言表太大，而且 auto 对英文散文很容易
     猜成"某个语言"，限定一小撮常用的反而更准、也更快。 */
  const AUTO = ['javascript', 'typescript', 'python', 'xml', 'css', 'json', 'bash'
    , 'sql', 'c', 'cpp', 'csharp', 'java', 'go', 'rust', 'yaml', 'php', 'ruby'];
  const AUTO_MAX = 6000;          // 超过这个长度就别猜了，太慢

  function labelOf(lang) {
    for (const [k, v] of LANGS)
      if (k === lang) return v;
    return lang || '自动识别';
  }

  /* 代码块的纯文本：textContent + <br> 折算成换行。
     不能直接用 textContent —— 用户在 <pre> 里按回车时 Chromium 插的是 <br>，
     那个字符 textContent 里根本不存在，直接读会把两行粘成一行。 */
  function textOf(pre) {
    let out = '';
    (function walk(node) {
      for (const c of node.childNodes) {
        if (c.nodeType === 3) out += c.nodeValue;
        else if (c.nodeType === 1) {
          if (c.tagName === 'BR') out += '\n';
          else walk(c);
        }
      }
    })(pre);
    return out;
  }

  function codeEl(pre) {
    const c = pre.firstElementChild;
    return (c && c.tagName === 'CODE') ? c : null;
  }

  /* 语言从哪来：data-lang（页面自己设的）> code.language-x（Markdown 渲染出来的） */
  function detect(pre) {
    const own = pre.getAttribute('data-lang');
    if (own) return own;
    const code = codeEl(pre);
    if (code) {
      const m = /(?:^|\s)language-([\w+#-]+)/.exec(code.className || '');
      if (m) return m[1];
      const d = code.getAttribute('data-lang');
      if (d) return d;
    }
    return '';
  }

  function setLang(pre, lang) {
    if (!pre) return;
    const code = codeEl(pre);
    if (lang) pre.setAttribute('data-lang', lang);
    else pre.removeAttribute('data-lang');
    if (code) {
      code.className = code.className.replace(/(?:^|\s)language-[\w+#-]+/g, '').trim();
      if (lang && lang !== 'text') code.className = (code.className + ' language-' + lang).trim();
      if (lang) code.setAttribute('data-lang', lang);
      else code.removeAttribute('data-lang');
    }
  }

  function esc(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  /* 真正把一块 <pre> 上色。textContent 必须一字不变 —— 这是这个函数唯一的承诺。 */
  function paint(pre) {
    if (!pre || pre.tagName !== 'PRE') return false;
    const text = textOf(pre);
    let lang = detect(pre);
    let html = '';

    if (has()) {
      try {
        if (lang && lang !== 'text' && root.hljs.getLanguage(lang)) {
          html = root.hljs.highlight(text, { language: lang, ignoreIllegals: true }).value;
        } else if (!lang && text.trim() && text.length <= AUTO_MAX) {
          const r = root.hljs.highlightAuto(text, AUTO);
          html = r.value;
          /* 猜出来的语言也记下来：导出的 HTML 才能带上 language-x，看的人
             打开就知道是什么语言的代码 */
          if (r.language && r.relevance >= 5) {
            setLang(pre, r.language);
            lang = r.language;
          }
        }
      } catch (_) {
        html = '';
      }
    }
    if (!html) html = esc(text);

    if (pre.innerHTML === html) return false;
    pre.innerHTML = html;
    pre.setAttribute('data-hl', lang || 'auto');
    return true;
  }

  /* 光标在不在这个块里。在的话绝对不能重画。 */
  function caretInside(pre) {
    const sel = root.getSelection && root.getSelection();
    if (!sel || !sel.rangeCount) return false;
    const n = sel.getRangeAt(0).commonAncestorContainer;
    return pre === n || pre.contains(n);
  }

  /* 批量上色。force=true 时连光标所在的块也画（只在显式"换个语言"时用，
     那种场景会顺手把光标按字符偏移放回去）。 */
  function paintAll(scope, opts) {
    const force = !!(opts && opts.force);
    const list = (scope || document).querySelectorAll('pre');
    let n = 0;
    for (const pre of list) {
      if (!force && caretInside(pre)) continue;
      if (paint(pre)) n++;
    }
    return n;
  }

  /* 按"字符偏移"记下光标，重画之后放回去。
     只在 setLang 这条路上用；正常打字路径永远不会触发重画。 */
  function caretOffset(pre) {
    const sel = root.getSelection && root.getSelection();
    if (!sel || !sel.rangeCount) return null;
    const r = sel.getRangeAt(0);
    if (!pre.contains(r.startContainer)) return null;
    const walker = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT);
    let acc = 0, n;
    while ((n = walker.nextNode())) {
      const len = n.nodeValue.length;
      if (n === r.startContainer) return { start: acc + r.startOffset, collapsed: r.collapsed, pre: pre };
      acc += len;
    }
    return { start: acc, collapsed: r.collapsed, pre: pre };
  }

  function restoreCaret(saved) {
    if (!saved) return;
    const pre = saved.pre;
    const walker = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT);
    let acc = 0, n, last = null;
    while ((n = walker.nextNode())) {
      const len = n.nodeValue.length;
      if (saved.start <= acc + len) {
        const r = document.createRange();
        r.setStart(n, Math.max(0, saved.start - acc));
        r.collapse(true);
        const sel = root.getSelection();
        sel.removeAllRanges();
        sel.addRange(r);
        return;
      }
      acc += len;
      last = n;
    }
    if (last) {
      const r = document.createRange();
      r.setStart(last, last.nodeValue.length);
      r.collapse(true);
      const sel = root.getSelection();
      sel.removeAllRanges();
      sel.addRange(r);
    }
  }

  root.CodeHL = {
    has: has,
    LANGS: LANGS,
    labelOf: labelOf,
    textOf: textOf,
    detect: detect,
    setLang: setLang,
    paint: paint,
    paintAll: paintAll,
    caretInside: caretInside,
    caretOffset: caretOffset,
    restoreCaret: restoreCaret
  };
})(typeof window !== 'undefined' ? window : globalThis);
