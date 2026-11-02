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
    opacity: 100,          // 30~100，整张便签的不透明度（宿主菜单里调）
    ready: false,
    dirty: false,
    maxed: false,          // 窗口被双击标题栏放大了（拖动/拉手柄这时要停手）
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
        case 'opacity': applyOpacity(msg.pct); break;
        case 'toggle-md': setMode(state.mode === 'md' ? 'rich' : 'md'); break;
        case 'copy-all': copyAll(); break;
        case 'font': applyFontSize(msg.size); break;
        case 'image-ok': onImageOk(msg); break;
        case 'image-fail': onImageFail(msg); break;
        case 'image-in': onImageIn(msg.url); break;
        case 'pick-image': hint('用拖拽或 Ctrl+V 也能插图'); break;
        case 'focus': editor.focus(); break;
        case 'saved': onSaved(msg); break;
        case 'cmd': runCmd(msg.name, msg); break;
        case 'max': setMaxed(msg.on); break;
        case 'toast': hint(msg.text || ''); break;
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
    applyOpacity(n.opacity);

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

    /* 库里的 body_html 本来就带着上一次的着色 span，能直接显示；但老数据、
       以及从 Markdown 渲染出来的代码块可能是素的，补一次。注意这时光标还没
       进编辑区，paintAll 不会碰到"正在编辑的块"。 */
    paintCodes(true);
    ensureTrailingBlock();

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
      let html = MD.render(md);
      /* 源码模式下编辑区里没有 DOM，代码块自然是素的。但 body_html 要拿去
         导出 HTML，颜色得在保存时就带上 —— 渲染到临时容器里上一次色再取
         innerHTML（容器没挂到文档，不影响页面和光标）。 */
      if (html.indexOf('<pre') >= 0 && window.CodeHL) {
        const box = document.createElement('div');
        box.innerHTML = html;
        CodeHL.paintAll(box, { force: true });
        html = box.innerHTML;
      }
      return { md: md, html: html, text: MD.plain(md), mode: 'md' };
    }
    const html = editor.innerHTML;
    return { html: html, text: editor.innerText, md: MD.toMarkdown(html), mode: 'rich' };
  }

  function saveNow(reason) {
    if (!state.ready) return;
    clearTimeout(state.saveTimer);
    state.saveTimer = 0;
    const s = snapshot();
    const manual = reason === 'manual';
    send({
      type: 'save',
      id: state.id,
      title: state.mode === 'md' ? MD.title(s.md, true) : MD.title(s.text, false),
      html: s.html,
      text: s.text,
      md: s.md,
      mode: s.mode,
      manual: manual ? 1 : 0
    });
    state.dirty = false;
    /* 自动保存用灰字时间戳（安静），Ctrl+S 用"保存中…"再让宿主回执改成
       "✓ 已保存" —— 用户按下去就想看见一个明确的答复，这是肌肉记忆。 */
    if (manual) hint('保存中…');
  }

  /* 宿主落库后的回执。只有 Ctrl+S 那条要显眼（"✓ 已保存 21:36:05"）：
     自动保存每 400ms 就可能来一次，每次都闪一下会把状态栏变成跑马灯。 */
  function onSaved(msg) {
    const t = new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
    state.lastSaved = t;
    if (msg && msg.manual) hint('✓ 已保存 ' + t, true);
  }

  function scheduleSave() {
    state.dirty = true;
    clearTimeout(state.saveTimer);
    state.saveTimer = setTimeout(() => saveNow(), 400);
    hint('编辑中…');
  }

  /* 打字时不要立刻重画代码块（光标在里面，重画就跳）。等 700ms 没人动了，
     把**除光标所在块以外**的块补一下色 —— 通常也就一两块，开销可以忽略。 */
  let paintTimer = 0;
  function schedulePaint() {
    clearTimeout(paintTimer);
    paintTimer = setTimeout(() => {
      paintCodes(false);
      ensureTrailingBlock();
    }, 700);
  }

  editor.addEventListener('input', () => { refreshEmpty(); updateCount(); scheduleSave(); schedulePaint(); });
  source.addEventListener('input', () => { updateCount(); scheduleSave(); });
  /* 失焦时把每块都补一次色：这时候光标已经走了，重画绝对安全，
     而且用户"准备离开这张便签"的时候最希望看到成品的样子。 */
  editor.addEventListener('blur', () => { paintCodes(false); saveNow(); });
  source.addEventListener('blur', () => saveNow());

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
      /* 从 Markdown 渲染出来的代码块是素的（只有语言 class），补一次色。
         这时光标在开头、不在任何 <pre> 里，重画是安全的。 */
      paintCodes(false);
      ensureTrailingBlock();
    }
    refreshEmpty();
    updateCount();
    saveNow();
  }

  /* ---- 顶栏拖动 / 双击最大化 --------------------------------------------- */

  /* 默认手动拖：便签是 WS_EX_LAYERED 的透明窗口，-webkit-app-region: drag 那条
     原生路线在真机上拖不动（能点、不跟手）。这里按下就通知宿主进系统移动循环。
     drag=native 时 CSS 会把顶栏交还给 app-region，浏览器会吃掉 mousedown，
     下面这段自然不会被触发，两种模式互不干扰。

     双击标题栏 = 最大化 / 还原。为什么不直接监听 dblclick：按下那一刻宿主已经
     进了系统的窗口移动循环（WM_NCLBUTTONDOWN），鼠标随后被系统接管 ——
     第二下的 click/dblclick 能不能派发到页面就不由我们说了算了。
     所以自己数点击：同一个位置、380ms 内的第二下就当双击，且**不**再发
     drag-start —— 否则第二次按下又会去拽窗口，把"放大"变成"挪一下"。 */
  const bar = document.querySelector('.bar');
  let lastDown = 0, lastX = 0, lastY = 0;
  const DBL_MS = 380, DBL_PX = 6;

  bar.addEventListener('mousedown', e => {
    if (e.button !== 0) return;
    if (e.target.closest('button')) return;
    if (state.mode === 'md' && e.target === source) return;
    e.preventDefault();

    const now = Date.now();
    if (now - lastDown < DBL_MS
      && Math.abs(e.screenX - lastX) < DBL_PX && Math.abs(e.screenY - lastY) < DBL_PX) {
      lastDown = 0;                       // 这一对用掉了，第三下重新计数
      send({ type: 'toggle-max', id: state.id });
      return;
    }
    lastDown = now; lastX = e.screenX; lastY = e.screenY;
    /* 最大化状态下没有"拖动"这回事（拖会把整屏的窗口挪走），双击才能还原。 */
    if (state.maxed) return;
    send({ type: 'drag-start', id: state.id });
  });

  function setMaxed(on) {
    state.maxed = !!on;
    document.body.dataset.max = state.maxed ? '1' : '0';
    hint(state.maxed ? '已铺满屏幕 · 双击标题栏还原' : '窗口已还原');
  }

  /* ---- 工具栏 ----------------------------------------------------------- */

  $('btnMd').addEventListener('click', () => setMode(state.mode === 'md' ? 'rich' : 'md'));
  $('btnPin').addEventListener('click', () => {
    state.pinned = state.pinned ? 0 : 1;
    setPinned(state.pinned);
    send({ type: 'pin', id: state.id, on: !!state.pinned });
  });
  /* ⋯ 按钮固定弹"便签操作"菜单：它是"这张便签"的总入口，不该跟着光标位置变 */
  $('btnMenu').addEventListener('click', () => send({ type: 'menu', id: state.id, zone: 'note' }));
  /* 右上角 X 是"收起"，不是删除。原来这个按钮直接 Destroy + Delete，
     和"关闭一个窗口"的直觉严重不符，误点一次便签就没了（虽然还能从列表里
     找回来，但正文已经删除）。删除只留右键菜单和列表窗口两个入口。 */
  $('btnClose').addEventListener('click', () => send({ type: 'hide', id: state.id }));

  /* 右键菜单用系统原生菜单（由宿主弹），不自己画：便签窗口最小可以缩到
     180×140，页面内的菜单根本放不下九项，原生菜单才能超出窗口边界。
     AreDefaultContextMenusEnabled 已经在宿主侧关掉了，所以不会打架。

     ★ 两套菜单，按落点分：
       标题栏 / 工具栏 / 状态栏 → zone=note   便签操作（置顶、颜色、导出、删除…）
       正文编辑区              → zone=edit   编辑命令（撤销、复制、粘贴、全选…）
     正文里右键弹出"删除这张便签"是很容易误点的组合，所以必须分开。

     右键落在代码块里时额外带 inpre + 当前语言，宿主据此决定要不要露出
     「代码语言」子菜单。 */
  document.addEventListener('contextmenu', e => {
    e.preventDefault();
    let inPre = 0, lang = '';
    if (state.mode === 'rich') {
      const pre = closestPre(e.target);
      if (pre) { inPre = 1; lang = CodeHL.detect(pre); }
    }
    send({ type: 'menu', id: state.id, zone: zoneOf(e.target), inpre: inPre, lang: lang });
  });

  /* 落点在正文里就是编辑菜单，其它（顶栏、底栏、缩放手柄）都是便签菜单 */
  function zoneOf(el) {
    if (state.mode === 'md') return (el === source) ? 'edit' : 'note';
    if (el === editor || editor.contains(el)) return 'edit';
    return 'note';
  }

  function closestPre(node) {
    let el = node && node.nodeType === 1 ? node : (node ? node.parentElement : null);
    while (el && el !== editor) {
      if (el.tagName === 'PRE') return el;
      el = el.parentElement;
    }
    return null;
  }

  function setPinned(on) {
    state.pinned = on ? 1 : 0;
    $('btnPin').classList.toggle('active', !!on);
    $('btnPin').title = on ? '已置顶（点击取消）' : '置顶';
  }

  function applyColor(name) {
    state.color = name || 'yellow';
    document.body.dataset.color = state.color;
  }

  /* 整张便签的不透明度。挂在 <html> 上而不是 .note：连 body 的兜底底色
     一起淡掉，分层窗口下才真的能透出桌面（只淡 .note 的话，不透明外观那条
     路——body 铺着便签色——看起来一点没变）。100% 时把样式清掉，
     不留 opacity:1 这种多余的合成层。 */
  function applyOpacity(pct) {
    const n = Math.max(30, Math.min(100, parseInt(pct, 10) || 100));
    state.opacity = n;
    document.documentElement.style.opacity = n >= 100 ? '' : String(n / 100);
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
    trackPre();                        // 光标离开代码块时给它补上颜色
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
      insertCodeBlock();
    } else if (cmd === 'link') {
      insertLink();
    } else if (cmd.startsWith('formatBlock:')) {
      document.execCommand('formatBlock', false, '<' + cmd.split(':')[1] + '>');
    } else {
      document.execCommand(cmd, false, null);
    }
    // 套完块级格式（h2 / 列表 / 引用）后可能把编辑器末尾变成块级元素，
    // 补一个落脚点，免得"光标出不来"的老毛病换个标签再犯一次。
    ensureTrailingBlock();
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
      /* 兜底：宿主万一没回执（存图报错、进程卡住），占位图会永远挂在那里，
         用户只看到一个虚线空框、也不知道发生了什么。10 秒后自己收掉并说明。 */
      setTimeout(() => {
        const el = editor.querySelector('img[data-req="' + req + '"]');
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

  /* Ctrl+V 粘图。只拦"带图片"的粘贴，普通文字照旧走浏览器默认行为。

     判定不能只看 item.type：
       · 截图（Win+Shift+S）、画图、浏览器里右键复制图片 → image/png 的 file item
       · 资源管理器里复制一个图片文件 → 是 file item，但 type 可能是空串，
         要靠扩展名认
     两种都收，否则"从文件夹复制一张图粘进来"会毫无反应。 */
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

  function onPaste(e) {
    const file = pickImageFile(e.clipboardData);
    if (!file) return;
    e.preventDefault();
    addImage(file);
  }

  /* 挂 document 而不是 editor：
     Ctrl+V 的 paste 事件投给"当前焦点元素"，用户在便签里点一下标题栏、
     或者刚关掉原生右键菜单，焦点就不在编辑区了，挂在 editor 上的监听根本
     收不到 —— 表现正是"右键插入图片能用，Ctrl+V 毫无反应"。
     capture 阶段挂可以保证在页面的其它处理之前拿到事件。 */
  document.addEventListener('drop', onDrop, true);
  document.addEventListener('paste', onPaste, true);

  /* ---- 代码块：着色 / 进出 / 语言 ---------------------------------------
     着色交给 code-hl.js（内部是本地 highlight.js）。这里只负责"什么时候画"：
       · 页面载入、编辑器失焦、光标离开某个代码块 → 画
       · 光标还在某块里面 → 一律不画（换 DOM 会跳光标、甚至吃掉刚敲的字）
     代价是正在打的那一块暂时是素的，一移开光标就上色。这个取舍是故意的：
     宁可颜色晚半秒，也不能让用户打字时丢字符。 */
  function richOn() {
    return state.mode === 'rich' && !editor.hidden;
  }

  function paintCodes(force) {
    if (!richOn() || !window.CodeHL) return 0;
    return CodeHL.paintAll(editor, { force: !!force });
  }

  /* 光标离开某块时把那块补上颜色。selectionchange 里做，因为这时候 DOM
     已经稳定，而且光标确定不在那一块了。 */
  let lastPre = null;
  function trackPre() {
    if (!richOn()) { lastPre = null; return; }
    const sel = window.getSelection();
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
    const last = editor.lastElementChild;
    if (!last) return;
    if (/^(PRE|HR|TABLE|BLOCKQUOTE|UL|OL)$/.test(last.tagName)) {
      const tail = document.createElement('div');
      tail.appendChild(document.createElement('br'));
      editor.appendChild(tail);
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
    const sel = window.getSelection();
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
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    editor.focus();
    scheduleSave();
    ensureTrailingBlock();
    return true;
  }

  /* 代码块里的按键。
     ★ 这里翻过一次车，留个记录：
       第一版为了"能从代码块里出来"，只看"光标后面到块尾全是空白"就跳出去。
       可是在块末尾正常敲回车想加第二行时，光标后面本来就是空的 —— 于是
       一按回车就被弹出块外，多行代码根本敲不进去（用户实测）。
       现在只认"当前这一行本来就是空行"：也就是**连按两次回车**才出去，
       和绝大多数笔记软件的代码块手感一致；只按一次永远是正常换行。

     显式出口（不用背也行，菜单/提示里都会写）：
       Ctrl+Enter（Alt/Cmd 也行）、Esc、光标在末尾按 ↓、空代码块直接回车、
       空代码块按退格整块拆掉。
     Shift+Enter 特意**不是**出口：那是"块内换行"的肌肉记忆，误触一次就等于
     把正在写的行扔出块外，比没有出口更气人。 */
  function handleCodeKeys(e) {
    if (!richOn()) return false;
    const sel = window.getSelection();
    if (!sel || !sel.rangeCount) return false;
    const pre = closestPre(sel.getRangeAt(0).startContainer);
    if (!pre) return false;

    const text = CodeHL.textOf(pre);

    if (e.key === 'Enter') {
      if (e.ctrlKey || e.altKey || e.metaKey) {
        e.preventDefault();
        return exitCodeBlock(pre);
      }
      /* 空块：回车就出去（刚插进来又不想要了，很自然的一下） */
      if (text === '') {
        e.preventDefault();
        return exitCodeBlock(pre);
      }
      /* 空行上再敲一次回车 → 出去（= 双击回车） */
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
      scheduleSave();
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
      scheduleSave();
      return true;
    }
    return false;
  }

  /* 直接往光标处塞文字。execCommand 比它多一条"能撤销"，但要求文档有焦点，
     窗口在后台时静默失败 —— 所以两条路都留着。 */
  function insertRaw(text) {
    const sel = window.getSelection();
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
    const sel = window.getSelection();
    return (sel && sel.rangeCount) ? sel.getRangeAt(0).cloneRange() : null;
  }

  function putCaret(r) {
    if (!r) return false;
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    return true;
  }

  /* Shift+Tab：把光标所在行开头的两格缩进去掉。
     只削光标前面的空格，不动别处 —— 块里可能还有别的行，改多了反而乱。 */
  function unindent() {
    const sel = window.getSelection();
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
    editor.focus();
    if (savedRange) {
      const s = window.getSelection();
      s.removeAllRanges();
      s.addRange(savedRange);
    }
    const sel = window.getSelection();
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
    scheduleSave();
    hint('代码块 · 连按两次回车 或 Ctrl+Enter 可跳出');
  }

  function setCodeLang(lang) {
    const sel = window.getSelection();
    const pre = (sel && sel.rangeCount) ? closestPre(sel.getRangeAt(0).startContainer) : null;
    if (!pre) { hint('先把光标放到代码块里'); return; }
    const saved = CodeHL.caretOffset(pre);
    CodeHL.setLang(pre, lang);
    CodeHL.paint(pre);
    if (saved) CodeHL.restoreCaret({ ...saved, pre: pre });
    scheduleSave();
    hint('代码语言：' + CodeHL.labelOf(lang || 'text'));
  }

  /* ---- 编辑菜单的命令 ---------------------------------------------------
     菜单由宿主画（系统原生），点哪一项就 postMessage 回来一条 cmd。
     剪切/复制走宿主的 A_Clipboard 而不是 navigator.clipboard：原生菜单点下去
     那一刻页面已经没有"用户手势"了，Clipboard API 会被拒。
     粘贴反过来 —— 读剪贴板必须靠真实按键，所以让宿主代按一次 Ctrl+V。 */
  function selectedText() {
    if (state.mode === 'md') {
      const s = source;
      const a = s.selectionStart, b = s.selectionEnd;
      if (a == null || a === b) return '';
      return s.value.slice(a, b);
    }
    return String(window.getSelection() || '');
  }

  function hasSelection() {
    if (state.mode === 'md') return source.selectionStart !== source.selectionEnd;
    const sel = window.getSelection();
    return !!(sel && sel.rangeCount && !sel.isCollapsed);
  }

  function deleteSelection() {
    if (state.mode === 'md') {
      const s = source;
      const a = s.selectionStart, b = s.selectionEnd;
      if (a != null && a !== b) {
        s.value = s.value.slice(0, a) + s.value.slice(b);
        s.selectionStart = s.selectionEnd = a;
        scheduleSave();
      }
      return;
    }
    document.execCommand('delete', false, null);
    scheduleSave();
  }

  function selectAllText() {
    if (state.mode === 'md') {
      source.focus();
      source.select();
      return;
    }
    const r = document.createRange();
    r.selectNodeContents(editor);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    editor.focus();
  }

  function runCmd(name, msg) {
    switch (name) {
      case 'undo': document.execCommand('undo', false, null); scheduleSave(); break;
      case 'redo': document.execCommand('redo', false, null); scheduleSave(); break;
      case 'cut': {
        const t = selectedText();
        if (!t) { hint('没有选中内容'); break; }
        send({ type: 'clipboard-set', text: t });
        deleteSelection();
        hint('已剪切');
        break;
      }
      case 'copy': {
        const t = selectedText();
        if (!t) { hint('没有选中内容'); break; }
        send({ type: 'clipboard-set', text: t });
        hint('已复制');
        break;
      }
      case 'paste':
        send({ type: 'paste-key' });
        break;
      case 'delete':
        deleteSelection();
        break;
      case 'select-all':
        selectAllText();
        break;
      case 'clear-format':
        if (state.mode === 'rich') { document.execCommand('removeFormat', false, null); scheduleSave(); }
        break;
      case 'codeblock':
        insertCodeBlock();
        break;
      case 'codelang':
        setCodeLang((msg && msg.lang) || '');
        break;
      case 'insert-image':
        send({ type: 'pick-image-req' });
        break;
      case 'toggle-md':
        setMode(state.mode === 'md' ? 'rich' : 'md');
        break;
      case 'save':
        saveNow('manual');
        break;
      default:
        break;
    }
  }

  /* ---- 点图片看原图 -----------------------------------------------------
     正文里的图最大 180px 高（见 note.css），看不清楚；点一下用遮罩铺满窗口
     显示原图。遮罩是 fixed 定位的独立元素，不参与正文排版，所以开关的时候
     文字不会跳动，也不会动到光标。 */
  const lightbox = $('lightbox');
  const lightboxImg = $('lightboxImg');

  function openLightbox(src, alt) {
    if (!src) return;
    lightboxImg.src = src;
    lightboxImg.alt = alt || '';
    lightbox.hidden = false;
  }

  function closeLightbox() {
    if (lightbox.hidden) return false;
    lightbox.hidden = true;
    lightboxImg.removeAttribute('src');
    return true;
  }

  lightbox.addEventListener('click', e => {
    e.preventDefault();
    closeLightbox();
  });

  editor.addEventListener('click', e => {
    const img = e.target;
    if (!img || img.tagName !== 'IMG' || img.classList.contains('pending')) return;
    e.preventDefault();
    openLightbox(img.getAttribute('src'), img.alt);
  });

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
    if (state.maxed) return;            // 已经占满整块屏，拉手柄只会让它变小，别理
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

    /* 宿主侧为了让 Ctrl+V / Ctrl+C 正常工作，开启了 WebView2 的浏览器快捷键
       （AreBrowserAcceleratorKeysEnabled）。副作用是 F5 / Ctrl+R 会刷新页面、
       Ctrl+P 会弹打印、Ctrl+F 会弹出查找条 —— 在一个便签窗口里全是误触。
       这些键在 Chromium 里页面能先拿到 keydown，preventDefault 掉即可。
       Ctrl+C/V/X/A/Z 千万别拦，那些正是我们要它工作的。 */
    if (e.key === 'F5' || (mod && ['r', 'p', 'f', 'n', 'o', 'j'].includes(e.key.toLowerCase()))) {
      e.preventDefault();
      return;
    }
    /* Ctrl+S：立刻落库，并且要看得见回执（宿主回 saved 之后显示"✓ 已保存"）。
       便签本身 400ms 就会自动保存，但按了没反应会让人以为保存失效。 */
    if (mod && e.key.toLowerCase() === 's') { e.preventDefault(); saveNow('manual'); return; }
    if (mod && e.key.toLowerCase() === 'm') { e.preventDefault(); setMode(state.mode === 'md' ? 'rich' : 'md'); return; }
    if (e.key === 'Escape') {
      if (closeLightbox()) return;      // 看图时 Esc 只关遮罩，别顺手把选区也清了
      /* Esc 在代码块里是"出来"，不是"存盘并清选区" —— 先让 handleCodeKeys
         处理，它没接手才走默认。 */
      if (handleCodeKeys(e)) return;
      saveNow();
      window.getSelection().removeAllRanges();
      return;
    }

    /* 代码块的出路。放在这里而不是 editor 上：Markdown 源码模式（textarea）
       也会冒泡到 document，handleCodeKeys 里已经按 richOn() 挡掉了。 */
    if (state.mode === 'rich' && handleCodeKeys(e)) return;

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
  function hint(text, ok) {
    hintEl.textContent = text;
    const status = $('status');
    status.classList.add('show');
    status.classList.toggle('ok', !!ok);
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => {
      status.classList.remove('show');
      status.classList.remove('ok');
    }, ok ? 2400 : 1600);
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
