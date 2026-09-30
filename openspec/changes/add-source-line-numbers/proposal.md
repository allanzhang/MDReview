## Why

源码视图（`View Source` / 工具栏切换）当前只显示纯文本。用户反馈在阅读器里核对 Markdown 原文时，无法快速指认"第几行"——讨论、给 AI 提问、比对外部编辑器改动时都要手动数行。渲染态的代码块已有行号栏（`reader.css` 的 `.code-gutter`），源码视图是唯一缺口。

## What Changes

- 源码视图左侧增加行号栏，常开不可关闭，与渲染态代码块行号栏的视觉语言一致（等宽字体、右对齐、灰色、不可选中）。
- 行号按**逻辑行**编号。长行软换行时只在首个视觉行标号，续行留空。
- 行号栏宽度随文档位数自适应，文本左边距同步让位。
- 选区覆盖的行整行高亮；跨软换行的行覆盖全部片段；行号栏中当前行的行号转为强调色。
- 高亮随点选、拖选、全文搜索跳转同步更新。
- 行号栏不接管命中测试，点击行号区域仍可正常选中文本。
- 暗色 / 亮色外观下配色跟随切换。

## Capabilities

### New Capabilities

- `source-line-numbers`: 管理源码视图的行号编号、行号栏布局与绘制、当前行高亮同步。

### Modified Capabilities

无。

## Impact

- `Sources/SourceLineIndex.swift`（新增）：纯 Foundation 行首下标索引与二分查询，可独立单测。
- `Sources/ContentView.swift`：`ThemedTextView` 增加当前行高亮绘制；新增 `SourceLineLayout`（行片段到行号与文本坐标的换算）与 `LineNumberGutterView`；`SourceTextCoordinator` 增加选区回调、尺寸同步与外观配色。
- 渲染端（`MarkdownRenderer.swift` / `reader.css`）、`DocState`、导出链路不受影响。
- 无新增依赖、无新增本地化文案。

### 已知偏离（非规格先行）

本 change 为实现完成后追认。L1/L2 未在实现前执行，属流程违规，补此文档是为让规格与代码一致，不作为流程合规证明。详见 `tasks.md` 的 Gate Summary。
