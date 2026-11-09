/* ============================================================================
   settings.js —— 设置窗口的页面逻辑

   和列表窗口一样：页面只管表单，落盘和生效都交给 AHK。保存时把整份值发过去，
   宿主校验（热键合法性）后回 {type:'saved', ok, msg}。

   快捷键不让人手打 "^!n"：聚焦输入框直接按组合键，这里翻成 AHK 写法。
   ========================================================================== */

(function () {
  'use strict';

  const bridge = window.chrome && window.chrome.webview;
  const $ = id => document.getElementById(id);

  const statusEl = $('status');
  let statusTimer = 0;
  /* 新建便签的默认颜色（宿主发来的键名，比如 yellow） */
  let defColor = 'yellow';

  function send(obj) {
    if (bridge) bridge.postMessage(obj);
  }

  function status(text, isErr) {
    statusEl.textContent = text || '';
    statusEl.classList.toggle('err', !!isErr);
    statusEl.classList.toggle('show', !!text);
    clearTimeout(statusTimer);
    if (text && !isErr) statusTimer = setTimeout(() => statusEl.classList.remove('show'), 2200);
  }

  /* ---- 与宿主通信 ------------------------------------------------------- */

  if (bridge) {
    bridge.addEventListener('message', ev => {
      const msg = ev.data;
      if (!msg || !msg.type) return;
      if (msg.type === 'init') fill(msg.cfg || {}, msg.info || {});
      else if (msg.type === 'smtpTest') {
        status(msg.ok ? '测试邮件已发出，去收件箱看看' : ('发送失败：' + (msg.msg || '未知错误')), !msg.ok);
      }
      else if (msg.type === 'saved') {
        if (msg.ok) status('已保存');
        else status(msg.msg || '保存失败', true);
      }
    });
  }

  function fill(cfg, info) {
    $('transparent').checked = !!cfg.transparent;
    $('fontSize').value = cfg.fontSize || 15;
    $('showAllOnStart').checked = !!cfg.showAllOnStart;
    $('openListOnStart').checked = !!cfg.openListOnStart;
    defColor = cfg.defColor || 'yellow';
    buildSwatches(cfg.colors || []);
    $('hkNew').value = cfg.hkNew || '';
    $('hkList').value = cfg.hkList || '';
    $('hkToggle').value = cfg.hkToggle || '';
    /* SMTP：密码框永远是空的 —— 宿主只告诉我们"有没有存过"，
       不回传密文，也不回传明文。留空 = 不改。 */
    $('smtpOn').checked = !!cfg.smtpOn;
    $('smtpHost').value = cfg.smtpHost || '';
    $('smtpPort').value = cfg.smtpPort || 465;
    $('smtpUser').value = cfg.smtpUser || '';
    $('smtpFrom').value = cfg.smtpFrom || '';
    $('smtpTo').value = cfg.smtpTo || '';
    $('smtpTimeout').value = cfg.smtpTimeout || 20;
    $('smtpPass').value = '';
    $('smtpPassHint').textContent = cfg.smtpHasPass
      ? '已保存（加密存储）；留空表示不改'
      : '还没填。QQ / 163 要在邮箱设置里生成授权码，不是登录密码';
    $('autostart').checked = !!cfg.autostart;
    if (info.dataDir) $('dataDir').textContent = info.dataDir;
    if (info.about) $('about').textContent = info.about;

    // 填值时浏览器可能把某个控件滚进视野，导致一打开就停在中间
    const body = $('body');
    if (body) body.scrollTop = 0;
  }

  /* ---- 新建便签的默认颜色 -----------------------------------------------
     色块完全按宿主发来的表画（颜色名/中文名/色值只在 AHK 的
     NoteWindow.Colors() 里定义一次），页面这边不抄表，改名或加颜色都不会漏。 */

  function buildSwatches(colors) {
    const box = $('swatches');
    if (!box) return;
    box.textContent = '';
    for (const c of colors) {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'chip';
      b.dataset.key = c.k;
      b.title = c.n;
      b.setAttribute('aria-label', c.n);
      b.style.background = '#' + c.h;
      b.addEventListener('click', () => {
        defColor = c.k;
        paintSwatches();
      });
      box.appendChild(b);
    }
    paintSwatches();
  }

  function paintSwatches() {
    document.querySelectorAll('#swatches .chip').forEach(ch => {
      const on = ch.dataset.key === defColor;
      ch.classList.toggle('on', on);
      ch.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
  }

  function clampNum(v, lo, hi, def) {
    const n = parseInt(v, 10);
    if (!Number.isFinite(n)) return def;
    return Math.max(lo, Math.min(hi, n));
  }

  function collect() {
    let fs = parseInt($('fontSize').value, 10);
    if (!Number.isFinite(fs)) fs = 15;
    fs = Math.max(10, Math.min(32, fs));
    $('fontSize').value = fs;
    return {
      transparent: $('transparent').checked ? 1 : 0,
      fontSize: fs,
      showAllOnStart: $('showAllOnStart').checked ? 1 : 0,
      openListOnStart: $('openListOnStart').checked ? 1 : 0,
      defColor: defColor,
      hkNew: $('hkNew').value.trim(),
      hkList: $('hkList').value.trim(),
      hkToggle: $('hkToggle').value.trim(),
      smtpOn: $('smtpOn').checked ? 1 : 0,
      smtpHost: $('smtpHost').value.trim(),
      smtpPort: clampNum($('smtpPort').value, 1, 65535, 465),
      smtpUser: $('smtpUser').value.trim(),
      /* 空串 = 不改（后端据此跳过写入，免得每次保存都把密码抹掉） */
      smtpPass: $('smtpPass').value,
      smtpFrom: $('smtpFrom').value.trim(),
      smtpTo: $('smtpTo').value.trim(),
      smtpTimeout: clampNum($('smtpTimeout').value, 5, 60, 20),
      autostart: $('autostart').checked ? 1 : 0
    };
  }

  /* ---- 快捷键录制 -------------------------------------------------------
     e.key 到 AHK 键名的映射。字母 / 数字直接用，其余查表；
     都没命中就原样用（AHK 那边校验不过会报错，不会静默失效）。 */
  const SPECIAL = {
    ' ': 'Space',
    'Escape': 'Esc',
    'ArrowUp': 'Up',
    'ArrowDown': 'Down',
    'ArrowLeft': 'Left',
    'ArrowRight': 'Right',
    'PageUp': 'PgUp',
    'PageDown': 'PgDn',
    'ContextMenu': 'AppsKey'
  };
  const MODIFIER_KEYS = ['Control', 'Shift', 'Alt', 'Meta'];

  function toAhk(e) {
    if (MODIFIER_KEYS.indexOf(e.key) >= 0) return null;
    let s = '';
    if (e.ctrlKey) s += '^';
    if (e.altKey) s += '!';
    if (e.shiftKey) s += '+';
    if (e.metaKey) s += '#';

    let k = e.key;
    if (k.length === 1) {
      k = k.toLowerCase();
      if (k === ' ') k = 'Space';
    } else {
      k = SPECIAL[k] || k;
    }

    // 裸字母当热键会抢走正常打字，必须带修饰键；F1~F24 例外
    if (!s && !/^F\d{1,2}$/.test(k)) return '';
    return s + k;
  }

  document.querySelectorAll('.hk').forEach(inp => {
    inp.addEventListener('focus', () => inp.classList.add('recording'));
    inp.addEventListener('blur', () => inp.classList.remove('recording'));

    inp.addEventListener('keydown', e => {
      if (e.key === 'Tab') return;                 // 保留 Tab 换焦点
      e.preventDefault();
      if (e.key === 'Backspace' || e.key === 'Delete') {
        inp.value = '';
        return;
      }
      const combo = toAhk(e);
      if (combo === null) return;                  // 只按了修饰键，继续等
      if (combo === '') {
        status('快捷键要带 Ctrl / Alt / Win，或者用 F1~F24', true);
        return;
      }
      inp.value = combo;
      status('');
    });
  });

  document.querySelectorAll('.clear').forEach(btn => {
    btn.addEventListener('click', () => {
      const box = $(btn.getAttribute('data-for'));
      if (box) box.value = '';
    });
  });

  /* ---- 按钮 ------------------------------------------------------------- */

  /* 字段一律平铺在消息顶层：宿主的 json.ahk 只认扁平结构，
     嵌套一个 vals 的话要另写一套解析，不值当 */
  function saveMsg() {
    return Object.assign({ type: 'save' }, collect());
  }

  $('btnSave').addEventListener('click', () => send(saveMsg()));
  $('btnCancel').addEventListener('click', () => send({ type: 'close' }));
  $('btnClose').addEventListener('click', () => send({ type: 'close' }));

  $('btnReset').addEventListener('click', () => {
    $('transparent').checked = true;
    $('fontSize').value = 15;
    $('showAllOnStart').checked = false;
    $('openListOnStart').checked = false;
    defColor = 'yellow';
    paintSwatches();
    $('hkNew').value = '^!n';
    $('hkList').value = '^!l';
    $('hkToggle').value = '^!h';
    $('smtpOn').checked = false;
    $('smtpHost').value = '';
    $('smtpPort').value = 465;
    $('smtpUser').value = '';
    $('smtpPass').value = '';
    $('smtpFrom').value = '';
    $('smtpTo').value = '';
    $('smtpTimeout').value = 20;
    $('autostart').checked = false;
    status('已填入默认值，点保存生效（授权码不会被清掉）');
  });

  /* 测试邮件：把当前表单值一起发过去（先存再发）。
     不先保存的话，用户改了主机/账号点测试，测的还是旧配置。 */
  $('btnSmtpTest').addEventListener('click', () => {
    status('正在发送，最多等 20 秒…');
    send(Object.assign({ type: 'smtpTest' }, collect()));
  });

  $('btnDataDir').addEventListener('click', () => send({ type: 'dataDir' }));
  $('btnLog').addEventListener('click', () => send({ type: 'log' }));

  document.addEventListener('keydown', e => {
    if (e.key === 'Escape') send({ type: 'close' });
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's') {
      e.preventDefault();
      send(saveMsg());
    }
  });

  // 顶栏拖动：交给宿主的系统移动循环（和列表窗口一套）
  const head = $('head');
  head.addEventListener('mousedown', e => {
    if (e.button !== 0 || e.target.closest('button')) return;
    send({ type: 'drag-start' });
  });

  send({ type: 'ready' });
})();
