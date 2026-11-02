/* ============================================================================
   note.js —— 一张便签的页面逻辑

   与宿主的分工：
     页面只管"编辑体验"，不碰数据库。任何要落盘的东西都 postMessage 给 AHK，
     由 AHK 单线程写 SQLite。保存是 400ms 防抖，切换模式/失焦/关闭前会立刻保存。

   两种编辑模式：
     rich —— contenteditable，正本是 innerHTML；md 源码是导出物
     md   —— textarea，正本是 Markdown；html 是 MD.render 出来的
   保存时四种表示一起发（html / text / md / mode），宿主原样入库。
   ========================================================================== */

(function () {
  'use strict';

  const bridge = window.chrome && window.chrome.webview;
  const $ = id => document.getElementById(id);

  const editor = $('editor');
  const source = $('source');
  const floatbar = $('floatbar');
  const hintEl = $('hint');
  const countEl = $('count');

  const state = {
    id: 0,
    mode: 'rich',
    color: 'yellow',
    pinned: 0,
    ready: false,
    dirty: false,
    saveTimer: 0,
    app: { transparent: false, fontSize: 15 },
    mdPending: {}          // Markdown 源码模式下，上传中的图片占位符：req -> token
  };

  /* ---- 与宿主通信 ------------------------------------------------------- */

  function send(obj) {
    if (bridge) bridge.postMessage(obj);
  }

  if (bridge) {
    bridge.addEventListener('message', ev => {
      const msg = ev.data;
      if (!msg || !msg.type) return;
      switch (msg.type) {
        case 'init': onInit(msg); break;
        case 'color': applyColor(msg.color); break;
        case 'pin': setPinned(msg.on); break;
        case 'toggle-md': setMode(state.mode === 'md' ? 'rich' : 'md'); break;
        case 'copy-all': copyAll(); break;
        case 'font': applyFontSize(msg.size); break;
        case 'image-ok': onImageOk(msg); break;
        case 'image-fail': onImageFail(msg); break;
        case 'image-in': onImageIn(msg.url); break;
        case 'pick-image': hint('用拖拽或 Ctrl+V 也能插图'); break;
        case 'focus': editor.focus(); break;
      }
    });
  }

  function onInit(msg) {
    const n = msg.note;
    state.id = n.id;
    state.mode = n.mode === 'md' ? 'md' : 'rich';
    state.app = msg.app || state.app;

    document.body.classList.toggle('transparent', !!state.app.transparent);
    // 拖动模式：manual = 顶栏让出来自己拖（默认）；native = 还给 -webkit-app-region
    document.body.dataset.drag = state.app.drag === 'native' ? 'native' : 'manual';
    if (state.app.fontSize) applyFontSize(state.app.fontSize);
    applyColor(n.color);
    setPinned(n.pinned);

    if (state.mode === 'md') {
      source.value = n.md || '';
      editor.hidden = true;
      source.hidden = false;
    } else {
      editor.innerHTML = n.html || (n.md ? MD.render(n.md) : '');
      editor.hidden = false;
      source.hidden = true;
    }
    state.ready = true;
    refreshEmpty();
    updateCount();
    hint('就绪');

    // 空白便签直接进编辑态
    if (!editor.innerText.trim() && !source.value.trim()) {
      if (state.mode === 'rich') editor.focus();
      else source.focus();
    }
  }

  /* ---- 保存 ------------------------------------------------------------- */

  function snapshot() {
    if (state.mode === 'md') {
      const md = source.value;
      return { md: md, html: MD.render(md), text: MD.plain(md), mode: 'md' };
    }
    const html = editor.innerHTML;
    return { html: html, text: editor.innerText, md: MD.toMarkdown(html), mode: 'rich' };
  }

  function saveNow() {
    if (!state.ready) return;
    clearTimeout(state.saveTimer);
    state.saveTimer = 0;
    const s = snapshot();
    send({
      type: 'save',
      id: state.id,
      title: state.mode === 'md' ? MD.title(s.md, true) : MD.title(s.text, false),
      html: s.html,
      text: s.text,
      md: s.md,
      mode: s.mode
    });
    state.dirty = false;
    hint('已保存 ' + new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' }));
  }

  function scheduleSave() {
    state.dirty = true;
    clearTimeout(state.saveTimer);
    state.saveTimer = setTimeout(saveNow, 400);
    hint('编辑中…');
  }

  editor.addEventListener('input', () => { refreshEmpty(); updateCount(); scheduleSave(); });
  source.addEventListener('input', () => { updateCount(); scheduleSave(); });
  editor.addEventListener('blur', saveNow);
  source.addEventListener('blur', saveNow);

  /* ---- 模式切换 --------------------------------------------------------- */

  function setMode(mode) {
    if (mode === state.mode) return;
    if (mode === 'md') {
      const md = MD.toMarkdown(editor.innerHTML);
      source.value = md;
      editor.hidden = true;
      source.hidden = false;
      state.mode = 'md';
      source.focus();
      const end = source.value.length;
      source.setSelectionRange(end, end);
      $('btnMd').classList.add('active');
      hint('Markdown 源码 · Ctrl+M 返回');
    } else {
      editor.innerHTML = MD.render(source.value);
      editor.hidden = false;
      source.hidden = true;
      state.mode = 'rich';
      editor.focus();
      $('btnMd').classList.remove('active');
      hint('所见即所得 · Ctrl+M 看源码');
    }
    refreshEmpty();
    updateCount();
    saveNow();
  }

  /* ---- 顶栏拖动 --------------------------------------------------------- */

  /* 默认手动拖：便签是 WS_EX_LAYERED 的透明窗口，-webkit-app-region: drag 那条
     原生路线在真机上拖不动（能点、不跟手）。这里按下就通知宿主进系统移动循环。
     drag=native 时 CSS 会把顶栏交还给 app-region，浏览器会吃掉 mousedown，
     下面这段自然不会被触发，两种模式互不干扰。 */
  document.querySelector('.bar').addEventListener('mousedown', e => {
    if (e.button !== 0) return;
    if (e.target.closest('button')) return;
    if (state.mode === 'md' && e.target === source) return;
    e.preventDefault();
    send({ type: 'drag-start', id: state.id });
  });

  /* ---- 工具栏 ----------------------------------------------------------- */

  $('btnMd').addEventListener('click', () => setMode(state.mode === 'md' ? 'rich' : 'md'));
  $('btnPin').addEventListener('click', () => {
    state.pinned = state.pinned ? 0 : 1;
    setPinned(state.pinned);
    send({ type: 'pin', id: state.id, on: !!state.pinned });
  });
  $('btnMenu').addEventListener('click', () => send({ type: 'menu', id: state.id }));
  $('btnClose').addEventListener('click', () => send({ type: 'close', id: state.id }));

  /* 右键菜单用系统原生菜单（由宿主弹），不自己画：便签窗口最小可以缩到
     180×140，页面内的菜单根本放不下九项，原生菜单才能超出窗口边界。
     AreDefaultContextMenusEnabled 已经在宿主侧关掉了，所以不会打架。
     注意别拦输入框的"粘贴"场景：菜单里没有粘贴项，但右键后 Ctrl+V 仍可用。 */
  document.addEventListener('contextmenu', e => {
    e.preventDefault();
    send({ type: 'menu', id: state.id });
  });

  function setPinned(on) {
    state.pinned = on ? 1 : 0;
    $('btnPin').classList.toggle('active', !!on);
    $('btnPin').title = on ? '已置顶（点击取消）' : '置顶';
  }

  function applyColor(name) {
    state.color = name || 'yellow';
    document.body.dataset.color = state.color;
  }

  /* ---- 选区浮动工具条 --------------------------------------------------- */

  let savedRange = null;

  function selectionInside() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return false;
    const range = sel.getRangeAt(0);
    return editor.contains(range.commonAncestorContainer);
  }

  document.addEventListener('selectionchange', () => {
    if (state.mode !== 'rich') { floatbar.hidden = true; return; }
    if (!selectionInside()) { floatbar.hidden = true; return; }
    const sel = window.getSelection();
    savedRange = sel.getRangeAt(0).cloneRange();
    const rect = savedRange.getBoundingClientRect();
    if (!rect || (!rect.width && !rect.height)) { floatbar.hidden = true; return; }
    floatbar.hidden = false;
    const bw = floatbar.offsetWidth;
    const bh = floatbar.offsetHeight;
    let left = rect.left + rect.width / 2 - bw / 2;
    let top = rect.top - bh - 8;
    if (top < 4) top = rect.bottom + 8;
    left = Math.max(4, Math.min(left, window.innerWidth - bw - 4));
    floatbar.style.left = Math.round(left) + 'px';
    floatbar.style.top = Math.round(top) + 'px';
  });

  // 点工具条不能把选区弄丢
  floatbar.addEventListener('mousedown', e => e.preventDefault());

  floatbar.addEventListener('click', e => {
    const btn = e.target.closest('button');
    if (!btn) return;
    const cmd = btn.dataset.cmd;
    editor.focus();
    if (savedRange) {
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(savedRange);
    }
    if (cmd === 'task') {
      insertTask();
    } else if (cmd === 'code') {
      wrapInlineCode();
    } else if (cmd === 'codeblock') {
      document.execCommand('formatBlock', false, '<pre>');
    } else if (cmd === 'link') {
      insertLink();
    } else if (cmd.startsWith('formatBlock:')) {
      document.execCommand('formatBlock', false, '<' + cmd.split(':')[1] + '>');
    } else {
      document.execCommand(cmd, false, null);
    }
    scheduleSave();
    refreshEmpty();
    updateCount();
  });

  function insertTask() {
    const sel = window.getSelection();
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

  /* 插入链接。分两种情况：有选中文字就给它套链接（createLink），
     没选中就把 URL 本身当文字插进去（insertHTML）。
     prompt() 在 WebView2 里是原生对话框，能用；这里不用页面内的小表单，
     是因为便签最小只有 180px 宽，弹个输入框会把窗口撑得一塌糊涂。 */
  function insertLink() {
    const sel = window.getSelection();
    const picked = sel && !sel.isCollapsed ? sel.toString() : '';
    const url = window.prompt('链接地址（http:// 或 https://）', 'https://');
    if (!url) return;
    const u = url.trim();
    if (!/^(https?:|mailto:)/i.test(u)) {
      hint('只支持 http / https / mailto 链接');
      return;
    }
    editor.focus();
    if (savedRange) {
      const s = window.getSelection();
      s.removeAllRanges();
      s.addRange(savedRange);
    }
    if (picked) {
      document.execCommand('createLink', false, u);
    } else {
      const a = document.createElement('a');
      a.href = u;
      a.target = '_blank';
      a.rel = 'noreferrer';
      a.textContent = u;
      insertAtCaret(a);
    }
    scheduleSave();
    hint('链接已插入');
  }

  function wrapInlineCode() {
    const sel = window.getSelection();
    if (!sel.rangeCount || sel.isCollapsed) return;
    const range = sel.getRangeAt(0);
    const code = document.createElement('code');
    code.textContent = range.toString();
    range.deleteContents();
    range.insertNode(code);
    range.setStartAfter(code);
    range.collapse(true);
    sel.removeAllRanges();
    sel.addRange(range);
  }

  /* ---- 图片 ------------------------------------------------------------- */

  /* 图片不进数据库：正文里只存 file:///.../data/images/xxx.png 这样的链接。
     理由 —— base64 内嵌会让一条便签的记录涨到几 MB，而且 body_html 和 body_md
     各存一份，之后每敲一个字都要重写整个 blob，编辑器会明显发卡。
     上传是异步的，所以先在光标处插一个占位 <img data-req="N">，宿主把文件落盘
     回一个 URL 再补 src。这样用户上传期间继续打字，图片位置也不会跑偏。

     三条入口：拖文件进来、Ctrl+V 粘截图、右键菜单「插入图片…」（宿主弹系统
     文件框，然后发 image-in 过来 —— 页内 <input type=file> 在没有用户手势的
     postMessage 上下文里会被浏览器拦，所以那条路走不通）。 */
  let reqSeq = 0;
  const MAX_IMG = 8 * 1024 * 1024;

  function caretRange() {
    const sel = window.getSelection();
    if (sel && sel.rangeCount) {
      const r = sel.getRangeAt(0);
      if (editor.contains(r.commonAncestorContainer)) return r.cloneRange();
    }
    const r = document.createRange();
    r.selectNodeContents(editor);
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
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(after);
  }

  function addImage(file) {
    if (!file || !file.type || file.type.indexOf('image/') !== 0) { hint('只能插入图片'); return; }
    if (file.size > MAX_IMG) { hint('图片太大（上限 8MB）'); return; }

    const req = ++reqSeq;
    if (state.mode === 'md') {
      // 源码模式没有 DOM 插入点，先写一段占位文本，收到 URL 再换掉
      const token = '![](qnote-pending:' + req + ')';
      const s = source;
      const start = s.selectionStart == null ? s.value.length : s.selectionStart;
      const end = s.selectionEnd == null ? start : s.selectionEnd;
      s.value = s.value.slice(0, start) + token + s.value.slice(end);
      s.selectionStart = s.selectionEnd = start + token.length;
      state.mdPending[req] = token;
      scheduleSave();
    } else {
      const ph = document.createElement('img');
      ph.className = 'pending';
      ph.setAttribute('data-req', String(req));
      ph.alt = '图片';
      insertAtCaret(ph);
    }

    const reader = new FileReader();
    reader.onload = () => {
      send({ type: 'image', req: req, name: file.name || '', data: String(reader.result) });
      hint('图片处理中…');
    };
    reader.onerror = () => {
      const el = editor.querySelector('img[data-req="' + req + '"]');
      if (el) el.remove();
      hint('读取图片失败');
    };
    reader.readAsDataURL(file);
  }

  function onImageOk(msg) {
    const el = editor.querySelector('img[data-req="' + msg.req + '"]');
    if (el) {
      el.src = msg.url;
      el.classList.remove('pending');
      el.removeAttribute('data-req');
    }
    const token = state.mdPending[msg.req];
    if (token) {
      source.value = source.value.replace(token, '![](' + msg.url + ')');
      delete state.mdPending[msg.req];
    }
    scheduleSave();
    hint('图片已插入');
  }

  function onImageFail(msg) {
    const el = editor.querySelector('img[data-req="' + msg.req + '"]');
    if (el) el.remove();
    const token = state.mdPending[msg.req];
    if (token) {
      source.value = source.value.replace(token, '');
      delete state.mdPending[msg.req];
    }
    hint('图片没插进去（存盘失败）');
  }

  // 宿主文件框选的图：这时 URL 已经就绪，直接插
  function onImageIn(url) {
    if (!url) return;
    if (state.mode === 'md') {
      const s = source;
      const start = s.selectionStart == null ? s.value.length : s.selectionStart;
      const txt = '![](' + url + ')';
      s.value = s.value.slice(0, start) + txt + s.value.slice(s.selectionEnd == null ? start : s.selectionEnd);
      s.selectionStart = s.selectionEnd = start + txt.length;
      scheduleSave();
    } else {
      const img = document.createElement('img');
      img.src = url;
      img.alt = '图片';
      insertAtCaret(img);
      scheduleSave();
    }
    hint('图片已插入');
  }

  /* 拖文件进来：光标先落到鼠标位置，图片才插在"掉下来的地方"。
     caretRangeFromPoint 在 WebView2（Chromium）里有；取不到就退回当前光标。

     注意两个监听区都要挂：富文本模式粘到 #editor，Markdown 源码模式粘到
     #source（textarea）。只挂 rich 那一侧的话，用户在源码模式里拖图/粘图
     会**完全没反应** —— 而 document 级的 preventDefault 又把默认行为拦掉了，
     连"什么都没发生"都显得莫名其妙。 */
  function onDrop(e) {
    const list = (e.dataTransfer && e.dataTransfer.files) || [];
    const files = Array.from(list).filter(f => f && f.type && f.type.indexOf('image/') === 0);
    if (!files.length) return;
    e.preventDefault();
    document.body.classList.remove('dragging');
    // textarea 里没有 DOM 选区，caretRangeFromPoint 对它是无意义的，跳过
    if (state.mode !== 'md') {
      try {
        const r = document.caretRangeFromPoint(e.clientX, e.clientY);
        if (r) {
          const sel = window.getSelection();
          sel.removeAllRanges();
          sel.addRange(r);
        }
      } catch (_) { /* 取不到就用当前选区 */ }
    }
    files.forEach(addImage);
  }

  // Ctrl+V 粘截图：只拦带图片的粘贴，普通文字照旧走浏览器默认行为
  function onPaste(e) {
    const items = Array.from((e.clipboardData && e.clipboardData.items) || []);
    const hit = items.find(it => it.type && it.type.indexOf('image/') === 0);
    if (!hit) return;
    const file = hit.getAsFile();
    if (!file) return;
    e.preventDefault();
    addImage(file);
  }

  editor.addEventListener('drop', onDrop);
  editor.addEventListener('paste', onPaste);
  source.addEventListener('drop', onDrop);
  source.addEventListener('paste', onPaste);

  /* ---- 勾选框 ----------------------------------------------------------- */

  editor.addEventListener('click', e => {
    const chk = e.target.closest('.chk');
    if (!chk) return;
    e.preventDefault();
    const on = chk.getAttribute('data-checked') === '1' ? '0' : '1';
    chk.setAttribute('data-checked', on);
    const line = chk.closest('.task-line');
    if (line) line.dataset.done = on;
    scheduleSave();
  });

  /* ---- 缩放手柄 --------------------------------------------------------- */

  $('grip').addEventListener('mousedown', e => {
    e.preventDefault();
    send({ type: 'resize-start', id: state.id, edge: 'se' });
  });

  /* ---- Ctrl + 滚轮缩放字号 ---------------------------------------------- */

  /* 改的是全局字号（config.ini 的 [appearance] fontSize），宿主收到 font 消息
     后落盘并广播给其它已打开的便签。不是"每张便签存一个字号"：用户要的是
     "把字调大点"这个动作，和浏览器 Ctrl+滚轮 一个心智，不该逐张去调。
     passive:false 必须显式写上 —— Chrome 默认把 wheel 监听当被动的，那样
     preventDefault() 无效（WebView2 会同时按自己的比例缩放整个页面，双倍放大）。 */
  const FS_MIN = 10, FS_MAX = 32, FS_DEFAULT = 15;

  function applyFontSize(px) {
    const n = Math.max(FS_MIN, Math.min(FS_MAX, Math.round(Number(px) || FS_DEFAULT)));
    state.app.fontSize = n;
    document.documentElement.style.setProperty('--fs', n + 'px');
    return n;
  }

  window.addEventListener('wheel', e => {
    if (!e.ctrlKey || !e.deltaY) return;
    e.preventDefault();
    const step = e.deltaY < 0 ? 1 : -1;
    const next = applyFontSize((state.app.fontSize || FS_DEFAULT) + step);
    hint('字号 ' + next);
    send({ type: 'font', size: next });
  }, { passive: false });

  /* ---- 快捷键 ----------------------------------------------------------- */

  document.addEventListener('keydown', e => {
    const mod = e.ctrlKey || e.metaKey;
    if (mod && e.key.toLowerCase() === 's') { e.preventDefault(); saveNow(); return; }
    if (mod && e.key.toLowerCase() === 'm') { e.preventDefault(); setMode(state.mode === 'md' ? 'rich' : 'md'); return; }
    if (e.key === 'Escape') { saveNow(); window.getSelection().removeAllRanges(); return; }

    // Markdown 源码里 Tab 要能缩进，而不是把焦点跳走
    if (state.mode === 'md' && e.key === 'Tab') {
      e.preventDefault();
      const s = source;
      const start = s.selectionStart, end = s.selectionEnd;
      s.value = s.value.slice(0, start) + '  ' + s.value.slice(end);
      s.selectionStart = s.selectionEnd = start + 2;
      scheduleSave();
    }

    if (state.mode === 'rich' && mod) {
      const k = e.key.toLowerCase();
      if (k === 'b' || k === 'i' || k === 'u') {
        e.preventDefault();
        document.execCommand(k === 'b' ? 'bold' : k === 'i' ? 'italic' : 'underline', false, null);
        scheduleSave();
      }
    }
  });

  /* ---- 杂项 ------------------------------------------------------------- */

  function refreshEmpty() {
    const empty = state.mode === 'rich'
      ? !editor.textContent.trim() && !editor.querySelector('img,hr,table')
      : !source.value.trim();
    editor.classList.toggle('empty', state.mode === 'rich' && empty);
  }

  function updateCount() {
    const t = state.mode === 'md' ? source.value : editor.innerText;
    const n = (t || '').replace(/\s/g, '').length;
    countEl.textContent = n ? n + ' 字' : '';
  }

  let hintTimer = 0;
  function hint(text) {
    hintEl.textContent = text;
    const status = $('status');
    status.classList.add('show');
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => status.classList.remove('show'), 1600);
  }

  function copyAll() {
    const text = state.mode === 'md' ? source.value : editor.innerText;
    navigator.clipboard.writeText(text).then(
      () => hint('已复制'),
      () => hint('复制失败')
    );
  }

  // 拖文件进来时别让 WebView2 把整个页面导航走
  ['dragover', 'drop'].forEach(t => document.addEventListener(t, e => {
    if (e.dataTransfer && Array.from(e.dataTransfer.types || []).includes('Files')) {
      e.preventDefault();
      document.body.classList.toggle('dragging', t === 'dragover');
    }
  }));

  // 页面就绪：告诉宿主可以下发 init 了
  send({ type: 'ready', id: new URLSearchParams(location.search).get('id') });
})();
