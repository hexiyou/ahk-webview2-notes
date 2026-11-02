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
      else if (msg && msg.type === 'init') {
        // manual = 顶栏交给 JS 拖；native = 还给 -webkit-app-region（见 list.css）
        document.body.dataset.drag = msg.drag === 'native' ? 'native' : 'manual';
        setTopmost(msg.topmost);
      }
      else if (msg && msg.type === 'topmost') setTopmost(msg.on);
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
    /* 快捷键角标：一眼看出哪张便签有"一键呼出"。宿主已经把 ^!1 翻成
       Ctrl+Alt+1 再发过来，这里不做第二份格式化。 */
    if (n.hk) {
      const hk = document.createElement('span');
      hk.className = 'hk';
      hk.textContent = n.hk;
      hk.title = '全局快捷键：' + n.hk + '（按一下呼出，再按收起）';
      row1.appendChild(hk);
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

  /* ---- 顶栏拖动 --------------------------------------------------------- */

  /* 原生 -webkit-app-region 在带 WS_THICKFRAME 的窗口上不生效（真机验证过：
     能点、拖不动），所以顶栏按下后交给宿主进系统移动循环。 */
  $('head').addEventListener('mousedown', e => {
    if (e.button !== 0) return;
    if (e.target.closest('button, input, .actions')) return;
    e.preventDefault();
    send({ type: 'drag-start' });
  });

  qEl.addEventListener('input', () => {
    query = qEl.value.trim();
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => send({ type: 'search', q: query }), 180);
  });

  $('btnNew').addEventListener('click', () => send({ type: 'new' }));
  $('btnClose').addEventListener('click', () => send({ type: 'close' }));
  $('btnMenu').addEventListener('click', () => send({ type: 'menu', id: 0 }));

  /* ---- 窗口置顶 ---------------------------------------------------------
     状态由宿主说了算：点一下只说"想变成什么"，宿主改完窗口样式再回一条
     {type:'topmost'} 把按钮点亮/熄掉。别在这里自己翻 class —— 页面和窗口
     一旦不同步，按钮显示的就不是真实状态。 */
  const pinEl = $('btnPin');
  function setTopmost(on) {
    pinEl.classList.toggle('on', !!on);
    pinEl.setAttribute('aria-pressed', on ? 'true' : 'false');
    pinEl.title = on ? '窗口已置顶（点击取消）' : '窗口置顶（置顶后不会被其他窗口盖住）';
  }
  pinEl.addEventListener('click', () => {
    send({ type: 'window-topmost', on: pinEl.classList.contains('on') ? 0 : 1 });
  });

  /* 右键：点在条目上出该条目的菜单，点空白/头部出面板菜单（id=0）。
     菜单本体由宿主用系统原生菜单弹出。 */
  document.addEventListener('contextmenu', e => {
    e.preventDefault();
    const row = e.target.closest('.item');
    send({ type: 'menu', id: row ? +row.dataset.id : 0 });
  });

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
