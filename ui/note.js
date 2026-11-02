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
    app: { transparent: false, fontSize: 15 }
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
