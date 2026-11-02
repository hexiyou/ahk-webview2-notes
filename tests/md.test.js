/* ============================================================================
   md.test.js —— Markdown 渲染/转换的单元测试（node 直接跑，无需浏览器）

   跑法：node tests/md.test.js
   ========================================================================== */

const MD = require('../ui/md.js');

let pass = 0, fail = 0;
const failures = [];

function eq(name, actual, expected) {
  if (actual === expected) { pass++; return; }
  fail++;
  failures.push(`${name}\n    期望: ${JSON.stringify(expected)}\n    实际: ${JSON.stringify(actual)}`);
}

function ok(name, cond, detail) {
  if (cond) { pass++; return; }
  fail++;
  failures.push(`${name}${detail ? '  (' + detail + ')' : ''}`);
}

function has(name, html, frag) {
  ok(name, html.indexOf(frag) >= 0, '缺少 ' + JSON.stringify(frag) + ' → ' + html.slice(0, 90));
}

function hasNot(name, html, frag) {
  ok(name, html.indexOf(frag) < 0, '不应出现 ' + JSON.stringify(frag) + ' → ' + html.slice(0, 90));
}

/* ---- 标题 --------------------------------------------------------------- */
eq('h1', MD.render('# 标题'), '<h1>标题</h1>');
eq('h2', MD.render('## 二级'), '<h2>二级</h2>');
eq('h3', MD.render('### 三级'), '<h3>三级</h3>');
has('h4 降到 h3', MD.render('#### 四级'), '<h3>四级</h3>');
has('标题尾部 # 去掉', MD.render('## 标题 ##'), '<h2>标题</h2>');

/* ---- 行内 --------------------------------------------------------------- */
eq('粗体', MD.render('**粗**'), '<p><strong>粗</strong></p>');
eq('粗体下划线语法', MD.render('__粗__'), '<p><strong>粗</strong></p>');
eq('斜体', MD.render('*斜*'), '<p><em>斜</em></p>');
eq('删除线', MD.render('~~删~~'), '<p><del>删</del></p>');
eq('行内代码', MD.render('`x = 1`'), '<p><code>x = 1</code></p>');
has('行内代码里的星号不当格式', MD.render('`a**b**c`'), '<code>a**b**c</code>');
eq('粗斜体混排', MD.render('**粗** 和 *斜*'), '<p><strong>粗</strong> 和 <em>斜</em></p>');

/* ---- 转义与安全 --------------------------------------------------------- */
has('尖括号被转义', MD.render('<script>alert(1)</script>'), '&lt;script&gt;');
hasNot('不产出 script 标签', MD.render('<script>alert(1)</script>'), '<script>');
has('引号被转义', MD.render('他说"你好"'), '&quot;');
hasNot('javascript: 链接被降级', MD.render('[点我](javascript:alert(1))'), 'href="javascript');
eq('javascript 链接只留文字', MD.render('[点我](javascript:alert(1))'), '<p>点我</p>');
has('https 链接可点', MD.render('[官网](https://example.com)'), 'href="https://example.com"');
has('链接带 target', MD.render('[a](https://a.b)'), 'target="_blank"');
hasNot('data:text 图片被拦', MD.render('![x](data:text/html;base64,AAA)'), '<img');
has('data:image 图片放行', MD.render('![x](data:image/png;base64,AAA)'), '<img');
has('裸链接自动识别', MD.render('访问 https://a.b 看看'), '<a href="https://a.b"');

/* ---- 块级 --------------------------------------------------------------- */
has('引用', MD.render('> 引用一句'), '<blockquote>引用一句</blockquote>');
has('分割线', MD.render('---'), '<hr>');
has('代码块', MD.render('```\nlet a = 1\n```'), '<pre><code>let a = 1</code></pre>');
has('代码块内容转义', MD.render('```\nif (a < b) {}\n```'), 'if (a &lt; b) {}');
has('无序列表', MD.render('- 一\n- 二'), '<ul><li>一</li><li>二</li></ul>');
has('星号列表', MD.render('* 一'), '<ul><li>一</li></ul>');
has('有序列表', MD.render('1. 一\n2. 二'), '<ol><li>一</li><li>二</li></ol>');
has('任务未完成', MD.render('- [ ] 待办'), 'data-checked="0"');
has('任务已完成', MD.render('- [x] 做完了'), 'data-checked="1"');
has('任务行标记完成', MD.render('- [X] 大写X'), 'data-done="1"');
has('表格', MD.render('| a | b |\n|---|---|\n| 1 | 2 |'), '<table>');
has('表格表头', MD.render('| a | b |\n|---|---|\n| 1 | 2 |'), '<th>a</th>');
has('表格数据', MD.render('| a | b |\n|---|---|\n| 1 | 2 |'), '<td>1</td>');
eq('段落内换行变 br', MD.render('第一行\n第二行'), '<p>第一行<br>第二行</p>');
eq('空行分段', MD.render('第一段\n\n第二段'), '<p>第一段</p><p>第二段</p>');
eq('空输入', MD.render(''), '');
eq('null 输入', MD.render(null), '');

/* ---- plain / title ------------------------------------------------------ */
eq('plain 去标记', MD.plain('**粗** 与 *斜*'), '粗 与 斜');
eq('plain 去标题号', MD.plain('## 标题\n正文'), '标题\n正文');
eq('plain 去列表符', MD.plain('- 一\n- 二'), '一\n二');
eq('plain 保留链接文字', MD.plain('[官网](https://a.b)'), '官网');
eq('plain 去代码块', MD.plain('```\ncode\n```\n正文').trim(), '正文');
eq('title 取第一行', MD.title('第一行\n第二行', true), '第一行');
eq('title 去标记', MD.title('# 大标题', true), '大标题');
eq('title 空', MD.title('', true), '');
ok('title 截断到 60 字', MD.title('很'.repeat(100), true).length <= 61);
ok('title 带省略号', MD.title('很'.repeat(100), true).endsWith('…'));

/* ---- 往返：html -> md -> html 的稳定性 ---------------------------------- */
// toMarkdown 依赖 DOM，node 里跳过；这里只验证 render 的幂等性
const once = MD.render('# 标题\n\n- [x] 完成\n- [ ] 未完成\n\n**粗** 和 `code`');
const twice = MD.render(MD.plain(once));
ok('重复渲染不崩', typeof twice === 'string' && twice.length > 0);

/* ---- 边界：不应死循环或抛异常 ------------------------------------------ */
const weird = [
  '```', '~~~', '|', '||', '- [', '**', '``', '\\', '\u0000', '#'.repeat(70),
  '> > >', '- - -', 'a\n'.repeat(50), '  ```js\n  var a\n  ```'
];
for (const w of weird) {
  try {
    const r = MD.render(w);
    ok('边界输入不抛异常: ' + JSON.stringify(w.slice(0, 12)), typeof r === 'string');
  } catch (e) {
    fail++;
    failures.push('边界输入抛异常: ' + JSON.stringify(w.slice(0, 12)) + ' → ' + e.message);
  }
}

/* ---- 代码块的语言标记 ---------------------------------------------------
   语言要写成 class="language-x"（highlight.js 认这个），同时留一份 data-lang
   给页面"改语言"时读回来。 */
has('代码块带语言 class', MD.render('```js\nlet a = 1\n```'), 'class="language-js"');
has('代码块带 data-lang', MD.render('```python\nx = 1\n```'), 'data-lang="python"');
has('没有语言就不加属性', MD.render('```\nplain\n```'), '<pre><code>');
eq('语言标记不影响正文', MD.render('```js\nlet a = 1\n```'),
  '<pre><code class="language-js" data-lang="js">let a = 1</code></pre>');
has('c++ 这种带符号的语言也认', MD.render('```c++\nint a;\n```'), 'language-c++');

/* preText：代码块里如果混进 <br>（用户按回车时 Chromium 插的），
   必须折成换行，否则导出的 Markdown 会把整个块挤成一行。
   这里用假节点树，node 里没有 DOM。 */
function fakeNode(tag, kids) { return { nodeType: 1, tagName: tag, childNodes: kids }; }
function fakeText(s) { return { nodeType: 3, nodeValue: s }; }
const fakePre = fakeNode('PRE', [
  fakeText('a = 1'), fakeNode('BR', []), fakeText('b = 2'),
  fakeNode('SPAN', [fakeText(' # 注释')]), fakeNode('BR', [])
]);
eq('preText 把 <br> 折成换行', MD.preText(fakePre), 'a = 1\nb = 2 # 注释\n');
eq('preText 空块', MD.preText(fakeNode('PRE', [])), '');
console.log('');
if (fail) {
  for (const f of failures) console.log('  FAIL  ' + f);
  console.log('');
}
console.log(`md.test.js  PASS ${pass}  FAIL ${fail}`);
process.exit(fail ? 1 : 0);
