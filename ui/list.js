/* ============================================================================
   list.js —— 便签列表 / 搜索面板

   数据由宿主推送：{type:"notes", items:[...]}。搜索、排序、过滤三件事全在宿主
   的 SQL 里做（页面拿不到正文，"含图片/含代码块"这种条件只能那边判），页面
   只负责把控件画出来、把"想怎么排/筛"发上去，再按回推的 state 点亮控件。

   勾选状态是本地的：它只影响批量操作条，跟数据库无关。宿主每次回推列表都
   会把已经不存在（被删了）的 id 从选中集里摘掉。

   消息：
     收：notes / init / state / topmost / refresh
     发：search / sort / filter-menu / filter-clear / batch / batch-menu
         open / new / hide / delete / menu / drag-start / window-topmost / close
   ========================================================================== */

(function () {
  'use strict';

  const bridge = window.chrome && window.chrome.webview;
  const $ = id => document.getElementById(id);
  const listEl = $('list');
  const qEl = $('q');
  const countEl = $('count');
  const sortSel = $('sortSel');
  const btnFilter = $('btnFilter');
  const fCount = $('fCount');
  const btnClearFilter = $('btnClearFilter');
  const chkAll = $('chkAll');
  const selbar = $('selbar');
  const selN = $('selN');
  const actPin = $('actPin');
  const actHide = $('actHide');

  let items = [];
  let query = '';
  let activeId = 0;
  let searchTimer = 0;
  let filterCount = 0;          // 生效中的过滤条件个数（宿主说了算）
  const sel = new Set();        // 勾选中的 id

  function send(obj) {
    if (bridge) bridge.postMessage(obj);
  }

  if (bridge) {
    bridge.addEventListener('message', ev => {
      const msg = ev.data;
      if (!msg) return;
      if (msg.type === 'notes') render(msg.items || []);
      else if (msg.type === 'state') applyState(msg);
      else if (msg.type === 'init') {
        // manual = 顶栏交给 JS 拖；native = 还给 -webkit-app-region（见 list.css）
        document.body.dataset.drag = msg.drag === 'native' ? 'native' : 'manual';
        setTopmost(msg.topmost);
      }
      else if (msg.type === 'topmost') setTopmost(msg.on);
      else if (msg.type === 'refresh') send({ type: 'search', q: query });
    });
  }

  /* ---- 排序 / 过滤状态 ---------------------------------------------------
     两端各存一份状态迟早会打架，所以状态只存在宿主：这里收到 state 就照着重画，
     用户改控件时只发"我想变成什么"，等下一轮 state 回推再落定。 */

  function applyState(msg) {
    const key = msg.sort || 'default';
    const dir = msg.desc ? 'desc' : 'asc';
    // "default" 只有倒序一种（它本身就是"置顶优先 + 新建在前"的固定规则）
    const want = key === 'default' ? 'default:desc' : key + ':' + dir;
    if (sortSel.value !== want) sortSel.value = want;

    const f = msg.filter || {};
    filterCount = Object.keys(f).length;
    fCount.hidden = filterCount === 0;
    fCount.textContent = String(filterCount);
    btnFilter.classList.toggle('has', filterCount > 0);
    btnFilter.title = filterCount
      ? '已启用 ' + filterCount + ' 个过滤条件（点击修改）'
      : '按条件过滤（可多选，条件之间同时满足）';
    btnClearFilter.hidden = filterCount === 0;
  }

  /* ---- 渲染 ------------------------------------------------------------- */

  function render(next) {
    items = next;
    /* 便签可能在别处被删了（另一张便签窗口、托盘、甚至外部进程）：
       先把已经不存在的 id 从选中集里摘掉，否则批量删会对着空气下手。 */
    const alive = new Set(items.map(n => n.id));
    for (const id of Array.from(sel)) {
      if (!alive.has(id)) sel.delete(id);
    }

    listEl.textContent = '';

    if (!items.length) {
      const div = document.createElement('div');
      div.className = 'empty';
      if (query) {
        div.innerHTML = '<b>没有匹配的便签</b>换个词试试';
      } else if (filterCount) {
        div.innerHTML = '<b>没有符合过滤条件的便签</b>点「清空」恢复全部';
      } else {
        div.innerHTML = '<b>还没有便签</b>点右上角「新建」，或按 Ctrl+Alt+N';
      }
      listEl.appendChild(div);
      countEl.textContent = query ? '0 条' : '共 0 张';
      updateSelUI();
      return;
    }

    const frag = document.createDocumentFragment();
    for (const n of items) {
      frag.appendChild(itemNode(n));
    }
    listEl.appendChild(frag);

    if (query) countEl.textContent = '匹配 ' + items.length + ' 张';
    else if (filterCount) countEl.textContent = '筛选出 ' + items.length + ' 张';
    else countEl.textContent = '共 ' + items.length + ' 张';
    updateSelUI();
  }

  function itemNode(n) {
    const row = document.createElement('div');
    row.className = 'item'
      + (n.id === activeId ? ' active' : '')
      + (sel.has(n.id) ? ' sel' : '');
    row.dataset.id = n.id;

    /* 复选框。外面套 <label> 是为了点空白处也能勾上（行不大，14px 的方框
       挺难瞄），但 label 的默认行为会触发两次 change —— 所以监听挂 input 上，
       行上的 click 见到 .chk-wrap 就直接 return。 */
    const wrap = document.createElement('label');
    wrap.className = 'chk-wrap';
    wrap.title = '选中这张（批量操作）';
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.className = 'rowchk';
    box.checked = sel.has(n.id);
    box.addEventListener('change', () => setSel(n.id, box.checked));
    wrap.appendChild(box);
    row.appendChild(wrap);

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

    /* 类型徽标：一眼分清"普通便签"和"待办便签"，不用点进去看 */
    if (n.kind === 'todo') {
      const k = document.createElement('span');
      k.className = 'badge kind-todo';
      k.textContent = '待办';
      k.title = '这是一张待办便签（一页多个事项）';
      row1.appendChild(k);
    }

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
    /* 待办便签的摘要位置放"进度"而不是正文片段：那张便签的价值就是
       "还剩几件事、有没有逾期"，摘要反而不重要。 */
    if (n.kind === 'todo' && typeof n.tTotal === 'number') {
      ex.className = 'excerpt todo-prog';
      if (n.tTotal === 0) {
        ex.textContent = '还没有事项';
      } else {
        ex.textContent = n.tDone + '/' + n.tTotal
          + (n.tOverdue ? ' · ' + n.tOverdue + ' 条逾期' : '');
        if (n.tOverdue) ex.classList.add('over');
      }
    } else {
      ex.textContent = n.excerpt || '（空白便签）';
    }
    main.appendChild(ex);

    row.appendChild(main);

    const time = document.createElement('div');
    time.className = 'time';
    time.textContent = relTime(sortTimeOf(n));
    time.title = '创建：' + absTime(n.created) + '\n更新：' + absTime(n.updated);
    row.appendChild(time);

    const ops = document.createElement('div');
    ops.className = 'ops';
    ops.appendChild(opBtn('收', '收起这张', () => send({ type: 'hide', id: n.id })));
    ops.appendChild(opBtn('✕', '删除', () => send({ type: 'delete', id: n.id }), 'del'));
    row.appendChild(ops);

    row.addEventListener('click', e => {
      if (e.target.closest('.ops')) return;
      if (e.target.closest('.chk-wrap')) return;   // 勾选不是"打开"
      activeId = n.id;
      send({ type: 'open', id: n.id });
      for (const el of listEl.querySelectorAll('.item'))
        el.classList.toggle('active', +el.dataset.id === activeId);
    });

    return row;
  }

  /* 时间列显示哪个时间：按当前排序走 —— 按更新时间排却显示创建时间，
     用户会以为排序坏了。 */
  function sortTimeOf(n) {
    const key = (sortSel.value || '').split(':')[0];
    if (key === 'created') return n.created || n.updated;
    return n.updated || n.created;
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

  function absTime(sec) {
    if (!sec) return '—';
    const d = new Date(sec * 1000);
    const p = x => String(x).padStart(2, '0');
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
      + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
  }

  /* ---- 勾选与批量 -------------------------------------------------------- */

  function setSel(id, on) {
    if (on) sel.add(id);
    else sel.delete(id);
    const row = listEl.querySelector('.item[data-id="' + id + '"]');
    if (row) row.classList.toggle('sel', on);
    updateSelUI();
  }

  function pickedItems() {
    return items.filter(n => sel.has(n.id));
  }

  function allPinned() {
    const p = pickedItems();
    return p.length > 0 && p.every(n => !!n.pinned);
  }

  function allHidden() {
    const p = pickedItems();
    return p.length > 0 && p.every(n => !!n.hidden);
  }

  function updateSelUI() {
    const n = sel.size;
    selN.textContent = String(n);
    selbar.hidden = n === 0;

    /* 置顶 / 收起两个按钮兼着"取消"：选中的全是置顶时，按钮就变成"取消置顶"。
       少一个按钮，也少一次"这个按钮到底会置顶还是取消"的猜测。 */
    actPin.textContent = allPinned() ? '取消置顶' : '置顶';
    actPin.title = allPinned() ? '把这 ' + n + ' 张取消置顶' : '把这 ' + n + ' 张置顶';
    actHide.textContent = allHidden() ? '展开' : '收起';
    actHide.title = allHidden()
      ? '把这 ' + n + ' 张重新显示到桌面'
      : '把这 ' + n + ' 张收起到列表里';

    const total = items.length;
    chkAll.disabled = total === 0;
    chkAll.checked = total > 0 && n >= total;
    chkAll.indeterminate = n > 0 && n < total;
  }

  chkAll.addEventListener('change', () => {
    if (chkAll.checked) {
      for (const n of items) sel.add(n.id);
    } else {
      sel.clear();
    }
    /* 只改 class 不重建 DOM：重建会把刚滚到的位置弹回顶部 */
    for (const el of listEl.querySelectorAll('.item')) {
      const on = sel.has(+el.dataset.id);
      el.classList.toggle('sel', on);
      const box = el.querySelector('.rowchk');
      if (box) box.checked = on;
    }
    updateSelUI();
  });

  $('btnSelClear').addEventListener('click', () => {
    sel.clear();
    for (const el of listEl.querySelectorAll('.item')) {
      el.classList.remove('sel');
      const box = el.querySelector('.rowchk');
      if (box) box.checked = false;
    }
    updateSelUI();
  });

  document.querySelector('.selacts').addEventListener('click', e => {
    const b = e.target.closest('button[data-act]');
    if (!b) return;
    const ids = Array.from(sel);
    if (!ids.length) return;
    switch (b.dataset.act) {
      case 'pin':
        send({ type: 'batch', action: 'pin', on: allPinned() ? 0 : 1, ids: ids });
        break;
      case 'hide':
        send({ type: 'batch', action: 'hide', on: allHidden() ? 0 : 1, ids: ids });
        break;
      /* 这三个要再选一个值（颜色 / 档位 / 格式），交给宿主弹原生菜单，
         菜单点完直接执行，不用再回页面绕一圈。 */
      case 'color':
      case 'opacity':
      case 'export':
        send({ type: 'batch-menu', kind: b.dataset.act, ids: ids });
        break;
      case 'clear-hotkey':
        send({ type: 'batch', action: 'clear-hotkey', ids: ids });
        break;
      case 'delete':
        // 二次确认在宿主那边弹（要列出标题、还要保证不被置顶窗口盖住）
        send({ type: 'batch', action: 'delete', ids: ids });
        break;
    }
  });

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

  sortSel.addEventListener('change', () => {
    const parts = (sortSel.value || 'default:desc').split(':');
    send({ type: 'sort', key: parts[0], desc: parts[1] === 'desc' ? 1 : 0 });
  });

  btnFilter.addEventListener('click', () => send({ type: 'filter-menu' }));
  btnClearFilter.addEventListener('click', () => send({ type: 'filter-clear' }));

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
      if (sel.size) { $('btnSelClear').click(); return; }
      if (qEl.value) { qEl.value = ''; query = ''; send({ type: 'search', q: '' }); }
      else send({ type: 'close' });
    }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'n') {
      e.preventDefault();
      send({ type: 'new' });
    }
    /* Ctrl+A 全选：比去够那个小方框快。焦点在搜索框里时不抢 —— 那时候
       用户要选的是输入框里的字。 */
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'a'
      && document.activeElement !== qEl) {
      e.preventDefault();
      if (items.length) {
        chkAll.checked = true;
        chkAll.dispatchEvent(new Event('change'));
      }
    }
    if (e.key === 'Enter' && document.activeElement === qEl && items.length) {
      activeId = items[0].id;
      send({ type: 'open', id: activeId });
    }
  });

  qEl.focus();
  send({ type: 'ready' });
})();
