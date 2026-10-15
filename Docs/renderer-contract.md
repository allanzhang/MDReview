# Renderer Contract

## 目的

渲染器是只读 Markdown 阅读体验的核心。本契约把“应该支持什么、允许偏离什么、改动如何验证”固定下来，避免只靠发布后人工发现解析缺陷。

## 基线

- 标准基线：**CommonMark 0.31.2**，官方 652 条 examples 固定在 `Tests/fixtures/commonmark/spec.json`。
- 渲染核心：仓库内置的 `Sources/Resources/markdown-it.min.js`。
- App 默认配置：

```js
{ html: true, linkify: true, typographer: false, breaks: false }
```

- CommonMark 一致性测试使用：

```js
{ html: true, linkify: false, typographer: false, breaks: false, xhtmlOut: true }
```

`xhtmlOut` 只用于匹配 CommonMark 参考输出的 `<br />` / `<hr />` 序列化形式，不改变解析规则。

## 支持的语法层

1. **CommonMark 核心**：标题、段落、引用、列表、代码块、行内代码、链接、图片、强调、转义、HTML 等。
2. **markdown-it 内置 GFM/常用能力**：表格、双波浪线删除线、自动链接；普通换行保持软换行，不自动替换标点。
3. **App 扩展插件**：emoji、`==高亮==`、上标、定义列表、脚注。
4. **App 自定义规则**：
   - `math`：`$...$` / `$$...$$` 交给 KaTeX，闭合符遵守解析范围及转义。
   - `tilde`：独立单波浪线中的数字 `H~2~O` 转下标；其他单波浪线保留原文，不借用双波浪线。
   - `task_lists`：解析阶段识别列表首段的任务标记，复选框只读；转义或实体产生的标记保留原文。
   - `validateLink`：放行合法 `data:image/*`，继续拦截 `javascript:`、`vbscript:`、`file:`。

## 规则优先级

- 粗体、斜体、链接、代码等由 markdown-it 的标准规则解析，不再使用标点粗体兜底。
- 自定义行内规则必须遵守 `posMax`；静默探测返回成功时也必须推进解析位置。
- `^[` 入口优先作为行内脚注处理，脚注正文仍支持上标、下标及数学公式。
- 正文、大纲与章节分块复用同一次解析的 tokens 和 env，只在安全顶层块边界切分；标题 ID 在渲染前统一生成。
- 公式标题的大纲使用公式源码文字，避免纯公式标题变为空白。

## CommonMark 已知差异

`Tests/fixtures/commonmark/divergences.json` 是专用 CommonMark profile 的允许差异清单，当前有 3 条等价 HTML 序列化差异；App profile 启用的插件扩展另由回归测试覆盖，不能用此清单代表全部 App 行为。

| Example | 类型 | 说明 |
|---|---|---|
| 218 / 239 / 240 | HTML 序列化 | markdown-it 的空 blockquote 不输出内部换行；浏览器渲染等价。 |

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
