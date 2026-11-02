/* ============================================================================
   md.js —— 轻量 Markdown ⇄ HTML

   为什么自己写而不用 marked/markdown-it：
     · 本项目不引入构建流程，vendored 库动辄 40~100KB，还要额外维护版本；
     · 便签只需要一个很小的子集，出问题也容易改；
     · render() 是纯函数，能在 node 里直接单测（见 tests/md.test.js）。

   支持的语法：标题、粗体/斜体/删除线、行内代码、代码块、链接、图片、
   引用、有序/无序列表、任务列表、分割线、表格、段落内换行。

   安全：所有文本先转义再拼标签；链接只放行 http/https/mailto/file 与页内锚点，
   其它协议（javascript: 等）一律降级成纯文本。
   ========================================================================== */

(function (root) {
  'use strict';

  function esc(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function safeUrl(url) {
    const u = String(url || '').trim();
    if (!u) return '';
    if (/^(https?:|mailto:|file:|data:image\/)/i.test(u)) return u;
    if (u.startsWith('#') || u.startsWith('./') || u.startsWith('../') || /^[\w./-]+$/.test(u)) return u;
    return '';
  }

  /* ---- 行内 ------------------------------------------------------------- */

  function inline(text) {
    const codes = [];
    // 行内代码先摘出来，避免里面的 * _ ~ 被当成格式
    let s = String(text).replace(/`([^`\n]+)`/g, function (_, c) {
      codes.push(c);
      return '\u0000' + (codes.length - 1) + '\u0000';
    });

    s = esc(s);

    // 图片 ![alt](src)
    s = s.replace(/!\[([^\]]*)\]\(((?:[^()\s]|\([^()]*\))+)(?:\s+&quot;[^&]*&quot;)?\)/g, function (m, alt, src) {
      const u = safeUrl(src);
      return u ? '<img src="' + esc(u) + '" alt="' + alt + '">' : m;
    });

    // 链接 [text](url)
    s = s.replace(/\[([^\]]+)\]\(((?:[^()\s]|\([^()]*\))+)(?:\s+&quot;[^&]*&quot;)?\)/g, function (m, label, href) {
      const u = safeUrl(href);
      return u ? '<a href="' + esc(u) + '" target="_blank" rel="noreferrer">' + label + '</a>' : label;
    });

    // 裸链接
    s = s.replace(/(^|[\s(])((?:https?:\/\/)[^\s<)]+)/g, function (m, pre, url) {
      return pre + '<a href="' + url + '" target="_blank" rel="noreferrer">' + url + '</a>';
    });

    s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    s = s.replace(/__([^_]+)__/g, '<strong>$1</strong>');
    s = s.replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>');
    s = s.replace(/(^|[^_])_([^_\n]+)_/g, '$1<em>$2</em>');
    s = s.replace(/~~([^~]+)~~/g, '<del>$1</del>');

    s = s.replace(/\u0000(\d+)\u0000/g, function (_, i) {
      return '<code>' + esc(codes[+i]) + '</code>';
    });
    return s;
  }

  /* ---- 块级 ------------------------------------------------------------- */

  function render(md) {
    if (md == null) return '';
    const lines = String(md).replace(/\r\n?/g, '\n').split('\n');
    const out = [];
    let i = 0;
    let para = [];

    function flushPara() {
      if (!para.length) return;
      // 段内单换行 → <br>，保持"所见即所得"的直觉
      out.push('<p>' + para.map(inline).join('<br>') + '</p>');
      para = [];
    }

    while (i < lines.length) {
      const line = lines[i];

      // 代码块 ``` 或 ~~~
      const fence = line.match(/^\s*(```+|~~~+)\s*([\w+#-]*)\s*$/);
      if (fence) {
        flushPara();
        const mark = fence[1][0];
        const lang = fence[2] || '';
        const body = [];
        i++;
        while (i < lines.length && !new RegExp('^\\s*' + mark + '{3,}\\s*$').test(lines[i])) {
          body.push(lines[i]);
          i++;
        }
        i++; // 跳过结束围栏
        /* 语言写成 class="language-x" 是通行写法，highlight.js 直接认；
           一并写到 data-lang 上，方便页面那边"改语言"时读回来。 */
        const attr = lang ? ' class="language-' + esc(lang) + '" data-lang="' + esc(lang) + '"' : '';
        out.push('<pre><code' + attr + '>' + esc(body.join('\n')) + '</code></pre>');
        continue;
      }

      // 空行
      if (/^\s*$/.test(line)) {
        flushPara();
        i++;
        continue;
      }

      // 分割线
      if (/^\s*([-*_])\s*(?:\1\s*){2,}$/.test(line)) {
        flushPara();
        out.push('<hr>');
        i++;
        continue;
      }

      // 标题
      const h = line.match(/^\s{0,3}(#{1,6})\s+(.*)$/);
      if (h) {
        flushPara();
        const lv = Math.min(h[1].length, 3);
        out.push('<h' + lv + '>' + inline(h[2].replace(/\s*#+\s*$/, '')) + '</h' + lv + '>');
        i++;
        continue;
      }

      // 引用（连续行合并）
      if (/^\s*>\s?/.test(line)) {
        flushPara();
        const body = [];
        while (i < lines.length && /^\s*>\s?/.test(lines[i])) {
          body.push(lines[i].replace(/^\s*>\s?/, ''));
          i++;
        }
        out.push('<blockquote>' + body.map(inline).join('<br>') + '</blockquote>');
        continue;
      }

      // 表格：| a | b |  +  |---|---|
      if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|[\s:|-]+\|\s*$/.test(lines[i + 1])) {
        flushPara();
        const head = splitRow(line);
        i += 2;
        const rows = [];
        while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) {
          rows.push(splitRow(lines[i]));
          i++;
        }
        let t = '<table><thead><tr>' + head.map(c => '<th>' + inline(c) + '</th>').join('') + '</tr></thead><tbody>';
        for (const r of rows) {
          t += '<tr>' + r.map(c => '<td>' + inline(c) + '</td>').join('') + '</tr>';
        }
        out.push(t + '</tbody></table>');
        continue;
      }

      // 列表（无序 / 有序 / 任务），支持一层缩进
      if (/^\s*([-*+]|\d+[.)])\s+/.test(line)) {
        flushPara();
        const ordered = /^\s*\d+[.)]\s+/.test(line);
        const items = [];
        while (i < lines.length && /^\s*([-*+]|\d+[.)])\s+/.test(lines[i])) {
          let raw = lines[i].replace(/^\s*([-*+]|\d+[.)])\s+/, '');
          const task = raw.match(/^\[([ xX])\]\s+(.*)$/);
          if (task) {
            const done = task[1].toLowerCase() === 'x';
            items.push('<li class="task-line" data-done="' + (done ? 1 : 0) + '">' +
              '<span class="chk" contenteditable="false" data-checked="' + (done ? 1 : 0) + '"></span>' +
              '<span class="task-text">' + inline(task[2]) + '</span></li>');
          } else {
            items.push('<li>' + inline(raw) + '</li>');
          }
          i++;
        }
        const tag = ordered ? 'ol' : 'ul';
        out.push('<' + tag + '>' + items.join('') + '</' + tag + '>');
        continue;
      }

      para.push(line);
      i++;
    }
    flushPara();
    return out.join('');
  }

  function splitRow(line) {
    return line.trim().replace(/^\||\|$/g, '').split('|').map(s => s.trim());
  }

  /* ---- HTML -> Markdown ------------------------------------------------- */

  /* 读出代码块的正文：文本节点照收，<br> 折成换行。
     不能直接用 textContent —— 用户在 <pre> 里按回车时 Chromium 插的是 <br>，
     那个换行在 textContent 里根本不存在，直接读会把两行粘成一行。 */
  function preText(node) {
    let out = '';
    (function walk(n) {
      for (const c of n.childNodes) {
        if (c.nodeType === 3) out += c.nodeValue;
        else if (c.nodeType === 1) {
          if (c.tagName === 'BR') out += '\n';
          else walk(c);
        }
      }
    })(node);
    return out;
  }

  function toMarkdown(html) {
    if (!html) return '';
    const holder = document.createElement('div');
    holder.innerHTML = html;
    const md = blockToMd(holder, 0);
    return md.replace(/\n{3,}/g, '\n\n').trim();
  }

  function blockToMd(node, depth) {
    let out = '';
    for (const child of Array.from(node.childNodes)) {
      out += nodeToMd(child, depth);
    }
    return out;
  }

  function nodeToMd(node, depth) {
    if (node.nodeType === 3) return node.nodeValue.replace(/[ \t]+/g, ' ');
    if (node.nodeType !== 1) return '';
    const tag = node.tagName.toLowerCase();
    const inner = () => blockToMd(node, depth);

    switch (tag) {
      case 'br': return '\n';
      case 'strong': case 'b': return '**' + inner().trim() + '**';
      case 'em': case 'i': return '*' + inner().trim() + '*';
      case 'del': case 's': case 'strike': return '~~' + inner().trim() + '~~';
      case 'code':
        if (node.parentElement && node.parentElement.tagName === 'PRE') return inner();
        return '`' + node.textContent + '`';
      case 'pre': {
        /* 代码块里可能是纯文本、也可能是着色后的 span，还可能有用户按回车
           插进来的 <br>。三种都得还原成换行，否则导出的 Markdown 会把整个
           代码块挤成一行（着色功能上线后必须这么读，textContent 会丢 <br>）。 */
        const codeNode = node.querySelector('code');
        const m = codeNode ? /(?:^|\s)language-([\w+#-]+)/.exec(codeNode.className || '') : null;
        const lang = m ? m[1] : '';
        const code = preText(node).replace(/\n+$/, '');
        return '\n```' + lang + '\n' + code + '\n```\n\n';
      }
      case 'h1': return '\n# ' + inner().trim() + '\n\n';
      case 'h2': return '\n## ' + inner().trim() + '\n\n';
      case 'h3': return '\n### ' + inner().trim() + '\n\n';
      case 'h4': case 'h5': case 'h6': return '\n#### ' + inner().trim() + '\n\n';
      case 'hr': return '\n---\n\n';
      case 'blockquote':
        return '\n' + inner().trim().split('\n').map(l => '> ' + l).join('\n') + '\n\n';
      case 'ul': case 'ol': {
        let s = '\n';
        let n = 1;
        for (const li of Array.from(node.children)) {
          if (li.tagName !== 'LI') continue;
          const bullet = tag === 'ol' ? (n++) + '. ' : '- ';
          const body = blockToMd(li, depth + 1).trim().replace(/\n+/g, ' ');
          const chk = li.querySelector(':scope > .chk');
          if (chk) {
            const done = chk.getAttribute('data-checked') === '1';
            const text = li.querySelector(':scope > .task-text');
            s += bullet + '[' + (done ? 'x' : ' ') + '] ' + (text ? text.textContent.trim() : '') + '\n';
          } else {
            s += bullet + body + '\n';
          }
        }
        return s + '\n';
      }
      case 'a': {
        const href = node.getAttribute('href') || '';
        const text = inner().trim();
        if (!text) return '';
        return text === href ? text : '[' + text + '](' + href + ')';
      }
      case 'img': {
        const src = node.getAttribute('src') || '';
        return '![' + (node.getAttribute('alt') || '') + '](' + src + ')';
      }
      case 'table': {
        const rows = Array.from(node.querySelectorAll('tr'));
        if (!rows.length) return '';
        const cells = r => Array.from(r.children).map(c => c.textContent.trim());
        const head = cells(rows[0]);
        let s = '\n| ' + head.join(' | ') + ' |\n|' + head.map(() => '---').join('|') + '|\n';
        for (const r of rows.slice(1)) s += '| ' + cells(r).join(' | ') + ' |\n';
        return s + '\n';
      }
      case 'div': case 'p': case 'section': case 'article': {
        // 任务行在富文本里是 div.task-line
        if (node.classList && node.classList.contains('task-line')) {
          const done = node.getAttribute('data-done') === '1';
          const text = node.querySelector('.task-text');
          return '\n- [' + (done ? 'x' : ' ') + '] ' + (text ? text.textContent.trim() : '') + '\n';
        }
        const t = inner();
        return t.trim() ? '\n' + t.trim() + '\n\n' : '';
      }
      case 'span': {
        if (node.classList && node.classList.contains('chk')) return '';
        return inner();
      }
      default:
        return inner();
    }
  }

  /* ---- 纯文本 ----------------------------------------------------------- */

  function plain(md) {
    return String(md || '')
      .replace(/```[\s\S]*?```/g, ' ')
      .replace(/`[^`]*`/g, ' ')
      .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ')
      .replace(/\[([^\]]*)\]\([^)]*\)/g, '$1')
      .replace(/^\s{0,3}#{1,6}\s+/gm, '')
      .replace(/^\s*>\s?/gm, '')
      .replace(/^\s*([-*+]|\d+[.)])\s+/gm, '')
      .replace(/[*_~]/g, '')
      .replace(/\|/g, ' ')
      .replace(/[ \t]+/g, ' ')
      .trim();
  }

  /* ---- 标题提取 --------------------------------------------------------- */

  function title(htmlOrMd, isMd) {
    const text = isMd ? plain(htmlOrMd) : String(htmlOrMd || '').replace(/<[^>]+>/g, ' ');
    const first = text.split('\n').map(s => s.trim()).find(Boolean) || '';
    const clean = first.replace(/\s+/g, ' ').trim();
    return clean.length > 60 ? clean.slice(0, 60) + '…' : clean;
  }

  const MD = {
    render: render, toMarkdown: toMarkdown, plain: plain, title: title,
    esc: esc, inline: inline, preText: preText
  };

  if (typeof module === 'object' && module.exports) module.exports = MD;
  else root.MD = MD;
})(typeof window !== 'undefined' ? window : globalThis);
