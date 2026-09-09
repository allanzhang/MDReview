# Renderer Contract

## 目的

渲染器是只读 Markdown 阅读体验的核心。本契约把“应该支持什么、允许偏离什么、改动如何验证”固定下来，避免只靠发布后人工发现解析缺陷。

## 基线

- 标准基线：**CommonMark 0.31.2**，官方 652 条 examples 固定在 `Tests/fixtures/commonmark/spec.json`。
- 渲染核心：仓库内置的 `Sources/Resources/markdown-it.min.js`。
- App 默认配置：

```js
{ html: true, linkify: true, typographer: true, breaks: true }
```

- CommonMark 一致性测试使用：

```js
{ html: true, linkify: false, typographer: false, breaks: false, xhtmlOut: true }
```

`xhtmlOut` 只用于匹配 CommonMark 参考输出的 `<br />` / `<hr />` 序列化形式，不改变解析规则。

## 支持的语法层

1. **CommonMark 核心**：标题、段落、引用、列表、代码块、行内代码、链接、图片、强调、转义、HTML 等。
2. **markdown-it 内置 GFM/常用能力**：表格、任务列表、删除线、自动链接、软换行转 `<br>`。
3. **App 扩展插件**：emoji、`==高亮==`、上标、定义列表、脚注。
4. **App 自定义行内规则**：
   - `punct_strong`：修复 `**"..."**`、`**（...）**` 等首尾紧邻 Unicode 标点时的粗体配对。
   - `math`：`$...$` / `$$...$$` 交给 KaTeX。
   - `tilde`：数字内容 `H~2~O` 转下标，其他 `~文字~` 转删除线。
   - `validateLink`：放行合法 `data:image/*`，继续拦截 `javascript:`、`vbscript:`、`file:`。

## 规则优先级

- 普通粗体、斜体、链接、代码等优先由 markdown-it 的标准规则解析。
- `punct_strong` 只在标准 flanking 规则无法配对，且粗体内容首尾紧邻 Unicode 标点（P/S 类）时接管。
- 三连星及以上、转义分隔符、代码跨度、嵌套链接/斜体/代码等由回归语料固定，防止兜底规则改变标准语义。
- 自定义规则出现异常时应回退到 markdown-it 默认行为，不能阻止正文渲染。

## CommonMark 已知差异

`Tests/fixtures/commonmark/divergences.json` 是唯一的允许差异清单。当前有 5 条：

| Example | 类型 | 说明 |
|---|---|---|
| 218 / 239 / 240 | HTML 序列化 | markdown-it 的空 blockquote 不输出内部换行；浏览器渲染等价。 |
| 380 | App 扩展 | `punct_strong` 会渲染 CommonMark 保留为字面量的引号粗体。 |
| 392 | App 扩展 | `punct_strong` 会渲染 CommonMark 保留为字面量的标点-only 粗体。 |

新增偏差必须同时满足：测试实际输出与文档说明一致、修改契约、说明为什么不能回到 CommonMark 行为。未登记的偏差会导致 CI 失败。

## 明确不支持

- MDX / JSX、Vue SFC、React 组件语法。
- YAML / TOML front matter 的特殊编辑或结构化渲染。
- Obsidian wiki link（`[[...]]`）、块引用嵌入、Dataview。
- Markdown 目录中的可编辑语法校验；本 App 是只读审阅器。
- 对任意 HTML 做安全净化；App 仅面向用户主动打开的本地文档。

## 修改门禁

任何渲染行为改动必须附带：

1. 最小复现 Markdown。
2. 对应的 `Tests/fixtures/renderer/*.json` golden case，或 CommonMark divergence 记录。
3. `node Tests/run.js` 通过。
4. `xcodebuild` 通过。
5. 行为变化同步更新本文档。

禁止只改测试期望来让旧行为“通过”。如果实现无法满足既有契约，应先说明原因并更新契约，再改代码。

## 验证边界

`Tests/run.js` 会从 `MarkdownRenderer.swift` 提取真实的 `jsRenderInline` 规则，并在 Node 中加载仓库内置的 markdown-it、插件和 KaTeX。因此它能验证真实解析规则与 JS 执行结果，但不会启动 WKWebView。

涉及页面注入、CSS、DOM 事件、WKWebView 消息通道或分块渲染的改动，除 CI 构建外仍需在 App 中做一次真实文档 smoke test；纯解析规则改动由本测试套件覆盖。
