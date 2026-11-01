/* ============================================================================
   list.js —— 便签列表 / 搜索面板

   数据由宿主推送：{type:"notes", items:[...]}。搜索不在前端过滤，而是把关键字
   发给宿主走 SQL LIKE —— 这样能搜到正文深处，中文也不需要分词。
   ========================================================================== */

(function () {
  'use strict';

  const bridge = window.chrome && window.chrome.webview;
  const $ = id => document.getElementById(id);
  const listEl = $('list');
  const qEl = $('q');
  const countEl = $('count');

  let items = [];
  let query = '';
  let activeId = 0;
  let searchTimer = 0;

  function send(obj) {
    if (bridge) bridge.postMessage(obj);
  }

  if (bridge) {
    bridge.addEventListener('message', ev => {
      const msg = ev.data;
      if (msg && msg.type === 'notes') render(msg.items || []);
      else if (msg && msg.type === 'refresh') send({ type: 'search', q: query });
    });
  }

  /* ---- 渲染 ------------------------------------------------------------- */

  function render(next) {
    items = next;
    listEl.textContent = '';

    if (!items.length) {
      const div = document.createElement('div');
      div.className = 'empty';
      div.innerHTML = query
        ? '<b>没有匹配的便签</b>换个词试试'
        : '<b>还没有便签</b>点右上角「新建」，或按 Ctrl+Alt+N';
      listEl.appendChild(div);
      countEl.textContent = query ? '0 条' : '共 0 张';
      return;
    }

    const frag = document.createDocumentFragment();
    for (const n of items) {
      frag.appendChild(itemNode(n));
    }
    listEl.appendChild(frag);
    countEl.textContent = (query ? '匹配 ' : '共 ') + items.length + ' 张';
  }

  function itemNode(n) {
    const row = document.createElement('div');
    row.className = 'item' + (n.id === activeId ? ' active' : '');
    row.dataset.id = n.id;

    const dot = document.createElement('span');
    dot.className = 'dot ' + (n.color || 'yellow');
    row.appendChild(dot);

    const main = document.createElement('div');
    main.className = 'main';

    const row1 = document.createElement('div');
    row1.className = 'row1';

    const name = document.createElement('div');
    name.className = 'name' + (n.title ? '' : ' untitled');
    name.textContent = n.title || '（无标题）';
    row1.appendChild(name);

    if (n.pinned) {
      const pin = document.createElement('span');
      pin.className = 'pin';
      pin.textContent = '置顶';
      row1.appendChild(pin);
    }
    if (n.hidden) {
      const b = document.createElement('span');
      b.className = 'badge';
      b.textContent = '已收起';
      row1.appendChild(b);
    }
    main.appendChild(row1);

    const ex = document.createElement('div');
    ex.className = 'excerpt';
    ex.textContent = n.excerpt || '（空白便签）';
    main.appendChild(ex);

    row.appendChild(main);

    const time = document.createElement('div');
    time.className = 'time';
    time.textContent = relTime(n.updated);
    row.appendChild(time);

    const ops = document.createElement('div');
    ops.className = 'ops';
    ops.appendChild(opBtn('收', '收起这张', () => send({ type: 'hide', id: n.id })));
    ops.appendChild(opBtn('✕', '删除', () => send({ type: 'delete', id: n.id }), 'del'));
    row.appendChild(ops);

    row.addEventListener('click', e => {
      if (e.target.closest('.ops')) return;
      activeId = n.id;
      send({ type: 'open', id: n.id });
      for (const el of listEl.querySelectorAll('.item'))
        el.classList.toggle('active', +el.dataset.id === activeId);
    });

    return row;
  }

  function opBtn(text, title, fn, extra) {
    const b = document.createElement('button');
    b.className = extra || '';
    b.title = title;
    b.textContent = text;
    b.addEventListener('click', e => {
      e.stopPropagation();
      fn();
    });
    return b;
  }

  function relTime(sec) {
    if (!sec) return '';
    const now = Date.now() / 1000;
    const d = Math.max(0, now - sec);
    if (d < 60) return '刚刚';
    if (d < 3600) return Math.floor(d / 60) + ' 分钟前';
    if (d < 86400) return Math.floor(d / 3600) + ' 小时前';
    if (d < 86400 * 2) return '昨天';
    if (d < 86400 * 7) return Math.floor(d / 86400) + ' 天前';
    const dt = new Date(sec * 1000);
    return (dt.getMonth() + 1) + '月' + dt.getDate() + '日';
  }

  /* ---- 交互 ------------------------------------------------------------- */

  qEl.addEventListener('input', () => {
    query = qEl.value.trim();
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => send({ type: 'search', q: query }), 180);
  });

  $('btnNew').addEventListener('click', () => send({ type: 'new' }));
  $('btnClose').addEventListener('click', () => send({ type: 'close' }));

  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') {
      if (qEl.value) { qEl.value = ''; query = ''; send({ type: 'search', q: '' }); }
      else send({ type: 'close' });
    }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'n') {
      e.preventDefault();
      send({ type: 'new' });
    }
    if (e.key === 'Enter' && document.activeElement === qEl && items.length) {
      activeId = items[0].id;
      send({ type: 'open', id: activeId });
    }
  });

  qEl.focus();
  send({ type: 'ready' });
})();
