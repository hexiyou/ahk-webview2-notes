/* ============================================================================
   editor-core.js —— 富文本块编辑内核（普通便签与待办事项共用）

   为什么要有这一层：
     普通便签页只有一个 #editor，所有编辑逻辑直接写着 editor 这个名字。待办页
     是一页 N 个独立的富文本块，如果复制一份出来改，两份代码会立刻开始分叉：
     代码块的进出规则、Tab 缩进、粘贴图片的兜底……改一处忘一处。
     所以把这些"以某个根节点为作用域"的原语抽到这里，两个页面各建一个实例。

   ★ 这是搬家，不是重写。每一段的注释都跟着搬过来了，逻辑逐行不变；
     普通便签页（note.js）只保留同名的一行转调，调用点一行都没改。

   契约 —— host 由页面提供：
     isRich()    当前是不是富文本可见状态（Markdown 源码模式下很多操作要空转）
     save()      请求保存（页面自己的 400ms 防抖）
     hint(text, ok)  状态栏提示
     mdArea()    当前可见的 Markdown 源码 <textarea>，没有就返回 null
     send(obj)   发给宿主（图片上传用）

   依赖：window.CodeHL（code-hl.js），必须先加载。
   ========================================================================== */

(function (global) {
  'use strict';

  const MAX_IMG = 8 * 1024 * 1024;

  function create(root, host) {
    if (!root) throw new Error('EditorCore.create 需要一个根节点');
    const h = host || {};
    const isRich = h.isRich || (() => true);
    const save = h.save || (() => {});
    const hint = h.hint || (() => {});
    const send = h.send || (() => {});
    const mdArea = h.mdArea || (() => null);

    let reqSeq = 0;
    let lastPre = null;
    /* Markdown 源码模式下"上传中的图片占位符"：req -> token。
       必须是一张表而不是单个字段：连粘两张图时两次上传会同时在飞，
       只记最后一个的话，先回来的那张就会留在文本里变成一段死文字。 */
    const pending = new Map();

    /* ---- 基础查询 ------------------------------------------------------- */

    /* 从 node 往上找最近的 <pre>，找不到就返回 null。边界是 root：
       一页 N 个块，不能翻到别的块里去。 */
    function closestPre(node) {
      let el = node && node.nodeType === 1 ? node : (node ? node.parentElement : null);
      while (el && el !== root) {
        if (el.tagName === 'PRE') return el;
        el = el.parentElement;
      }
      return null;
    }

    function richOn() {
      return isRich() && !root.hidden;
    }

    function codeText(pre) {
      return CodeHL.textOf(pre).replace(/\n+$/, '');
    }

    /* ---- 着色时机 ------------------------------------------------------- */

    /* 着色交给 code-hl.js（内部是本地 highlight.js）。这里只负责"什么时候画"：
       · 页面载入、编辑器失焦、光标离开某个代码块 → 画
       · 光标还在某块里面 → 一律不画（换 DOM 会跳光标、甚至吃掉刚敲的字） */
    function paintCodes(force) {
      if (!richOn() || !global.CodeHL) return 0;
      return CodeHL.paintAll(root, { force: !!force });
    }

    /* 光标离开某块时把那块补上颜色。selectionchange 里做，因为这时候 DOM
       已经稳定，而且光标确定不在那一块了。 */
    function trackPre() {
      if (!richOn()) { lastPre = null; return; }
      const sel = global.getSelection();
      const pre = (sel && sel.rangeCount) ? closestPre(sel.getRangeAt(0).startContainer) : null;
      if (lastPre && lastPre !== pre && lastPre.isConnected) {
        CodeHL.paint(lastPre);
        ensureTrailingBlock();
      }
      lastPre = pre;
    }

    /* 编辑器末尾不能停在 <pre>/<hr>/<table> 上：那样鼠标点在下面的空白处
       没有任何东西可落，用户会觉得"光标出不来"。补一个空段落当落脚点。 */
    function ensureTrailingBlock() {
      if (!richOn()) return;
      const last = root.lastElementChild;
      if (!last) return;
      if (/^(PRE|HR|TABLE|BLOCKQUOTE|UL|OL)$/.test(last.tagName)) {
        const tail = document.createElement('div');
        tail.appendChild(document.createElement('br'));
        root.appendChild(tail);
      }
    }

    /* 把 <pre> 的正文换掉（只用于"退出代码块时削掉末尾空行"这一处，
       调用前光标已经要离开了，所以不用担心位置）。
       有 <code> 就写进 <code>：直接写 pre.textContent 会把 <code> 一起冲掉，
       导出的 HTML 里就少一层结构（也没了 language-x）。 */
    function setPreText(pre, text) {
      const code = pre.firstElementChild && pre.firstElementChild.tagName === 'CODE'
        ? pre.firstElementChild : null;
      if (code) code.textContent = text;
      else pre.textContent = text;
      CodeHL.paint(pre);
    }

    /* 光标是不是停在块的最末尾（它后面再没有可见字符）。
       不能拿字符偏移比 text.length —— textOf() 把 <br> 折成了 \n，而
       caretOffset() 只数文本节点，两者天生差几个字符。这里直接问 DOM：
       从光标到块尾的这一段 range 取字符串，全是空白就算"在末尾"。 */
    function caretAtEnd(pre) {
      const sel = global.getSelection();
      if (!sel || !sel.rangeCount || !sel.isCollapsed) return false;
      const r = sel.getRangeAt(0);
      if (!pre.contains(r.startContainer)) return false;
      const probe = document.createRange();
      probe.setStart(r.startContainer, r.startOffset);
      probe.setEnd(pre, pre.childNodes.length);
      return probe.toString().replace(/[\s\u200b]/g, '') === '';
    }

    /* 最后一行是不是空的。判据是 <pre> 的正文以换行结尾 —— 用户刚敲出来的那个
       空行正好长这样（Chromium 里是末尾多一个 <br>，textOf 折成 \n）。 */
    function lastLineEmpty(text) {
      const nl = text.lastIndexOf('\n');
      return nl >= 0 && text.slice(nl + 1) === '';
    }

    /* 退出代码块：在后面补一个空段落，把光标放进去。 */
    function exitCodeBlock(pre) {
      const text = CodeHL.textOf(pre);
      // 末尾那几行是空行（用户是连着敲回车敲出来的）就顺手削掉，别在代码块
      // 底下留一片空白 —— 那看起来像"块没结束"。
      if (/\n\s*$/.test(text)) setPreText(pre, text.replace(/\n+$/, ''));
      let next = pre.nextElementSibling;
      if (!next) {
        next = document.createElement('div');
        next.appendChild(document.createElement('br'));
        pre.after(next);
      }
      const r = document.createRange();
      r.setStart(next, 0);
      r.collapse(true);
      const sel = global.getSelection();
      sel.removeAllRanges();
      sel.addRange(r);
      root.focus();
      save();
      ensureTrailingBlock();
      return true;
    }

    /* 代码块里的按键。
       ★ 这里翻过一次车，留个记录：
         第一版为了"能从代码块里出来"，只看"光标后面到块尾全是空白"就跳出去。
         可是在块末尾正常敲回车想加第二行时，光标后面本来就是空的 —— 于是
         一按回车就被弹出块外，多行代码根本敲不进去（用户实测）。
         现在只认"当前这一行本来就是空行"：也就是**连按两次回车**才出去。

       显式出口：Ctrl+Enter（Alt/Cmd 也行）、Esc、光标在末尾按 ↓、空代码块直接回车、
       空代码块按退格整块拆掉。Shift+Enter 特意**不是**出口。 */
    function handleCodeKeys(e) {
      if (!richOn()) return false;
      const sel = global.getSelection();
      if (!sel || !sel.rangeCount) return false;
      const pre = closestPre(sel.getRangeAt(0).startContainer);
      if (!pre) return false;

      const text = CodeHL.textOf(pre);

      if (e.key === 'Enter') {
        if (e.ctrlKey || e.altKey || e.metaKey) {
          e.preventDefault();
          return exitCodeBlock(pre);
        }
        if (text === '') {
          e.preventDefault();
          return exitCodeBlock(pre);
        }
        if (caretAtEnd(pre) && lastLineEmpty(text)) {
          e.preventDefault();
          return exitCodeBlock(pre);
        }
        return false;                     // 其余情况交给浏览器换行
      }
      if (e.key === 'Escape' && !e.shiftKey) {
        e.preventDefault();
        return exitCodeBlock(pre);
      }
      if (e.key === 'ArrowDown' && !e.shiftKey && caretAtEnd(pre)) {
        e.preventDefault();
        return exitCodeBlock(pre);
      }
      /* Tab 在块里应该是缩进，不是"把焦点跳走"。 */
      if (e.key === 'Tab') {
        e.preventDefault();
        if (e.shiftKey) { unindent(); return true; }
        const before = CodeHL.textOf(pre);
        const caret = grabCaret();
        document.execCommand('insertText', false, '  ');
        /* execCommand 认的是"当前选区"，而文档没有焦点时它会连选区一起丢掉。
           所以先记一份，插不进去就自己塞（自检里就是这条兜底在起作用）。 */
        if (CodeHL.textOf(pre) === before) {
          putCaret(caret);
          insertRaw('  ');
        }
        save();
        return true;
      }
      if (e.key === 'Backspace' && text.trim() === '') {
        // 空的代码块：退格直接把它拆掉，变回普通段落
        e.preventDefault();
        const div = document.createElement('div');
        div.appendChild(document.createElement('br'));
        pre.replaceWith(div);
        const r = document.createRange();
        r.setStart(div, 0);
        r.collapse(true);
        sel.removeAllRanges();
        sel.addRange(r);
        save();
        return true;
      }
      return false;
    }

    /* 直接往光标处塞文字。execCommand 比它多一条"能撤销"，但要求文档有焦点，
       窗口在后台时静默失败 —— 所以两条路都留着。 */
    function insertRaw(text) {
      const sel = global.getSelection();
      if (!sel || !sel.rangeCount) return false;
      const r = sel.getRangeAt(0);
      r.deleteContents();
      const node = document.createTextNode(text);
      r.insertNode(node);
      const after = document.createRange();
      after.setStart(node, text.length);
      after.collapse(true);
      sel.removeAllRanges();
      sel.addRange(after);
      return true;
    }

    /* 存/还原光标。execCommand 在文档没有焦点时会把选区抹掉，
       到时候连"往哪儿插"都不知道了，先留一份。 */
    function grabCaret() {
      const sel = global.getSelection();
      return (sel && sel.rangeCount) ? sel.getRangeAt(0).cloneRange() : null;
    }

    function putCaret(r) {
      if (!r) return false;
      const sel = global.getSelection();
      sel.removeAllRanges();
      sel.addRange(r);
      return true;
    }

    /* Shift+Tab：把光标所在行开头的两格缩进去掉。
       只削光标前面的空格，不动别处 —— 块里可能还有别的行，改多了反而乱。 */
    function unindent() {
      const sel = global.getSelection();
      if (!sel.rangeCount) return;
      const r = sel.getRangeAt(0);
      const n = r.startContainer;
      if (n.nodeType !== 3) return;
      const v = n.nodeValue, off = r.startOffset;
      let del = 0;
      while (del < 2 && off - del - 1 >= 0 && v[off - del - 1] === ' ') del++;
      if (!del) return;
      const rr = document.createRange();
      rr.setStart(n, off - del);
      rr.setEnd(n, off);
      const backup = rr.cloneRange();
      sel.removeAllRanges();
      sel.addRange(rr);
      document.execCommand('delete', false, null);
      if (n.nodeValue === v) {              // 一个字符都没删掉 → 自己删
        putCaret(backup);
        backup.deleteContents();
      }
    }

    /* 插入代码块：先给选区套 formatBlock，再保证它后面有落脚点，
       最后把光标放进去、立刻上一次色（空块没什么可上的，主要是把语言标记写上）。 */
    function insertCodeBlock() {
      root.focus();
      const sel = global.getSelection();
      const pre0 = (sel && sel.rangeCount) ? closestPre(sel.getRangeAt(0).startContainer) : null;
      if (!pre0) {
        document.execCommand('formatBlock', false, '<pre>');
      }
      const pre = (sel && sel.rangeCount) ? closestPre(sel.getRangeAt(0).startContainer) : null;
      if (pre) {
        /* 特意不写死语言：留着让"光标离开时自动识别"去判。写死成 text 的话
           用户敲进来的 JS 永远不会上色，反而更差。 */
        CodeHL.paint(pre);
      }
      ensureTrailingBlock();
      save();
      hint('代码块 · 连按两次回车 或 Ctrl+Enter 可跳出');
    }

    function setCodeLang(lang) {
      const sel = global.getSelection();
      const pre = (sel && sel.rangeCount) ? closestPre(sel.getRangeAt(0).startContainer) : null;
      if (!pre) { hint('先把光标放到代码块里'); return; }
      const saved = CodeHL.caretOffset(pre);
      CodeHL.setLang(pre, lang);
      CodeHL.paint(pre);
      if (saved) CodeHL.restoreCaret({ ...saved, pre: pre });
      save();
      hint('代码语言：' + CodeHL.labelOf(lang || 'text'));
    }

    /* ---- 选区与插入 ----------------------------------------------------- */

    function caretRange() {
      const sel = global.getSelection();
      if (sel && sel.rangeCount) {
        const r = sel.getRangeAt(0);
        if (root.contains(r.commonAncestorContainer)) return r.cloneRange();
      }
      const r = document.createRange();
      r.selectNodeContents(root);
      r.collapse(false);
      return r;
    }

    function insertAtCaret(node) {
      const r = caretRange();
      r.deleteContents();
      r.insertNode(node);
      const after = document.createRange();
      after.setStartAfter(node);
      after.collapse(true);
      const sel = global.getSelection();
      sel.removeAllRanges();
      sel.addRange(after);
    }

    function caretToEnd() {
      const r = document.createRange();
      r.selectNodeContents(root);
      r.collapse(false);
      const sel = global.getSelection();
      sel.removeAllRanges();
      sel.addRange(r);
      root.scrollTop = root.scrollHeight;
    }

    function insertTask() {
      const sel = global.getSelection();
      if (!sel.rangeCount) return;
      const range = sel.getRangeAt(0);
      const div = document.createElement('div');
      div.className = 'task-line';
      div.dataset.done = '0';
      div.innerHTML = '<span class="chk" contenteditable="false" data-checked="0"></span><span class="task-text">' +
        (range.toString() || '待办') + '</span>';
      range.deleteContents();
      range.insertNode(div);
      // 光标放到任务后面
      const after = document.createElement('div');
      after.innerHTML = '<br>';
      div.after(after);
      const r2 = document.createRange();
      r2.setStart(after, 0);
      r2.collapse(true);
      sel.removeAllRanges();
      sel.addRange(r2);
    }

    /* ---- 纯文本 ⇄ HTML -------------------------------------------------- */

    /* 一行一个段落，空行留空；用 textContent 写入，文本里的 < > & 不会被当成标签 */
    function textToHtml(text) {
      const box = document.createElement('div');
      for (const line of String(text).split('\n')) {
        const d = document.createElement('div');
        if (line.trim() === '') d.appendChild(document.createElement('br'));
        else d.textContent = line;
        box.appendChild(d);
      }
      return box.innerHTML;
    }

    /* 削掉末尾连续的空白行块（<div><br></div> 这类）。只削"纯空白且没有
       图片/表格/代码块"的块——末尾停着一张图时不能删，那是用户的内容。 */
    function trimTrailingBlank(el) {
      while (el.lastElementChild) {
        const last = el.lastElementChild;
        if (last.tagName !== 'DIV') break;
        if (last.textContent.trim()) break;
        if (last.querySelector('img,pre,table,hr')) break;
        last.remove();
      }
    }

    /* ---- 图片 -----------------------------------------------------------
       图片不进数据库：正文里只存 file:///.../data/images/xxx.png 这样的链接。
       base64 内嵌会让一条记录涨到几 MB，而且 html / md 各存一份，之后每敲一个
       字都要重写整个 blob，编辑器会明显发卡。
       上传是异步的，所以先在光标处插一个占位 <img data-req="N">，宿主把文件
       落盘回一个 URL 再补 src —— 用户上传期间继续打字，图片位置也不会跑偏。

       三条入口：拖文件进来、Ctrl+V 粘截图、右键菜单「插入图片…」。 */
    function addImage(file) {
      if (!file || !file.type || file.type.indexOf('image/') !== 0) { hint('只能插入图片'); return; }
      if (file.size > MAX_IMG) { hint('图片太大（上限 8MB）'); return; }

      const req = ++reqSeq;
      const area = mdArea();
      if (area) {
        // 源码模式没有 DOM 插入点，先写一段占位文本，收到 URL 再换掉
        const token = '![](qnote-pending:' + req + ')';
        const start = area.selectionStart == null ? area.value.length : area.selectionStart;
        const end = area.selectionEnd == null ? start : area.selectionEnd;
        area.value = area.value.slice(0, start) + token + area.value.slice(end);
        area.selectionStart = area.selectionEnd = start + token.length;
        pending.set(req, token);
        save();
      } else {
        const ph = document.createElement('img');
        ph.className = 'pending';
        ph.setAttribute('data-req', String(req));
        ph.alt = '图片';
        insertAtCaret(ph);
        /* 兜底：宿主万一没回执（存图报错、进程卡住），占位图会永远挂在那里，
           用户只看到一个虚线空框、也不知道发生了什么。10 秒后自己收掉并说明。 */
        setTimeout(() => {
          const el = root.querySelector('img[data-req="' + req + '"]');
          if (el) {
            el.remove();
            hint('图片没能插入（宿主没有响应）');
          }
        }, 10000);
      }

      const reader = new FileReader();
      reader.onload = () => {
        send({ type: 'image', req: req, name: file.name || '', data: String(reader.result) });
        hint('图片处理中…');
      };
      reader.onerror = () => {
        const el = root.querySelector('img[data-req="' + req + '"]');
        if (el) el.remove();
        hint('读取图片失败');
      };
      reader.readAsDataURL(file);
    }

    /* 源码模式下的占位符凭 req 从 pending 里认领。 */
    function mdPendingToken(req) {
      return pending.get(req) || '';
    }

    function onImageOk(msg) {
      const el = root.querySelector('img[data-req="' + msg.req + '"]');
      if (el) {
        el.src = msg.url;
        el.classList.remove('pending');
        el.removeAttribute('data-req');
      }
      const area = mdArea();
      const token = mdPendingToken(msg.req);
      if (area && token) {
        area.value = area.value.replace(token, '![](' + msg.url + ')');
      }
      pending.delete(msg.req);
      save();
      hint('图片已插入');
    }

    function onImageFail(msg) {
      const el = root.querySelector('img[data-req="' + msg.req + '"]');
      if (el) el.remove();
      const area = mdArea();
      const token = mdPendingToken(msg.req);
      if (area && token) {
        area.value = area.value.replace(token, '');
      }
      pending.delete(msg.req);
      hint('图片没插进去（存盘失败）');
    }

    // 宿主文件框选的图：这时 URL 已经就绪，直接插
    function onImageIn(url) {
      if (!url) return;
      const area = mdArea();
      if (area) {
        const start = area.selectionStart == null ? area.value.length : area.selectionStart;
        const txt = '![](' + url + ')';
        area.value = area.value.slice(0, start) + txt
          + area.value.slice(area.selectionEnd == null ? start : area.selectionEnd);
        area.selectionStart = area.selectionEnd = start + txt.length;
        save();
      } else {
        const img = document.createElement('img');
        img.src = url;
        img.alt = '图片';
        insertAtCaret(img);
        save();
      }
      hint('图片已插入');
    }

    /* 判定规则见模块末尾的 pickImageFile —— 与实例无关，页面也直接用它。 */

    return {
      root: root,
      closestPre: closestPre,
      richOn: richOn,
      codeText: codeText,
      paintCodes: paintCodes,
      trackPre: trackPre,
      ensureTrailingBlock: ensureTrailingBlock,
      setPreText: setPreText,
      caretAtEnd: caretAtEnd,
      lastLineEmpty: lastLineEmpty,
      exitCodeBlock: exitCodeBlock,
      handleCodeKeys: handleCodeKeys,
      insertRaw: insertRaw,
      grabCaret: grabCaret,
      putCaret: putCaret,
      unindent: unindent,
      insertCodeBlock: insertCodeBlock,
      setCodeLang: setCodeLang,
      insertTask: insertTask,
      caretRange: caretRange,
      insertAtCaret: insertAtCaret,
      caretToEnd: caretToEnd,
      textToHtml: textToHtml,
      trimTrailingBlank: trimTrailingBlank,
      addImage: addImage,
      onImageOk: onImageOk,
      onImageFail: onImageFail,
      onImageIn: onImageIn,
      pickImageFile: pickImageFile,
      MAX_IMG: MAX_IMG
    };
  }

  /* 判定不能只看 item.type：
       · 截图（Win+Shift+S）、画图、浏览器里右键复制图片 → image/png 的 file item
       · 资源管理器里复制一个图片文件 → 是 file item，但 type 可能是空串，
         要靠扩展名认
     与实例无关，所以挂在模块上，页面可以直接用。 */
  function pickImageFile(dt) {
    if (!dt) return null;
    const items = Array.from(dt.items || []);
    for (const it of items) {
      if (it.kind !== 'file') continue;
      const f = it.getAsFile();
      if (!f) continue;
      if (/^image\//i.test(f.type || '') || /\.(png|jpe?g|gif|webp|bmp)$/i.test(f.name || ''))
        return f;
    }
    const files = Array.from(dt.files || []);
    for (const f of files) {
      if (/^image\//i.test(f.type || '') || /\.(png|jpe?g|gif|webp|bmp)$/i.test(f.name || ''))
        return f;
    }
    return null;
  }

  global.EditorCore = { create: create, pickImageFile: pickImageFile };
})(window);
