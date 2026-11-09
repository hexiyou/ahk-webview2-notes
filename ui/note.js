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
        /* 宿主那边执行完图片操作（复制/另存/路径）后的回执。
           走状态栏而不是系统托盘气泡：气泡会被置顶的便签盖住，而且用户
           正在盯着这张便签，反馈就该出现在它自己身上。 */
        case 'hint': hint(msg.text || '', !!msg.ok); break;
        /* 宿主读好文件、问过"覆盖还是追加"之后，把正文发过来（见 App.ImportNote）。
           怎么落地是页面的事：富文本模式要把 Markdown 渲染成 DOM，源码模式原样贴。 */
        case 'import': doImport(msg); break;
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
    hideCodeCopy();     // 换模式时正文 DOM 整批换掉，手里那块 <pre> 已经作废
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

     ★ 三套菜单，按落点分：
       标题栏 / 工具栏 / 状态栏 → zone=note   便签操作（置顶、颜色、导出、删除…）
       正文编辑区              → zone=edit   编辑命令（撤销、复制、粘贴、全选…）
       图片（大图预览、正文缩略图）→ zone=image  复制图片 / 另存为 / 删除这张图
     正文里右键弹出"删除这张便签"是很容易误点的组合，所以必须分开。

     右键落在代码块里时额外带 inpre + 当前语言，宿主据此决定要不要露出
     「代码语言」子菜单。 */
  document.addEventListener('contextmenu', e => {
    e.preventDefault();
    hideCodeCopy();       // 弹菜单时那个小按钮让路，菜单本身就有「复制这段代码」

    /* 大图预览开着：不管点是遮罩还是图本身，都是"这张图"的菜单。
       要在下面的 zoneOf 之前判 —— 遮罩不在 editor 里，会被判成 zone=note，
       于是右键一张图却弹出"删除这张便签"。 */
    if (!lightbox.hidden) {
      ctxImg = lightboxFor;
      send({ type: 'menu', id: state.id, zone: 'image', src: lightboxImg.getAttribute('src') || '' });
      return;
    }

    /* 正文里对着缩略图右键，也是图片菜单。顺带把"图片删不掉"这条老路补上：
       点图片会打开预览，正文里根本选不中它，只能靠这个菜单删。 */
    if (state.mode === 'rich') {
      const im = (e.target && e.target.tagName === 'IMG') ? e.target : null;
      if (im && !im.classList.contains('pending')) {
        ctxImg = im;
        send({ type: 'menu', id: state.id, zone: 'image', src: im.getAttribute('src') || '' });
        return;
      }
    }

    let inPre = 0, lang = '';
    if (state.mode === 'rich') {
      const pre = closestPre(e.target);
      if (pre) { inPre = 1; lang = CodeHL.detect(pre); }
      /* 记下这一块：菜单点下去时光标可能已经不在块里了（右键不一定移动
         插入符），「复制这段代码」只能靠这份引用。 */
      ctxPre = pre;
    } else {
      ctxPre = null;
    }
    send({ type: 'menu', id: state.id, zone: zoneOf(e.target), inpre: inPre, lang: lang });
  });

  /* 落点在正文里就是编辑菜单，其它（顶栏、底栏、缩放手柄）都是便签菜单 */
  function zoneOf(el) {
    if (state.mode === 'md') return (el === source) ? 'edit' : 'note';
    if (el === editor || editor.contains(el)) return 'edit';
    return 'note';
  }

  /* 编辑内核（着色时机、代码块进出、Tab 缩进、插图、末尾兜底）在
     ui/editor-core.js 里，与待办页共用同一份实现。这里只做绑定：
     下面这些同名函数都是对 core 的一行转调，调用点（事件监听、菜单命令）
     一行都没改 —— 抽取是"搬家"，不是重写。 */
  const core = EditorCore.create(editor, {
    isRich: () => richOn(),
    save: () => scheduleSave(),
    hint: (text, ok) => hint(text, ok),
    mdArea: () => (state.mode === 'md' ? source : null),
    send: (obj) => send(obj)
  });

  function closestPre(node) {
    return core.closestPre(node);
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
    core.insertTask();
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

  /* ---- 图片 -------------------------------------------------------------
     图片管线（占位 <img data-req> → 宿主落盘 → 回填 src）在 editor-core.js，
     与待办事项共用。这里只留三个转调，事件监听保持原样。 */
  function caretRange() {
    return core.caretRange();
  }

  function insertAtCaret(node) {
    core.insertAtCaret(node);
  }

  function addImage(file) {
    core.addImage(file);
  }

  function onImageOk(msg) {
    core.onImageOk(msg);
  }

  function onImageFail(msg) {
    core.onImageFail(msg);
  }

  // 宿主文件框选的图：这时 URL 已经就绪，直接插
  function onImageIn(url) {
    core.onImageIn(url);
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
     哪种算图片由 editor-core 的 pickImageFile 判（截图 / 从资源管理器复制的文件
     两条路都要认，只认 item.type 的话后者会毫无反应）。 */
  function pickImageFile(dt) {
    return core.pickImageFile(dt);
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

  /* ---- 导入文件 ----------------------------------------------------------
     文件是宿主读的（编码识别、大小上限、覆盖/追加的询问都在那边），这里只拿到
     一段文本 + 格式 + 模式，负责把它变成正文。

     · Markdown → MD.render 出来的 DOM，导入完就是渲染好的样子（代码块还会着色）
     · TXT      → 一行一个段落，空行留空；用 textContent 写入，正文里的 < > & 不会被当成标签
     · 源码模式 → 两种格式都原样贴进去（那本来就是纯文本编辑区），
                  用户自己按 Ctrl+M 切回去就会渲染 */
  /* 纯文本 → HTML 与"削掉末尾空白块"在 editor-core 里（待办页导入也要用） */
  function textToHtml(text) {
    return core.textToHtml(text);
  }

  function trimTrailingBlank(root) {
    core.trimTrailingBlank(root);
  }

  function caretToEnd() {
    core.caretToEnd();
  }

  function doImport(msg) {
    const text = msg.text || '';
    if (!text.trim()) { hint('文件里没有内容'); return; }
    const isMd = msg.format === 'md';
    const replace = msg.mode === 'replace';
    hideCodeCopy();
    closeLightbox();

    if (state.mode === 'md') {
      const cur = source.value;
      source.value = replace ? text
        : (cur.trim() ? cur.replace(/\s+$/, '') + '\n\n' : '') + text;
      source.selectionStart = source.selectionEnd = source.value.length;
      source.scrollTop = source.scrollHeight;
    } else {
      const html = isMd ? MD.render(text) : textToHtml(text);
      if (replace) {
        editor.innerHTML = html;
      } else {
        /* 接在末尾，中间留**一个**空段落：最后一行和导入的第一行黏在一起会
           看起来像同一段。但原正文末尾本来就常常挂着几个空行（用户回车留下的），
           直接再补一个就成了三四行的空隙，所以先把末尾的空块削干净。 */
        if (editor.textContent.trim()) {
          trimTrailingBlank(editor);
          const sep = document.createElement('div');
          sep.appendChild(document.createElement('br'));
          editor.appendChild(sep);
        }
        editor.insertAdjacentHTML('beforeend', html);
      }
      paintCodes(true);
      ensureTrailingBlock();
      caretToEnd();
    }
    refreshEmpty();
    updateCount();
    saveNow('manual');
    const lines = text.split('\n').length;
    hint('已' + (replace ? '覆盖导入' : '追加导入') + ' ' + lines + ' 行'
      + (isMd ? ' Markdown' : ' 文本'), true);
  }

  /* ---- 代码块：着色 / 进出 / 语言 ---------------------------------------
     着色交给 code-hl.js（内部是本地 highlight.js）。这里只负责"什么时候画"：
       · 页面载入、编辑器失焦、光标离开某个代码块 → 画
       · 光标还在某块里面 → 一律不画（换 DOM 会跳光标、甚至吃掉刚敲的字）
     代价是正在打的那一块暂时是素的，一移开光标就上色。这个取舍是故意的：
     宁可颜色晚半秒，也不能让用户打字时丢字符。 */
  function richOn() {
    return state.mode === 'rich' && !editor.hidden;
  }

  /* 着色 / 光标离开补色 / 末尾落脚点 / 改 <pre> 正文，四件事都在 editor-core。
     "光标还在块里就绝不重画"这条策略也搬过去了，两个页面共用一套节奏。 */
  function paintCodes(force) {
    return core.paintCodes(force);
  }

  function trackPre() {
    core.trackPre();
  }

  function ensureTrailingBlock() {
    core.ensureTrailingBlock();
  }

  function setPreText(pre, text) {
    core.setPreText(pre, text);
  }

  /* 光标是否停在块尾 / 最后一行是否空 / 退出代码块 —— 都在 editor-core */
  function caretAtEnd(pre) {
    return core.caretAtEnd(pre);
  }

  function lastLineEmpty(text) {
    return core.lastLineEmpty(text);
  }

  function exitCodeBlock(pre) {
    return core.exitCodeBlock(pre);
  }

  /* 代码块里的按键（回车出去 / Esc / ↓ / Tab 缩进 / 空块退格拆掉）。
     ★ 那条"连按两次回车才出去"的教训写在 editor-core.js 里，别只改一边。 */
  function handleCodeKeys(e) {
    return core.handleCodeKeys(e);
  }

  /* 光标处的底层操作：塞文字 / 存还原选区 / 反缩进 —— 都在 editor-core */
  function insertRaw(text) {
    return core.insertRaw(text);
  }

  function grabCaret() {
    return core.grabCaret();
  }

  function putCaret(r) {
    return core.putCaret(r);
  }

  function unindent() {
    core.unindent();
  }

  /* 插入代码块。savedRange 是普通便签页浮动工具条记下的选区（core 不认识它），
     所以先在这里还原选区，再交给 core 去套 formatBlock。 */
  function insertCodeBlock() {
    editor.focus();
    if (savedRange) {
      const s = window.getSelection();
      s.removeAllRanges();
      s.addRange(savedRange);
    }
    core.insertCodeBlock();
  }

  function setCodeLang(lang) {
    core.setCodeLang(lang);
  }

  /* ---- 代码块右上角的「复制」按钮 ---------------------------------------
     参考博客里着色器的常见做法：鼠标移到代码块上，右上角浮出一个小按钮，
     点一下就把整块代码送进剪贴板。

     ★ 按钮既不能放进 <pre>，也不能放进 #editor：
       放进 <pre>    —— CodeHL.paint() 是直接换 innerHTML，按钮会被整块冲掉；
                        textOf() 还会把按钮上"复制"两个字算进代码里。
       放进 #editor  —— snapshot() 取的就是 editor.innerHTML，按钮会被当成
                        正文存进库，重新打开凭空多出一个按钮。
     所以它是 body 下的独立节点，position: fixed，靠 getBoundingClientRect()
     跟着代码块的位置走。不在文档流里，开关的时候文字不跳、光标也不动。
     （图片预览的遮罩 .lightbox 是同一个理由。） */
  const codeCopy = $('codeCopy');
  const codeCopyText = $('codeCopyText');
  let copyPre = null;           // 按钮当前对应哪一块 <pre>
  let copyHideTimer = 0;        // "鼠标离开后过一会儿再收"的定时器
  let copyOkTimer = 0;          // "已复制"回执的复位定时器
  let hoveringEditor = false;
  let ctxPre = null;            // 最近一次右键落的代码块（编辑菜单「复制这段代码」用）

  /* 代码块的纯文本。末尾那个换行是 <pre> 的排版产物（块尾总带一个 \n），
     复制出去会在粘贴处多一个空行 —— 和 Markdown 导出削掉它保持一致。
     （实现与待办页共用，在 editor-core 里。） */
  function codeText(pre) {
    return core.codeText(pre);
  }

  function resetCodeCopy() {
    clearTimeout(copyOkTimer);
    copyOkTimer = 0;
    codeCopy.classList.remove('ok');
    codeCopyText.textContent = '复制';
  }

  /* 把按钮摆到代码块右上角。返回 false 表示这块已经不在可见范围里了。 */
  function placeCodeCopy() {
    if (!copyPre || !copyPre.isConnected) return false;
    const ed = editor.getBoundingClientRect();
    const r = copyPre.getBoundingClientRect();
    /* 块整个滚出编辑区就收起；只露一半时把按钮压在可见区域顶端 ——
       "这块看得见却复制不了"比"按钮贴边走"更让人恼火。 */
    if (r.bottom < ed.top + 6 || r.top > ed.bottom - 6) return false;
    const w = codeCopy.offsetWidth || 56, h = codeCopy.offsetHeight || 21;
    let top = Math.min(Math.max(r.top + 4, ed.top + 2), ed.bottom - h - 2);
    let left = Math.min(r.right - w - 6, ed.left + editor.clientWidth - w - 2);
    left = Math.max(left, ed.left + 2);
    codeCopy.style.top = Math.round(top) + 'px';
    codeCopy.style.left = Math.round(left) + 'px';
    return true;
  }

  function showCodeCopy(pre) {
    if (!richOn() || !pre || !pre.isConnected) { hideCodeCopy(); return false; }
    if (pre !== copyPre) resetCodeCopy();
    copyPre = pre;
    clearTimeout(copyHideTimer);
    copyHideTimer = 0;
    /* ★ 先显示再量尺寸：display:none 的元素 offsetWidth 是 0，那样每次都会
       落到兜底的 56px，窄便签里按钮就会顶到右边框外面（实测偏 6px）。 */
    codeCopy.hidden = false;
    if (!placeCodeCopy()) { codeCopy.hidden = true; return false; }
    return true;
  }

  function hideCodeCopy() {
    clearTimeout(copyHideTimer);
    copyHideTimer = 0;
    codeCopy.hidden = true;
    copyPre = null;
    hoveringEditor = false;
  }

  /* 鼠标离开代码块后不立刻收：从块里移到按钮上那一瞬间会先收到"离开"，
     马上隐藏的话按钮根本点不到。留 200ms 缓冲。 */
  function hideCodeCopySoon() {
    if (codeCopy.hidden) { copyPre = null; return; }
    clearTimeout(copyHideTimer);
    copyHideTimer = setTimeout(hideCodeCopy, 200);
  }

  function copyCodeBlock(pre) {
    if (!pre || !pre.isConnected) { hint('代码块已经不在了'); return ''; }
    const text = codeText(pre);
    if (!text) { hint('这段代码是空的'); return ''; }
    /* 剪贴板交给宿主写：页面这边虽然算真用户手势，但宿主那一份实现会把
       换行统一成 CRLF —— 记事本之类只认 CRLF 的老程序才不会把整段代码
       挤成一行。见 note-window.ahk 的 clipboard-set / lib\clip.ahk。 */
    send({ type: 'clipboard-set', text: text });
    return text;
  }

  function reportCopied(text) {
    const lines = text.split('\n').length;
    hint(lines > 1 ? '已复制 ' + lines + ' 行代码' : '已复制代码');
  }

  /* mousedown 的默认行为会把焦点和光标挪走 —— 代码块里的选区、
     正在编辑的位置就都没了。拦下来，复制完还能接着往下敲。 */
  codeCopy.addEventListener('mousedown', e => e.preventDefault());

  codeCopy.addEventListener('mouseenter', () => {
    if (copyHideTimer) { clearTimeout(copyHideTimer); copyHideTimer = 0; }
  });

  codeCopy.addEventListener('click', e => {
    e.preventDefault();
    e.stopPropagation();
    const pre = (copyPre && copyPre.isConnected) ? copyPre : null;
    const text = copyCodeBlock(pre);
    if (!text) return;
    resetCodeCopy();
    codeCopy.classList.add('ok');
    codeCopyText.textContent = '已复制';
    copyOkTimer = setTimeout(resetCodeCopy, 1200);
    reportCopied(text);
  });

  /* 用 mousemove 而不是 pre 上的 mouseenter：代码块随时会被着色重绘
     （innerHTML 整个换掉），绑在块上的监听器跟着一起消失。挂在 document
     上，靠 target 反查是哪一块，重绘多少次都不受影响。
     按住鼠标（拖选文字）时一律不显示，免得挡住选区。 */
  document.addEventListener('mousemove', e => {
    if (e.buttons) { hideCodeCopy(); return; }
    if (e.target === codeCopy || codeCopy.contains(e.target)) return;
    hoveringEditor = (e.target === editor || editor.contains(e.target));
    const pre = richOn() ? closestPre(e.target) : null;
    if (pre) {
      if (codeCopy.hidden || pre !== copyPre) showCodeCopy(pre);
      return;
    }
    hoveringEditor = false;
    hideCodeCopySoon();
  });

  /* 滚轮/拖动滚动条之后按钮要跟着走；块滚出视野就收起来。 */
  editor.addEventListener('scroll', () => {
    if (!copyPre || codeCopy.hidden) return;
    if (!hoveringEditor || !placeCodeCopy()) codeCopy.hidden = true;
  }, { passive: true });

  window.addEventListener('resize', hideCodeCopy);
  document.documentElement.addEventListener('mouseleave', hideCodeCopy);

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
      /* 编辑菜单的「复制这段代码」。按钮在页面里、菜单在宿主侧，两条入口
         共用同一份复制逻辑（copyCodeBlock），免得改一处漏一处。 */
      case 'copy-code': {
        const t = copyCodeBlock(ctxPre);
        if (t) reportCopied(t);
        break;
      }
      case 'insert-image':
        send({ type: 'pick-image-req' });
        break;
      case 'toggle-md':
        setMode(state.mode === 'md' ? 'rich' : 'md');
        break;
      case 'save':
        saveNow('manual');
        break;
      /* 图片菜单的「从正文中删除这张图」。只断正文里的这一处引用，
         文件留在 data\images 里（同一条便签/别的便签可能还引着它）。 */
      case 'delete-image':
        deleteImage();
        break;
      default:
        break;
    }
  }

  /* ---- 点图片看原图 -----------------------------------------------------
     正文里的图最大 180px 高（见 note.css），看不清楚；点一下用遮罩铺满窗口
     显示原图。遮罩是 fixed 定位的独立元素，不参与正文排版，所以开关的时候
     文字不会跳动，也不会动到光标。

     两张"当前图"的引用：
       lightboxFor —— 打开预览的那张正文图（Esc/点击关闭时还要靠它回删）
       ctxImg      —— 最近一次右键的那张（图片菜单「从正文中删除」用它）
     都留 DOM 引用而不是自己按 src 去查：同一条便签里同一张图可以贴两次，
     按 src 查只能找到第一张，删错位置。 */
  const lightbox = $('lightbox');
  const lightboxImg = $('lightboxImg');
  let lightboxFor = null;
  let ctxImg = null;

  function openLightbox(img) {
    if (!img) return;
    const src = img.getAttribute('src');
    if (!src) return;
    hideCodeCopy();                 // 大图遮罩一开，代码块的复制按钮就该让路
    lightboxFor = img;
    lightboxImg.setAttribute('src', src);
    lightboxImg.alt = img.alt || '';
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
    openLightbox(img);
  });

  /* 从正文里删掉"当前这张图"（宿主菜单「从正文中删除这张图」调过来）。
     走 execCommand('delete') 而不是 el.remove()：前者进浏览器的撤销栈，
     误删还能 Ctrl+Z 找回来。图片文件本身不删 —— 可能还有别处引用，
     也可能用户只是想把它从这段文字里挪走。 */
  function deleteImage() {
    const el = (ctxImg && ctxImg.isConnected) ? ctxImg
      : (lightboxFor && lightboxFor.isConnected ? lightboxFor : null);
    if (!el) { hint('这张图已经不在正文里了'); return; }
    editor.focus();
    const r = document.createRange();
    r.selectNode(el);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
    document.execCommand('delete', false, null);
    closeLightbox();
    ctxImg = null;
    lightboxFor = null;
    scheduleSave();
    hint('已从正文中删除（图片文件还留着）');
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

    /* 看图时 Ctrl+C 就是"复制这张图"。菜单里写着 Ctrl+C，那它就得真的能用；
       剪贴板由宿主写（原生菜单/快捷键回调时页面都没有用户手势）。 */
    if (!lightbox.hidden && mod && e.key.toLowerCase() === 'c') {
      e.preventDefault();
      send({ type: 'copy-image', src: lightboxImg.getAttribute('src') || '' });
      return;
    }

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
