/* ============================================================================
   todo.js —— 待办便签页

   与普通便签页的关系：
     窗口、配色、置顶、透明度、拖动/缩放、图片管线、"哪些操作要落盘"全部沿用
     note.js 的那一套；真正共用的编辑原语在 editor-core.js 里，本页每个事项
     各建一个 core 实例（root 就是那张卡片的正文节点）。

   数据流（单向，宿主是唯一事实来源）：
     页面只发"我想做什么"（todo-add / todo-save / todo-move / ...）
     宿主改库之后推 {"type":"items", items:[...]} 回来，页面按 id 复用 DOM 重排。
     ★ 正文保存（todo-save）宿主**不**回推 items —— 一推就会重建正文节点，
       光标和滚动位置全丢。它只回一条 {"type":"saved"} 作为回执。

   消息：
     收：init / items / saved / item-body / color / pin / opacity / max /
         toast / hint / image-ok / image-fail / image-in
     发：todo-add / todo-save / todo-save-md / todo-title / todo-status /
         todo-menu / todo-times / todo-move / todo-del / open-note /
         image / clipboard-set / paste-key / pick-image-req / menu /
         drag-start / resize-start / toggle-max / hide / pin
   ========================================================================== */

(function () {
  'use strict';

  const bridge = window.chrome && window.chrome.webview;
  const $ = id => document.getElementById(id);

  const listEl = $('items');
  const emptyEl = $('empty');
  const hintEl = $('hint');
  const countEl = $('count');
  const progEl = $('prog');
  const fltSel = $('fltSel');
  const floatbar = $('floatbar');
  const tp = $('tp'), tpStart = $('tpStart'), tpDue = $('tpDue');
  const mdp = $('mdp'), mdpText = $('mdpText'), mdpName = $('mdpName');
  const lightbox = $('lightbox'), lightboxImg = $('lightboxImg');
  const codeCopy = $('codeCopy'), codeCopyText = $('codeCopyText');

  const state = {
    id: 0,
    items: [],
    app: { transparent: false, fontSize: 15 },
    color: 'yellow',
    pinned: 0,
    opacity: 100,
    filter: 'all',
    maxed: false,
    ready: false,
    mdId: 0,          // Markdown 面板正在编辑的事项
    tpId: 0,          // 时间弹层对应的事项
    pickId: 0         // 宿主文件框选图时"落到哪个事项"
  };

  const cards = new Map();      // id -> { el, body, core, titleEl, ... }
  const timers = new Map();     // id -> 正文防抖 timer
  const paintTimers = new Map();// id -> 补色 timer
  /* 刚点了「+ 新事项」：等宿主把新行推回来之后，把光标放进它的正文。
     用一次性标志，不在 render 里猜"是不是刚加的"。 */
  let pendingFocus = 0;

  function send(obj) {
    if (bridge) bridge.postMessage(obj);
  }

  /* ---- 与宿主通信 ------------------------------------------------------- */

  if (bridge) {
    bridge.addEventListener('message', ev => {
      const msg = ev.data;
      if (!msg || !msg.type) return;
      switch (msg.type) {
        case 'init': onInit(msg); break;
        case 'items': render(msg.items || []); break;
        case 'saved': onSaved(msg); break;
        case 'item-body': onItemBody(msg); break;
        case 'color': applyColor(msg.color); break;
        case 'pin': setPinned(msg.on); break;
        case 'opacity': applyOpacity(msg.pct); break;
        case 'max': setMaxed(msg.on); break;
        case 'toast':
        case 'hint': hint(msg.text || '', !!msg.ok); break;
        case 'image-ok': onImageOk(msg); break;
        case 'image-fail': onImageFail(msg); break;
        case 'image-in': onImageIn(msg.url); break;
        case 'pick-image': hint('用拖拽或 Ctrl+V 也能插图'); break;
        case 'cmd': runCmd(msg.name, msg); break;
      }
    });
  }

  function onInit(msg) {
    const n = msg.note || {};
    state.id = n.id;
    state.app = msg.app || state.app;

    document.body.classList.toggle('transparent', !!state.app.transparent);
    document.body.dataset.drag = state.app.drag === 'native' ? 'native' : 'manual';
    if (state.app.fontSize) document.documentElement.style.setProperty('--fs', state.app.fontSize + 'px');
    applyColor(n.color);
    setPinned(n.pinned);
    applyOpacity(n.opacity);

    state.ready = true;
    render(msg.items || []);
    hint('就绪');

    // 空列表直接把光标放进"新事项"的正文，省一次点击
    if (!state.items.length) addItem();
  }

  /* ---- 卡片 ------------------------------------------------------------- */

  function fmtShort(sec) {
    if (!sec) return '';
    const d = new Date(sec * 1000);
    const p = v => (v < 10 ? '0' : '') + v;
    return p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  function fmtFull(sec) {
    if (!sec) return '';
    const d = new Date(sec * 1000);
    const p = v => (v < 10 ? '0' : '') + v;
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
      + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }

  function toInput(sec) {
    if (!sec) return '';
    return fmtFull(sec).replace(' ', 'T');
  }

  function fromInput(v) {
    if (!v) return 0;
    const m = String(v).match(/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?/);
    if (!m) return 0;
    const d = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], m[6] ? +m[6] : 0);
    const t = Math.floor(d.getTime() / 1000);
    return t > 0 ? t : 0;
  }

  const ST_LABEL = { todo: '未开始', doing: '进行中', done: '已完成', canceled: '已取消' };

  /* 三个派生标志都是现算的，不落库：计划时间到了不用改数据，显示就对了；
     把计划时间改回去，显示也跟着退回去，不会留下"进行中"的既成事实。 */
  function derived(it, now) {
    const open = it.status === 'todo' || it.status === 'doing';
    const overdue = open && it.due_at > 0 && now > it.due_at;
    const soon = open && it.due_at > 0 && !overdue && it.due_at - now <= 86400;
    const auto = it.status === 'todo' && it.start_at > 0 && now >= it.start_at;
    return { open: open, overdue: overdue, soon: soon, auto: auto };
  }

  function agoText(sec, now) {
    const d = Math.max(0, now - sec);
    if (d < 3600) return Math.max(1, Math.floor(d / 60)) + ' 分钟';
    if (d < 86400) return Math.floor(d / 3600) + ' 小时';
    if (d < 86400 * 30) return Math.floor(d / 86400) + ' 天';
    return Math.floor(d / 86400 / 30) + ' 个月';
  }

  function soonText(sec, now) {
    const d = Math.max(0, sec - now);
    if (d < 3600) return Math.max(1, Math.floor(d / 60)) + ' 分钟后';
    if (d < 86400) return Math.floor(d / 3600) + ' 小时后';
    return Math.floor(d / 86400) + ' 天后';
  }

  function createCard(it) {
    const el = document.createElement('article');
    el.className = 'ti';
    el.dataset.id = it.id;
    el.innerHTML =
      '<div class="ti-head">'
      + '<span class="ti-grip" title="按住拖动排序">≡</span>'
      + '<span class="ti-chk" data-on="0" title="勾选完成（Ctrl+Shift+D）"></span>'
      + '<input class="ti-title" type="text" placeholder="事项标题" maxlength="200">'
      + '<span class="pill st"></span>'
      + '<span class="pill tm" title="计划开始 → 预计完成"></span>'
      + '<button class="ti-btn lk" title="打开关联的便签">↗</button>'
      + '<button class="ti-btn mo" title="这个事项的更多操作">⋮</button>'
      + '</div>'
      + '<div class="editor ti-body" contenteditable="true" spellcheck="false" '
      + 'data-placeholder="补充说明…（支持全部 Markdown：列表、表格、代码块、图片）"></div>'
      + '<div class="ti-foot"></div>';

    const body = el.querySelector('.ti-body');
    const titleEl = el.querySelector('.ti-title');

    const card = {
      el: el,
      body: body,
      titleEl: titleEl,
      chkEl: el.querySelector('.ti-chk'),
      stEl: el.querySelector('.st'),
      tmEl: el.querySelector('.tm'),
      lkEl: el.querySelector('.lk'),
      footEl: el.querySelector('.ti-foot'),
      core: null,
      item: it
    };

    /* 每个事项一个编辑内核实例。root 就是这张卡片的正文 —— 代码块进出、
       Tab 缩进、粘贴图片全都只在这块里生效，不会串到别的事项。 */
    card.core = EditorCore.create(body, {
      isRich: () => true,
      save: () => scheduleSave(it.id),
      hint: (text, ok) => hint(text, ok),
      mdArea: () => (state.mdId === it.id ? mdpText : null),
      send: (obj) => send(obj)
    });

    body.innerHTML = it.body_html || '';
    refreshEmpty(card);

    body.addEventListener('input', () => {
      refreshEmpty(card);
      scheduleSave(it.id);
      schedulePaint(card);
    });
    /* 失焦：这时候光标已经走了，重画绝对安全，而且用户"准备离开这一条"
       的时候最希望看到成品的样子。 */
    body.addEventListener('blur', () => {
      card.core.paintCodes(false);
      saveNow(it.id);
    });
    body.addEventListener('keydown', e => {
      card.core.handleCodeKeys(e);
    });
    /* 代码块里的链接/图片点击交给专门的处理器，正文本身不跳转 */
    body.addEventListener('click', e => {
      const im = e.target.closest && e.target.closest('img');
      if (im && !im.classList.contains('pending')) {
        openLightbox(im);
        e.preventDefault();
      }
    });

    titleEl.addEventListener('change', () => {
      send({ type: 'todo-title', id: it.id, title: titleEl.value });
    });
    titleEl.addEventListener('keydown', e => {
      if (e.key === 'Enter') { e.preventDefault(); titleEl.blur(); }
    });

    card.chkEl.addEventListener('click', () => {
      const it2 = card.item;
      send({
        type: 'todo-status', id: it2.id,
        status: it2.status === 'done' ? 'todo' : 'done'
      });
    });
    card.stEl.addEventListener('click', () => send({ type: 'todo-menu', id: it.id, kind: 'status' }));
    card.tmEl.addEventListener('click', e => openTimePop(it.id, e.currentTarget));
    card.lkEl.addEventListener('click', () => {
      const it2 = card.item;
      if (it2.link_ok) send({ type: 'open-note', id: it2.link_note_id });
      else send({ type: 'todo-menu', id: it2.id, kind: 'link' });
    });
    el.querySelector('.mo').addEventListener('click', () => send({ type: 'todo-menu', id: it.id, kind: 'item' }));

    bindDrag(card);
    return card;
  }

  /* 只更新"头部元信息"，不动正文 —— 正文一旦重设 innerHTML，光标就没了。 */
  function updateCard(card, it) {
    const now = Math.floor(Date.now() / 1000);
    const d = derived(it, now);
    card.item = it;
    card.el.dataset.status = it.status;
    card.el.classList.toggle('done', it.status === 'done' || it.status === 'canceled');

    if (document.activeElement !== card.titleEl)
      card.titleEl.value = it.title || '';

    card.chkEl.dataset.on = it.status === 'done' ? '1' : (it.status === 'canceled' ? '2' : '0');

    card.stEl.className = 'pill st st-' + it.status + (d.auto ? ' auto' : '');
    card.stEl.textContent = d.auto ? '进行中（自动）' : (ST_LABEL[it.status] || it.status);

    /* 时间胶囊：逾期最要紧，其次"即将到期"，都没有才显示截止时刻 */
    card.tmEl.className = 'pill tm';
    if (it.due_at > 0 && d.overdue) {
      card.tmEl.classList.add('due-over');
      card.tmEl.textContent = '逾期 ' + agoText(it.due_at, now);
      card.tmEl.title = '预计完成 ' + fmtFull(it.due_at) + '（已逾期）';
    } else if (it.due_at > 0 && d.soon) {
      card.tmEl.classList.add('due-soon');
      card.tmEl.textContent = soonText(it.due_at, now);
      card.tmEl.title = '预计完成 ' + fmtFull(it.due_at);
    } else if (it.due_at > 0) {
      card.tmEl.textContent = fmtShort(it.due_at);
      card.tmEl.title = '预计完成 ' + fmtFull(it.due_at);
    } else if (it.start_at > 0) {
      card.tmEl.textContent = fmtShort(it.start_at);
      card.tmEl.title = '计划开始 ' + fmtFull(it.start_at);
    } else {
      card.tmEl.classList.add('no-time');
      card.tmEl.textContent = '设时间';
      card.tmEl.title = '设置计划开始 / 预计完成时间';
    }

    /* 关联按钮：能跳转就亮着，关联的便签已经不在了就打灰 */
    if (it.link_note_id > 0 && it.link_ok) {
      card.lkEl.className = 'ti-btn lk link-ok';
      card.lkEl.title = '打开关联便签：' + (it.link_title || '（无标题）');
    } else if (it.link_note_id > 0) {
      card.lkEl.className = 'ti-btn lk link-dead';
      card.lkEl.title = '关联的便签已被删除';
    } else {
      card.lkEl.className = 'ti-btn lk';
      card.lkEl.title = '关联一张便签';
    }

    let foot = '';
    if (it.start_at || it.due_at) {
      foot = '计划 ' + (it.start_at ? fmtShort(it.start_at) : '—')
        + ' → ' + (it.due_at ? fmtShort(it.due_at) : '—');
    }
    if (it.status === 'done' && it.done_at) foot += (foot ? ' · ' : '') + '完成于 ' + fmtShort(it.done_at);
    if (it.status === 'canceled' && it.canceled_at) foot += (foot ? ' · ' : '') + '取消于 ' + fmtShort(it.canceled_at);
    if (!it.link_ok && it.link_note_id > 0) foot += (foot ? ' · ' : '') + '关联已失效';
    card.footEl.textContent = foot;
    card.footEl.hidden = !foot;
  }

  function render(items) {
    state.items = items;
    const alive = new Set(items.map(it => String(it.id)));
    for (const [id, c] of Array.from(cards)) {
      if (!alive.has(String(id))) {
        c.el.remove();
        cards.delete(id);
        clearTimeout(timers.get(id));
        clearTimeout(paintTimers.get(id));
        timers.delete(id);
        paintTimers.delete(id);
      }
    }
    items.forEach((it, i) => {
      let c = cards.get(it.id);
      if (!c) {
        c = createCard(it);
        cards.set(it.id, c);
      }
      updateCard(c, it);
      const ref = listEl.children[i] || null;
      if (ref !== c.el) listEl.insertBefore(c.el, ref);
    });
    emptyEl.hidden = items.length > 0;
    applyFilter();
    updateProg();
    if (pendingFocus) {
      pendingFocus = 0;
      focusLastBody();
    }
  }

  function applyFilter() {
    const now = Math.floor(Date.now() / 1000);
    const f = state.filter;
    for (const it of state.items) {
      const c = cards.get(it.id);
      if (!c) continue;
      const d = derived(it, now);
      let show = true;
      if (f === 'open') show = d.open;
      else if (f === 'done') show = it.status === 'done';
      else if (f === 'overdue') show = d.overdue;
      c.el.classList.toggle('hidden', !show);
    }
  }

  function updateProg() {
    const now = Math.floor(Date.now() / 1000);
    let done = 0, over = 0, open = 0;
    for (const it of state.items) {
      if (it.status === 'done') done++;
      if (it.status === 'todo' || it.status === 'doing') open++;
      if (derived(it, now).overdue) over++;
    }
    const total = state.items.length;
    progEl.innerHTML = '<b>' + done + '</b>/' + total
      + (over ? ' <span class="od">· ' + over + ' 条逾期</span>' : '');
    countEl.textContent = total ? (open + ' 条未完成') : '';
  }

  function refreshEmpty(card) {
    const empty = !card.body.textContent.trim() && !card.body.querySelector('img,pre,table,hr');
    card.body.classList.toggle('empty', empty);
  }

  /* ---- 保存 -------------------------------------------------------------
     按事项 id 分别排队：一个事项在打字不应该把别的事项也提交一遍
     （那会让 updated_at 集体乱跳，"最近编辑"的语义就失真了）。 */

  function snapshot(card) {
    const html = card.body.innerHTML;
    return { html: html, text: card.body.innerText, md: MD.toMarkdown(html) };
  }

  function saveNow(id) {
    const card = cards.get(id);
    if (!card) return;
    clearTimeout(timers.get(id));
    timers.delete(id);
    const s = snapshot(card);
    send({
      type: 'todo-save',
      id: id,
      title: card.titleEl.value,
      html: s.html,
      text: s.text,
      md: s.md
    });
  }

  function scheduleSave(id) {
    clearTimeout(timers.get(id));
    timers.set(id, setTimeout(() => saveNow(id), 400));
    hint('编辑中…');
  }

  function saveAll() {
    for (const id of cards.keys()) saveNow(id);
  }

  function schedulePaint(card) {
    const id = card.item.id;
    clearTimeout(paintTimers.get(id));
    /* 打字时不要立刻重画代码块（光标在里面，重画就跳）。等 700ms 没人动了，
       把**除光标所在块以外**的块补一下色 —— 通常也就一两块。 */
    paintTimers.set(id, setTimeout(() => {
      card.core.paintCodes(false);
      card.core.ensureTrailingBlock();
    }, 700));
  }

  function onSaved(msg) {
    const c = cards.get(msg.id);
    if (!c) return;
    /* 标题是自动生成的（正文首行）时，宿主会把算出来的值回传 ——
       用户正在改标题就别覆盖他手里的输入。 */
    if (msg.title != null && document.activeElement !== c.titleEl)
      c.titleEl.value = msg.title;
    if (msg.manual) hint('✓ 已保存 ' + new Date().toLocaleTimeString('zh-CN',
      { hour: '2-digit', minute: '2-digit', second: '2-digit' }), true);
  }

  function onItemBody(msg) {
    const c = cards.get(msg.id);
    if (!c) return;
    c.body.innerHTML = msg.html || '';
    refreshEmpty(c);
    c.core.paintCodes(true);
    c.core.ensureTrailingBlock();
  }

  /* ---- 操作 ------------------------------------------------------------- */

  function addItem() {
    pendingFocus = 1;
    send({ type: 'todo-add' });
  }

  function focusLastBody() {
    const it = state.items[state.items.length - 1];
    if (!it) return;
    const c = cards.get(it.id);
    if (!c) return;
    c.el.scrollIntoView({ block: 'nearest' });
    c.body.focus();
    const r = document.createRange();
    r.selectNodeContents(c.body);
    r.collapse(true);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(r);
  }

  $('btnAdd').addEventListener('click', addItem);

  fltSel.addEventListener('change', () => {
    state.filter = fltSel.value || 'all';
    applyFilter();
    hint(fltSel.options[fltSel.selectedIndex].text);
  });

  /* ---- 时间弹层 --------------------------------------------------------- */

  function openTimePop(id, anchor) {
    const c = cards.get(id);
    if (!c) return;
    state.tpId = id;
    tpStart.value = toInput(c.item.start_at);
    tpDue.value = toInput(c.item.due_at);
    tp.hidden = false;
    /* 贴在胶囊下方；右边放不下就左移，底下放不下就翻到上面 */
    const r = anchor.getBoundingClientRect();
    const w = tp.offsetWidth, h = tp.offsetHeight;
    let left = Math.min(Math.max(4, r.left), window.innerWidth - w - 4);
    let top = r.bottom + 4;
    if (top + h > window.innerHeight - 4) top = Math.max(4, r.top - h - 4);
    tp.style.left = Math.round(left) + 'px';
    tp.style.top = Math.round(top) + 'px';
    tpStart.focus();
  }

  function closeTimePop() {
    tp.hidden = true;
    state.tpId = 0;
  }

  $('tpCancel').addEventListener('click', closeTimePop);
  $('tpClear').addEventListener('click', () => {
    tpStart.value = '';
    tpDue.value = '';
    applyTime();
  });
  $('tpOk').addEventListener('click', applyTime);

  function applyTime() {
    const id = state.tpId;
    const start = fromInput(tpStart.value);
    const due = fromInput(tpDue.value);
    closeTimePop();
    if (!id) return;
    if (start && due && due < start) {
      hint('预计完成时间早于计划开始时间，已按你填的保存', true);
    }
    send({ type: 'todo-times', id: id, start: start, due: due });
  }

  tp.addEventListener('keydown', e => {
    if (e.key === 'Escape') { e.preventDefault(); closeTimePop(); }
    if (e.key === 'Enter') { e.preventDefault(); applyTime(); }
  });

  /* ---- 单事项 Markdown 源码 -------------------------------------------- */

  function openMd(id) {
    const c = cards.get(id);
    if (!c) return;
    state.mdId = id;
    mdpName.textContent = '· ' + (c.item.title || '（无标题）');
    mdpText.value = c.item.body_md || MD.toMarkdown(c.body.innerHTML);
    mdp.hidden = false;
    mdpText.focus();
    mdpText.setSelectionRange(0, 0);
  }

  function closeMd() {
    mdp.hidden = true;
    state.mdId = 0;
  }

  function applyMd() {
    const id = state.mdId;
    const text = mdpText.value;
    closeMd();
    if (!id) return;
    const c = cards.get(id);
    /* md 是正本，html 在页面这边用 MD.render 算好一起发 —— 宿主里没有
       Markdown 渲染器（md.js 是页面脚本），也不该为了这件事再引一份。 */
    send({
      type: 'todo-save-md', id: id,
      md: text,
      html: MD.render(text),
      text: MD.plain(text),
      title: c ? c.titleEl.value : ''
    });
  }

  $('mdpCancel').addEventListener('click', closeMd);
  $('mdpOk').addEventListener('click', applyMd);
  mdpText.addEventListener('keydown', e => {
    if (e.key === 'Escape') { e.preventDefault(); closeMd(); }
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); applyMd(); }
    /* Markdown 源码里 Tab 要能缩进，而不是把焦点跳走 */
    if (e.key === 'Tab') {
      e.preventDefault();
      const s = mdpText;
      const a = s.selectionStart, b = s.selectionEnd;
      s.value = s.value.slice(0, a) + '  ' + s.value.slice(b);
      s.selectionStart = s.selectionEnd = a + 2;
    }
  });

  /* ---- 图片 ------------------------------------------------------------- */

  function openLightbox(img) {
    lightboxImg.src = img.getAttribute('src') || '';
    lightbox.hidden = false;
  }

  function closeLightbox() {
    if (lightbox.hidden) return false;
    lightbox.hidden = true;
    lightboxImg.removeAttribute('src');
    return true;
  }

  lightbox.addEventListener('click', closeLightbox);

  function activeCard() {
    const ae = document.activeElement;
    const el = ae && ae.closest ? ae.closest('.ti') : null;
    if (!el) return null;
    return cards.get(Number(el.dataset.id)) || null;
  }

  function onImageOk(msg) {
    const c = activeCard() || cards.get(state.pickId);
    if (!c) return;
    c.core.onImageOk(msg);
  }

  function onImageFail(msg) {
    const c = activeCard() || cards.get(state.pickId);
    if (!c) return;
    c.core.onImageFail(msg);
  }

  function onImageIn(url) {
    const c = activeCard() || cards.get(state.pickId);
    if (!c) return;
    c.core.onImageIn(url);
  }

  function pickImageFile(dt) {
    return EditorCore.pickImageFile(dt);
  }

  /* 拖文件进来：光标先落到鼠标位置，图片才插在"掉下来的地方" */
  document.addEventListener('drop', e => {
    const files = Array.from((e.dataTransfer && e.dataTransfer.files) || [])
      .filter(f => f && f.type && f.type.indexOf('image/') === 0);
    if (!files.length) return;
    e.preventDefault();
    const body = e.target.closest && e.target.closest('.ti-body');
    if (!body) return;
    const card = cards.get(Number(body.closest('.ti').dataset.id));
    if (!card) return;
    state.pickId = card.item.id;
    try {
      const r = document.caretRangeFromPoint(e.clientX, e.clientY);
      if (r) {
        const sel = window.getSelection();
        sel.removeAllRanges();
        sel.addRange(r);
      }
    } catch (_) { /* 取不到就用当前选区 */ }
    files.forEach(f => card.core.addImage(f));
  }, true);

  /* Ctrl+V 粘图：只拦"带图片"的粘贴，普通文字照旧走浏览器默认行为 */
  document.addEventListener('paste', e => {
    const file = pickImageFile(e.clipboardData);
    if (!file) return;
    const card = activeCard();
    if (!card) return;
    e.preventDefault();
    state.pickId = card.item.id;
    card.core.addImage(file);
  }, true);

  /* ---- 选区浮动工具条 --------------------------------------------------- */

  let savedRange = null;
  let selBody = null;

  document.addEventListener('selectionchange', () => {
    /* 光标离开代码块时给它补上颜色（每个 core 自己盯着自己那一块） */
    for (const c of cards.values()) c.core.trackPre();

    if (!lightbox.hidden) { floatbar.hidden = true; return; }
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) { floatbar.hidden = true; return; }
    const range = sel.getRangeAt(0);
    const host = range.commonAncestorContainer;
    const el = host.nodeType === 1 ? host : host.parentElement;
    const body = el && el.closest ? el.closest('.ti-body') : null;
    if (!body) { floatbar.hidden = true; return; }
    savedRange = range.cloneRange();
    selBody = body;
    const rect = savedRange.getBoundingClientRect();
    if (!rect || (!rect.width && !rect.height)) { floatbar.hidden = true; return; }
    floatbar.hidden = false;
    const bw = floatbar.offsetWidth, bh = floatbar.offsetHeight;
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
    if (!btn || !selBody) return;
    const card = cards.get(Number(selBody.closest('.ti').dataset.id));
    if (!card) return;
    const cmd = btn.dataset.cmd;
    selBody.focus();
    if (savedRange) {
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(savedRange);
    }
    if (cmd === 'code') {
      wrapInlineCode(card);
    } else if (cmd === 'codeblock') {
      card.core.insertCodeBlock();
    } else if (cmd === 'link') {
      insertLink(card);
    } else if (cmd.startsWith('formatBlock:')) {
      document.execCommand('formatBlock', false, '<' + cmd.split(':')[1] + '>');
    } else {
      document.execCommand(cmd, false, null);
    }
    card.core.ensureTrailingBlock();
    scheduleSave(card.item.id);
    refreshEmpty(card);
    floatbar.hidden = true;
  });

  function wrapInlineCode(card) {
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

  /* prompt() 在 WebView2 里是原生对话框，能用；不用页面内小表单是因为
     便签窗口最窄只有 180px，弹个输入框会把窗口撑得一塌糊涂。 */
  function insertLink(card) {
    const sel = window.getSelection();
    const picked = sel && !sel.isCollapsed ? sel.toString() : '';
    const url = window.prompt('链接地址（http:// 或 https://）', 'https://');
    if (!url) return;
    const u = url.trim();
    if (!/^(https?:|mailto:)/i.test(u)) { hint('只支持 http / https / mailto 链接'); return; }
    card.body.focus();
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
      card.core.insertAtCaret(a);
    }
    scheduleSave(card.item.id);
    hint('链接已插入');
  }

  /* ---- 代码块复制按钮 --------------------------------------------------- */

  let copyPre = null, copyCard = null;
  let copyHideTimer = 0, copyOkTimer = 0;
  /* 右键落点那一块 <pre>。菜单点下去时鼠标早就离开了那块，只能靠这份引用；
     弹菜单前 hideCodeCopy() 会把 copyPre 清掉，所以必须单独记。 */
  let ctxPre = null;

  function codeTextOf(pre) {
    for (const c of cards.values())
      if (c.body.contains(pre)) return c.core.codeText(pre);
    return '';
  }

  function resetCodeCopy() {
    clearTimeout(copyOkTimer);
    codeCopy.classList.remove('ok');
    codeCopyText.textContent = '复制';
  }

  function placeCodeCopy() {
    if (!copyPre || !copyPre.isConnected) return false;
    const r = copyPre.getBoundingClientRect();
    if (r.bottom < 6 || r.top > window.innerHeight - 6) return false;
    const w = codeCopy.offsetWidth || 56, h = codeCopy.offsetHeight || 21;
    let top = Math.min(Math.max(r.top + 4, 4), window.innerHeight - h - 4);
    let left = Math.min(r.right - w - 6, window.innerWidth - w - 4);
    codeCopy.style.top = Math.round(top) + 'px';
    codeCopy.style.left = Math.round(Math.max(4, left)) + 'px';
    return true;
  }

  function showCodeCopy(pre) {
    if (!pre || !pre.isConnected) { hideCodeCopy(); return; }
    if (pre !== copyPre) resetCodeCopy();
    copyPre = pre;
    clearTimeout(copyHideTimer);
    copyHideTimer = 0;
    /* 先显示再量尺寸：display:none 的元素 offsetWidth 是 0 */
    codeCopy.hidden = false;
    if (!placeCodeCopy()) codeCopy.hidden = true;
  }

  function hideCodeCopy() {
    clearTimeout(copyHideTimer);
    copyHideTimer = 0;
    codeCopy.hidden = true;
    copyPre = null;
  }

  function hideCodeCopySoon() {
    if (codeCopy.hidden) { copyPre = null; return; }
    clearTimeout(copyHideTimer);
    copyHideTimer = setTimeout(hideCodeCopy, 200);
  }

  codeCopy.addEventListener('mousedown', e => e.preventDefault());
  codeCopy.addEventListener('mouseenter', () => {
    if (copyHideTimer) { clearTimeout(copyHideTimer); copyHideTimer = 0; }
  });
  codeCopy.addEventListener('click', e => {
    e.preventDefault();
    e.stopPropagation();
    if (!copyPre || !copyPre.isConnected) { hideCodeCopy(); return; }
    const text = codeTextOf(copyPre);
    if (!text) { hint('这段代码是空的'); return; }
    /* 剪贴板交给宿主写：它会把换行统一成 CRLF，记事本之类才不会挤成一行 */
    send({ type: 'clipboard-set', text: text });
    resetCodeCopy();
    codeCopy.classList.add('ok');
    codeCopyText.textContent = '已复制';
    copyOkTimer = setTimeout(resetCodeCopy, 1200);
    const lines = text.split('\n').length;
    hint(lines > 1 ? '已复制 ' + lines + ' 行代码' : '已复制代码');
  });

  /* 用 mousemove 而不是 pre 上的 mouseenter：代码块随时会被着色重绘
     （innerHTML 整个换掉），绑在块上的监听器跟着一起消失。 */
  document.addEventListener('mousemove', e => {
    if (e.buttons) { hideCodeCopy(); return; }
    if (e.target === codeCopy || codeCopy.contains(e.target)) return;
    const pre = e.target.closest ? e.target.closest('pre') : null;
    if (pre && pre.closest('.ti-body')) {
      if (codeCopy.hidden || pre !== copyPre) showCodeCopy(pre);
      return;
    }
    hideCodeCopySoon();
  });

  listEl.addEventListener('scroll', () => {
    if (!copyPre || codeCopy.hidden) return;
    if (!placeCodeCopy()) codeCopy.hidden = true;
  }, { passive: true });

  window.addEventListener('resize', hideCodeCopy);
  document.documentElement.addEventListener('mouseleave', hideCodeCopy);

  /* ---- 拖动排序 --------------------------------------------------------
     ★ 只有按住把手才把卡片设成 draggable：整卡可拖的话，正文里选一段文字
       会变成拖卡片（HTML5 拖拽会吃掉文本选区），那是比"排不了序"更烦的事。 */
  let dragId = 0;

  function bindDrag(card) {
    const el = card.el;
    const grip = el.querySelector('.ti-grip');

    grip.addEventListener('mousedown', () => { el.draggable = true; });

    el.addEventListener('dragstart', e => {
      dragId = card.item.id;
      el.classList.add('dragging');
      e.dataTransfer.effectAllowed = 'move';
      try { e.dataTransfer.setData('text/plain', String(dragId)); } catch (_) { }
    });

    el.addEventListener('dragend', () => {
      el.draggable = false;
      el.classList.remove('dragging');
      clearDropMarks();
      dragId = 0;
    });

    el.addEventListener('dragover', e => {
      if (!dragId || dragId === card.item.id) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      const r = el.getBoundingClientRect();
      const after = e.clientY > r.top + r.height / 2;
      clearDropMarks();
      el.classList.add(after ? 'drop-after' : 'drop-before');
    });

    el.addEventListener('drop', e => {
      if (!dragId || dragId === card.item.id) return;
      e.preventDefault();
      e.stopPropagation();
      const r = el.getBoundingClientRect();
      const after = e.clientY > r.top + r.height / 2;
      const from = state.items.findIndex(x => x.id === dragId);
      let target = state.items.findIndex(x => x.id === card.item.id) + (after ? 1 : 0);
      if (from < target) target--;
      clearDropMarks();
      if (target !== from)
        send({ type: 'todo-move', id: dragId, idx: target + 1 });
    });
  }

  function clearDropMarks() {
    for (const el of listEl.querySelectorAll('.ti'))
      el.classList.remove('drop-before', 'drop-after');
  }

  /* ---- 工具栏 / 窗口 ---------------------------------------------------- */

  $('btnPin').addEventListener('click', () => {
    state.pinned = state.pinned ? 0 : 1;
    setPinned(state.pinned);
    send({ type: 'pin', id: state.id, on: !!state.pinned });
  });
  $('btnMenu').addEventListener('click', () => send({ type: 'menu', id: state.id, zone: 'note' }));
  $('btnClose').addEventListener('click', () => send({ type: 'hide', id: state.id }));

  function setPinned(on) {
    state.pinned = on ? 1 : 0;
    $('btnPin').classList.toggle('active', !!on);
    $('btnPin').title = on ? '已置顶（点击取消）' : '置顶';
  }

  function applyColor(name) {
    state.color = name || 'yellow';
    document.body.dataset.color = state.color;
  }

  function applyOpacity(pct) {
    const n = Math.max(30, Math.min(100, parseInt(pct, 10) || 100));
    state.opacity = n;
    document.documentElement.style.opacity = n >= 100 ? '' : String(n / 100);
  }

  function setMaxed(on) {
    state.maxed = !!on;
    document.body.dataset.max = state.maxed ? '1' : '0';
    hint(state.maxed ? '已铺满屏幕 · 双击标题栏还原' : '窗口已还原');
  }

  /* 顶栏拖动 / 双击最大化。与 note.js 同一套理由：分层窗口下原生 app-region
     拖不动，而且按下瞬间宿主就进系统移动循环，dblclick 不一定派发得到页面。 */
  const bar = document.querySelector('.bar');
  let lastDown = 0, lastX = 0, lastY = 0;
  const DBL_MS = 380, DBL_PX = 6;

  bar.addEventListener('mousedown', e => {
    if (e.button !== 0) return;
    if (e.target.closest('button')) return;
    e.preventDefault();
    const now = Date.now();
    if (now - lastDown < DBL_MS
      && Math.abs(e.screenX - lastX) < DBL_PX && Math.abs(e.screenY - lastY) < DBL_PX) {
      lastDown = 0;
      send({ type: 'toggle-max', id: state.id });
      return;
    }
    lastDown = now; lastX = e.screenX; lastY = e.screenY;
    if (state.maxed) return;
    send({ type: 'drag-start', id: state.id });
  });

  $('grip').addEventListener('mousedown', e => {
    if (e.button !== 0) return;
    e.preventDefault();
    send({ type: 'resize-start', id: state.id, edge: 'se' });
  });

  document.addEventListener('contextmenu', e => {
    e.preventDefault();
    hideCodeCopy();
    /* 落在某个事项的正文/头部 → 这个事项的菜单；落在空白处 → 便签菜单 */
    const ti = e.target.closest ? e.target.closest('.ti') : null;
    if (ti) {
      const card = cards.get(Number(ti.dataset.id));
      if (card) {
        const pre = e.target.closest('pre');
        ctxPre = (pre && card.body.contains(pre)) ? pre : null;
        send({
          type: 'menu', id: state.id, zone: 'todo',
          item: card.item.id,
          inpre: ctxPre ? 1 : 0,
          lang: ctxPre ? (CodeHL.detect(ctxPre) || '') : ''
        });
        return;
      }
    }
    ctxPre = null;
    send({ type: 'menu', id: state.id, zone: 'note' });
  });

  /* ---- 编辑菜单命令（宿主原生菜单点回来的） ----------------------------- */

  function runCmd(name, msg) {
    switch (name) {
      case 'save': saveAll(); break;
      case 'todo-add': addItem(); break;
      case 'todo-md': if (msg.item) openMd(msg.item); break;
      case 'todo-time': {
        const c = cards.get(msg.item);
        if (c) openTimePop(c.item.id, c.tmEl);
        break;
      }
      /* 菜单里的「代码语言」：菜单在宿主侧，页面拿不到光标，所以认
         "右键落点那一块"（ctxPre）—— 右键时已经记下来了。 */
      case 'codelang': {
        const c = cards.get(msg.item);
        const pre = (ctxPre && ctxPre.isConnected && c && c.body.contains(ctxPre))
          ? ctxPre : null;
        if (!pre) { hint('这个事项里没有代码块'); break; }
        CodeHL.setLang(pre, msg.lang || '');
        CodeHL.paint(pre);
        if (c) scheduleSave(c.item.id);
        hint('代码语言：' + CodeHL.labelOf(msg.lang || 'text'));
        break;
      }
      case 'copy-code': {
        const pre = (ctxPre && ctxPre.isConnected) ? ctxPre : copyPre;
        if (!pre) { hint('先把鼠标移到代码块上'); break; }
        const text = codeTextOf(pre);
        if (!text) { hint('这段代码是空的'); break; }
        send({ type: 'clipboard-set', text: text });
        hint('已复制代码');
        break;
      }
      case 'insert-image':
        state.pickId = (msg && msg.item) || (activeCard() ? activeCard().item.id : 0);
        send({ type: 'pick-image-req' });
        break;
      case 'paste':
        send({ type: 'paste-key' });
        break;
    }
  }

  /* ---- 键盘 ------------------------------------------------------------- */

  document.addEventListener('keydown', e => {
    const mod = e.ctrlKey || e.metaKey;

    /* 关掉 F5 / Ctrl+R 这类浏览器快捷键的副作用（宿主刻意开着它们，
       否则 Ctrl+V 会一起失效，见 note-window.ahk 里的注释）。
       Ctrl+C/V/X/A/Z 千万别拦，那些正是我们要它工作的。 */
    if (e.key === 'F5' || (mod && ['r', 'p', 'f', 'n', 'o', 'j'].includes(e.key.toLowerCase()))) {
      e.preventDefault();
      return;
    }

    const card = activeCard();

    if (mod && e.key.toLowerCase() === 's') { e.preventDefault(); saveAll(); return; }
    if (mod && e.key === 'Enter') { e.preventDefault(); addItem(); return; }

    /* Markdown 面板开着时，格式化快捷键归面板自己的 textarea */
    if (!mdp.hidden) return;

    if (mod && e.shiftKey && e.key.toLowerCase() === 'd') {
      e.preventDefault();
      if (card) send({
        type: 'todo-status', id: card.item.id,
        status: card.item.status === 'done' ? 'todo' : 'done'
      });
      return;
    }

    if (e.altKey && (e.key === 'ArrowUp' || e.key === 'ArrowDown') && card) {
      e.preventDefault();
      const idx = state.items.findIndex(x => x.id === card.item.id);
      if (idx < 0) return;
      const target = idx + (e.key === 'ArrowUp' ? 0 : 2);   // MoveTo 是 1 基
      if (target < 1 || target > state.items.length) return;
      send({ type: 'todo-move', id: card.item.id, idx: target });
      return;
    }

    if (e.key === 'Escape') {
      if (closeLightbox()) return;
      if (!tp.hidden) { closeTimePop(); return; }
    }

    if (mod && card && mdp.hidden && ['b', 'i', 'u'].includes(e.key.toLowerCase())) {
      e.preventDefault();
      document.execCommand(e.key.toLowerCase() === 'b' ? 'bold'
        : e.key.toLowerCase() === 'i' ? 'italic' : 'underline', false, null);
      scheduleSave(card.item.id);
    }
  });

  /* ---- 杂项 ------------------------------------------------------------- */

  function hint(text, ok) {
    hintEl.textContent = text || '';
    hintEl.classList.toggle('ok', !!ok);
  }

  /* 告诉宿主"页面装好了，可以推数据了"。没有这一条，宿主永远不会 PushInit，
     表现就是一张永远空白的待办窗口（和 note.js 里那一行是同一个约定）。 */
  send({ type: 'ready', id: new URLSearchParams(location.search).get('id') });

  /* ---- 自检钩子 ---------------------------------------------------------
     --selftest-todo 用 ExecuteScriptAsync 驱动页面。只暴露"页面上本来就有的
     动作"，不额外开后门：自检点的是真按钮、走的是真防抖。 */
  window.__todo = {
    count: () => listEl.querySelectorAll('.ti').length,
    ids: () => Array.from(listEl.querySelectorAll('.ti')).map(el => Number(el.dataset.id)),
    idx: id => Array.from(listEl.querySelectorAll('.ti')).findIndex(el => Number(el.dataset.id) === id),
    prog: () => progEl.textContent,
    add: () => addItem(),
    titleOf: i => (listEl.querySelectorAll('.ti-title')[i] || {}).value,
    setTitle: (i, v) => {
      const el = listEl.querySelectorAll('.ti-title')[i];
      if (!el) return 0;
      el.value = v;
      el.dispatchEvent(new Event('change'));
      return 1;
    },
    setBody: (i, html) => {
      const el = listEl.querySelectorAll('.ti-body')[i];
      if (!el) return 0;
      el.innerHTML = html;
      el.dispatchEvent(new Event('input'));
      return 1;
    },
    bodyHTML: i => {
      const el = listEl.querySelectorAll('.ti-body')[i];
      return el ? el.innerHTML : '';
    },
    chk: i => {
      const el = listEl.querySelectorAll('.ti-chk')[i];
      if (!el) return 0;
      el.click();
      return 1;
    },
    hasClass: (i, sel, cls) => {
      const el = listEl.querySelectorAll(sel)[i];
      return el && el.classList.contains(cls) ? 1 : 0;
    },
    text: (i, sel) => {
      const el = listEl.querySelectorAll(sel)[i];
      return el ? el.textContent : '';
    },
    filter: v => {
      fltSel.value = v;
      fltSel.dispatchEvent(new Event('change'));
      return state.filter;
    },
    visible: () => Array.from(listEl.querySelectorAll('.ti'))
      .filter(el => !el.classList.contains('hidden')).length,
    openMd: i => {
      const el = listEl.querySelectorAll('.ti')[i];
      if (!el) return 0;
      openMd(Number(el.dataset.id));
      return 1;
    },
    mdValue: () => mdpText.value,
    setMd: v => { mdpText.value = v; applyMd(); return 1; },
    mdOpen: () => (mdp.hidden ? 0 : 1),
    openTime: i => {
      const el = listEl.querySelectorAll('.tm')[i];
      if (!el) return 0;
      const ti = el.closest('.ti');
      openTimePop(Number(ti.dataset.id), el);
      return 1;
    },
    tpOpen: () => (tp.hidden ? 0 : 1),
    tpSet: (a, b) => { tpStart.value = a; tpDue.value = b; applyTime(); return 1; },
    state: () => ({ id: state.id, filter: state.filter, items: state.items.length })
  };
})();
